#define MyAppName "STEMwerk"
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

#define BundleRuntime GetEnv('STEMWERK_BUNDLE_RUNTIME')
#if BundleRuntime == "1"
  #define OutputSuffix "-bundled"
#else
  #define OutputSuffix ""
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
; Small wizard image removed to avoid overlap with status text
DefaultDirName={userappdata}\REAPER\Scripts\STEMwerk-reaper
DefaultGroupName=STEMwerk
DisableProgramGroupPage=yes
OutputDir=dist
OutputBaseFilename=STEMwerk-Setup-{#MyAppVersion}{#OutputSuffix}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; Core files needed to run in REAPER
Source: "..\..\scripts\reaper\*"; DestDir: "{app}"; Excludes: "*.bak,*.bak2,*.pyc,sync_to_reaper.sh,STEMwerk_Enable_Debug.lua,STEMwerk_Disable_Debug.lua,STEMwerk_Set_FFmpegPath.lua,STEMwerk_Set_PythonPath.lua,STEMwerk_separate.lua,__pycache__\*,vendor\stemwerk-core\build\*,vendor\stemwerk-core\src\*.egg-info\*,vendor\stemwerk-core\pyproject.toml"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "..\..\i18n\*"; DestDir: "{app}\i18n"; Flags: recursesubdirs createallsubdirs ignoreversion

#if BundleRuntime == "1"
  #if FileExists('payload\python\python-3.11.8-amd64.exe')
Source: "payload\python\python-3.11.8-amd64.exe"; DestDir: "{app}\_bundled\python"; Flags: ignoreversion
  #else
    #error STEMWERK_BUNDLE_RUNTIME=1 but payload\python\python-3.11.8-amd64.exe is missing.
  #endif
  #if FileExists('payload\ffmpeg\ffmpeg-release-essentials.zip')
Source: "payload\ffmpeg\ffmpeg-release-essentials.zip"; DestDir: "{app}\_bundled\ffmpeg"; Flags: ignoreversion
  #else
    #error STEMWERK_BUNDLE_RUNTIME=1 but payload\ffmpeg\ffmpeg-release-essentials.zip is missing.
  #endif
#endif

; Helpful docs
Source: "STEMwerk_Windows_Setup_Guide.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\TODO.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "STEMwerk_Installer_Windows.ps1"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\STEMwerk\Open install folder"; Filename: "{app}"
Name: "{userprograms}\STEMwerk\Windows setup guide"; Filename: "{app}\STEMwerk_Windows_Setup_Guide.md"

[Run]
Filename: "{app}\STEMwerk_Windows_Setup_Guide.md"; Description: "Open Windows setup guide"; Flags: postinstall shellexec skipifsilent
Filename: "{sys}\notepad.exe"; Parameters: """{localappdata}\STEMwerk\logs\bootstrap.log"""; Description: "Open setup log"; Flags: postinstall skipifsilent unchecked
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -NoProfile -File ""{app}\STEMwerk_Installer_Windows.ps1"""; StatusMsg: "Preparing STEMwerk runtime..."; Flags: runhidden waituntilterminated

[Code]
var
  LogMemo: TNewMemo;
  StatusPrefixLabel: TNewStaticText;
  StatusStemS: TNewStaticText;
  StatusStemT: TNewStaticText;
  StatusStemE: TNewStaticText;
  StatusStemM: TNewStaticText;
  StatusSuffixLabel: TNewStaticText;
  FinishedPrefixLabel: TNewStaticText;
  FinishedStemS: TNewStaticText;
  FinishedStemT: TNewStaticText;
  FinishedStemE: TNewStaticText;
  FinishedStemM: TNewStaticText;
  FinishedSuffixLabel: TNewStaticText;
  StatusDetailLabel: TNewStaticText;
  StepLabelS: TNewStaticText;
  StepLabelT: TNewStaticText;
  StepLabelE: TNewStaticText;
  StepLabelM: TNewStaticText;
  StepTrackS: TPanel;
  StepTrackT: TPanel;
  StepTrackE: TPanel;
  StepTrackM: TPanel;
  StepFillS: TPanel;
  StepFillT: TPanel;
  StepFillE: TPanel;
  StepFillM: TPanel;
  LogTimerId: LongInt;
  LogTimerProc: LongWord;
  LastLogText: string;
  LastProgress: Integer;
  LastStep: Integer;

const
  WM_VSCROLL = $0115;
  SB_BOTTOM = 7;
  EM_GETLINECOUNT = $00BA;
  EM_GETFIRSTVISIBLELINE = $00CE;

function SendMessage(hWnd: LongInt; Msg: LongInt; wParam: LongInt; lParam: LongInt): LongInt;
  external 'SendMessageW@user32.dll stdcall';

function SetTimer(hWnd: LongInt; nIDEvent, uElapse: LongInt; lpTimerFunc: LongWord): LongInt;
  external 'SetTimer@user32.dll stdcall';
function KillTimer(hWnd, nIDEvent: LongInt): LongInt;
  external 'KillTimer@user32.dll stdcall';

function RGBColor(R, G, B: Byte): Integer;
begin
  Result := Integer(R) or (Integer(G) shl 8) or (Integer(B) shl 16);
end;

function MemoVisibleLines(M: TNewMemo): Integer;
begin
  Result := 8;
  if M = nil then Exit;
  if M.Font.Size > 0 then
    Result := M.ClientHeight div (M.Font.Size + 2);
  if Result < 1 then Result := 1;
end;

function MemoIsAtBottom(M: TNewMemo): Boolean;
var
  FirstLine: Integer;
  LineCount: Integer;
  VisibleLines: Integer;
begin
  Result := True;
  if (M = nil) or (M.Handle = 0) then Exit;
  FirstLine := SendMessage(M.Handle, EM_GETFIRSTVISIBLELINE, 0, 0);
  LineCount := SendMessage(M.Handle, EM_GETLINECOUNT, 0, 0);
  VisibleLines := MemoVisibleLines(M);
  Result := (LineCount - FirstLine) <= (VisibleLines + 1);
end;

function GetLogPath: string;
begin
  Result := ExpandConstant('{localappdata}\STEMwerk\logs\bootstrap.log');
end;

function FindLastPos(const SubStr, S: string): Integer;
var
  i: Integer;
begin
  Result := 0;
  if (SubStr = '') or (S = '') then
    Exit;
  for i := Length(S) - Length(SubStr) + 1 downto 1 do
  begin
    if Copy(S, i, Length(SubStr)) = SubStr then
    begin
      Result := i;
      Exit;
    end;
  end;
end;

function DefaultStatusDetailText: string;
begin
  Result := 'First-time setup can take several minutes.' + #13#10 +
    'STEMwerk prepares the runtime, creates the Python environment, checks FFmpeg, and installs the core packages.';
end;

function ExtractStatusDetail(const Text: string): string;
var
  Marker: string;
  P: Integer;
  Tail: string;
  EolPos: Integer;
begin
  Result := '';
  Marker := 'STEMWERK_STATUS detail=';
  P := FindLastPos(Marker, Text);
  if P = 0 then
    Exit;
  Tail := Copy(Text, P + Length(Marker), Length(Text));
  EolPos := Pos(#13, Tail);
  if EolPos = 0 then
    EolPos := Pos(#10, Tail);
  if EolPos > 0 then
    Tail := Copy(Tail, 1, EolPos - 1);
  Result := Trim(Tail);
end;

function ExtractBootstrapProgress(const Text: string): Integer;
var
  UpperText: string;
begin
  Result := -1;
  UpperText := Uppercase(Text);
  if FindLastPos('BOOTSTRAP COMPLETE', UpperText) > 0 then Result := 100
  else if (FindLastPos('[4/4]', Text) > 0) or (FindLastPos('STEP 4/4', UpperText) > 0) then Result := 78
  else if (FindLastPos('[3/4]', Text) > 0) or (FindLastPos('STEP 3/4', UpperText) > 0) then Result := 58
  else if (FindLastPos('[2/4]', Text) > 0) or (FindLastPos('STEP 2/4', UpperText) > 0) then Result := 38
  else if (FindLastPos('[1/4]', Text) > 0) or (FindLastPos('STEP 1/4', UpperText) > 0) then Result := 18;
end;

function ExtractBootstrapStep(const Text: string): Integer;
begin
  Result := 0;
  if (FindLastPos('[4/4]', Text) > 0) or (FindLastPos('STEP 4/4', Uppercase(Text)) > 0) then Result := 4
  else if (FindLastPos('[3/4]', Text) > 0) or (FindLastPos('STEP 3/4', Uppercase(Text)) > 0) then Result := 3
  else if (FindLastPos('[2/4]', Text) > 0) or (FindLastPos('STEP 2/4', Uppercase(Text)) > 0) then Result := 2
  else if (FindLastPos('[1/4]', Text) > 0) or (FindLastPos('STEP 1/4', Uppercase(Text)) > 0) then Result := 1;
end;

procedure SetStepLabelState(L: TNewStaticText; Active: Boolean; BaseColor: Integer);
begin
  if L = nil then Exit;
  if Active then
  begin
    L.Font.Style := [fsBold];
    L.Font.Color := BaseColor;
  end
  else
  begin
    L.Font.Style := [];
    L.Font.Color := RGBColor(120, 120, 120);
  end;
end;

procedure SetStepBarState(TrackPanel, FillPanel: TPanel; Step, ActiveStep, FillColor: Integer);
var
  TargetWidth: Integer;
begin
  if (TrackPanel = nil) or (FillPanel = nil) then Exit;
  TrackPanel.Color := RGBColor(232, 232, 232);
  FillPanel.Color := FillColor;
  if (ActiveStep > 0) and (Step < ActiveStep) then
    TargetWidth := TrackPanel.Width
  else if Step = ActiveStep then
    TargetWidth := (TrackPanel.Width * 55) div 100
  else
    TargetWidth := 0;
  FillPanel.Width := TargetWidth;
  FillPanel.Visible := TargetWidth > 0;
end;

procedure UpdateStepLegend(const Text: string);
var
  Step: Integer;
begin
  Step := ExtractBootstrapStep(Text);
  if Step > 0 then
    LastStep := Step
  else
    Step := LastStep;
  SetStepLabelState(StepLabelS, Step = 1, RGBColor(255, 100, 100));
  SetStepLabelState(StepLabelT, Step = 2, RGBColor(100, 200, 255));
  SetStepLabelState(StepLabelE, Step = 3, RGBColor(150, 100, 255));
  SetStepLabelState(StepLabelM, Step = 4, RGBColor(100, 255, 150));
  SetStepBarState(StepTrackS, StepFillS, 1, Step, RGBColor(255, 100, 100));
  SetStepBarState(StepTrackT, StepFillT, 2, Step, RGBColor(100, 200, 255));
  SetStepBarState(StepTrackE, StepFillE, 3, Step, RGBColor(150, 100, 255));
  SetStepBarState(StepTrackM, StepFillM, 4, Step, RGBColor(100, 255, 150));
end;

procedure UpdateProgressGauge(const Text: string);
var
  P: Integer;
begin
  P := ExtractBootstrapProgress(Text);
  if P < 0 then Exit;
  if P <> LastProgress then
  begin
    LastProgress := P;
    WizardForm.ProgressGauge.Max := 100;
    WizardForm.ProgressGauge.Position := P;
  end;
end;

function ReadLogTail(const FileName: string; MaxChars: Integer): string;
var
  S: AnsiString;
  T: string;
begin
  Result := '';
  if LoadStringFromFile(FileName, S) then
  begin
    T := String(S);
    if (MaxChars > 0) and (Length(T) > MaxChars) then
      Result := Copy(T, Length(T) - MaxChars + 1, MaxChars)
    else
      Result := T;
  end;
end;

procedure UpdateLogMemo;
var
  Path, Text, Detail: string;
  WasAtBottom: Boolean;
begin
  if (LogMemo <> nil) and LogMemo.Focused then
  begin
    UpdateProgressGauge(LastLogText);
    UpdateStepLegend(LastLogText);
    Exit;
  end;
  WasAtBottom := MemoIsAtBottom(LogMemo);
  Path := GetLogPath;
  Text := ReadLogTail(Path, 12000);
  if Text = '' then
    Text := 'Waiting for bootstrap log at:' + #13#10 + Path + #13#10 +
            'Installer will update this view automatically...';
  if Text <> LastLogText then
  begin
    LastLogText := Text;
    if WasAtBottom or (LogMemo.Lines.Count = 0) then
    begin
      LogMemo.Lines.Text := Text;
      if LogMemo.Handle <> 0 then
        SendMessage(LogMemo.Handle, WM_VSCROLL, SB_BOTTOM, 0);
    end;
  end;
  Detail := ExtractStatusDetail(Text);
  if StatusDetailLabel <> nil then
  begin
    if Detail <> '' then
      StatusDetailLabel.Caption := 'Current task:' + #13#10 + Detail + #13#10 +
        'Long package installs are normal on slower systems and VMs.'
    else
      StatusDetailLabel.Caption := DefaultStatusDetailText;
  end;
  UpdateProgressGauge(Text);
  UpdateStepLegend(Text);
end;

procedure LogTimerTick(Sender: TObject);
begin
  UpdateLogMemo;
end;

procedure LogTimerProcThunk(hWnd, uMsg, idEvent, dwTime: LongInt);
begin
  UpdateLogMemo;
end;

procedure InitializeWizard;
var
  PageW: Integer;
  ColumnGap: Integer;
  ColumnW: Integer;
  BarTop: Integer;
  x: Integer;
  y: Integer;
  StepTop: Integer;
begin
  WizardForm.StatusLabel.Visible := False;
  y := WizardForm.StatusLabel.Top - ScaleY(18);
  PageW := WizardForm.InstallingPage.ClientWidth;
  ColumnGap := ScaleX(10);
  ColumnW := (PageW - (ColumnGap * 3)) div 4;

  StatusPrefixLabel := TNewStaticText.Create(WizardForm);
  StatusPrefixLabel.Parent := WizardForm.InstallingPage;
  StatusPrefixLabel.AutoSize := True;
  StatusPrefixLabel.Font.Size := 12;
  StatusPrefixLabel.Font.Style := [fsBold];
  StatusPrefixLabel.Font.Color := RGBColor(30, 30, 30);
  StatusPrefixLabel.Caption := 'Preparing ';
  StatusPrefixLabel.Left := WizardForm.StatusLabel.Left;
  StatusPrefixLabel.Top := y;
  x := StatusPrefixLabel.Left + StatusPrefixLabel.Width;

  StatusStemS := TNewStaticText.Create(WizardForm);
  StatusStemS.Parent := WizardForm.InstallingPage;
  StatusStemS.AutoSize := True;
  StatusStemS.Font.Size := 12;
  StatusStemS.Font.Style := [fsBold];
  StatusStemS.Font.Color := RGBColor(255, 100, 100);
  StatusStemS.Caption := 'S';
  StatusStemS.Left := x;
  StatusStemS.Top := y;
  x := StatusStemS.Left + StatusStemS.Width;

  StatusStemT := TNewStaticText.Create(WizardForm);
  StatusStemT.Parent := WizardForm.InstallingPage;
  StatusStemT.AutoSize := True;
  StatusStemT.Font.Size := 12;
  StatusStemT.Font.Style := [fsBold];
  StatusStemT.Font.Color := RGBColor(100, 200, 255);
  StatusStemT.Caption := 'T';
  StatusStemT.Left := x;
  StatusStemT.Top := y;
  x := StatusStemT.Left + StatusStemT.Width;

  StatusStemE := TNewStaticText.Create(WizardForm);
  StatusStemE.Parent := WizardForm.InstallingPage;
  StatusStemE.AutoSize := True;
  StatusStemE.Font.Size := 12;
  StatusStemE.Font.Style := [fsBold];
  StatusStemE.Font.Color := RGBColor(150, 100, 255);
  StatusStemE.Caption := 'E';
  StatusStemE.Left := x;
  StatusStemE.Top := y;
  x := StatusStemE.Left + StatusStemE.Width;

  StatusStemM := TNewStaticText.Create(WizardForm);
  StatusStemM.Parent := WizardForm.InstallingPage;
  StatusStemM.AutoSize := True;
  StatusStemM.Font.Size := 12;
  StatusStemM.Font.Style := [fsBold];
  StatusStemM.Font.Color := RGBColor(100, 255, 150);
  StatusStemM.Caption := 'M';
  StatusStemM.Left := x;
  StatusStemM.Top := y;
  x := StatusStemM.Left + StatusStemM.Width;

  StatusSuffixLabel := TNewStaticText.Create(WizardForm);
  StatusSuffixLabel.Parent := WizardForm.InstallingPage;
  StatusSuffixLabel.AutoSize := True;
  StatusSuffixLabel.Font.Style := [fsBold];
  StatusSuffixLabel.Font.Color := RGBColor(30, 30, 30);
  StatusSuffixLabel.Font.Size := 12;
  StatusSuffixLabel.Caption := 'werk runtime';
  StatusSuffixLabel.Left := x;
  StatusSuffixLabel.Top := y;

  StatusDetailLabel := TNewStaticText.Create(WizardForm);
  StatusDetailLabel.Parent := WizardForm.InstallingPage;
  StatusDetailLabel.AutoSize := False;
  StatusDetailLabel.WordWrap := True;
  StatusDetailLabel.Font.Size := 9;
  StatusDetailLabel.Font.Color := RGBColor(90, 90, 90);
  StatusDetailLabel.Caption := DefaultStatusDetailText;
  StatusDetailLabel.Left := WizardForm.StatusLabel.Left;
  StatusDetailLabel.Top := y + ScaleY(18);
  StatusDetailLabel.Width := PageW - StatusDetailLabel.Left - ScaleX(8);
  StatusDetailLabel.Height := ScaleY(72);

  StepTop := StatusDetailLabel.Top + StatusDetailLabel.Height + ScaleY(8);
  BarTop := StepTop + ScaleY(18);

  StepLabelS := TNewStaticText.Create(WizardForm);
  StepLabelS.Parent := WizardForm.InstallingPage;
  StepLabelS.AutoSize := False;
  StepLabelS.Width := ColumnW;
  StepLabelS.Height := ScaleY(16);
  StepLabelS.Font.Size := 9;
  StepLabelS.Caption := '1. Runtime';
  StepLabelS.Left := 0;
  StepLabelS.Top := StepTop;

  StepTrackS := TPanel.Create(WizardForm);
  StepTrackS.Parent := WizardForm.InstallingPage;
  StepTrackS.Left := 0;
  StepTrackS.Top := BarTop;
  StepTrackS.Width := ColumnW;
  StepTrackS.Height := ScaleY(12);
  StepTrackS.Caption := '';
  StepTrackS.ParentBackground := False;
  StepTrackS.BevelInner := bvNone;
  StepTrackS.BevelOuter := bvNone;
  StepTrackS.Color := RGBColor(232, 232, 232);

  StepFillS := TPanel.Create(WizardForm);
  StepFillS.Parent := StepTrackS;
  StepFillS.Left := 0;
  StepFillS.Top := 0;
  StepFillS.Width := 0;
  StepFillS.Height := StepTrackS.Height;
  StepFillS.Caption := '';
  StepFillS.ParentBackground := False;
  StepFillS.BevelInner := bvNone;
  StepFillS.BevelOuter := bvNone;
  StepFillS.Color := RGBColor(255, 100, 100);

  StepLabelT := TNewStaticText.Create(WizardForm);
  StepLabelT.Parent := WizardForm.InstallingPage;
  StepLabelT.AutoSize := False;
  StepLabelT.Width := ColumnW;
  StepLabelT.Height := ScaleY(16);
  StepLabelT.Font.Size := 9;
  StepLabelT.Caption := '2. Python + venv';
  StepLabelT.Left := ColumnW + ColumnGap;
  StepLabelT.Top := StepTop;

  StepTrackT := TPanel.Create(WizardForm);
  StepTrackT.Parent := WizardForm.InstallingPage;
  StepTrackT.Left := ColumnW + ColumnGap;
  StepTrackT.Top := BarTop;
  StepTrackT.Width := ColumnW;
  StepTrackT.Height := ScaleY(12);
  StepTrackT.Caption := '';
  StepTrackT.ParentBackground := False;
  StepTrackT.BevelInner := bvNone;
  StepTrackT.BevelOuter := bvNone;
  StepTrackT.Color := RGBColor(232, 232, 232);

  StepFillT := TPanel.Create(WizardForm);
  StepFillT.Parent := StepTrackT;
  StepFillT.Left := 0;
  StepFillT.Top := 0;
  StepFillT.Width := 0;
  StepFillT.Height := StepTrackT.Height;
  StepFillT.Caption := '';
  StepFillT.ParentBackground := False;
  StepFillT.BevelInner := bvNone;
  StepFillT.BevelOuter := bvNone;
  StepFillT.Color := RGBColor(100, 200, 255);

  StepLabelE := TNewStaticText.Create(WizardForm);
  StepLabelE.Parent := WizardForm.InstallingPage;
  StepLabelE.AutoSize := False;
  StepLabelE.Width := ColumnW;
  StepLabelE.Height := ScaleY(16);
  StepLabelE.Font.Size := 9;
  StepLabelE.Caption := '3. FFmpeg';
  StepLabelE.Left := (ColumnW + ColumnGap) * 2;
  StepLabelE.Top := StepTop;

  StepTrackE := TPanel.Create(WizardForm);
  StepTrackE.Parent := WizardForm.InstallingPage;
  StepTrackE.Left := (ColumnW + ColumnGap) * 2;
  StepTrackE.Top := BarTop;
  StepTrackE.Width := ColumnW;
  StepTrackE.Height := ScaleY(12);
  StepTrackE.Caption := '';
  StepTrackE.ParentBackground := False;
  StepTrackE.BevelInner := bvNone;
  StepTrackE.BevelOuter := bvNone;
  StepTrackE.Color := RGBColor(232, 232, 232);

  StepFillE := TPanel.Create(WizardForm);
  StepFillE.Parent := StepTrackE;
  StepFillE.Left := 0;
  StepFillE.Top := 0;
  StepFillE.Width := 0;
  StepFillE.Height := StepTrackE.Height;
  StepFillE.Caption := '';
  StepFillE.ParentBackground := False;
  StepFillE.BevelInner := bvNone;
  StepFillE.BevelOuter := bvNone;
  StepFillE.Color := RGBColor(150, 100, 255);

  StepLabelM := TNewStaticText.Create(WizardForm);
  StepLabelM.Parent := WizardForm.InstallingPage;
  StepLabelM.AutoSize := False;
  StepLabelM.Width := ColumnW;
  StepLabelM.Height := ScaleY(16);
  StepLabelM.Font.Size := 9;
  StepLabelM.Caption := '4. Core packages';
  StepLabelM.Left := (ColumnW + ColumnGap) * 3;
  StepLabelM.Top := StepTop;

  StepTrackM := TPanel.Create(WizardForm);
  StepTrackM.Parent := WizardForm.InstallingPage;
  StepTrackM.Left := (ColumnW + ColumnGap) * 3;
  StepTrackM.Top := BarTop;
  StepTrackM.Width := ColumnW;
  StepTrackM.Height := ScaleY(12);
  StepTrackM.Caption := '';
  StepTrackM.ParentBackground := False;
  StepTrackM.BevelInner := bvNone;
  StepTrackM.BevelOuter := bvNone;
  StepTrackM.Color := RGBColor(232, 232, 232);

  StepFillM := TPanel.Create(WizardForm);
  StepFillM.Parent := StepTrackM;
  StepFillM.Left := 0;
  StepFillM.Top := 0;
  StepFillM.Width := 0;
  StepFillM.Height := StepTrackM.Height;
  StepFillM.Caption := '';
  StepFillM.ParentBackground := False;
  StepFillM.BevelInner := bvNone;
  StepFillM.BevelOuter := bvNone;
  StepFillM.Color := RGBColor(100, 255, 150);

  StepTrackS.BringToFront;
  StepTrackT.BringToFront;
  StepTrackE.BringToFront;
  StepTrackM.BringToFront;
  StepLabelS.BringToFront;
  StepLabelT.BringToFront;
  StepLabelE.BringToFront;
  StepLabelM.BringToFront;

  WizardForm.ProgressGauge.Left := 0;
  WizardForm.ProgressGauge.Width := PageW;
  WizardForm.ProgressGauge.Top := BarTop + ScaleY(24);

  UpdateStepLegend('');

  LogMemo := TNewMemo.Create(WizardForm);
  LogMemo.Parent := WizardForm.InstallingPage;
  LogMemo.Left := 0;
  LogMemo.Top := WizardForm.ProgressGauge.Top + WizardForm.ProgressGauge.Height + ScaleY(18);
  LogMemo.Width := WizardForm.InstallingPage.ClientWidth;
  LogMemo.Height := WizardForm.InstallingPage.ClientHeight - LogMemo.Top;
  LogMemo.ScrollBars := ssNone;
  LogMemo.ReadOnly := True;
  LogMemo.WordWrap := True;
  LogMemo.TabStop := False;
  LogMemo.Enabled := True;
  LogMemo.Font.Name := 'Consolas';
  LogMemo.Font.Size := 9;
  LogMemo.Lines.Text := 'Preparing bootstrap log...';

  LogTimerId := 0;
  LogTimerProc := 0;
  LastProgress := -1;
  LastStep := 0;

  if WizardForm.FinishedHeadingLabel <> nil then
  begin
    WizardForm.FinishedHeadingLabel.Visible := False;
    y := WizardForm.FinishedHeadingLabel.Top;
    x := WizardForm.FinishedHeadingLabel.Left;

    FinishedPrefixLabel := TNewStaticText.Create(WizardForm);
    FinishedPrefixLabel.Parent := WizardForm.FinishedPage;
    FinishedPrefixLabel.AutoSize := True;
    FinishedPrefixLabel.Font.Size := 12;
    FinishedPrefixLabel.Font.Style := [fsBold];
    FinishedPrefixLabel.Font.Color := RGBColor(30, 30, 30);
    FinishedPrefixLabel.Caption := 'Completing the ';
    FinishedPrefixLabel.Left := x;
    FinishedPrefixLabel.Top := y;
    x := FinishedPrefixLabel.Left + FinishedPrefixLabel.Width;

    FinishedStemS := TNewStaticText.Create(WizardForm);
    FinishedStemS.Parent := WizardForm.FinishedPage;
    FinishedStemS.AutoSize := True;
    FinishedStemS.Font.Size := 12;
    FinishedStemS.Font.Style := [fsBold];
    FinishedStemS.Font.Color := RGBColor(255, 100, 100);
    FinishedStemS.Caption := 'S';
    FinishedStemS.Left := x;
    FinishedStemS.Top := y;
    x := FinishedStemS.Left + FinishedStemS.Width;

    FinishedStemT := TNewStaticText.Create(WizardForm);
    FinishedStemT.Parent := WizardForm.FinishedPage;
    FinishedStemT.AutoSize := True;
    FinishedStemT.Font.Size := 12;
    FinishedStemT.Font.Style := [fsBold];
    FinishedStemT.Font.Color := RGBColor(100, 200, 255);
    FinishedStemT.Caption := 'T';
    FinishedStemT.Left := x;
    FinishedStemT.Top := y;
    x := FinishedStemT.Left + FinishedStemT.Width;

    FinishedStemE := TNewStaticText.Create(WizardForm);
    FinishedStemE.Parent := WizardForm.FinishedPage;
    FinishedStemE.AutoSize := True;
    FinishedStemE.Font.Size := 12;
    FinishedStemE.Font.Style := [fsBold];
    FinishedStemE.Font.Color := RGBColor(150, 100, 255);
    FinishedStemE.Caption := 'E';
    FinishedStemE.Left := x;
    FinishedStemE.Top := y;
    x := FinishedStemE.Left + FinishedStemE.Width;

    FinishedStemM := TNewStaticText.Create(WizardForm);
    FinishedStemM.Parent := WizardForm.FinishedPage;
    FinishedStemM.AutoSize := True;
    FinishedStemM.Font.Size := 12;
    FinishedStemM.Font.Style := [fsBold];
    FinishedStemM.Font.Color := RGBColor(100, 255, 150);
    FinishedStemM.Caption := 'M';
    FinishedStemM.Left := x;
    FinishedStemM.Top := y;
    x := FinishedStemM.Left + FinishedStemM.Width;

    FinishedSuffixLabel := TNewStaticText.Create(WizardForm);
    FinishedSuffixLabel.Parent := WizardForm.FinishedPage;
    FinishedSuffixLabel.AutoSize := True;
    FinishedSuffixLabel.Font.Size := 12;
    FinishedSuffixLabel.Font.Style := [fsBold];
    FinishedSuffixLabel.Font.Color := RGBColor(30, 30, 30);
    FinishedSuffixLabel.Caption := 'werk Setup Wizard';
    FinishedSuffixLabel.Left := x;
    FinishedSuffixLabel.Top := y;
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpInstalling then
  begin
    LastLogText := '';
    LastProgress := 0;
    LastStep := 0;
    WizardForm.ProgressGauge.Max := 100;
    WizardForm.ProgressGauge.Position := 0;
    UpdateLogMemo;
    if LogTimerId = 0 then
    begin
      if LogTimerProc = 0 then
        LogTimerProc := CreateCallback(@LogTimerProcThunk);
      LogTimerId := SetTimer(0, 0, 500, LogTimerProc);
    end;
  end
  else
    if LogTimerId <> 0 then
    begin
      KillTimer(0, LogTimerId);
      LogTimerId := 0;
    end;
end;

procedure DeinitializeSetup;
begin
  if LogTimerId <> 0 then
  begin
    KillTimer(0, LogTimerId);
    LogTimerId := 0;
  end;
end;
