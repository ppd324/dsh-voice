'use strict';
// DSH Voice control panel: zero-dependency local server.
// Serves the configuration UI and runs component installs with live progress.
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const crypto = require('node:crypto');
const { URL } = require('node:url');

const ROOT = path.resolve(__dirname, '..');            // .../voice
const PUB = path.join(__dirname, 'public');
const CONFIG_PATH = path.join(ROOT, 'config.json');
const HOME = process.env.USERPROFILE || process.env.HOME || '';
const DSH_HOME = process.env.DSH_HOME || path.join(HOME, '.dsh');

const PORT = Number(process.env.DSH_VOICE_GUI_PORT || 7788);

// ---------------------------------------------------------------- utilities
function readJson(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}
function writeJson(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(data, null, 2), 'utf8');
}
function run(cmd, args, opts = {}) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { windowsHide: true, ...opts });
    let out = '', err = '';
    child.stdout?.on('data', (d) => { out += d; opts.onData?.(d.toString(), 'out'); });
    child.stderr?.on('data', (d) => { err += d; opts.onData?.(d.toString(), 'err'); });
    child.on('error', (e) => resolve({ code: -1, out, err: err + e.message }));
    child.on('close', (code) => resolve({ code, out, err }));
  });
}

// ---------------------------------------------------------------- components
const MODEL_DIR = path.join(DSH_HOME, 'speech-to-text', 'sensevoice', 'models');
const MODEL_FILES = [
  { name: 'tokens.txt', dir: 'sensevoice-onnx', bytes: 315894,
    sha: 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc',
    urls: ['https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07/tokens.txt'] },
  { name: 'silero_vad.onnx', dir: 'silero', bytes: 1807522,
    sha: 'a35ebf52fd3ce5f1469b2a36158dba761bc47b973ea3382b3186ca15b1f5af28',
    urls: ['https://hf-mirror.com/csukuangfj/vad/resolve/fba88cd2e921609e7675c3aaf51e0b9b295da4bc/silero_vad.onnx'] },
  { name: 'model.int8.onnx', dir: 'sensevoice-onnx', bytes: 239233841,
    sha: 'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51',
    urls: ['https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07/model.int8.onnx'] },
];

// Pair each friendly device name with its dshow "Alternative name" (the stable id).
async function listMicrophones(ffmpeg) {
  if (!ffmpeg) return [];
  const r = await run(ffmpeg, ['-hide_banner', '-list_devices', 'true', '-f', 'dshow', '-i', 'dummy']);
  const lines = (r.err || '').split(/\r?\n/);
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/"([^"]+)"\s*\(audio\)/);
    if (!m) continue;
    const name = m[1];
    let alt = '';
    for (let j = i + 1; j < Math.min(i + 3, lines.length); j++) {
      const a = lines[j].match(/Alternative name "([^"]+)"/);
      if (a) { alt = a[1]; break; }
    }
    out.push({ name, alt: alt || name });
  }
  return out;
}

// Render endpoints via NAudio (bundled under bin/naudio). Cached: devices rarely change.
let speakerCache = { at: 0, list: [] };

async function listSpeakers(pwsh) {
  const now = Date.now();
  if (now - speakerCache.at < 30000 && speakerCache.list.length) return speakerCache.list;
  const script = path.join(__dirname, 'list-speakers.ps1');
  const r = await run(pwsh || 'powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script]);
  const list = (r.out || '').split(/\r?\n/).map((l) => l.trim()).filter(Boolean).map((l) => {
    const [name, id, def] = l.split('|');
    return { name, id, isDefault: def === '1' };
  }).filter((d) => d.id);
  if (list.length) speakerCache = { at: now, list };
  return list.length ? list : speakerCache.list;
}

function hashOf(file) {
  return new Promise((resolve) => {
    const h = crypto.createHash('sha256');
    const s = fs.createReadStream(file);
    s.on('data', (d) => h.update(d));
    s.on('end', () => resolve(h.digest('hex')));
    s.on('error', () => resolve(''));
  });
}

async function findDsh() {
  const candidates = [
    process.env.DSH_EXE,
    'D:/dsh/DeepSeek Harness.exe',
    path.join(process.env.LOCALAPPDATA || '', 'Programs', 'DeepSeek Harness', 'DeepSeek Harness.exe'),
    path.join(process.env.ProgramFiles || '', 'DeepSeek Harness', 'DeepSeek Harness.exe'),
  ].filter(Boolean);
  for (const c of candidates) if (fs.existsSync(c)) return c;
  const where = await run('where.exe', ['dsh']);
  const first = (where.out || '').split(/\r?\n/).map((s) => s.trim()).filter(Boolean)[0];
  if (first && fs.existsSync(first)) return first;
  // registry fallback: uninstall entries carry InstallLocation
  const reg = await run('powershell.exe', ['-NoProfile', '-Command',
    "$p=@('HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*','HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*');" +
    "Get-ItemProperty $p -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*DeepSeek Harness*' } | Select-Object -First 1 -ExpandProperty InstallLocation"]);
  const loc = (reg.out || '').trim();
  if (loc) {
    const exe = path.join(loc, 'DeepSeek Harness.exe');
    if (fs.existsSync(exe)) return exe;
  }
  return '';
}

let versionCache = { at: 0, exe: '', version: '' };
async function dshVersion(exe) {
  if (!exe) return '';
  const now = Date.now();
  if (versionCache.exe === exe && now - versionCache.at < 300000) return versionCache.version;
  let version = '';
  const bin = path.join(path.dirname(exe), 'resources', 'app.asar', 'dsh', 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js');
  if (fs.existsSync(bin)) {
    const r = await run(exe, [bin, '--version'], { env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' } });
    version = (r.out || '').trim().split(/\r?\n/).pop() || '';
    if (!/^\d+\./.test(version)) version = '';
  }
  if (!version) {
    // fallback: the uninstall entry carries the installed version
    const reg = await run('powershell.exe', ['-NoProfile', '-Command',
      "$p=@('HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*','HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*');" +
      "(Get-ItemProperty $p -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*DeepSeek Harness*' } | Select-Object -First 1).DisplayVersion"]);
    const v = (reg.out || '').trim();
    if (/^\d+\./.test(v)) version = v;
  }
  versionCache = { at: now, exe, version };
  return version;
}

// account readiness: the CLI fails with a credential error when signed out
let accountCache = { at: 0, ok: false };
async function accountReady(exe) {
  if (!exe) return false;
  const now = Date.now();
  if (now - accountCache.at < 300000) return accountCache.ok;
  // the CLI stores the signed-in account next to its home directory
  let ok = false;
  for (const f of ['.credentials.yaml', 'credentials.json', 'auth.json']) {
    const p = path.join(DSH_HOME, f);
    try { if (fs.statSync(p).size > 0) { ok = true; break; } } catch {}
  }
  if (!ok) {
    const bin = path.join(path.dirname(exe), 'resources', 'app.asar', 'dsh', 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js');
    if (fs.existsSync(bin)) {
      const r = await run(exe, [bin, '--profile', 'voice', '--dump-config'],
        { env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' } });
      const all = (r.out || '') + (r.err || '');
      ok = r.code === 0 && !/MISSING_CREDENTIAL|ACCOUNT_SIGN_IN_REQUIRED|no API key/i.test(all);
    }
  }
  accountCache = { at: now, ok };
  return ok;
}

let detectCache = { at: 0, data: null };
async function detect() {
  if (detectCache.data && Date.now() - detectCache.at < 6000) return detectCache.data;
  const cfg = readJson(CONFIG_PATH, {});
  const dshExe = await findDsh();
  const version = await dshVersion(dshExe);
  const signedIn = await accountReady(dshExe);

  const modelOk = [];
  for (const f of MODEL_FILES) {
    const p = path.join(MODEL_DIR, f.dir, f.name);
    const ok = fs.existsSync(p) && fs.statSync(p).size === f.bytes;
    modelOk.push({ ...f, path: p, ok });
  }

  const ffmpeg = cfg.ffmpeg && fs.existsSync(cfg.ffmpeg) ? cfg.ffmpeg : '';
  const python = cfg?.tts?.python && fs.existsSync(cfg.tts.python) ? cfg.tts.python : '';
  let edgeTts = false;
  if (python) {
    const r = await run(python, ['-c', 'import edge_tts; print("ok")']);
    edgeTts = (r.out || '').includes('ok');
  }

  const profileDir = path.join(DSH_HOME, 'profiles', 'voice');
  const pluginOk = fs.existsSync(path.join(profileDir, 'node_modules', 'dsh-windows-mcp'));
  const toolchainRoot = path.join(DSH_HOME, 'dsh-windows-mcp', 'toolchain');
  let toolchain = '';
  try {
    for (const d of fs.readdirSync(toolchainRoot)) {
      const exe = path.join(toolchainRoot, d, 'windows-mcp', 'Scripts', 'windows-mcp.exe');
      if (fs.existsSync(exe)) toolchain = exe;
    }
  } catch {}

  const microphones = await listMicrophones(ffmpeg);
  const speakers = await listSpeakers(cfg.pwsh);
  const micDevice = cfg.audioDevice || '';
  const currentMic = microphones.find((m) => m.alt === micDevice || m.name === micDevice);

  const data = {
    config: cfg,
    components: [
      { id: 'dsh', name: 'DSH 运行时', required: true, ok: !!dshExe, detail: dshExe ? `${dshExe}  版本 ${version || '未知'}` : '未找到安装', action: dshExe ? null : 'guide', guide: 'https://github.com/deepseek-ai/deepseek-harness' },
      { id: 'model', name: '语音识别模型 (SenseVoice)', required: true, ok: modelOk.every((m) => m.ok), detail: modelOk.every((m) => m.ok) ? '已安装并校验通过' : `缺 ${modelOk.filter((m) => !m.ok).length} 个文件, 共 231 MB`, action: 'install', bytes: 231 },
      { id: 'ffmpeg', name: 'ffmpeg', required: true, ok: !!ffmpeg, detail: ffmpeg || '未找到', action: 'detect' },
      { id: 'python', name: 'Python', required: true, ok: !!python, detail: python || '未找到', action: 'detect' },
      { id: 'edge-tts', name: '神经语音 (edge-tts)', required: true, ok: edgeTts, detail: edgeTts ? '已安装' : '未安装', action: 'install' },
      { id: 'mcp-plugin', name: 'Windows-MCP 插件', required: true, ok: pluginOk, detail: pluginOk ? '已装在 voice profile' : '未安装', action: 'install' },
      { id: 'mcp-toolchain', name: 'MCP 工具链', required: true, ok: !!toolchain, detail: toolchain || '未安装(在 DSH 插件页安装一次)', action: toolchain ? null : 'guide', guide: '' },
      { id: 'speaker', name: '扬声器', required: true, ok: speakers.length > 0, action: 'select',
        detail: (() => {
          const cur = speakers.find((d) => d.id === cfg.speakerId);
          if (cur) return '当前: ' + cur.name;
          const def = speakers.find((d) => d.isDefault);
          return def ? ('当前: 跟随系统默认 · ' + def.name) : '未选择';
        })(),
        devices: speakers, current: cfg.speakerId || '' },
      { id: 'mic', name: '麦克风', required: true, ok: !!currentMic, action: 'select',
        detail: currentMic ? ('当前: ' + currentMic.name) : '未选择或设备已拔出',
        devices: microphones, current: currentMic ? currentMic.alt : micDevice },
      { id: 'account', name: 'DSH 账号', required: true, ok: signedIn, detail: signedIn ? '已登录, 可直接使用' : '未登录: 在 DSH 里登录一次即可', action: signedIn ? null : 'guide', guide: '' },
    ],
    running: isDaemonRunning(),
  };
  detectCache = { at: Date.now(), data };
  return data;
}

function isDaemonRunning() {
  try {
    const pid = Number(fs.readFileSync(path.join(ROOT, 'daemon.pid'), 'utf8').trim());
    process.kill(pid, 0);
    return pid;
  } catch { return 0; }
}

// ---------------------------------------------------------------- tasks
const tasks = new Map();
let taskSeq = 0;
function newTask(component) {
  const id = `t${++taskSeq}`;
  const t = { id, component, status: 'running', percent: 0, bytes: 0, total: 0, message: '准备中…', log: [] };
  tasks.set(id, t);
  return t;
}
function logTask(t, line) {
  const s = String(line).trim();
  if (!s) return;
  t.log.push(s.slice(0, 400));
  if (t.log.length > 200) t.log.shift();
}

function download(url, dest, t, label) {
  return new Promise((resolve, reject) => {
    const tmp = dest + '.part';
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    const req = http.get(url, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume();
        return download(res.headers.location, dest, t, label).then(resolve, reject);
      }
      if (res.statusCode !== 200) { res.resume(); return reject(new Error(`HTTP ${res.statusCode}`)); }
      const total = Number(res.headers['content-length'] || 0);
      let got = 0;
      const out = fs.createWriteStream(tmp);
      res.on('data', (d) => {
        got += d.length;
        t.bytes += d.length;
        if (t.total) t.percent = Math.min(99, Math.round((t.bytes / t.total) * 100));
        t.message = `${label} ${(got / 1048576).toFixed(1)} MB${total ? ' / ' + (total / 1048576).toFixed(1) + ' MB' : ''}`;
      });
      res.pipe(out);
      out.on('finish', () => { out.close(() => { fs.renameSync(tmp, dest); resolve(dest); }); });
      out.on('error', reject);
    });
    req.on('error', reject);
    req.setTimeout(60000, () => req.destroy(new Error('timeout')));
  });
}

async function installModel(t) {
  t.total = MODEL_FILES.reduce((a, f) => a + f.bytes, 0);
  for (const f of MODEL_FILES) {
    const dest = path.join(MODEL_DIR, f.dir, f.name);
    if (fs.existsSync(dest) && fs.statSync(dest).size === f.bytes) { logTask(t, `已存在 ${f.name}`); t.bytes += f.bytes; continue; }
    logTask(t, `下载 ${f.name}`);
    await download(f.urls[0], dest, t, f.name);
    const h = await hashOf(dest);
    if (h !== f.sha) { fs.unlinkSync(dest); throw new Error(`${f.name} 校验失败`); }
    logTask(t, `校验通过 ${f.name}`);
  }
  t.percent = 100;
}

async function installEdgeTts(t) {
  const cfg = readJson(CONFIG_PATH, {});
  const python = cfg?.tts?.python;
  if (!python || !fs.existsSync(python)) throw new Error('先找到 Python');
  logTask(t, 'pip install edge-tts');
  const r = await run(python, ['-m', 'pip', 'install', '--quiet', 'edge-tts'], { onData: (d) => logTask(t, d) });
  if (r.code !== 0) throw new Error('pip 安装失败');
  t.percent = 100;
}

async function installMcpPlugin(t) {
  const node = path.join(DSH_HOME, 'dsh-runtimes', 'dsh-primary-runtime', 'dependencies', 'node', 'bin', 'node.exe');
  const pnpm = path.join(DSH_HOME, 'dsh-runtimes', 'dsh-primary-runtime', 'dependencies', 'pnpm', 'bin', 'pnpm.mjs');
  const profile = path.join(DSH_HOME, 'profiles', 'voice');
  if (!fs.existsSync(node) || !fs.existsSync(pnpm)) throw new Error('找不到 DSH 自带的 node/pnpm');
  fs.mkdirSync(profile, { recursive: true });
  logTask(t, 'pnpm add dsh-windows-mcp');
  const r = await run(node, [pnpm, 'add', 'dsh-windows-mcp'], { cwd: profile, onData: (d) => logTask(t, d) });
  if (r.code !== 0) throw new Error('插件安装失败');
  t.percent = 100;
}

function startInstall(component) {
  const t = newTask(component);
  const job = (async () => {
    try {
      if (component === 'model') await installModel(t);
      else if (component === 'edge-tts') await installEdgeTts(t);
      else if (component === 'mcp-plugin') await installMcpPlugin(t);
      else throw new Error('该组件暂不支持自动安装');
      t.status = 'done'; t.message = '完成'; t.percent = 100;
    } catch (e) {
      t.status = 'error'; t.message = e.message || String(e);
      logTask(t, 'ERROR ' + t.message);
    }
  })();
  job.catch(() => {});
  return t;
}

// ---------------------------------------------------------------- http
function send(res, code, type, body) {
  res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store' });
  res.end(body);
}
function json(res, code, obj) { send(res, code, 'application/json; charset=utf-8', JSON.stringify(obj)); }

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.png': 'image/png', '.svg': 'image/svg+xml' };

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`);
  try {
    if (url.pathname === '/api/state') return json(res, 200, await detect());

    if (url.pathname === '/api/install' && req.method === 'POST') {
      const body = await new Promise((r) => { let b = ''; req.on('data', (d) => (b += d)); req.on('end', () => r(b)); });
      const { component } = JSON.parse(body || '{}');
      return json(res, 200, startInstall(component));
    }

    if (url.pathname.startsWith('/api/task/')) {
      const id = url.pathname.split('/').pop();
      const t = tasks.get(id);
      return t ? json(res, 200, t) : json(res, 404, { error: 'no such task' });
    }

    if (url.pathname === '/api/config') {
      if (req.method === 'GET') return json(res, 200, readJson(CONFIG_PATH, {}));
      const body = await new Promise((r) => { let b = ''; req.on('data', (d) => (b += d)); req.on('end', () => r(b)); });
      const incoming = JSON.parse(body);
      const current = readJson(CONFIG_PATH, {});
      // merge the nested objects we edit, so a partial payload cannot drop keys
      const cfg = Object.assign({}, current, incoming);
      cfg.tts = Object.assign({}, current.tts || {}, incoming.tts || {});
      cfg.corrections = Object.assign({}, current.corrections || {}, incoming.corrections || {});
      cfg.aliases = Object.assign({}, current.aliases || {}, incoming.aliases || {});
      writeJson(CONFIG_PATH, cfg);
      fs.writeFileSync(path.join(ROOT, 'reload.flag'), String(Date.now()));
      return json(res, 200, { ok: true, reload: true });
    }

    if (url.pathname === '/api/orb' && req.method === 'POST') {
      const body = await new Promise((r) => { let b = ''; req.on('data', (d) => (b += d)); req.on('end', () => r(b)); });
      const { style, logo } = JSON.parse(body || '{}');
      const cfg = readJson(CONFIG_PATH, {});
      if (style !== undefined) cfg.orbStyle = style;
      if (logo !== undefined) cfg.orbLogo = logo;
      writeJson(CONFIG_PATH, cfg);
      fs.writeFileSync(path.join(ROOT, 'reload.flag'), String(Date.now()));
      // the orb watches config.json itself, so no restart is needed
      return json(res, 200, { ok: true, orbStyle: cfg.orbStyle || 'bot', orbLogo: cfg.orbLogo || '' });
    }

    if (url.pathname === '/api/speaker' && req.method === 'POST') {
      const body = await new Promise((r) => { let b = ''; req.on('data', (d) => (b += d)); req.on('end', () => r(b)); });
      const { id, test } = JSON.parse(body || '{}');
      const cfg = readJson(CONFIG_PATH, {});
      if (id !== undefined) {
        cfg.speakerId = id || '';
        writeJson(CONFIG_PATH, cfg);
        fs.writeFileSync(path.join(ROOT, 'reload.flag'), String(Date.now()));
        detectCache = { at: 0, data: null };
      }
      if (test) {
        const py = cfg?.tts?.python;
        const script = path.join(ROOT, 'speak-edge.py');
        if (py && fs.existsSync(script)) {
          const target = id === undefined ? (cfg.speakerId || '') : (id || '');
          spawn(py, [script, '这是语音试听', cfg?.tts?.voice || 'zh-CN-XiaoxiaoNeural', cfg?.tts?.rate || '+0%'], {
            windowsHide: true, stdio: 'ignore',
            env: { ...process.env, DSH_VOICE_SPEAKER: target },
          });
        }
      }
      return json(res, 200, { ok: true, speakerId: cfg.speakerId || '' });
    }

    if (url.pathname === '/api/microphone' && req.method === 'POST') {
      const body = await new Promise((r) => { let b = ''; req.on('data', (d) => (b += d)); req.on('end', () => r(b)); });
      const { alt, name } = JSON.parse(body || '{}');
      const cfg = readJson(CONFIG_PATH, {});
      cfg.audioDevice = alt || name || '';
      writeJson(CONFIG_PATH, cfg);
      fs.writeFileSync(path.join(ROOT, 'reload.flag'), String(Date.now()));
      // the capture process is bound to the old device: restart the daemon
      await run('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(ROOT, 'stop-daemon.ps1')]);
      await run('wscript.exe', [path.join(ROOT, 'start-all.vbs')]);
      detectCache = { at: 0, data: null };
      return json(res, 200, { ok: true, audioDevice: cfg.audioDevice });
    }

    if (url.pathname === '/api/daemon' && req.method === 'POST') {
      const body = await new Promise((r) => { let b = ''; req.on('data', (d) => (b += d)); req.on('end', () => r(b)); });
      const { action } = JSON.parse(body || '{}');
      const script = action === 'stop' ? 'stop-daemon.ps1' : 'start-all.vbs';
      const cmd = action === 'stop' ? 'powershell.exe' : 'wscript.exe';
      const args = action === 'stop'
        ? ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(ROOT, script)]
        : [path.join(ROOT, script)];
      await run(cmd, args);
      return json(res, 200, { ok: true, running: isDaemonRunning() });
    }

    // static
    let file = url.pathname === '/' ? '/index.html' : url.pathname;
    const full = path.join(PUB, path.normalize(file).replace(/^([/\\])+/, ''));
    if (!full.startsWith(PUB) || !fs.existsSync(full)) return send(res, 404, 'text/plain', 'not found');
    return send(res, 200, MIME[path.extname(full)] || 'application/octet-stream', fs.readFileSync(full));
  } catch (e) {
    return json(res, 500, { error: e.message });
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`control panel on http://127.0.0.1:${PORT}`);
});
