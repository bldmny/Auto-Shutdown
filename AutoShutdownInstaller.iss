#define MyAppName "Auto Shutdown"
#define MyAppVersion "1.0"
#define MyAppExeName "AutoShutdown.exe"

[Setup]
AppId={{A74DC681-8E49-4F22-88E4-A3F5285C1F72}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={localappdata}\Programs\Auto Shutdown
DefaultGroupName=Auto Shutdown
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=Installer Output
OutputBaseFilename=AutoShutdownSetup
SetupIconFile=AutoShutdown.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "AutoShutdown.exe"; DestDir: "{app}"; Flags: ignoreversion

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Icons]
Name: "{group}\Auto Shutdown"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{autodesktop}\Auto Shutdown"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[UninstallDelete]
Type: files; Name: "{app}\settings.ini"
Type: files; Name: "{app}\settings.*.tmp"
Type: files; Name: "{app}\settings.*.bak"
Type: dirifempty; Name: "{app}"