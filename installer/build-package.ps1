param(
  [string]$OutDir = (Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'dist'),
  [switch]$WithModels,      # bundle the ~228 MB model (offline install)
  [switch]$SkipZip
)
# Build a distributable package: voice layer + ffmpeg + installer, as a ZIP
# (and as an Inno Setup .exe when ISCC.exe is available on this machine).
$ErrorActionPreference = 'Stop'
$voice = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)   # ...\voice
$stage = Join-Path $OutDir 'DSHVoice'
$version = '0.1.0'

function Step($m) { Write-Output ('[..] ' + $m) }
function Ok($m)   { Write-Output ('[ok] ' + $m) }

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'bin') | Out-Null

Step 'copying the voice layer'
$skip = @('dist', 'installer', 'state.json', 'orb.heartbeat', 'watchdog.heartbeat',
         'audio-activity.json', 'audio-activity.pid', 'daemon.pid', 'watchdog.pid',
         'voice-session.json', 'command-queue.jsonl', 'config.json', 'config.example.json',
         'cache', '*.log', 'demo*', 'test-*', '*.mp4', '*.gif', '*.wav', 'dsh-exe.txt', 'screenshots', 'orb-*.png',
         'icon-preview.png', 'icon-zoom*.png', 'taskbar-icon*.png', 'titlebar-icon.png', 'icon-zoom.png')
Copy-Item (Join-Path $voice '*') $stage -Recurse -Force -Exclude $skip
Copy-Item (Join-Path $voice 'installer') $stage -Recurse -Force
Copy-Item (Join-Path $voice 'config.example.json') (Join-Path $stage 'config.example.json') -Force
Write-Output '[..] packaged config.example.json (installer fills real paths)'

# capture artifacts and demo media must not ship
Step 'pruning artifacts'
Remove-Item (Join-Path $stage 'gui\*.png') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $stage 'screenshots') -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem $stage -Recurse -Include *.mp4,*.gif,*.wav -File -ErrorAction SilentlyContinue |
  Remove-Item -Force -ErrorAction SilentlyContinue

Step 'copying ffmpeg'
$ffmpeg = Join-Path $env:USERPROFILE '.dsh\tools\bin\ffmpeg.exe'
if (Test-Path $ffmpeg) {
  Copy-Item $ffmpeg (Join-Path $stage 'bin\ffmpeg.exe') -Force
  Ok 'ffmpeg bundled'
} else {
  Write-Output '[!!] ffmpeg.exe not found - the package will rely on PATH'
}

if ($WithModels) {
  Step 'bundling the SenseVoice model'
  $modelRoot = Join-Path $env:USERPROFILE '.dsh\speech-to-text\sensevoice\models'
  if (Test-Path $modelRoot) {
    Copy-Item $modelRoot (Join-Path $stage 'models') -Recurse -Force
    Ok 'models bundled (offline install)'
  } else {
    Write-Output '[!!] model cache missing; the installer will download it instead'
  }
}

Step 'writing the bootstrap'
$bootstrap = @'
@echo off
setlocal
set SCRIPT=%~dp0installer\install-voice.ps1
where pwsh >nul 2>nul
if %errorlevel%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
)
if errorlevel 1 pause
'@
Set-Content -Path (Join-Path $OutDir 'install.cmd') -Value $bootstrap -Encoding ASCII
Ok 'install.cmd written'

if (-not $SkipZip) {
  Step 'creating the ZIP'
  $zip = Join-Path $OutDir ('DSHVoice-' + $version + '.zip')
  if (Test-Path $zip) { Remove-Item $zip -Force }
  Compress-Archive -Path (Join-Path $OutDir 'DSHVoice'), (Join-Path $OutDir 'install.cmd') -DestinationPath $zip -CompressionLevel Optimal
  $sizeMb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
  Ok ('ZIP: ' + $zip + ' (' + $sizeMb + ' MB)')
}

$iscc = @(
  'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
  'C:\Program Files\Inno Setup 6\ISCC.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($iscc) {
  Step 'building the Inno Setup installer'
  & $iscc (Join-Path $voice 'installer\DSHVoice.iss') | Out-Null
  Ok 'setup.exe built'
} else {
  Write-Output '[..] Inno Setup not found - ZIP only (install DSHVoice.iss with ISCC.exe later)'
}
