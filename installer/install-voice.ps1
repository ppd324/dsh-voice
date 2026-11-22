param(
  [switch]$Check,          # only report what would happen
  [switch]$SkipModels,     # do not download the ASR model
  [switch]$SkipStart,      # do not start the daemon at the end
  [switch]$InPlace,        # the voice layer already sits in %LOCALAPPDATA%\DSHVoice
  [string]$DshExe = ''     # override the DSH executable path
)
# DSH Voice installer: lays the voice layer next to an existing DSH Desktop install.
# It never touches the DSH installation itself; it prepares the voice profile, the
# model cache, a Python environment for edge-tts, and the logon autostart entries.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:problems = @()
function Step($m) { Write-Output ("[..] " + $m) }
function Ok($m)   { Write-Output ("[ok] " + $m) }
function Bad($m)  { Write-Output ("[!!] " + $m); $script:problems += $m }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path        # ...\installer
$sourceVoice = Split-Path -Parent $here                        # ...\voice
$target = Join-Path $env:LOCALAPPDATA 'DSHVoice'
$dshHome = Join-Path $env:USERPROFILE '.dsh'

# --- model catalog (pinned by size + sha256, mirrors tried in order) --------
$MODELS = @(
  @{ name = 'tokens.txt';       dir = 'sensevoice-onnx'; bytes = 315894;    sha = 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc'
     urls = @('https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07/tokens.txt',
              'https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07/tokens.txt') },
  @{ name = 'silero_vad.onnx';  dir = 'silero';           bytes = 1807522;   sha = 'a35ebf52fd3ce5f1469b2a36158dba761bc47b973ea3382b3186ca15b1f5af28'
     urls = @('https://hf-mirror.com/csukuangfj/vad/resolve/fba88cd2e921609e7675c3aaf51e0b9b295da4bc/silero_vad.onnx',
              'https://huggingface.co/csukuangfj/vad/resolve/fba88cd2e921609e7675c3aaf51e0b9b295da4bc/silero_vad.onnx') },
  @{ name = 'model.int8.onnx';  dir = 'sensevoice-onnx'; bytes = 239233841; sha = 'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51'
     urls = @('https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07/model.int8.onnx',
              'https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07/model.int8.onnx') }
)

function Test-Asset($path, $bytes, $sha) {
  if (-not (Test-Path $path)) { return $false }
  if ((Get-Item $path).Length -ne $bytes) { return $false }
  return ((Get-FileHash $path -Algorithm SHA256).Hash.ToLower() -eq $sha)
}

function Invoke-Download($url, $dest) {
  # curl.exe ships with Windows 10+; --ssl-no-revoke avoids schannel revocation stalls
  $curl = Join-Path $env:WINDIR 'System32\curl.exe'
  $part = $dest + '.part'
  if (Test-Path $part) { Remove-Item $part -Force }
  if (Test-Path $curl) {
    & $curl -fL --ssl-no-revoke --retry 4 --retry-delay 3 --connect-timeout 20 -o $part $url 2>$null
  } else {
    Invoke-WebRequest -Uri $url -OutFile $part -UseBasicParsing
  }
  if (-not (Test-Path $part)) { return $false }
  Move-Item $part $dest -Force
  return $true
}

function Install-Models {
  $root = Join-Path $dshHome 'speech-to-text\sensevoice\models'
  foreach ($m in $MODELS) {
    $dir = Join-Path $root $m.dir
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dest = Join-Path $dir $m.name
    if (Test-Asset $dest $m.bytes $m.sha) { Ok ('model asset present: ' + $m.name); continue }
    $sizeMb = [math]::Round($m.bytes / 1MB)
    Step ('downloading ' + $m.name + ' (' + $sizeMb + ' MB)')
    $done = $false
    foreach ($url in $m.urls) {
      if (Invoke-Download $url $dest) {
        if (Test-Asset $dest $m.bytes $m.sha) { $done = $true; Ok ('downloaded ' + $m.name); break }
        Bad ('checksum mismatch for ' + $m.name + ' from ' + $url)
        Remove-Item $dest -Force -ErrorAction SilentlyContinue
      }
    }
    if (-not $done) { Bad ('could not download ' + $m.name + ' from any mirror') }
  }
}

