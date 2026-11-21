param(
  [string]$ConfigPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'config.json')
)
# First-run wizard: record one sample while the user speaks, then judge the level,
# the recognition result and the voice output in one pass.
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}

$WAKE = [string][char]0x4F60 + [char]0x597D + [char]0x7535 + [char]0x8111        # wake word
$SAY_TEST = [string][char]0x8BED + [char]0x97F3 + [char]0x6D4B + [char]0x8BD5    # voice test

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not (Test-Path $ConfigPath)) { Write-Host "config.json not found: $ConfigPath" -ForegroundColor Red; exit 2 }
$config = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

$ffmpeg = $config.ffmpeg
$device = $config.audioDevice
$voicePy = $config.tts.python
$nodeExe = (Get-ChildItem (Join-Path $env:USERPROFILE '.dsh\dsh-runtimes') -Directory -ErrorAction SilentlyContinue |
  ForEach-Object { Join-Path $_.FullName 'dependencies\node\bin\node.exe' } |
  Where-Object { Test-Path $_ } | Select-Object -First 1)
if (-not $nodeExe) { $nodeExe = (Get-Command node.exe -ErrorAction SilentlyContinue).Source }

function Line { Write-Host ('-' * 62) -ForegroundColor DarkGray }
function Good($m) { Write-Host ('  OK   ' + $m) -ForegroundColor Green }
function Warn($m) { Write-Host ('  WARN ' + $m) -ForegroundColor Yellow }
function Bad($m)  { Write-Host ('  FAIL ' + $m) -ForegroundColor Red }

Line
Write-Host ' DSH Voice - first run check' -ForegroundColor Cyan
Line
Write-Host ''

# --- 1. one recording: level + recognition --------------------------------
Write-Host '1/2  Say the wake word out loud now. Recording for 5 seconds...' -ForegroundColor White
Write-Host ('     >>> ' + $WAKE + ' <<<') -ForegroundColor Yellow
Start-Sleep -Seconds 1

$wav = Join-Path $env:TEMP 'dsh-voice-check.wav'
if (Test-Path $wav) { Remove-Item $wav -Force }
& $ffmpeg -hide_banner -loglevel error -f dshow -i ("audio=" + $device) -t 5 `
  -af 'highpass=f=90,volume=20dB' -ar 16000 -ac 1 -y $wav 2>$null

if (-not (Test-Path $wav)) {
  Bad 'could not record (microphone busy or missing)'
} else {
  $probe = & $ffmpeg -hide_banner -i $wav -af volumedetect -f null - 2>&1 | Out-String
  $peak = [regex]::Match($probe, 'max_volume:\s*(-?[\d.]+) dB')
  if ($peak.Success) {
    $db = [double]$peak.Groups[1].Value
    Write-Host ('     peak = ' + $db + ' dBFS')
    if ($db -lt -40) { Bad 'essentially silent - the wrong input device or a muted microphone' }
    elseif ($db -lt -30) { Warn 'very quiet - move closer, or raise the Windows input volume' }
    elseif ($db -lt -18) { Warn 'usable but quiet - speak a little louder' }
    else { Good 'level is healthy' }
  }

  $listen = Join-Path $here 'listen.js'
  if ((Test-Path $listen) -and (Test-Path $nodeExe)) {
    $env:ELECTRON_RUN_AS_NODE = '1'
    $env:VOICE_DRY_RUN = '1'
    $out = & $nodeExe $listen --feed $wav 2>&1 | Out-String
    Remove-Item Env:VOICE_DRY_RUN -ErrorAction SilentlyContinue
    $heard = [regex]::Match($out, 'heard \([^)]*\):\s*(.+)')
    if ($heard.Success) {
      Good ('recognized: ' + $heard.Groups[1].Value.Trim())
    } else {
      Bad 'nothing recognized - check the level verdict above'
    }
  }
}
Write-Host ''

# --- 2. voice output -------------------------------------------------------
Write-Host '2/2  Voice output' -ForegroundColor White
if ($voicePy -and (Test-Path (Join-Path $here 'speak-edge.py'))) {
  & $voicePy (Join-Path $here 'speak-edge.py') $SAY_TEST $config.tts.voice $config.tts.rate 2>$null
  if ($LASTEXITCODE -eq 0) { Good 'neural voice played' } else { Warn 'edge-tts failed; SAPI fallback will be used' }
} else {
  Warn 'python or speak-edge.py missing; SAPI will be used'
}

Line
Write-Host ' Done. Say the wake word, then one short command.' -ForegroundColor Cyan
Write-Host (' Log: ' + (Join-Path $here 'daemon.log'))
Line
