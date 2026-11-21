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
Copy-Item (Join-Path $voice '*') $stage -Recurse -Force -Exclude @('dist', 'state.json', 'orb.heartbeat', '*.log', 'voice-session.json', 'cache')

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
