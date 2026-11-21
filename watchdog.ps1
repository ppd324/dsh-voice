# Keeps the voice daemon alive: checks every 60s, restarts when the pid is stale.
$ErrorActionPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidFile = Join-Path $here 'daemon.pid'
$vbs = Join-Path $here 'start-daemon.vbs'
$log = Join-Path $here 'watchdog.log'

# single instance via pid file (a stale mutex can block a fresh start)
$selfPid = Join-Path $here 'watchdog.pid'
if (Test-Path $selfPid) {
  $old = 0
  [int]::TryParse((Get-Content $selfPid -Raw).Trim(), [ref]$old) | Out-Null
  if ($old -gt 0 -and (Get-Process -Id $old -ErrorAction SilentlyContinue)) { exit 0 }
}
try { [System.IO.File]::WriteAllText($selfPid, [string]$PID) } catch {}

function Log([string]$m) { try { Add-Content -Path $log -Value ((Get-Date -Format o) + ' ' + $m) -Encoding UTF8 } catch {} }

Log 'watchdog started'
while ($true) {
  $alive = $false
  if (Test-Path $pidFile) {
    $raw = (Get-Content $pidFile -Raw).Trim()
    if ($raw -match '^\d+$') {
      if (Get-Process -Id ([int]$raw) -ErrorAction SilentlyContinue) { $alive = $true }
    }
  }
  if (-not $alive) {
    Log 'daemon down; restarting'
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + $vbs + '"') -WindowStyle Hidden
    Start-Sleep -Seconds 8
  }
  try { [System.IO.File]::WriteAllText((Join-Path $here 'watchdog.heartbeat'), [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString()) } catch {}
  Start-Sleep -Seconds 60
}
