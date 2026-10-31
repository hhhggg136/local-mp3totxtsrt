; Install only inside the current user's profile. No services or automatic start.
#ifndef AppArch
 #define AppArch "x64"
#endif
#define AppVersion "0.7.1"
[Setup]
SourceDir=..
AppId={{D0D58A6A-F2F5-4608-933F-9CD44CA756DB}
AppName=听听兽 · 本地字幕工具
AppVersion={#AppVersion}
AppPublisher=JING
DefaultDirName={localappdata}\Programs\TingTingBeast
DefaultGroupName=听听兽
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
SetupIconFile=.local\win-{#AppArch}\assets\listening-mascot.ico
UninstallDisplayIcon={app}\assets\listening-mascot.ico
OutputDir=dist\windows
OutputBaseFilename=TingTingBeast-{#AppVersion}-Windows-{#AppArch}-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
LicenseFile=LICENSE
#if AppArch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
MinVersion=10.0.22000
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.18362
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut with the TingTingBeast icon"; Flags: checkedonce

[Files]
Source: ".local\win-{#AppArch}\dist\TingTingBeast\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\听听兽 · 本地字幕工具"; Filename: "{app}\TingTingBeast.exe"; IconFilename: "{app}\assets\listening-mascot.ico"
Name: "{userdesktop}\听听兽 · 本地字幕工具"; Filename: "{app}\TingTingBeast.exe"; IconFilename: "{app}\assets\listening-mascot.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\TingTingBeast.exe"; Description: "Launch TingTingBeast"; Flags: nowait postinstall skipifsilent
