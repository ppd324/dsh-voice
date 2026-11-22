param(
  [string]$VoiceDir = (Split-Path -Parent $MyInvocation.MyCommand.Path),
  [switch]$Desktop
)
# Create a Start-menu (and optionally desktop) shortcut that launches the control
# panel and carries the app icon. Used by the ZIP install path.
$ErrorActionPreference = 'Stop'
$shell = New-Object -ComObject WScript.Shell
$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
$launcher = Join-Path $VoiceDir 'start-gui.vbs'
$icon = Join-Path $VoiceDir 'assets\icon.ico'

if (-not (Test-Path $launcher)) { throw "start-gui.vbs not found in $VoiceDir" }

$targets = @(Join-Path ([Environment]::GetFolderPath('Programs')) 'DSH Voice.lnk')
if ($Desktop) { $targets += Join-Path ([Environment]::GetFolderPath('Desktop')) 'DSH Voice.lnk' }

foreach ($lnk in $targets) {
  $sc = $shell.CreateShortcut($lnk)
  $sc.TargetPath = $wscript
  $sc.Arguments = '"' + $launcher + '"'
  $sc.WorkingDirectory = $VoiceDir
  if (Test-Path $icon) { $sc.IconLocation = $icon }
  $sc.Description = 'DSH Voice 控制面板'
  $sc.Save()
  Write-Output ('created ' + $lnk)
}
