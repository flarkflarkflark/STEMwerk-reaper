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
DefaultDirName={userappdata}\REAPER\Scripts\STEMwerk-reaper
DefaultGroupName=STEMwerk
DisableProgramGroupPage=yes
OutputDir=dist
OutputBaseFilename=STEMwerk-Setup-{#MyAppVersion}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
InfoAfterFile=after_install.txt

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; Core files needed to run in REAPER
Source: "..\..\scripts\reaper\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "..\..\i18n\*"; DestDir: "{app}\i18n"; Flags: recursesubdirs createallsubdirs ignoreversion

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
