param([int]$TargetPid = 0)
# Enumerate top-level windows and their bounds; filter by process id when given.
$cs = @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class WinEnum {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  public struct RECT { public int L, T, R, B; }
  public static string[] List(int target) {
    var outList = new List<string>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (target == 0 || pid == (uint)target) {
        var sb = new StringBuilder(256);
        GetWindowTextW(h, sb, 256);
        var cls = new StringBuilder(256);
        GetClassNameW(h, cls, 256);
        RECT r; GetWindowRect(h, out r);
        outList.Add(String.Format("hwnd={0} pid={1} visible={2} class={3} title={4} rect={5},{6},{7},{8}",
          h, pid, IsWindowVisible(h), cls.ToString(), sb.ToString(), r.L, r.T, r.R, r.B));
      }
      return true;
    }, IntPtr.Zero);
    return outList.ToArray();
  }
}
'@
Add-Type -TypeDefinition $cs -Language CSharp
$rows = [WinEnum]::List($TargetPid)
if ($rows.Count -eq 0) { Write-Output "no windows for pid=$TargetPid" } else { $rows | ForEach-Object { Write-Output $_ } }
