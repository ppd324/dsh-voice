# Start the control panel server detached (WMI), then the app window.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$server = Join-Path $here 'gui\server.js'
$node = Join-Path $env:USERPROFILE '.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe'
if (-not (Test-Path $node)) { $node = 'node.exe' }
if (-not (Test-Path $server)) { throw 'gui/server.js missing' }

$already = Get-CimInstance Win32_Process |
  Where-Object { $_.Name -eq 'node.exe' -and $_.CommandLine -like '*gui\server.js*' }
if (-not $already) {
  $startup = ([wmiclass]'Win32_ProcessStartup').CreateInstance()
  $startup.ShowWindow = 0
  $startup.CreateFlags = 0x00000008
  $r = ([wmiclass]'Win32_Process').Create(('"' + $node + '" "' + $server + '"'), $here, $startup)
  if ($r.ReturnValue -eq 0) { Write-Output ('server started pid=' + $r.ProcessId) }
  else { throw ('server start failed rc=' + $r.ReturnValue) }
  Start-Sleep -Milliseconds 800
}

$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
if (-not (Test-Path $edge)) { $edge = 'C:\Program Files\Microsoft\Edge\Application\msedge.exe' }
$url = 'http://127.0.0.1:7788/#components'
if (Test-Path $edge) { Start-Process $edge -ArgumentList ('--app=' + $url), '--window-size=1020,780' }
else { Start-Process $url }
