param(
  [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text,
  [switch]$Submit,
  [string]$WindowTitle = 'DeepSeek Harness',
  [int]$RetrySeconds = 15,
  [switch]$NewSession
)
# Inject text into the DSH composer: activate window -> locate composer via UIA -> click it -> paste -> optional Enter.
# Safety: aborts before pasting unless the DSH window is confirmed foreground and the composer was found.
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
}
"@

$proc = Get-Process | Where-Object {
  $_.MainWindowTitle -like "*$WindowTitle*" -and $_.ProcessName -like 'DeepSeek*'
} | Select-Object -First 1
if (-not $proc) { Write-Output "error=window-not-found"; exit 3 }
$hwnd = $proc.MainWindowHandle

function Activate([IntPtr]$h) {
  if ([W]::IsIconic($h)) { [W]::ShowWindow($h, 9) | Out-Null; Start-Sleep -Milliseconds 200 }
  [W]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
  [W]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  if ([W]::SetForegroundWindow($h)) { return $true }
  $fg = [W]::GetForegroundWindow(); $pidFg = 0
  $tFg = [W]::GetWindowThreadProcessId($fg, [ref]$pidFg)
  $tMe = [W]::GetCurrentThreadId()
  [W]::AttachThreadInput($tMe, $tFg, $true) | Out-Null
  $r = [W]::SetForegroundWindow($h)
  [W]::AttachThreadInput($tMe, $tFg, $false) | Out-Null
  return $r
}

$focused = $false
for ($i = 0; $i -lt 4 -and -not $focused; $i++) {
  Activate $hwnd | Out-Null
  Start-Sleep -Milliseconds 180
  $focused = ([W]::GetForegroundWindow() -eq $hwnd)
}
if (-not $focused) { Write-Output "error=no-foreground action=abort"; exit 4 }

# Locate the composer: the Edit control in the lower half of the window.
function Find-Composer($rootEl) {
  $cond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Edit)
  $edits = $rootEl.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
  # 取面积最大的 Edit: 会话视图在底部, 新会话视图在中上部, 面积判据对两者都成立
  $best = $null
  $bestArea = 0
  foreach ($e in $edits) {
    $r = $e.Current.BoundingRectangle
    if ($r.Width -lt 200) { continue }
    $area = $r.Width * $r.Height
    if ($area -gt $bestArea) { $bestArea = $area; $best = $e }
  }
  return $best
}

$root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)

if ($NewSession) {
  # 通过「新建会话」按钮开一个干净会话, 避免把语音指令塞进当前对话
  $btnCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Button)
  $buttons = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond)
  $newBtn = $null
  foreach ($b in $buttons) {
    if ($b.Current.Name -match '新建会话|New session|New chat') {
      $obj = $null
      try { if ($b.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$obj)) { $newBtn = $b; break } } catch {}
    }
  }
  if (-not $newBtn) { Write-Output "error=new-session-button-not-found"; exit 8 }
  $newBtn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 1600
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
}

$composer = Find-Composer $root
if (-not $composer) { Write-Output "error=composer-not-found"; exit 5 }

$cr = $composer.Current.BoundingRectangle
$cx = [int]($cr.X + $cr.Width / 2)
$cy = [int]($cr.Y + $cr.Height / 2)
[W]::SetCursorPos($cx, $cy) | Out-Null
Start-Sleep -Milliseconds 80
[W]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)   # left down
[W]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)   # left up
Start-Sleep -Milliseconds 180

Set-Clipboard -Value $Text
Start-Sleep -Milliseconds 120
# 先清空草稿: 残留内容会让语音指令拼接成错误的命令
[System.Windows.Forms.SendKeys]::SendWait('^a')
Start-Sleep -Milliseconds 60
[System.Windows.Forms.SendKeys]::SendWait('{DEL}')
Start-Sleep -Milliseconds 80
[System.Windows.Forms.SendKeys]::SendWait('^v')
Start-Sleep -Milliseconds 250

$valuePattern = $null
try { $valuePattern = $composer.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern) } catch {}

function Read-Composer {
  if (-not $valuePattern) { return $null }
  try { return [string]$valuePattern.Current.Value } catch { return $null }
}

$typed = Read-Composer

# 空文本 = 只清空输入框(调试/清理用)
if ($Text.Length -eq 0) { Write-Output "ok cleared"; exit 0 }

if ($null -ne $typed -and $typed.Length -eq 0) {
  Write-Output "error=paste-failed action=abort"
  exit 6
}

function Focus-Composer {
  [W]::SetCursorPos($cx, $cy) | Out-Null
  Start-Sleep -Milliseconds 60
  [W]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  [W]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 130
}

if ($Submit) {
  # agent 忙时回车可能被忽略, 因此在窗口内重试, 而不是去点按钮(那可能是"停止")
  $deadline = (Get-Date).AddSeconds($RetrySeconds)
  $attempts = 0
  $left = Read-Composer
  while (($null -eq $left -or $left.Trim().Length -gt 0) -and (Get-Date) -lt $deadline) {
    $attempts++
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Start-Sleep -Milliseconds 800
    $left = Read-Composer
    if ($null -ne $left -and $left.Trim().Length -gt 0) {
      Focus-Composer
      [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
      Start-Sleep -Milliseconds 700
      $left = Read-Composer
    }
  }

  $remaining = if ($null -ne $left) { $left.Trim().Length } else { -1 }
  if ($remaining -ne 0) {
    # 放弃: 清掉输入框里的残留, 免得污染用户自己的草稿
    Focus-Composer
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    Start-Sleep -Milliseconds 80
    [System.Windows.Forms.SendKeys]::SendWait('{DEL}')
    Write-Output "fail submitted=False remaining=$remaining attempts=$attempts"
    exit 7
  }
  Write-Output "ok focused=True clicked=$cx,$cy submitted=True len=$($Text.Length) remaining=0 attempts=$attempts"
} else {
  $len = if ($null -ne $typed) { $typed.Length } else { -1 }
  Write-Output "ok focused=True clicked=$cx,$cy submitted=False len=$($Text.Length) composer=$len"
}
