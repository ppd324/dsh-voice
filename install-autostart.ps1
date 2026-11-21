param(
  [switch]$Remove
)
# Register (or remove) the logon autostart entries for DSH Desktop and the voice daemon.
$ErrorActionPreference = 'Stop'
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$vbs = Join-Path $here 'start-daemon.vbs'
$dshExe = 'D:\dsh\DeepSeek Harness.exe'

if ($Remove) {
  foreach ($n in @('DSHVoice', 'DeepSeekHarness', 'DSHVoiceWatchdog')) {
    if ((Get-ItemProperty -Path $key -Name $n -ErrorAction SilentlyContinue)) {
      Remove-ItemProperty -Path $key -Name $n
      Write-Output "removed $n"
    }
  }
  exit 0
}

if (-not (Test-Path $vbs)) { throw "missing $vbs" }
if (-not (Test-Path $dshExe)) { throw "missing $dshExe" }

$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
Set-ItemProperty -Path $key -Name 'DSHVoice' -Value ('"' + $wscript + '" "' + $vbs + '"') -Type String
Set-ItemProperty -Path $key -Name 'DeepSeekHarness' -Value ('"' + $dshExe + '"') -Type String

# watchdog: keeps the daemon alive even if the app restart kills it
$watchdog = Join-Path $here 'watchdog.ps1'
$psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
Set-ItemProperty -Path $key -Name 'DSHVoiceWatchdog' -Value ('"' + $psExe + '" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $watchdog + '"') -Type String

Write-Output '--- registered ---'
Write-Output ('DeepSeekHarness = ' + (Get-ItemProperty -Path $key -Name 'DeepSeekHarness').DeepSeekHarness)
Write-Output ('DSHVoice        = ' + (Get-ItemProperty -Path $key -Name 'DSHVoice').DSHVoice)
