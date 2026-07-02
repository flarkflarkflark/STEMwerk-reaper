#define MyAppName "STEMwerk Update Patch"
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
#if FileExists('..\assets\stemwerk-wizard.bmp')
WizardImageFile=..\assets\stemwerk-wizard.bmp
#endif
#if FileExists('..\assets\stemwerk-wizard-small-logo.bmp')
WizardSmallImageFile=..\assets\stemwerk-wizard-small-logo.bmp
#endif
DefaultDirName={userappdata}\REAPER\Scripts\STEMwerk-reaper
DisableProgramGroupPage=yes
OutputDir=dist
OutputBaseFilename=STEMwerk-{#MyAppVersion}-update-patch
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
Uninstallable=no
CreateAppDir=yes
DirExistsWarning=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\..\scripts\reaper\*"; DestDir: "{app}"; Excludes: "*.bak,*.bak2,*.pyc,.DS_Store,._*,__MACOSX\*,sync_to_reaper.sh,STEMwerk_Enable_Debug.lua,STEMwerk_Disable_Debug.lua,STEMwerk_Set_FFmpegPath.lua,STEMwerk_Set_PythonPath.lua,STEMwerk_separate.lua,__pycache__\*,themes\*,assets\toolbar_icons\stemwerk_*.png,vendor\stemwerk-core\build\*,vendor\stemwerk-core\src\*.egg-info\*"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "..\..\i18n\*"; DestDir: "{app}\i18n"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\docs\RELEASE_{#MyAppVersion}.md"; DestDir: "{app}\docs"; Flags: ignoreversion

[Code]
var
  DetectedOldVersion: string;
  ShowReleaseNotesCheckbox: TNewCheckBox;

function InstallRootLooksModern(const Dir: string): Boolean;
begin
  Result :=
    FileExists(AddBackslash(Dir) + 'STEMwerk.lua') and
    FileExists(AddBackslash(Dir) + 'i18n\languages.lua');
end;

function InstallRootLooksLegacy(const Dir: string): Boolean;
begin
  Result :=
    FileExists(AddBackslash(Dir) + 'STEMwerk.lua') and
    FileExists(AddBackslash(Dir) + 'audio_separator_process.py') and
    FileExists(AddBackslash(Dir) + '_internal\STEMwerk_Setup_Internal.lua');
end;

function InstallRootLooksValid(const Dir: string): Boolean;
begin
  Result := InstallRootLooksModern(Dir) or InstallRootLooksLegacy(Dir);
end;

function WrapPathForFinishLabel(const Path: string; MaxLineLen: Integer): string;
var
  Remaining: string;
  BreakPos: Integer;
  i: Integer;
begin
  Remaining := Path;
  Result := '';
  if MaxLineLen < 16 then
    MaxLineLen := 16;

  while Length(Remaining) > MaxLineLen do
  begin
    BreakPos := 0;
    for i := MaxLineLen downto 1 do
    begin
      if Remaining[i] = '\' then
      begin
        BreakPos := i;
        Break;
      end;
    end;

    if BreakPos <= 0 then
      BreakPos := MaxLineLen;

    Result := Result + Copy(Remaining, 1, BreakPos) + #13#10 + '  ';
    Remaining := Copy(Remaining, BreakPos + 1, Length(Remaining));
  end;

  Result := Result + Remaining;
end;

function ExtractVersionFromLine(const Line: string): string;
var
  StartPos: Integer;
  EndPos: Integer;
  Work: string;
begin
  Result := '';
  Work := Trim(Line);

  if Pos('APP_VERSION', Work) > 0 then
  begin
    StartPos := Pos('"', Work);
    if StartPos > 0 then
    begin
      EndPos := Pos('"', Copy(Work, StartPos + 1, Length(Work)));
      if EndPos > 0 then
      begin
        Result := Copy(Work, StartPos + 1, EndPos - 1);
        Exit;
      end;
    end;
  end;

  StartPos := Pos('@version', Work);
  if StartPos > 0 then
  begin
    Work := Trim(Copy(Work, StartPos + Length('@version'), Length(Work)));
    EndPos := Pos(' ', Work);
    if EndPos > 0 then
      Result := Copy(Work, 1, EndPos - 1)
    else
      Result := Work;
    Exit;
  end;
end;

function ReadFirstDetectedVersion(const FilePath: string): string;
var
  Lines: TArrayOfString;
  i: Integer;
  Parsed: string;
begin
  Result := '';
  if not FileExists(FilePath) then
    Exit;

  if not LoadStringsFromFile(FilePath, Lines) then
    Exit;

  for i := 0 to GetArrayLength(Lines) - 1 do
  begin
    Parsed := ExtractVersionFromLine(Lines[i]);
    if Parsed <> '' then
    begin
      Result := Parsed;
      Exit;
    end;
  end;
end;

function DetectInstalledVersion(const InstallDir: string): string;
var
  Root: string;
begin
  Result := '';
  Root := AddBackslash(InstallDir);

  Result := ReadFirstDetectedVersion(Root + 'STEMwerk.lua');
  if Result <> '' then
    Exit;

  Result := ReadFirstDetectedVersion(Root + 'STEMwerk-SETUP.lua');
  if Result <> '' then
    Exit;

  Result := ReadFirstDetectedVersion(Root + '_internal\STEMwerk_Setup_Internal.lua');
end;

function BuildVersionTransitionText: string;
var
  NewVersion: string;
begin
  NewVersion := '{#MyAppVersion}';
  if NewVersion = '' then
    NewVersion := 'unknown';

  if Trim(DetectedOldVersion) = '' then
    Result := '- STEMwerk for REAPER: previous install -> v' + NewVersion
  else
    Result := '- STEMwerk for REAPER: v' + Trim(DetectedOldVersion) + ' -> v' + NewVersion;
end;

function BuildVersionTransitionValue: string;
var
  NewVersion: string;
begin
  NewVersion := '{#MyAppVersion}';
  if NewVersion = '' then
    NewVersion := 'unknown';

  if Trim(DetectedOldVersion) = '' then
    Result := 'previous install -> v' + NewVersion
  else
    Result := 'v' + Trim(DetectedOldVersion) + ' -> v' + NewVersion;
end;

function GetUpdateNotesPath(Param: string): string;
begin
  Result := ExpandConstant('{app}\docs\RELEASE_{#MyAppVersion}.md');
end;

function InitializeSetup: Boolean;
var
  DefaultDir: string;
begin
  DefaultDir := ExpandConstant('{userappdata}\REAPER\Scripts\STEMwerk-reaper');
  if not InstallRootLooksValid(DefaultDir) then
  begin
    SuppressibleMsgBox(
      'This patch updates an existing STEMwerk installation.' + #13#10 + #13#10 +
      'Select your current STEMwerk install folder in the next step.' + #13#10 +
      'Accepted folder markers are either:' + #13#10 +
      '- Modern: STEMwerk.lua + i18n\\languages.lua' + #13#10 +
      '- Legacy: STEMwerk.lua + audio_separator_process.py + _internal\\STEMwerk_Setup_Internal.lua',
      mbInformation,
      MB_OK,
      IDOK
    );
  end;
  Result := True;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  TargetDir: string;
  ConfirmText: string;
  UpdateNotesPath: string;
  ExecResultCode: Integer;
begin
  Result := True;
  if CurPageID = wpSelectDir then
  begin
    if not InstallRootLooksValid(WizardDirValue) then
    begin
      SuppressibleMsgBox(
        'Choose the existing STEMwerk installation folder.' + #13#10 + #13#10 +
        'The selected folder must already match one of these layouts:' + #13#10 +
        '- Modern: STEMwerk.lua + i18n\\languages.lua' + #13#10 +
        '- Legacy: STEMwerk.lua + audio_separator_process.py + _internal\\STEMwerk_Setup_Internal.lua',
        mbError,
        MB_OK,
        IDOK
      );
      Result := False;
    end
    else
    begin
      DetectedOldVersion := DetectInstalledVersion(WizardDirValue);
      TargetDir := Trim(WizardDirValue);
      if TargetDir = '' then
        TargetDir := Trim(ExpandConstant('{app}'));
      if TargetDir = '' then
        TargetDir := '(selected install folder unavailable)';

      ConfirmText :=
        'Existing STEMwerk install detected.' + #13#10 + #13#10 +
        'Folder:' + #13#10 +
        TargetDir + #13#10 + #13#10 +
        'Version:' + #13#10 +
        BuildVersionTransitionValue + #13#10 + #13#10 +
        'Continue with this update?';

      if SuppressibleMsgBox(ConfirmText, mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDYES) <> IDYES then
      begin
        Result := False;
        Exit;
      end;
    end;
  end
  else if CurPageID = wpFinished then
  begin
    if Assigned(ShowReleaseNotesCheckbox) and ShowReleaseNotesCheckbox.Checked then
    begin
      UpdateNotesPath := GetUpdateNotesPath('');
      if FileExists(UpdateNotesPath) then
      begin
        ShellExec('', UpdateNotesPath, '', '', SW_SHOWNORMAL, ewNoWait, ExecResultCode);
      end;
      if not FileExists(UpdateNotesPath) then
      begin
        SuppressibleMsgBox(
          'Update notes were not found in the installed patch folder.',
          mbInformation,
          MB_OK,
          IDOK
        );
      end;
    end;
  end;
end;

function BuildPatchFinishedSummary: string;
var
  TargetDir: string;
  WrappedTargetDir: string;
begin
  TargetDir := Trim(WizardDirValue);
  if TargetDir = '' then
    TargetDir := Trim(ExpandConstant('{app}'));
  if TargetDir = '' then
    TargetDir := '(selected install folder unavailable)';
  WrappedTargetDir := WrapPathForFinishLabel(TargetDir, 50);

  Result :=
    'Patch completed successfully.' + #13#10 + #13#10 +
    'Updated:' + #13#10 +
    BuildVersionTransitionText + #13#10 +
    '- REAPER scripts in:' + #13#10 +
    '  ' + WrappedTargetDir;
end;

procedure LayoutFinishedSummaryLabel;
var
  DesiredHeight: Integer;
begin
  WizardForm.FinishedLabel.AutoSize := False;
  WizardForm.FinishedLabel.WordWrap := True;

  DesiredHeight := ScaleY(160);
  if Assigned(ShowReleaseNotesCheckbox) and ShowReleaseNotesCheckbox.Visible then
    DesiredHeight := ShowReleaseNotesCheckbox.Top - WizardForm.FinishedLabel.Top - ScaleY(8);

  if DesiredHeight < ScaleY(96) then
    DesiredHeight := ScaleY(96);

  WizardForm.FinishedLabel.Height := DesiredHeight;
end;

procedure InitializeWizard;
begin
  WizardForm.WelcomeLabel1.Caption := 'STEMwerk update patch';
  WizardForm.WelcomeLabel2.Caption :=
    'Use this patch to update an existing STEMwerk installation. This patch is not a full offline all-models installer. For fully offline setup, use one of the offline bundled allmodels installers.';
  WizardForm.FinishedHeadingLabel.Caption := 'Patch applied successfully';
  WizardForm.FinishedLabel.Caption := BuildPatchFinishedSummary;

  ShowReleaseNotesCheckbox := TNewCheckBox.Create(WizardForm);
  ShowReleaseNotesCheckbox.Parent := WizardForm.FinishedPage;
  ShowReleaseNotesCheckbox.Caption := 'Show what changed in v{#MyAppVersion}';
  ShowReleaseNotesCheckbox.Checked := False;
  ShowReleaseNotesCheckbox.Visible := False;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpFinished then
  begin
    WizardForm.FinishedHeadingLabel.Caption := 'Patch applied successfully';
    ShowReleaseNotesCheckbox.Left := WizardForm.FinishedLabel.Left;
    ShowReleaseNotesCheckbox.Top := WizardForm.NextButton.Top - ScaleY(30);
    ShowReleaseNotesCheckbox.Width := WizardForm.FinishedLabel.Width;
    ShowReleaseNotesCheckbox.Height := ScaleY(18);
    ShowReleaseNotesCheckbox.Visible := True;
    ShowReleaseNotesCheckbox.BringToFront;
    LayoutFinishedSummaryLabel;
    WizardForm.FinishedLabel.Caption := BuildPatchFinishedSummary;
  end;

  if CurPageID <> wpFinished then
    ShowReleaseNotesCheckbox.Visible := False;
end;
