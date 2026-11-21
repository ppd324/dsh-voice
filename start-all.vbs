' Hidden entry point: runs start-all.ps1, which creates the daemon and the
' watchdog through WMI so they are not children of any terminal or job object.
Option Explicit
Dim sh, fso, here, ps1, ps
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(here, "start-all.ps1")
ps = sh.ExpandEnvironmentStrings("%WINDIR%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
If Not fso.FileExists(ps1) Then WScript.Quit 3
sh.Run """" & ps & """ -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """", 0, False
