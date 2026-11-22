' Hidden launcher for the dsh-voice daemon + floating orb.
' Prefers the standalone Node runtime so the daemon survives quitting the DSH app;
' falls back to the Electron binary in Node mode when that runtime is missing.
Option Explicit
Dim sh, fso, here, js, orb, exe, nodeExe, ps
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
js = fso.BuildPath(here, "listen.js")
orb = fso.BuildPath(here, "orb.ps1")
exe = "D:\dsh\DeepSeek Harness.exe"
ps = sh.ExpandEnvironmentStrings("%WINDIR%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
nodeExe = sh.ExpandEnvironmentStrings("%USERPROFILE%") & "\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe"

If Not fso.FileExists(js) Then WScript.Quit 3

' floating orb first, hidden console (the WinForms window is created by the script)
If fso.FileExists(orb) Then
  sh.Run """" & ps & """ -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & orb & """", 0, False
End If

sh.CurrentDirectory = here
If fso.FileExists(nodeExe) Then
  ' standalone: independent of the DSH app process tree
  sh.Run """" & nodeExe & """ """ & js & """", 0, False
Else
  ' fallback: packaged Electron in Node mode
  sh.Environment("Process")("ELECTRON_RUN_AS_NODE") = "1"
  sh.Run """" & exe & """ """ & js & """", 0, False
End If
