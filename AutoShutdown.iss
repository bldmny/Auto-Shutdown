#define MyAppName "Auto Shutdown"
#define MyAppVersion "1.1"
#define MyAppExeName "AutoShutdown.exe"
#define SourceDir "..\release\app"
#define InstallerOutputDir "..\release\installer"
#define AppIcon "..\outputs\AutoShutdown.ico"

[Setup]
AppId={{2E34D0F8-92B4-4F47-B98B-4D24C4E2D287}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} v{#MyAppVersion}
AppPublisher=Ciara
DefaultDirName={localappdata}\Programs\{#MyAppName}
DisableDirPage=no
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#InstallerOutputDir}
OutputBaseFilename=AutoShutdownSetup-v{#MyAppVersion}
SetupIconFile={#AppIcon}
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
UsedUserAreasWarning=no
CloseApplications=no
VersionInfoVersion=1.1.0.0
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppVersion}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\AutoShutdown.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\AutoShutdown.exe.config"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\NetworkAutoShutdown.xaml"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\AutoShutdown.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\{#MyAppName}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\AutoShutdown.ico"
Name: "{userdesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\AutoShutdown.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: files; Name: "{app}\settings.ini"
Type: files; Name: "{app}\settings.*.tmp"
Type: files; Name: "{app}\settings.*.bak"
Type: dirifempty; Name: "{app}"
