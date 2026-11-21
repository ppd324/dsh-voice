param(
  [Parameter(Mandatory=$true)][string]$ProcessName = 'douyin',
  [ValidateSet('maximize','restore','minimize','foreground')][string]$Action = 'maximize'
)
# Maximize / restore / focus the main window of a process (ASCII-only source).
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WM {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte v, byte s, uint f, UIntPtr e);
}
"@

$p = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { Write-Output "error=no-window process=$ProcessName"; exit 3 }

$h = $p.MainWindowHandle
switch ($Action) {
  'maximize' { [WM]::ShowWindow($h, 3) | Out-Null }   # SW_MAXIMIZE
  'restore'  { [WM]::ShowWindow($h, 9) | Out-Null }   # SW_RESTORE
  'minimize' { [WM]::ShowWindow($h, 6) | Out-Null }   # SW_MINIMIZE
}

# foreground unlock, so the window also comes to the front
[WM]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
[WM]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 60
[WM]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 200

Write-Output ("ok action=$Action pid=" + $p.Id + " hwnd=$h")
