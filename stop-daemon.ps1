param([switch]$Quiet)
# Stop the dsh-voice daemon (pid file), the floating orb, and any ffmpeg capture child.
$ErrorActionPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidFile = Join-Path $here 'daemon.pid'
$stopped = @()

if (Test-Path $pidFile) {
  $daemonPid = 0
  [int]::TryParse((Get-Content $pidFile -Raw).Trim(), [ref]$daemonPid) | Out-Null
  if ($daemonPid -gt 0) {
    if (Get-Process -Id $daemonPid -ErrorAction SilentlyContinue) {
      Stop-Process -Id $daemonPid -Force
      $stopped += "daemon:$daemonPid"
    }
  }
  Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

# floating orb (WinForms host process running orb.ps1)
Get-CimInstance -ClassName Win32_Process | Where-Object {
  $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*orb.ps1*'
} | ForEach-Object {
  Stop-Process -Id $_.ProcessId -Force
  $stopped += "orb:$($_.ProcessId)"
}

Get-Process ffmpeg -ErrorAction SilentlyContinue | ForEach-Object {
  Stop-Process -Id $_.Id -Force
  $stopped += "ffmpeg:$($_.Id)"
}

if (-not $Quiet) {
  if ($stopped.Count) { Write-Output ('stopped ' + ($stopped -join ', ')) } else { Write-Output 'nothing running' }
}