# --- 1. locate DSH Desktop -------------------------------------------------
if (-not $DshExe) {
  foreach ($candidate in @(
      'D:\dsh\DeepSeek Harness.exe',
      (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'),
      (Join-Path $env:ProgramFiles 'DeepSeek Harness\DeepSeek Harness.exe')
    )) {
    if (Test-Path $candidate) { $DshExe = $candidate; break }
  }
}
if (-not $DshExe -or -not (Test-Path $DshExe)) {
  Bad 'DSH Desktop not found. Install DeepSeek Harness first, then rerun with -DshExe <path>.'
  exit 2
}
Ok ('DSH Desktop: ' + $DshExe)
$dshRoot = Split-Path -Parent $DshExe

# --- 2. user profile -------------------------------------------------------
if (-not (Test-Path (Join-Path $dshHome 'profiles\desktop'))) {
  Bad ('DSH profile not found at ' + $dshHome + '\profiles\desktop - open DSH once and sign in.')
} else {
  Ok 'DSH profile present'
}

# --- 3. python for edge-tts ------------------------------------------------
$python = ''
foreach ($candidate in @(
    (Join-Path $dshHome 'dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe'),
    'C:\Python312\python.exe'
  )) {
  if (Test-Path $candidate) { $python = $candidate; break }
}
if (-not $python) { $python = (Get-Command python.exe -ErrorAction SilentlyContinue).Source }
if ($python) { Ok ('Python: ' + $python) } else { Bad 'Python not found; edge-tts voice will fall back to SAPI.' }

# --- 4. ffmpeg -------------------------------------------------------------
$ffmpeg = ''
foreach ($candidate in @(
    (Join-Path $dshHome 'tools\bin\ffmpeg.exe'),
    (Join-Path $target 'bin\ffmpeg.exe'),
    (Join-Path $sourceVoice 'bin\ffmpeg.exe')
  )) {
  if (Test-Path $candidate) { $ffmpeg = $candidate; break }
}
if (-not $ffmpeg) { $ffmpeg = (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue).Source }
if ($ffmpeg) { Ok ('ffmpeg: ' + $ffmpeg) } else { Bad 'ffmpeg not found; ship it in the package bin\ folder.' }

# --- 5. model cache --------------------------------------------------------
$modelRoot = Join-Path $dshHome 'speech-to-text\sensevoice\models'
$modelFile = Join-Path $modelRoot 'sensevoice-onnx\model.int8.onnx'
if (Test-Asset $modelFile 239233841 'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51') {
  Ok 'SenseVoice model present and verified'
} elseif ($SkipModels) {
  Step 'model missing (skipped by -SkipModels)'
} else {
  Step 'SenseVoice model will be downloaded (~228 MB)'
}

# --- 6. plan ---------------------------------------------------------------
Write-Output ''
Write-Output 'Plan:'
Write-Output ('  voice layer  -> ' + $target)
Write-Output ('  profile      -> ' + (Join-Path $dshHome 'profiles\voice'))
Write-Output ('  model cache  -> ' + $modelRoot)
Write-Output ('  autostart    -> HKCU Run: DSHVoice, DSHVoiceWatchdog, DeepSeekHarness')
if ($Check) {
  Write-Output ''
  if ($script:problems.Count) {
    Write-Output 'CHECK FAILED:'
    $script:problems | ForEach-Object { Write-Output ('  - ' + $_) }
    exit 1
  }
  Write-Output 'CHECK PASSED - rerun without -Check to install.'
  exit 0
}

# --- 7. copy the voice layer ----------------------------------------------
if ($InPlace -or ($sourceVoice -eq $target)) {
  Ok 'voice layer already in place'
} else {
  Step ('copying voice layer to ' + $target)
  New-Item -ItemType Directory -Force -Path $target | Out-Null
  Copy-Item (Join-Path $sourceVoice '*') $target -Recurse -Force -Exclude @('installer')
  Ok 'voice layer copied'
}

# --- 8. standalone runtime: copy the native ASR modules out of app.asar ----
# Running the daemon on the packaged Electron binary ties it to the DSH app process
# tree: quitting the app kills the daemon. A plain Node runtime avoids that.
$runtimeModules = Join-Path $target 'runtime\node_modules'
New-Item -ItemType Directory -Force -Path $runtimeModules | Out-Null
$asarModules = Join-Path $dshRoot 'resources\app.asar\dsh\node_modules'
$copyScript = @'
const fs=require('node:fs'), path=require('node:path');
const [src,dst]=process.argv.slice(2);
let n=0;
function cp(from,to){ fs.mkdirSync(to,{recursive:true});
  for(const e of fs.readdirSync(from,{withFileTypes:true})){
    const f=path.join(from,e.name), t=path.join(to,e.name);
    if(e.isDirectory()) cp(f,t); else { fs.copyFileSync(f,t); n++; }
  } }
for(const name of ['sherpa-onnx-node','sherpa-onnx-win-x64']) cp(path.join(src,name), path.join(dst,name));
console.log('copied '+n+' files');
'@
if (-not (Test-Path (Join-Path $runtimeModules 'sherpa-onnx-node'))) {
  Step 'copying the ASR runtime out of app.asar'
  $tmp = Join-Path $env:TEMP 'dsh-voice-copy.js'
  Set-Content -Path $tmp -Value $copyScript -Encoding UTF8
  $env:ELECTRON_RUN_AS_NODE = '1'
  & $DshExe $tmp $asarModules $runtimeModules | Out-Null
  Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
  if (Test-Path (Join-Path $runtimeModules 'sherpa-onnx-node')) { Ok 'ASR runtime extracted' } else { Bad 'ASR runtime extraction failed' }
} else {
  Ok 'ASR runtime already present'
}

# --- 9. write config.json with detected paths ------------------------------
$configPath = Join-Path $target 'config.json'
$example = Join-Path $target 'config.example.json'
if (-not (Test-Path $configPath) -and (Test-Path $example)) {
  Copy-Item $example $configPath -Force
  Ok 'seeded config.json from config.example.json'
}
$config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$config.installDir = $runtimeModules

# pick a capture device if the config still has a placeholder
if (-not $config.audioDevice -or $config.audioDevice -like '*<*' -or $config.audioDevice -eq '') {
  Step 'detecting the microphone'
  $list = (& $ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1 | Out-String)
  $names = [regex]::Matches($list, '"([^"]+)"\s*\(audio\)') | ForEach-Object { $_.Groups[1].Value }
  $pick = $names | Where-Object { $_ -match '麦克风|Microphone|Mic' } | Select-Object -First 1
  if (-not $pick) { $pick = $names | Select-Object -First 1 }
  if ($pick) { $config.audioDevice = $pick; Ok ('microphone: ' + $pick) } else { Bad 'no capture device found; set audioDevice in config.json' }
}
# default workspace (DSH's own default) when not set
if (-not $config.workspaceDir -or $config.workspaceDir -like '*<*') {
  $ws = Join-Path $env:USERPROFILE 'Documents\deepseek-harness\default-workspace'
  if (Test-Path $ws) { $config.workspaceDir = $ws }
}
$config.ffmpeg = $ffmpeg
$config.pwsh = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$config.tts.python = $python
$config.zstd = ''
$config | ConvertTo-Json -Depth 8 | Set-Content $configPath -Encoding UTF8
Ok 'config.json written'

# --- 9. models -------------------------------------------------------------
if (-not $SkipModels) { Install-Models }

# --- 10. voice profile -----------------------------------------------------
$voiceProfile = Join-Path $dshHome 'profiles\voice'
if (-not (Test-Path $voiceProfile)) {
  Step 'creating the voice profile from the headless template'
  Copy-Item (Join-Path $sourceVoice 'installer\voice-profile') $voiceProfile -Recurse -Force
  Ok 'voice profile created'
} else {
  Ok 'voice profile already exists'
}

# install the Windows-MCP plugin into that profile (pnpm from the DSH runtime)
$pnpm = Join-Path $dshHome 'dsh-runtimes\dsh-primary-runtime\dependencies\pnpm\bin\pnpm.mjs'
$node = Join-Path $dshHome 'dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe'
if ((Test-Path $pnpm) -and (Test-Path $node)) {
  Step 'installing dsh-windows-mcp into the voice profile'
  Push-Location $voiceProfile
  & $node $pnpm add dsh-windows-mcp 2>$null | Out-Null
  $code = $LASTEXITCODE
  Pop-Location
  if ($code -eq 0) { Ok 'dsh-windows-mcp installed' } else { Bad 'dsh-windows-mcp install failed (offline?)' }
} else {
  Bad 'DSH runtime pnpm not found; install the plugin later with: dsh plugin --profile voice add dsh-windows-mcp'
}

# write the bridge row pointing at the installed Windows-MCP toolchain
$toolchainRoot = Join-Path $dshHome 'dsh-windows-mcp\toolchain'
$toolchain = $null
if (Test-Path $toolchainRoot) {
  $toolchain = Get-ChildItem $toolchainRoot -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName 'windows-mcp\Scripts\windows-mcp.exe') } |
    Sort-Object Name -Descending | Select-Object -First 1
}
$profilePatch = Join-Path $voiceProfile 'cordis.patch.yml'
if ($toolchain) {
  $exe = Join-Path $toolchain.FullName 'windows-mcp\Scripts\windows-mcp.exe'
  if (-not (Select-String -Path $profilePatch -Pattern 'windows-mcp-bridge' -Quiet)) {
    $q = [char]39
    $row = @('', '- id: windows-mcp-bridge', '  disabled: false', '  config:',
      '    serverName: windows', '    transport: stdio',
      ('    command: ' + $q + $exe.Replace('\', '/') + $q),
      '    args: [serve, --exclude-tools, "App,PowerShell,FileSystem"]',
      '    toolCallTimeoutMs: 120000', '    failOnStartupError: false')
    Add-Content -Path $profilePatch -Value $row -Encoding UTF8
    Ok ('windows-mcp bridge -> ' + $exe)
  } else {
    Ok 'windows-mcp bridge already configured'
  }
} else {
  Bad 'Windows-MCP toolchain missing: open DSH > Plugins > Windows desktop automation and run its dependency install once.'
}

# --- 11. edge-tts ----------------------------------------------------------
if ($python) {
  Step 'ensuring edge-tts'
  & $python -m pip install --quiet edge-tts 2>$null
  if ($LASTEXITCODE -eq 0) { Ok 'edge-tts ready' } else { Bad 'edge-tts install failed; SAPI fallback will be used' }
}

# --- 12. autostart ---------------------------------------------------------
$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
$startAll = Join-Path $target 'start-all.vbs'
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
# start-all.vbs creates the daemon and the watchdog through WMI, so neither is a
# child of the session that installed it (quitting an app cannot reap them).
Set-ItemProperty -Path $key -Name 'DSHVoice' -Value ('"' + $wscript + '" "' + $startAll + '"') -Type String
Set-ItemProperty -Path $key -Name 'DeepSeekHarness' -Value ('"' + $DshExe + '"') -Type String
Remove-ItemProperty -Path $key -Name 'DSHVoiceWatchdog' -ErrorAction SilentlyContinue
Ok 'autostart entries written'

# --- 12b. shortcuts --------------------------------------------------------
# Start-menu shortcut carries the app icon; the ZIP install would otherwise have none.
try {
  $shell = New-Object -ComObject WScript.Shell
  $lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'DSH Voice.lnk'
  $sc = $shell.CreateShortcut($lnk)
  $sc.TargetPath = (Join-Path $env:WINDIR 'System32\wscript.exe')
  $sc.Arguments = '"' + (Join-Path $target 'start-gui.vbs') + '"'
  $sc.WorkingDirectory = $target
  $icon = Join-Path $target 'assets\icon.ico'
  if (Test-Path $icon) { $sc.IconLocation = $icon }
  $sc.Save()
  Ok ('start menu shortcut -> ' + $lnk)
} catch { Bad ('could not create shortcut: ' + $_.Exception.Message) }

# --- 13. start -------------------------------------------------------------
if (-not $SkipStart) {
  Step 'starting the voice stack (detached)'
  & $wscript (Join-Path $target 'start-all.vbs')
  Start-Sleep -Seconds 6
  Ok 'daemon + watchdog started'
}

Write-Output ''
if ($script:problems.Count) {
  Write-Output 'INSTALLED WITH WARNINGS:'
  $script:problems | ForEach-Object { Write-Output ('  - ' + $_) }
  Write-Output ''
  Write-Output 'Next: run the first-run wizard -> pwsh -File "' + (Join-Path $target 'first-run.ps1') + '"'
  exit 1
}
Write-Output 'INSTALLED.'
Write-Output 'Next: run the first-run wizard -> pwsh -File "' + (Join-Path $target 'first-run.ps1') + '"'
Write-Output 'Then say: 你好电脑'
