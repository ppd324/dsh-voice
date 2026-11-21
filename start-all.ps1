$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$startup = ([wmiclass]'Win32_ProcessStartup').CreateInstance()
$startup.ShowWindow = 0
$startup.CreateFlags = 0x00000008
foreach ($vbs in @('start-daemon.vbs', 'start-watchdog.vbs')) {
  $path = Join-Path $here $vbs
  if (-not (Test-Path $path)) { continue }
  $r = ([wmiclass]'Win32_Process').Create('wscript.exe "' + $path + '"', $here, $startup)
  if ($r.ReturnValue -eq 0) { Write-Output ('started ' + $vbs + ' pid=' + $r.ProcessId) }
  else { Write-Output ('failed ' + $vbs + ' rc=' + $r.ReturnValue) }
}
