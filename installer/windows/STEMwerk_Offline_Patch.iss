#define MyAppName "STEMwerk Offline Patch"
#define MyAppPublisher "flarkAUDIO <flarkaudio@pm.me>"
#define MyAppURL "https://github.com/flarkflarkflark/STEMwerk"

; Version comes from env in CI. Local builds fall back to the repo VERSION file.
#define MyAppVersion GetEnv('STEMWERK_VERSION')
#if MyAppVersion == ""
  #define VersionFile "..\..\VERSION"
  #if FileExists(VersionFile)
    #define VersionHandle FileOpen(VersionFile)
    #if VersionHandle
      #define MyAppVersion Trim(FileRead(VersionHandle))
      #expr FileClose(VersionHandle)
    #endif
  #endif
#endif
#if MyAppVersion == ""
  #error STEMWERK_VERSION is not set and VERSION could not be read.
#endif

[Setup]
AppId={{B0E7A7AF-7A48-4305-BF6A-BBE489BC4A5E}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
#if FileExists('..\assets\stemwerk.ico')
SetupIconFile=..\assets\stemwerk.ico
#endif
DefaultDirName={userappdata}\REAPER\Scripts\STEMwerk-reaper
DisableProgramGroupPage=yes
OutputDir=dist
OutputBaseFilename=STEMwerk-{#MyAppVersion}-offline-patch
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
Uninstallable=no
CreateAppDir=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\..\scripts\reaper\*"; DestDir: "{app}"; Excludes: "*.bak,*.bak2,*.pyc,sync_to_reaper.sh,STEMwerk_Enable_Debug.lua,STEMwerk_Disable_Debug.lua,STEMwerk_Set_FFmpegPath.lua,STEMwerk_Set_PythonPath.lua,STEMwerk_separate.lua,__pycache__\*,assets\toolbar_icons\stemwerk_*.png,vendor\stemwerk-core\build\*,vendor\stemwerk-core\src\*.egg-info\*"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Code]
function InstallRootLooksValid(const Dir: string): Boolean;
begin
  Result :=
    FileExists(AddBackslash(Dir) + 'STEMwerk.lua') and
    FileExists(AddBackslash(Dir) + 'i18n\languages.lua');
end;

function InitializeSetup: Boolean;
var
  DefaultDir: string;
begin
  DefaultDir := ExpandConstant('{userappdata}\REAPER\Scripts\STEMwerk-reaper');
  if not InstallRootLooksValid(DefaultDir) then
  begin
    SuppressibleMsgBox(
      'This patch updates an existing STEMwerk offline installation.' + #13#10 + #13#10 +
      'Select your current STEMwerk install folder in the next step.' + #13#10 +
      'Expected folder contents include STEMwerk.lua and i18n\\languages.lua.',
      mbInformation,
      MB_OK,
      IDOK
    );
  end;
  Result := True;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = wpSelectDir then
  begin
    if not InstallRootLooksValid(WizardDirValue) then
    begin
      SuppressibleMsgBox(
        'Choose the existing STEMwerk installation folder.' + #13#10 + #13#10 +
        'The selected folder must already contain:' + #13#10 +
        '- STEMwerk.lua' + #13#10 +
        '- i18n\\languages.lua',
        mbError,
        MB_OK,
        IDOK
      );
      Result := False;
    end;
  end;
end;

function BuildPatchFinishedSummary: string;
begin
  Result :=
    'Patch completed successfully.' + #13#10 + #13#10 +
    'What was updated:' + #13#10 +
    '- REAPER scripts in:' + #13#10 +
    '  ' + WizardDirValue + #13#10 +
    '- Language files in:' + #13#10 +
    '  ' + AddBackslash(WizardDirValue) + 'i18n' + #13#10 + #13#10 +
    'What was kept as-is:' + #13#10 +
    '- Runtime folder: %LOCALAPPDATA%\STEMwerk' + #13#10 +
    '- Cached models and downloaded dependencies';
end;

procedure InitializeWizard;
begin
  WizardForm.WelcomeLabel1.Caption := 'STEMwerk offline patch';
  WizardForm.WelcomeLabel2.Caption :=
    'This small patch updates an existing offline STEMwerk install without replacing your bundled models or runtime.';
  WizardForm.FinishedHeadingLabel.Caption := 'Patch applied successfully';
  WizardForm.FinishedLabel.Caption := BuildPatchFinishedSummary;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpFinished then
  begin
    WizardForm.FinishedHeadingLabel.Caption := 'Patch applied successfully';
    WizardForm.FinishedLabel.Caption := BuildPatchFinishedSummary;
  end;
end;
