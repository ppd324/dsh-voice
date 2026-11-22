param(
  [Parameter(Mandatory = $true)][string]$Wav,
  [string]$DeviceId = '',      # empty = system default endpoint
  [int]$TimeoutSeconds = 120
)
# Play a wav file to a specific render device (WASAPI shared mode) via NAudio.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Get-ChildItem (Join-Path $here 'bin\naudio') -Filter *.dll | ForEach-Object {
  [void][System.Reflection.Assembly]::LoadFrom($_.FullName)
}

$en = New-Object NAudio.CoreAudioApi.MMDeviceEnumerator
if ($DeviceId) {
  $device = $en.GetDevice($DeviceId)
} else {
  $device = $en.GetDefaultAudioEndpoint([NAudio.CoreAudioApi.DataFlow]::Render, [NAudio.CoreAudioApi.Role]::Multimedia)
}
if (-not $device) { throw 'render device not found' }
try {
  $log = Join-Path $here 'playback.log'
  Add-Content -Path $log -Value ((Get-Date -Format o) + ' device=' + $device.FriendlyName + ' wav=' + (Split-Path -Leaf $Wav)) -Encoding UTF8
} catch {}

$reader = New-Object NAudio.Wave.WaveFileReader($Wav)
$out = New-Object NAudio.Wave.WasapiOut($device, [NAudio.CoreAudioApi.AudioClientShareMode]::Shared, $false, 100)
try {
  $out.Init($reader)
  $out.Play()
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ($out.PlaybackState -eq [NAudio.Wave.PlaybackState]::Playing -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 50
  }
} finally {
  try { $out.Stop() } catch {}
  $out.Dispose()
  $reader.Dispose()
}
