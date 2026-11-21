param(
  [Parameter(Mandatory = $true)][string]$CommandLine,
  [string]$WorkingDirectory = '',
  [string]$Name = 'detached'
)
# Start a process that is NOT a child of the calling shell/job:
# Win32_Process.Create makes WmiPrvSE the parent, so terminal/session cleanup
# (and this agent's job objects) cannot reap it.
$ErrorActionPreference = 'Stop'
if (-not $WorkingDirectory) { $WorkingDirectory = (Get-Location).Path }

$startup = ([wmiclass]'Win32_ProcessStartup').CreateInstance()
$startup.ShowWindow = 0
$startup.CreateFlags = 0x00000008   # CREATE_NO_WINDOW

$result = ([wmiclass]'Win32_Process').Create($CommandLine, $WorkingDirectory, $startup)
if ($result.ReturnValue -ne 0) {
  Write-Output ("error=" + $result.ReturnValue + " name=" + $Name)
  exit 1
}
Write-Output ("launched " + $Name + " pid=" + $result.ProcessId)
