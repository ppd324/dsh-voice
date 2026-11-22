; Inno Setup script for DSH Voice.
; Build with: ISCC.exe DSHVoice.iss   (Inno Setup 6)
; Produces DSHVoice-Setup-<version>.exe in ..\..\dist

#define AppName "DSH Voice"
#define AppVersion "0.2.0"
#define AppPublisher "DSH Voice"
#define SourceDir ".."

[Setup]
AppId={{8E2C1F0A-6D4B-4E2A-9B77-2C1A5E9D3F10}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\DSHVoice
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=DSHVoice-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName={#AppName}
SetupIconFile={#SourceDir}\assets\icon.ico
UninstallDisplayIcon={app}\assets\icon.ico

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion; \
  Excludes: "dist\*,installer\build-package.ps1,state.json,orb.heartbeat,*.log,voice-session.json,cache\*"
Source: "{#SourceDir}\bin\ffmpeg.exe"; DestDir: "{app}\bin"; Flags: ignoreversion skipifsourcedoesntexist

[Icons]
Name: "{userprograms}\DSH Voice\First run check"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\first-run.ps1"""; WorkingDir: "{app}"; \
  IconFilename: "{app}\assets\icon.ico"
Name: "{userprograms}\DSH Voice\Start voice assistant"; Filename: "{sys}\wscript.exe"; \
  Parameters: """{app}\start-daemon.vbs"""; WorkingDir: "{app}"; \
  IconFilename: "{app}\assets\icon.ico"
Name: "{userprograms}\DSH Voice\Stop voice assistant"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\stop-daemon.ps1"""; WorkingDir: "{app}"; \
  IconFilename: "{app}\assets\icon.ico"

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\installer\install-voice.ps1"" -InPlace"; \
  StatusMsg: "Preparing the voice profile and model cache..."; Flags: waituntilterminated
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\first-run.ps1"""; \
  Description: "Run the microphone and voice check now"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\stop-daemon.ps1"""; Flags: runhidden
  IconFilename: "{app}\assets\icon.ico"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\cache"
Type: filesandordirs; Name: "{app}\state.json"
