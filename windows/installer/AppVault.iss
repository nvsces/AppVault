; Compiled by scripts/package.ps1. Keep AppId stable across upgrades.
#if VER < EncodeVer(6, 3, 0)
  #error Inno Setup 6.3 or newer is required
#endif
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef AppFileVersion
  #error AppFileVersion is required
#endif
#ifndef SourceDir
  #error SourceDir is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif

[Setup]
AppId={{14AC75B1-A8C5-47B6-BB6D-62B6656402E4}
AppName=AppVault
AppVersion={#AppVersion}
AppPublisher=AppVault
VersionInfoVersion={#AppFileVersion}
DefaultDirName={localappdata}\Programs\AppVault
DefaultGroupName=AppVault
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename=AppVault-Setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\AppVault.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
CloseApplicationsFilter=*.exe,*.dll
RestartApplications=no
Uninstallable=yes

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; Remove stale Flutter assets during upgrades; user data is outside {app}.
Type: filesandordirs; Name: "{app}\data\flutter_assets"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\AppVault"; Filename: "{app}\AppVault.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\AppVault"; Filename: "{app}\AppVault.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\AppVault.exe"; Description: "{cm:LaunchProgram,AppVault}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent
