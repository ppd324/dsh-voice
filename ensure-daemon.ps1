# Ensure the voice daemon is running; start it when the pid file is missing or stale.
$ErrorActionPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidFile = Join-Path $here 'daemon.pid'
$vbs = Join-Path $here 'start-daemon.vbs'
$log = Join-Path $here 'watchdog.log'

function Write-WatchdogLog([string]$message) {
  try { Add-Content -Path $log -Value ((Get-Date -Format o) + ' ' + $message) -Encoding UTF8 } catch {}
}

$alive = $false
if (Test-Path $pidFile) {
  $raw = (Get-Content $pidFile -Raw).Trim()
  if ($raw -match '^\d+$') {
    $proc = Get-Process -Id ([int]$raw) -ErrorAction SilentlyContinue
    if ($proc) { $alive = $true }
  }
}

if ($alive) { return }

Write-WatchdogLog 'daemon not running; starting'
if (Test-Path $vbs) {
  Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + $vbs + '"') -WindowStyle Hidden
  Start-Sleep -Seconds 3
  if (Test-Path $pidFile) { Write-WatchdogLog ('started pid=' + (Get-Content $pidFile -Raw).Trim()) }
} else {
  Write-WatchdogLog 'start-daemon.vbs missing'
}
