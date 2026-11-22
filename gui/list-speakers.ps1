# Enumerate render endpoints for the control panel: one "name|id|isDefault" line each.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$voice = Split-Path -Parent $here
Get-ChildItem (Join-Path $voice 'bin\naudio') -Filter *.dll | ForEach-Object {
  [void][System.Reflection.Assembly]::LoadFrom($_.FullName)
}
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$en = New-Object NAudio.CoreAudioApi.MMDeviceEnumerator
$def = $en.GetDefaultAudioEndpoint([NAudio.CoreAudioApi.DataFlow]::Render, [NAudio.CoreAudioApi.Role]::Multimedia)
foreach ($d in $en.EnumerateAudioEndPoints([NAudio.CoreAudioApi.DataFlow]::Render, [NAudio.CoreAudioApi.DeviceState]::Active)) {
  if ($d.ID -eq $def.ID) { Write-Output ($d.FriendlyName + '|' + $d.ID + '|1') }
  else { Write-Output ($d.FriendlyName + '|' + $d.ID + '|0') }
}
