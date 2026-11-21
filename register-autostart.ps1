# Register the voice stack autostart entry (HKCU Run), pointing at start-all.vbs
# which launches everything detached through WMI.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
$startAll = Join-Path $here 'start-all.vbs'

Set-ItemProperty -Path $key -Name 'DSHVoice' -Value ('"' + $wscript + '" "' + $startAll + '"') -Type String
Remove-ItemProperty -Path $key -Name 'DSHVoiceWatchdog' -ErrorAction SilentlyContinue

$dsh = (Get-ItemProperty $key).DeepSeekHarness
if (-not $dsh) { Set-ItemProperty -Path $key -Name 'DeepSeekHarness' -Value ('"D:\dsh\DeepSeek Harness.exe"') -Type String }

Get-ItemProperty $key | Select-Object DeepSeekHarness, DSHVoice, DSHVoiceWatchdog | Format-List
