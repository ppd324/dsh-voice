' Hidden launcher for the voice watchdog (survives app restarts and shell exits).
Option Explicit
Dim sh, fso, here, ps1, ps
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(here, "watchdog.ps1")
ps = sh.ExpandEnvironmentStrings("%WINDIR%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
If Not fso.FileExists(ps1) Then WScript.Quit 3
sh.Run """" & ps & """ -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & ps1 & """", 0, False
