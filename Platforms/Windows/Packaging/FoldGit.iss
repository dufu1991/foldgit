[Setup]
AppId=dufu.FoldGit
AppName=FoldGit
AppVersion={#AppVersion}
AppPublisher=dufu
AppPublisherURL=https://foldgit.com
AppSupportURL=https://github.com/dufu1991/foldgit/issues
DefaultDirName={localappdata}\Programs\FoldGit
DefaultGroupName=FoldGit
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed={#AllowedArchitecture}
ArchitecturesInstallIn64BitMode={#AllowedArchitecture}
MinVersion=10.0.26100
OutputDir={#OutputDirectory}
OutputBaseFilename=FoldGit-{#AppVersion}-Windows-{#Architecture}
SetupIconFile=..\src\FoldGit.App\Assets\FoldGit.ico
UninstallDisplayIcon={app}\FoldGit.App.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Files]
Source: "{#PublishDirectory}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.pdb"

[Icons]
Name: "{autoprograms}\FoldGit"; Filename: "{app}\FoldGit.App.exe"

[Run]
Filename: "{app}\FoldGit.App.exe"; Description: "Launch FoldGit"; Flags: nowait postinstall skipifsilent
