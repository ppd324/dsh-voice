#!/usr/bin/env node
'use strict';
/*
 * dsh-voice: 常驻语音入口。
 *
 * 链路: ffmpeg(dshow 麦克风, 16k 单声道) → Silero VAD 分段 → SenseVoice 识别
 *      → 唤醒词匹配 → 注入 DSH 输入框并回车 → 跟踪会话日志 → 朗读回复
 *
 * 运行: 需要 Electron 的 Node 模式, 才能加载 asar 内的原生模块：
 *   ELECTRON_RUN_AS_NODE=1 "D:\dsh\DeepSeek Harness.exe" listen.js
 */
const { spawn, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

const ROOT = __dirname;
const CONFIG = JSON.parse(fs.readFileSync(path.join(ROOT, 'config.json'), 'utf8'));
const LOG_FILE = path.join(ROOT, 'daemon.log');
const PID_FILE = path.join(ROOT, 'daemon.pid');
const SAMPLE_RATE = 16000;
const FRAME_SAMPLES = 512;
const FRAME_BYTES = FRAME_SAMPLES * 2;

function log(...parts) {
  const line = `[${new Date().toISOString()}] ${parts.map(p => (typeof p === 'string' ? p : JSON.stringify(p))).join(' ')}`;
  try { fs.appendFileSync(LOG_FILE, line + '\n'); } catch {}
  // 竞态下 Electron 可能没有可用 stdout, 忽略写入错误
  try { process.stdout.write(line + '\n'); } catch {}
}

// --- 单实例 ---------------------------------------------------------------
// 调试/自检模式(--feed/--simulate)不参与单实例锁, 否则守护进程在跑时无法做识别自检
const isProbeMode = ['--feed', '--simulate', '--say'].includes(process.argv[2]);
try {
  const old = parseInt(fs.readFileSync(PID_FILE, 'utf8').trim(), 10);
  if (!isProbeMode && old && old !== process.pid) {
    try { process.kill(old, 0); log('already running pid=' + old); process.exit(0); } catch {}
  }
} catch {}
if (!isProbeMode) { try { fs.writeFileSync(PID_FILE, String(process.pid)); } catch {} }
process.on('exit', () => { try { if (fs.readFileSync(PID_FILE, 'utf8').trim() === String(process.pid)) fs.unlinkSync(PID_FILE); } catch {} });

// --- 资源检查 -------------------------------------------------------------
const modelDir = path.join(CONFIG.dataRoot, 'models', 'sensevoice-onnx');
const vadDir = path.join(CONFIG.dataRoot, 'models', 'silero');
const modelFile = path.join(modelDir, 'model.int8.onnx');
const tokensFile = path.join(modelDir, 'tokens.txt');
const vadFile = path.join(vadDir, 'silero_vad.onnx');
for (const [label, f] of [['model', modelFile], ['tokens', tokensFile], ['vad', vadFile]]) {
  if (!fs.existsSync(f)) { log('FATAL missing ' + label + ': ' + f); process.exit(1); }
}

const sherpa = require(path.join(CONFIG.installDir, 'sherpa-onnx-node'));

log('booting; pid=' + process.pid);

const recognizer = new sherpa.OfflineRecognizer({
  featConfig: { sampleRate: SAMPLE_RATE, featureDim: 80 },
  modelConfig: {
    senseVoice: { model: modelFile, language: CONFIG.asrLanguage || 'auto', useInverseTextNormalization: 1 },
    tokens: tokensFile,
    debug: false,
    numThreads: 4,
    provider: 'cpu',
  },
});

const vad = new sherpa.Vad({
  sileroVad: {
    model: vadFile,
    threshold: 0.4,
    minSpeechDuration: 0.25,
    minSilenceDuration: 0.4,
    maxSpeechDuration: 15,
    windowSize: FRAME_SAMPLES,
  },
  sampleRate: SAMPLE_RATE,
  numThreads: 1,
  debug: false,
}, 60);

// --- 状态 -----------------------------------------------------------------
let armed = false;
let armedTimer = null;
let speaking = false;
let muteUntil = 0;
let followUpUntil = 0;
let followUpTimer = null;
let lastArmExtend = 0;
let muteReset = false;
let lastMuteLog = 0;
let lastSysLog = 0;
let micLevel = 0;
let lastLevelWrite = 0;
let busy = false;
const segmentQueue = [];

function beep(kind) {
  if (!CONFIG.beep) return;
  const tone = kind === 'error' ? '[console]::beep(320,260)' : kind === 'ok' ? '[console]::beep(880,90)' : '[console]::beep(660,120)';
  try { spawn(CONFIG.pwsh, ['-NoProfile', '-Command', tone], { stdio: 'ignore', windowsHide: true }); } catch {}
}

const { findTrigger, isCancel, stripCommand, stripLeadingTrigger, applyCorrections } = require('./match.js');
const { maxSeq, messageText, replyAfter, findUserMessage, isTurnActive } = require('./session-log.js');

const hasTrigger = (raw) => {
  const hit = findTrigger(CONFIG.triggers, raw);
  if (!hit) return null;
  // 唤醒词必须出现在句首附近; 媒体语音里夹带的"电脑"不该被当成唤醒
  const lead = raw.slice(0, hit.index).replace(/[\s,，。.、!！?？~～:：]/g, '');
  const allowed = CONFIG.wakeLeadChars === undefined ? 2 : CONFIG.wakeLeadChars;
  if (lead.length > allowed) return null;
  return hit;
};

// 只由唤醒词/语气词组成的短语, 不能当作指令
function isWakeOnly(raw) {
  const bare = String(raw).replace(/[\s，,。.！!？?~～]/g, '');
  if (bare === '') return true;
  if (/^(喂|你好|好|嗨)?(电脑|助手)$/.test(bare)) return true;
  const hit = hasTrigger(raw);
  if (!hit) return false;
  const rest = raw.slice(hit.index + hit.length).replace(/[\s，,。.！!？?~～]/g, '');
  return rest === '' || /^(电脑|助手)$/.test(rest);
}
const isCancelWord = (raw) => isCancel(CONFIG.cancelWords, raw);
const toCommand = (raw) => stripCommand(raw, CONFIG.maxCommandChars);

function transcribe(samples) {
  const stream = recognizer.createStream();
  stream.acceptWaveform({ sampleRate: SAMPLE_RATE, samples });
  recognizer.decode(stream);
  return (recognizer.getResult(stream).text || '').trim();
}

// --- 会话日志: 找出最近的一轮回复 ---------------------------------------
function newestSessionFile() {
  const base = path.join(os.homedir(), '.dsh', 'sessions');
  let best = null;
  let workspaces = [];
  try { workspaces = fs.readdirSync(base); } catch { return null; }
  for (const ws of workspaces) {
    const wsDir = path.join(base, ws);
    let entries = [];
    try { if (!fs.statSync(wsDir).isDirectory()) continue; entries = fs.readdirSync(wsDir); } catch { continue; }
    for (const e of entries) {
      if (!e.startsWith('session-')) continue;
      const f = path.join(wsDir, e, 'session.v4.jsonl.zstd');
      try {
        const st = fs.statSync(f);
        if (!best || st.mtimeMs > best.mtimeMs) best = { file: f, mtimeMs: st.mtimeMs };
      } catch {}
    }
  }
  return best ? best.file : null;
}

function readRecords(file) {
  const r = spawnSync(CONFIG.zstd, ['-dcq', file], { maxBuffer: 96 * 1024 * 1024 });
  const out = r.stdout ? r.stdout.toString('utf8') : '';
  const records = [];
  for (const line of out.split('\n')) {
    if (!line.trim()) continue;
    try { records.push(JSON.parse(line)); } catch {}
  }
  return records;
}

function spokenForm(text) {
  return text
    .replace(/```[\s\S]*?```/g, ' (代码略) ')
    .replace(/`([^`]+)`/g, '$1')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
    .replace(/https?:\/\/\S+/g, ' 链接 ')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/^\s*#{1,6}\s*/gm, '')
    .replace(/[*_>|]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, CONFIG.tts.maxChars);
}


// --- 悬浮球状态 -----------------------------------------------------------
const STATE_FILE = path.join(ROOT, 'state.json');
let lastStateAt = 0;
let stateTimer = null;
let pendingState = null;

function emitState(payload) {
  try {
    const tmp = STATE_FILE + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify(payload), 'utf8');
    fs.renameSync(tmp, STATE_FILE);
  } catch {}
  lastStateAt = Date.now();
}

const STATE_LABELS = { listening: '我在听', heard: '收到', nudge: '需要唤醒词', thinking: '执行中', speaking: '朗读中', idle: '' };

let liveState = { state: 'idle', text: '' };

function currentPayload() {
  return {
    state: liveState.state,
    label: STATE_LABELS[liveState.state] || '',
    text: liveState.text,
    level: Math.round(micLevel * 100) / 100,
    ts: Date.now(),
    pid: process.pid,
  };
}

// 长任务期间保持心跳, 否则球会按"20 秒没有新状态"自我隐藏
setInterval(() => {
  if (liveState.state !== 'idle') emitState(currentPayload());
}, 3000).unref?.();

// 系统是否正在外放声音(视频/音乐/通话): 由 audio-activity.ps1 采样 CoreAudio 峰值表
const AUDIO_ACTIVITY_FILE = path.join(__dirname, 'audio-activity.json');
let sysAudio = { level: 0, ts: 0, at: 0 };
function readSystemAudio() {
  const now = Date.now();
  if (now - sysAudio.at < 200) return sysAudio;
  sysAudio.at = now;
  try {
    const st = fs.statSync(AUDIO_ACTIVITY_FILE);
    if (st.mtimeMs !== sysAudio.mtime) {
      sysAudio.mtime = st.mtimeMs;
      const j = JSON.parse(fs.readFileSync(AUDIO_ACTIVITY_FILE, 'utf8'));
      sysAudio.level = Number(j.level) || 0;
      sysAudio.ts = Number(j.ts) || 0;
    }
  } catch (e) {
    sysAudio.level = 0;
  }
  return sysAudio;
}
function systemIsPlaying() {
  if (CONFIG.muteWhenSystemAudio === false) return false;
  const a = readSystemAudio();
  if (Date.now() - a.ts > 2500) return false;          // helper stalled: fail open
  return a.level > (CONFIG.systemAudioThreshold === undefined ? 0.03 : CONFIG.systemAudioThreshold);
}

// 托管 CoreAudio 峰值检测器: 由守护进程自己拉起, 挂了 10 秒内自动重启
let meterProc = null;
function ensureAudioMeter() {
  if (CONFIG.muteWhenSystemAudio === false) return;
  const a = readSystemAudio();
  const stale = Date.now() - (a.ts || 0) > 4000;
  if (meterProc && meterProc.exitCode === null && !stale) return;
  const ps = CONFIG.pwsh || 'powershell.exe';
  const script = path.join(__dirname, 'audio-activity.ps1');
  try {
    meterProc = spawn(ps, ['-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', script],
      { windowsHide: true, stdio: 'ignore', detached: false });
    log('restarted system-audio meter pid=' + meterProc.pid);
  } catch (e) {
    log('audio meter spawn failed:', e.message);
  }
}

function writeState(state, text) {
  liveState = { state, text: text || '' };
  const payload = {
    state,
    label: STATE_LABELS[state] || '',
    text: text || '',
    level: Math.round(micLevel * 100) / 100,
    ts: Date.now(),
    pid: process.pid,
  };
  const now = Date.now();
  if (now - lastStateAt > 90) { emitState(payload); return; }
  pendingState = payload;
  if (!stateTimer) {
    stateTimer = setTimeout(() => {
      stateTimer = null;
      if (pendingState) { const p = pendingState; pendingState = null; emitState(p); }
    }, 100);
  }
}

// 识别器是单实例, 部分解码与整句解码必须串行
let asrChain = Promise.resolve();
function decodeAsync(samples) {
  const run = asrChain.then(() => transcribe(samples));
  asrChain = run.catch(() => {});
  return run;
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function runProcess(cmd, args, timeoutMs) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(cmd, args, { stdio: 'ignore', windowsHide: true });
    } catch (e) { resolve(-1); return; }
    const t = timeoutMs ? setTimeout(() => {
      try { require('node:child_process').execFile('taskkill', ['/PID', String(child.pid), '/T', '/F']); } catch (e) {}
      try { child.kill(); } catch (e) {}
    }, timeoutMs) : null;
    child.on('exit', (code) => { if (t) clearTimeout(t); resolve(code === null ? -1 : code); });
    child.on('error', () => { if (t) clearTimeout(t); resolve(-1); });
  });
}

function playWav(file) {
  return runProcess(CONFIG.pwsh, ['-NoProfile', '-Command',
    "$p = New-Object System.Media.SoundPlayer '" + file + "'; $p.PlaySync()"]);
}

const PHRASE_CACHE = { '我在': path.join(ROOT, 'cache', 'wozai.wav') };

function playCachedPhrase(say) {
  const file = PHRASE_CACHE[say];
  if (!file) return null;
  if (!fs.existsSync(file)) return null;
  return playWav(file);
}

function armWithTimeout(ms) {
  if (armedTimer) clearTimeout(armedTimer);
  armedTimer = setTimeout(() => {
    if (armed) {
      armed = false;
      log('armed timeout; closing');
      writeState('idle', '');
    }
  }, ms);
}

// 待命期间检测到说话就续期, 避免"我明明开口了还是被关"
function extendArmOnVoice() {
  if (!armed) return;
  const now = Date.now();
  if (now - lastArmExtend < 1000) return;
  lastArmExtend = now;
  armWithTimeout(CONFIG.armExtendMs || 10000);
  log('arm extended by voice activity');
}

// 按句切分: 每句单独合成播放, 首句很快出声, 也避免长文本一次超时
function splitSentences(text, maxLen) {
  const limit = maxLen || 60;
  const parts = String(text).split(/(?<=[。！？!?；;\n])|(?<=\.\s)/).map((x) => x.trim()).filter(Boolean);
  const out = [];
  let buf = '';
  for (const part of parts) {
    if (buf && (buf.length + part.length) > limit) { out.push(buf); buf = part; }
    else { buf += part; }
  }
  if (buf) out.push(buf);
  return out.length ? out : [String(text)];
}

function openFollowUpWindow() {
  const ms = CONFIG.followUpMs || 20000;
  followUpUntil = Date.now() + ms;
  writeState('listening', '我在听…');
  if (followUpTimer) clearTimeout(followUpTimer);
  followUpTimer = setTimeout(() => {
    followUpUntil = 0;
    if (!armed) writeState('idle', '');
  }, ms);
}

async function speak(text, openFollowUp) {
  if (!CONFIG.tts.enabled) return;
  const say = spokenForm(text);
  if (!say) return;
  speaking = true;
  writeState('speaking', say.slice(0, 120));
  log('speaking:', say.slice(0, 80));

  // 高频短句用预生成缓存, 避免每次都要联网合成
  const cached = playCachedPhrase(say);
  if (cached) {
    await cached;
    speaking = false;
    muteUntil = Date.now() + 300;
    if (openFollowUp) openFollowUpWindow();
    return;
  }

  const engine = CONFIG.tts.engine || 'sapi';
  if (engine === 'edge') {
    const chunks = splitSentences(say);
    let playedAny = false;
    for (let i = 0; i < chunks.length; i++) {
      const chunk = chunks[i];
      if (!chunk) continue;
      const budget = Math.min(120000, 8000 + chunk.length * 400);
      const code = await runProcess(CONFIG.tts.python,
        [path.join(ROOT, 'speak-edge.py'), chunk, CONFIG.tts.voice || 'zh-CN-XiaoxiaoNeural', CONFIG.tts.rate || '+0%'], budget);
      if (code === 0) { playedAny = true; continue; }
      log('edge chunk ' + (i + 1) + '/' + chunks.length + ' failed code=' + code);
      // 只有第一段失败、且允许兜底时, 才用 SAPI; 否则宁可静音也不重复朗读
      if (!playedAny && CONFIG.tts.fallbackToSapi) {
        await runProcess(CONFIG.pwsh, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(ROOT, 'speak.ps1'),
          '-Text', chunk, '-Rate', String(CONFIG.tts.sapiRate ?? 0), '-Volume', String(CONFIG.tts.volume || 100), '-VoiceMatch', CONFIG.tts.voiceMatch || 'Huihui']);
        playedAny = true;
      }
    }
  } else {
    await runProcess(CONFIG.pwsh, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(ROOT, 'speak.ps1'),
      '-Text', say, '-Rate', String(CONFIG.tts.sapiRate ?? 0), '-Volume', String(CONFIG.tts.volume || 100), '-VoiceMatch', CONFIG.tts.voiceMatch || 'Huihui']);
  }
  speaking = false;
  muteUntil = Date.now() + 800;
  segmentQueue.length = 0;
  if (openFollowUp) openFollowUpWindow();
}

// 监督悬浮球: 心跳文件超过 20 秒不动就重启它
function startOrb() {
  try {
    spawn(CONFIG.pwsh, ['-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', path.join(ROOT, 'orb.ps1')],
      { stdio: 'ignore', windowsHide: true, detached: true }).unref();
  } catch (e) { log('orb start failed', String(e)); }
}

function superviseOrb() {
  const beat = path.join(ROOT, 'orb.heartbeat');
  let age = Infinity;
  try { age = Date.now() - fs.statSync(beat).mtimeMs; } catch {}
  if (age < 20000) return;
  log('orb heartbeat stale (' + Math.round(age / 1000) + 's); restarting');
  const kill = "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*orb.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }";
  const child = spawn(CONFIG.pwsh, ['-NoProfile', '-Command', kill], { stdio: 'ignore', windowsHide: true });
  child.on('exit', () => setTimeout(startOrb, 600));
  child.on('error', () => setTimeout(startOrb, 600));
}

// 启动时后台预生成 "我在" 的缓存音频
function warmPhraseCache() {
  try {
    const dir = path.join(ROOT, 'cache');
    fs.mkdirSync(dir, { recursive: true });
    const target = PHRASE_CACHE['我在'];
    if (fs.existsSync(target) && fs.statSync(target).size > 2000) return;
    const args = [path.join(ROOT, 'speak-edge.py'), '--cache', '我在', CONFIG.tts.voice || 'zh-CN-XiaoxiaoNeural', CONFIG.tts.rate || '+0%', target];
    const child = spawn(CONFIG.tts.python, args, { stdio: 'ignore', windowsHide: true });
    child.on('exit', (c) => log('wake phrase cache ready code=' + c));
    child.on('error', () => log('wake phrase cache failed'));
  } catch (e) { log('cache warm error', String(e)); }
}

function sessionFiles() {
  const base = path.join(os.homedir(), '.dsh', 'sessions');
  const out = [];
  let workspaces = [];
  try { workspaces = fs.readdirSync(base); } catch { return out; }
  for (const ws of workspaces) {
    const wsDir = path.join(base, ws);
    let entries = [];
    try { if (!fs.statSync(wsDir).isDirectory()) continue; entries = fs.readdirSync(wsDir); } catch { continue; }
    for (const e of entries) {
      if (!e.startsWith('session-')) continue;
      const f = path.join(wsDir, e, 'session.v4.jsonl.zstd');
      try { out.push({ file: f, mtimeMs: fs.statSync(f).mtimeMs }); } catch {}
    }
  }
  return out.sort((a, b) => b.mtimeMs - a.mtimeMs);
}

// 用注入的原句定位它所属轮次, 再朗读该轮最后的助手正文
async function watchReply(command, baselineSeq) {
  const deadline = Date.now() + CONFIG.replyTimeoutMs;
  const wanted = command.trim();
  while (Date.now() < deadline) {
    await sleep(900);
    for (const { file } of sessionFiles().slice(0, 5)) {
      let records;
      try { records = readRecords(file); } catch { continue; }
      const hit = findUserMessage(records, wanted, baselineSeq);
      if (!hit) continue;
      const text = replyAfter(records, hit.seq);
      if (text) { await speak(text, true); return; }
    }
  }
  log('reply timeout, nothing spoken');
}

// agent 正在跑回合时输入框不接受回车, 先等它结束
async function waitForIdle(command) {
  const deadline = Date.now() + (CONFIG.idleWaitMs || 60000);
  let announced = false;
  while (Date.now() < deadline) {
    const file = newestSessionFile();
    if (!file) return true;
    let busy = false;
    try { busy = isTurnActive(readRecords(file)); } catch {}
    if (!busy) return true;
    if (!announced) { writeState('thinking', '排队中：' + command); announced = true; log('agent busy; queued:', command); }
    await sleep(700);
  }
  log('idle wait timed out; injecting anyway');
  return false;
}

// --- CLI mode: dsh <profile> "<task>" runs one fresh session; the answer comes from stdout ---
const CLI_JS = 'D:/dsh/resources/app.asar/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js';
const VOICE_SESSION_FILE = path.join(__dirname, 'voice-session.json');

function loadVoiceSession() {
  try { return JSON.parse(fs.readFileSync(VOICE_SESSION_FILE, 'utf8')).sessionId || null; } catch (e) { return null; }
}
function saveVoiceSession(id) {
  if (!id) return;
  try { fs.writeFileSync(VOICE_SESSION_FILE, JSON.stringify({ sessionId: id, updatedAt: new Date().toISOString() }, null, 2)); } catch (e) {}
}
// DSH executable: config.cliExe first, then the usual install locations
function findDshExe() {
  const candidates = [
    CONFIG.cliExe,
    process.env.DSH_EXE,
    'D:/dsh/DeepSeek Harness.exe',
    path.join(process.env.LOCALAPPDATA || '', 'Programs/DeepSeek Harness/DeepSeek Harness.exe'),
    path.join(process.env.ProgramFiles || '', 'DeepSeek Harness/DeepSeek Harness.exe'),
  ].filter(Boolean);
  for (const c of candidates) {
    try { if (fs.existsSync(c)) return c; } catch (e) {}
  }
  return candidates[0] || 'DeepSeek Harness.exe';
}
const DSH_EXE = findDshExe();

// 把已知的"外号=账号"带给 agent, 省掉它每次重新查
function withAliases(command) {
  const aliases = CONFIG.aliases || {};
  const keys = Object.keys(aliases);
  if (!keys.length) return command;
  const table = keys.map((k) => k + '=' + aliases[k]).join(', ');
  return '[Known streamer aliases: ' + table + ']' + String.fromCharCode(10) + command;
}

// agent 回传的 ALIAS: 外号=账号 行(可能在行首, 也可能接在正文后面)
function absorbAliasLines(out) {
  const NL = String.fromCharCode(10);
  const re = /ALIAS:\s*([^=]+?)\s*=\s*(.+)$/i;
  let changed = false;
  const kept = [];
  for (const line of String(out).split(NL)) {
    const idx = line.search(/ALIAS:/i);
    if (idx === -1) { kept.push(line); continue; }
    const prefix = line.slice(0, idx).trim();
    const m = re.exec(line.slice(idx));
    if (m) {
      const alias = m[1].trim();
      const handle = m[2].trim().slice(0, 200);
      if (alias && handle) {
        CONFIG.aliases = CONFIG.aliases || {};
        if (CONFIG.aliases[alias] !== handle) {
          CONFIG.aliases[alias] = handle;
          changed = true;
          log('learned alias:', alias, '=', handle);
        }
      }
    }
    if (prefix) kept.push(prefix);
  }
  if (changed) {
    try { fs.writeFileSync(path.join(ROOT, 'config.json'), JSON.stringify(CONFIG, null, 2), 'utf8'); } catch (e) { log('alias save failed', String(e)); }
  }
  return kept.join(NL).trim();
}

function runCliOnce(task, sessionId, timeoutMs) {
  return new Promise((resolve) => {
    const args = [CLI_JS, CONFIG.cliProfile || 'voice'];
    if (sessionId) args.push('--session-id', sessionId);
    args.push('--json', task);
    const child = spawn(DSH_EXE, args, {
      cwd: CONFIG.workspaceDir || process.cwd(),
      env: Object.assign({}, process.env, { ELECTRON_RUN_AS_NODE: '1', DSH_PERMISSION_MODE: 'danger-full-access' }),
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
    });
    let out = '';
    let err = '';
    child.stdout.on('data', (d) => { out += d.toString('utf8'); });
    child.stderr.on('data', (d) => { err += d.toString('utf8'); });
    const startedAt = Date.now();
    const progress = setInterval(() => {
      const sec = Math.round((Date.now() - startedAt) / 1000);
      writeState('thinking', '执行：' + task.replace(/^\[Known streamer aliases:[^\]]*\]\s*/, '') + ' · ' + sec + 's');
    }, 2000);
    const timer = setTimeout(() => {
      log('cli timeout; killing tree');
      try { require('node:child_process').execFile('taskkill', ['/PID', String(child.pid), '/T', '/F']); } catch (e) {}
      try { child.kill(); } catch (e) {}
    }, timeoutMs);
    child.on('error', (e) => { clearTimeout(timer); clearInterval(progress); resolve({ code: -1, out: '', err: String(e), sessionId: null, text: '' }); });
    child.on('close', (code) => {
      clearTimeout(timer);
      clearInterval(progress);
      resolve({ code, out, err, ...parseEvents(out) });
    });
  });
}

// --json 输出的是 NDJSON 事件流: 取 sessionId 与 final.text
function parseEvents(raw) {
  let sessionId = null;
  let finalText = '';
  let errorText = '';
  const texts = [];
  for (const line of raw.split(String.fromCharCode(10))) {
    const t = line.trim();
    if (!t || t[0] !== '{') continue;
    let ev;
    try { ev = JSON.parse(t); } catch (e) { continue; }
    if (ev.type === 'session' && ev.sessionId) sessionId = ev.sessionId;
    if (ev.type === 'final') {
      if (ev.sessionId) sessionId = ev.sessionId;
      if (typeof ev.text === 'string') finalText = ev.text;
    }
    if (ev.type === 'error') errorText = String(ev.message || ev.error || 'cli error');
    if (ev.type === 'text' && typeof ev.text === 'string') texts.push(ev.text);
  }
  return { sessionId, text: finalText || texts.join(''), errorText };
}

// 按意图生成简短应答(不调 LLM, 立即出声)
function buildAck(command) {
  const raw = String(command).replace(/[。,.，！!？?\s]+$/g, '').trim();
  const stripPrefix = (t) => t.replace(/^(帮我|请|麻烦|给我|你)\s*/g, '');
  const body = stripPrefix(raw);
  const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];

  // 疑问类: 提取主题, 说"我查一下<主题>"
  const questionTail = /(怎么样|如何|是多少|多少钱|多少|几点|是什么|为什么|能不能|可不可以|吗|呢|了没)$/;
  if (questionTail.test(body)) {
    const topic = body.replace(questionTail, '').replace(/[，,。\s]+$/g, '').slice(0, 16);
    return pick(['好，我查一下', '我看一下']) + (topic || '');
  }
  // 查询类动词
  const mQuery = /^(?:帮我)?(查一下|查询|搜一下|搜索|找一下|看看)\s*(.+)$/.exec(body);
  if (mQuery) {
    return pick(['好，我查一下', '我看一下']) + mQuery[2].replace(/的$/, '').slice(0, 16);
  }
  // 打开类
  const mOpen = /^(打开|启动|运行|开一下|帮我打开)\s*(.+)$/.exec(raw);
  if (mOpen) {
    return pick(['这就帮您打开', '好的，打开']) + mOpen[2].replace(/的$/, '').slice(0, 16);
  }
  // 关闭类
  const mClose = /^(关闭|关掉|退出|结束|停止)\s*(.+)$/.exec(raw);
  if (mClose) {
    return pick(['好的，这就关']) + mClose[2].slice(0, 12);
  }
  // 调整类(最大化/最小化/静音...)
  if (/(最大化|最小化|全屏|静音|放大|缩小|置顶)/.test(raw)) {
    return pick(['好的，这就调整', '好，我调一下']);
  }
  return pick(['好的，我处理一下', '好，这就去做']);
}

async function submitViaCli(command) {
  const task = withAliases(command);
  let sessionId = loadVoiceSession();
  let r = await runCliOnce(task, sessionId, CONFIG.cliTimeoutMs || 240000);

  // 会话失效或被别的进程占着写锁时, 换一个新会话重跑一次
  const reason = ((r.errorText || '') + ' ' + (r.err || '')).trim();
  if (r.code !== 0 && sessionId && /already owned|active write handle|unknown|not found|no such session|in use/i.test(reason)) {
    log('stored voice session unusable (' + reason.slice(0, 120) + '); starting a fresh one');
    saveVoiceSession(null);
    try { fs.unlinkSync(VOICE_SESSION_FILE); } catch (e) {}
    r = await runCliOnce(task, null, CONFIG.cliTimeoutMs || 240000);
  }
  if (r.sessionId) saveVoiceSession(r.sessionId);
  return { code: r.code, out: r.text || '', err: r.err || '', errorText: r.errorText || '', sessionId: r.sessionId };
}

async function submit(command) {
  log('submit:', command);
  followUpUntil = 0;
  if (followUpTimer) { clearTimeout(followUpTimer); followUpTimer = null; }
  if (process.env.VOICE_DRY_RUN === '1') { log('dry-run: 不注入 DSH'); return; }
  if ((CONFIG.mode || 'gui') === 'cli') {
    writeState('thinking', '执行：' + command);
    beep('ok');
    // 先应一声(按意图生成, 不复述指令), 然后后台执行
    speak(buildAck(command));
    const r = await submitViaCli(command);
    log('cli exit=' + r.code + ' stdout=' + r.out.slice(0, 200));
    const reply = r.out || (r.code === 0 ? '完成了' : '命令执行失败，请重试');
    await speak(reply, true);
    writeState('idle', '');
    return;
  }
  if (CONFIG.newSessionPerCommand) { log('new session per command'); } else { await waitForIdle(command); }
  let baselineSeq = 0;
  const sessionFile = newestSessionFile();
  if (sessionFile) {
    try { baselineSeq = maxSeq(readRecords(sessionFile)); } catch {}
  }
  const r = spawnSync(CONFIG.pwsh, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(ROOT, 'inject.ps1'),
    '-Text', command, '-Submit', '-RetrySeconds', String(CONFIG.submitRetrySeconds || 15),
    ...(CONFIG.newSessionPerCommand ? ['-NewSession'] : [])],
    { encoding: 'utf8', timeout: 60000, windowsHide: true });
  const out = (r.stdout || '') + (r.stderr || '');
  if (r.status !== 0 || !/^ok /m.test(out)) {
    log('inject failed: status=' + r.status + ' ' + out.trim());
    beep('error');
    return;
  }
  beep('ok');
  log('injected; waiting for reply');
  writeState('thinking', '执行：' + command);
  await watchReply(command, baselineSeq);
  writeState('idle', '');
}

function peakDb(samples) {
  let peak = 0;
  for (let i = 0; i < samples.length; i++) {
    const v = Math.abs(samples[i]);
    if (v > peak) peak = v;
  }
  return 20 * Math.log10(peak + 1e-9);
}

async function handleSegment(samples) {
  const seconds = samples.length / SAMPLE_RATE;
  log('segment level: ' + peakDb(samples).toFixed(1) + ' dBFS, ' + seconds.toFixed(1) + 's');
  if (seconds < CONFIG.minSegmentSeconds) return;
  if (speaking) { log('skip: while speaking'); return; }

  let text = await decodeAsync(samples);
  if (!text) return;
  const corrected = applyCorrections(CONFIG.corrections, text);
  if (corrected !== text) { log('corrected:', text, '->', corrected); text = corrected; }
  log(`heard (${seconds.toFixed(1)}s):`, text);
  // 只有确实要响应时才把这句话显示到球上: 唤醒词命中、或正在待命/追问;
  // 否则播放中的视频/音乐会让球不停弹出
  const willHandle = armed || Date.now() < followUpUntil || !!hasTrigger(text);
  if (willHandle) { writeState('heard', text); }

  if (armed) {
    if (isCancelWord(text)) {
      armed = false;
      if (armedTimer) { clearTimeout(armedTimer); armedTimer = null; }
      log('command cancelled');
      writeState('idle', '');
      beep('error');
      return;
    }
    const cmd = toCommand(stripLeadingTrigger(CONFIG.triggers, text));
    if (!cmd) return;
    if (isWakeOnly(cmd)) { log('wake-only while armed; keep listening'); writeState('listening', '我在听…'); return; }
    armed = false;
    if (armedTimer) { clearTimeout(armedTimer); armedTimer = null; }
    await submit(cmd);
    return;
  }

  // 追问窗口: 刚回答完 20 秒内, 不用再喊唤醒词
  if (!armed && Date.now() < followUpUntil) {
    const cmd = toCommand(stripLeadingTrigger(CONFIG.triggers, text));
    if (isWakeOnly(cmd) || (!cmd && hasTrigger(text))) {
      followUpUntil = 0;
      armed = true;
      if (armedTimer) clearTimeout(armedTimer);
      writeState('listening', '我在听…');
      log('wake word during follow-up; armed again');
      speak('我在');
      armWithTimeout(CONFIG.armTimeoutMs);
      return;
    }
    if (!cmd) return;
    if (isCancelWord(cmd)) { log('follow-up cancelled'); followUpUntil = 0; writeState('idle', ''); return; }
    log('follow-up accepted (no wake word needed):', cmd);
    followUpUntil = 0;
    await submit(cmd);
    return;
  }

  let hit = hasTrigger(text);
  if (!hit) {
    // 兜底: 句首被切掉时 ASR 只剩 "电脑"/"好电脑"; 默认关闭, 否则外放语音极易误触发
    const bare = text.replace(/[\s，,。.！!？?~～]/g, '');
    if (CONFIG.allowBareWake === true && /^(喂|你好|好)?电脑$/.test(bare)) {
      hit = { index: 0, length: text.length, trigger: 'bare-computer' };
    }
  }
  if (!hit) {
    // 没有唤醒词就是休眠状态: 只记日志, 不弹球(否则看视频时球会一直闪)
    log('ignored (no wake word):', text);
    return;
  }

  const rest = toCommand(text.slice(hit.index + hit.length));
  if (rest && !isWakeOnly(rest)) {
    await submit(rest);
    return;
  }
  // 只说唤醒词: 进入待命, 等下一句
  armed = true;
  log('armed; waiting for command');
  writeState('listening', '我在听…');
  beep('wake');
  speak('我在');   // 唤醒应答, 不阻塞后续识别
  armWithTimeout(CONFIG.armTimeoutMs);
}

async function drainQueue() {
  if (busy) return;
  busy = true;
  try {
    while (segmentQueue.length) {
      const samples = segmentQueue.shift();
      try { await handleSegment(samples); } catch (err) { log('segment error:', String(err && err.stack || err)); }
    }
  } finally { busy = false; }
}

// --- 采集 ----------------------------------------------------------------
let ffmpegProc = null;
let shuttingDown = false;
let carry = Buffer.alloc(0);
let partialFrames = [];
let lastPartialAt = 0;
let speechActive = false;
let onsetPad = [];
let pendingPre = [];
let absPos = 0;
let framesWithPos = [];
const PAD_FRAMES = 14;   // ~0.45s, 补回 VAD 漏掉的句首(过大导致句首重复)
let restartDelay = 1000;

// 从帧缓冲里取 [upto-pad, upto) 的音频
function prerollBefore(upto, pad) {
  if (!upto || pad <= 0) return new Float32Array(0);
  const picked = [];
  let total = 0;
  for (let i = framesWithPos.length - 1; i >= 0 && total < pad; i--) {
    const f = framesWithPos[i];
    if (f.start >= upto) continue;
    picked.unshift(f.data);
    total += f.data.length;
  }
  if (!picked.length) return new Float32Array(0);
  const buf = concatFrames(picked);
  return buf.length > pad ? buf.subarray(buf.length - pad) : buf;
}

function concatFrames(frames) {
  const total = frames.reduce((n, f) => n + f.length, 0);
  const out = new Float32Array(total);
  let at = 0;
  for (const f of frames) { out.set(f, at); at += f.length; }
  return out;
}

function startCapture() {
  ffmpegProc = spawn(CONFIG.ffmpeg, [
    '-hide_banner', '-loglevel', 'error',
    '-f', 'dshow', '-i', 'audio=' + CONFIG.audioDevice,
    '-af', CONFIG.audioFilter || 'highpass=f=90,volume=20dB',
    '-ar', String(SAMPLE_RATE), '-ac', '1',
    '-f', 's16le', '-',
  ], { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });

  log('capture started; pid=' + ffmpegProc.pid);

  ffmpegProc.stdout.on('data', (chunk) => {
    carry = carry.length ? Buffer.concat([carry, chunk]) : chunk;
    while (carry.length >= FRAME_BYTES) {
      const frame = carry.subarray(0, FRAME_BYTES);
      carry = carry.subarray(FRAME_BYTES);
      const samples = new Float32Array(FRAME_SAMPLES);
      for (let i = 0; i < FRAME_SAMPLES; i++) samples[i] = frame.readInt16LE(i * 2) / 32768;

      // 朗读中/刚结束: 整段音频不送进 VAD, 否则回声会在朗读结束后被切出来
      const sysBusy = systemIsPlaying();
      if (sysBusy && !speaking && Date.now() - lastSysLog > 5000) {
        lastSysLog = Date.now();
        log('system audio playing; wake detection paused');
      }
      if (CONFIG.muteWhileSpeaking !== false && (speaking || Date.now() < muteUntil || sysBusy)) {
        if (!muteReset) { muteReset = true; try { vad.reset(); } catch (e) {} segmentQueue.length = 0; partialFrames = []; }
        if (Date.now() - lastMuteLog > 3000) { lastMuteLog = Date.now(); log('mic muted while speaking; input dropped'); }
        continue;
      }
      muteReset = false;
      vad.acceptWaveform(samples);

      // 记下绝对位置, 用于按 seg.start 精确补句首
      framesWithPos.push({ start: absPos, data: samples });
      absPos += samples.length;
      if (framesWithPos.length > 100) framesWithPos.shift();   // ~3.2s
      // 麦克风电平(0..1), 供悬浮球做音量律动
      let sum = 0;
      for (let i = 0; i < samples.length; i++) sum += samples[i] * samples[i];
      const rms = Math.sqrt(sum / samples.length);
      const instant = Math.min(1, rms * 9);
      micLevel = micLevel * 0.6 + instant * 0.4;
      const live = armed || Date.now() < followUpUntil;
      if (live && Date.now() - lastLevelWrite > 100) {
        lastLevelWrite = Date.now();
        writeState(liveState.state === 'idle' ? 'listening' : liveState.state, liveState.text);
      }

      const active = vad.isDetected();
      if (active) { speechActive = true; extendArmOnVoice(); } else { speechActive = false; }

      // 滚动字幕: VAD 判定"正在说话"时把音频攒起来, 定期做一次部分解码
      if (active) {
        partialFrames.push(Float32Array.from(samples));
        const total = partialFrames.length * FRAME_SAMPLES;
        if (total > SAMPLE_RATE * 20) partialFrames.shift();
        if (armed && !speaking && Date.now() - lastPartialAt > 550 && total >= SAMPLE_RATE * 0.4) {
          lastPartialAt = Date.now();
          const snapshot = concatFrames(partialFrames);
          decodeAsync(snapshot).then((partial) => {
            const fixed = applyCorrections(CONFIG.corrections, partial);
            if (fixed && armed && vad.isDetected()) writeState('listening', fixed);
          }).catch(() => {});
        }
      } else if (partialFrames.length) {
        partialFrames = [];
      }

      while (!vad.isEmpty()) {
        const seg = vad.front(false);
        vad.pop();
        // VAD 返回的可能是外部内存, Electron 的 V8 沙箱不允许, 必须复制
        let samples2 = Float32Array.from(seg.samples);
        // 按 VAD 给出的绝对起点, 取它之前的一段补回去, 不重叠
        const padSamples = Math.round(SAMPLE_RATE * (CONFIG.onsetPadSeconds ?? 0.5));
        const pre = prerollBefore(seg.start, padSamples);
        if (pre.length) samples2 = concatFrames([pre, samples2]);
        // 朗读中/刚结束的音频是 TTS 回声, 直接丢弃
        if (speaking || Date.now() < muteUntil) { pendingPre = []; continue; }
        segmentQueue.push(samples2);
        if (segmentQueue.length > 4) segmentQueue.shift();
      }
      if (!busy) drainQueue();
    }
    if (carry.length > FRAME_BYTES * 64) carry = carry.subarray(carry.length - FRAME_BYTES);
  });

  ffmpegProc.stderr.on('data', (d) => {
    const msg = d.toString('utf8').trim();
    if (msg) log('ffmpeg:', msg.slice(0, 300));
  });

  ffmpegProc.on('exit', (code, signal) => {
    log('capture exited code=' + code + ' signal=' + signal);
    if (shuttingDown) return;
    setTimeout(startCapture, restartDelay);
    restartDelay = Math.min(restartDelay * 2, 30000);
  });
}

function shutdown(reason) {
  if (shuttingDown) return;
  shuttingDown = true;
  log('shutting down: ' + reason);
  try { if (ffmpegProc) ffmpegProc.kill(); } catch {}
  process.exit(0);
}
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('uncaughtException', (e) => log('uncaught:', String(e && e.stack || e)));

// 调试入口: 把一段 wav 当麦克风输入喂进同一套 VAD/识别/唤醒词逻辑
function readWavPcm16(file) {
  const buf = fs.readFileSync(file);
  if (buf.toString('ascii', 0, 4) !== 'RIFF' || buf.toString('ascii', 8, 12) !== 'WAVE') throw new Error('not a WAV: ' + file);
  let offset = 12, fmt = null, data = null;
  while (offset + 8 <= buf.length) {
    const id = buf.toString('ascii', offset, offset + 4);
    const size = buf.readUInt32LE(offset + 4);
    const body = offset + 8;
    if (id === 'fmt ') fmt = { channels: buf.readUInt16LE(body + 2), sampleRate: buf.readUInt32LE(body + 4), bits: buf.readUInt16LE(body + 14) };
    else if (id === 'data') data = buf.subarray(body, body + size);
    offset = body + size + (size % 2);
  }
  if (!fmt || !data) throw new Error('malformed WAV');
  const count = Math.floor(data.length / 2 / fmt.channels);
  const samples = new Float32Array(count);
  for (let i = 0; i < count; i++) samples[i] = data.readInt16LE(i * fmt.channels * 2) / 32768;
  return { samples, sampleRate: fmt.sampleRate };
}

async function feedWave(file) {
  const { samples, sampleRate } = readWavPcm16(file);
  if (sampleRate !== SAMPLE_RATE) throw new Error('wav must be 16k, got ' + sampleRate);
  log('feed: ' + file + ' (' + (samples.length / sampleRate).toFixed(2) + 's)');
  for (let i = 0; i + FRAME_SAMPLES <= samples.length; i += FRAME_SAMPLES) {
    const frame = samples.subarray(i, i + FRAME_SAMPLES);
    vad.acceptWaveform(frame);
    if (vad.isDetected()) {
      if (!speechActive) { speechActive = true; onsetPad = pendingPre.slice(-PAD_FRAMES); pendingPre = []; }
    } else {
      speechActive = false;
      pendingPre.push(Float32Array.from(frame));
      if (pendingPre.length > PAD_FRAMES) pendingPre.shift();
    }
    while (!vad.isEmpty()) {
      const seg = vad.front(false);
      vad.pop();
      let s2 = Float32Array.from(seg.samples);
      if (onsetPad.length) { s2 = concatFrames(onsetPad.concat([s2])); onsetPad = []; }
      segmentQueue.push(s2);
    }
    await drainQueue();
  }
  // 收尾: 让 VAD 吐出最后一段(补静音)
  const tail = new Float32Array(SAMPLE_RATE);
  vad.acceptWaveform(tail);
  while (!vad.isEmpty()) {
    const seg = vad.front(false);
    vad.pop();
    segmentQueue.push(Float32Array.from(seg.samples));
  }
  await drainQueue();
  log('feed done');
}

// 调试入口: 跳过麦克风, 直接把一条指令走完"注入→等待回复→朗读"链路
if (process.argv[2] === '--say') {
  const text = process.argv[3] || '这是一次朗读测试';
  log('say mode:', text.slice(0, 40));
  speak(text, false).then(() => process.exit(0)).catch(() => process.exit(1));
} else if (process.argv[2] === '--simulate') {
  const cmd = process.argv[3] || '你好电脑配置检查';
  log('simulate mode; command=' + cmd);
  submit(cmd).then(() => process.exit(0)).catch((e) => { log('simulate error', String(e)); process.exit(1); });
} else if (process.argv[2] === '--feed') {
  feedWave(process.argv[3]).then(() => process.exit(0)).catch((e) => { log('feed error', String(e)); process.exit(1); });
} else {
  warmPhraseCache();
  setInterval(superviseOrb, 15000).unref?.();
  setInterval(ensureAudioMeter, 10000).unref?.();
  startCapture();
  log('ready; triggers=' + CONFIG.triggers.join('/'));
ensureAudioMeter();
}
