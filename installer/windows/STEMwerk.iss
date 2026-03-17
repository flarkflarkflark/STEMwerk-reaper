#define MyAppName "STEMwerk"
#define MyAppPublisher "flarkAUDIO <flarkaudio@pm.me>"
#define MyAppURL "https://github.com/flarkflarkflark/STEMwerk"

; Version comes from env in CI (fallback to 0.0.0 locally)
#define MyAppVersion GetEnv('STEMWERK_VERSION')
#if MyAppVersion == ""
  #define MyAppVersion "0.0.0"
#endif

[Setup]
AppId={{9A6BDA0D-6A2A-4B36-9C3B-1D4C77E5D0A3}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
#if FileExists('..\assets\stemwerk.ico')
SetupIconFile=..\assets\stemwerk.ico
#endif
#if FileExists('..\assets\stemwerk-wizard.bmp')
WizardImageFile=..\assets\stemwerk-wizard.bmp
#endif
#if FileExists('..\assets\stemwerk-wizard-small.bmp')
WizardSmallImageFile=..\assets\stemwerk-wizard-small.bmp
#endif
DefaultDirName={userdocs}\STEMwerk
DefaultGroupName=STEMwerk
DisableProgramGroupPage=yes
OutputDir=dist
OutputBaseFilename=STEMwerk-Setup-{#MyAppVersion}
Compression=lzma
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; Core files needed to run in REAPER
Source: "..\..\scripts\reaper\*"; DestDir: "{app}\scripts\reaper"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "..\..\i18n\*"; DestDir: "{app}\i18n"; Flags: recursesubdirs createallsubdirs ignoreversion

; Non-nerd friendly: also install into the default REAPER Scripts folder (per-user).
; This makes STEMwerk immediately loadable from REAPER without manual copying.
Source: "..\..\scripts\reaper\*"; DestDir: "{userappdata}\REAPER\Scripts\STEMwerk\scripts\reaper"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "..\..\i18n\*"; DestDir: "{userappdata}\REAPER\Scripts\STEMwerk\i18n"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "..\..\docs\*"; DestDir: "{userappdata}\REAPER\Scripts\STEMwerk\docs"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "..\..\README.md"; DestDir: "{userappdata}\REAPER\Scripts\STEMwerk"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{userappdata}\REAPER\Scripts\STEMwerk"; Flags: ignoreversion
Source: "..\..\TODO.md"; DestDir: "{userappdata}\REAPER\Scripts\STEMwerk"; Flags: ignoreversion
Source: "..\..\INTEGRATION.md"; DestDir: "{userappdata}\REAPER\Scripts\STEMwerk"; Flags: ignoreversion
Source: "..\..\TESTING.md"; DestDir: "{userappdata}\REAPER\Scripts\STEMwerk"; Flags: ignoreversion

; Helpful docs
Source: "..\..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\TODO.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\INTEGRATION.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\TESTING.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\STEMwerk\Open install folder"; Filename: "{app}"
Name: "{userprograms}\STEMwerk\README"; Filename: "{app}\README.md"

[Run]
Filename: "{app}\README.md"; Description: "Open README"; Flags: postinstall shellexec skipifsilent
