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
; Small wizard image removed to avoid overlap with status text
DefaultDirName={userappdata}\REAPER\Scripts\STEMwerk-reaper
DefaultGroupName=STEMwerk
DisableProgramGroupPage=yes
OutputDir=dist
OutputBaseFilename=STEMwerk-Setup-{#MyAppVersion}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
InfoAfterFile=after_install.txt
PrivilegesRequired=lowest

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
Source: "STEMwerk_Installer_Windows.ps1"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\STEMwerk\Open install folder"; Filename: "{app}"
Name: "{userprograms}\STEMwerk\README"; Filename: "{app}\README.md"

[Run]
Filename: "{app}\README.md"; Description: "Open README"; Flags: postinstall shellexec skipifsilent
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -NoProfile -File ""{app}\STEMwerk_Installer_Windows.ps1"""; StatusMsg: "Preparing STEMwerk runtime..."; Flags: runhidden waituntilterminated

[Code]
var
  LogMemo: TNewMemo;
  StatusPrefixLabel: TNewStaticText;
  StatusSuffixLabel: TNewStaticText;
  StemLabelS: TNewStaticText;
  StemLabelT: TNewStaticText;
  StemLabelE: TNewStaticText;
  StemLabelM: TNewStaticText;
  StemLabelWerk: TNewStaticText;
  LogTimerId: LongInt;
  LogTimerProc: LongWord;
  LastLogText: string;
  LastProgress: Integer;

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

function ExtractBootstrapProgress(const Text: string): Integer;
begin
  Result := -1;
  if FindLastPos('[4/4]', Text) > 0 then Result := 100
  else if FindLastPos('[3/4]', Text) > 0 then Result := 75
  else if FindLastPos('[2/4]', Text) > 0 then Result := 50
  else if FindLastPos('[1/4]', Text) > 0 then Result := 25;
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
  Path, Text: string;
  WasAtBottom: Boolean;
begin
  if (LogMemo <> nil) and LogMemo.Focused and (LogMemo.SelLength > 0) then
  begin
    UpdateProgressGauge(LastLogText);
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
  UpdateProgressGauge(Text);
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
  x: Integer;
  y: Integer;
begin
  WizardForm.StatusLabel.Visible := False;
  y := WizardForm.StatusLabel.Top;
  x := WizardForm.StatusLabel.Left;

  StatusPrefixLabel := TNewStaticText.Create(WizardForm);
  StatusPrefixLabel.Parent := WizardForm.InstallingPage;
  StatusPrefixLabel.AutoSize := True;
  StatusPrefixLabel.Font.Size := 11;
  StatusPrefixLabel.Font.Style := [fsBold];
  StatusPrefixLabel.Font.Color := RGBColor(30, 30, 30);
  StatusPrefixLabel.Caption := 'Preparing ';
  StatusPrefixLabel.Left := x;
  StatusPrefixLabel.Top := y;
  x := StatusPrefixLabel.Left + StatusPrefixLabel.Width;
  StemLabelS := TNewStaticText.Create(WizardForm);
  StemLabelS.Parent := WizardForm.InstallingPage;
  StemLabelS.AutoSize := True;
  StemLabelS.Font.Style := [fsBold];
  StemLabelS.Font.Size := 11;
  StemLabelS.Font.Color := RGBColor(255, 100, 100);
  StemLabelS.Caption := 'S';
  StemLabelS.Left := x;
  StemLabelS.Top := y;
  x := StemLabelS.Left + StemLabelS.Width;

  StemLabelT := TNewStaticText.Create(WizardForm);
  StemLabelT.Parent := WizardForm.InstallingPage;
  StemLabelT.AutoSize := True;
  StemLabelT.Font.Style := [fsBold];
  StemLabelT.Font.Size := 11;
  StemLabelT.Font.Color := RGBColor(100, 200, 255);
  StemLabelT.Caption := 'T';
  StemLabelT.Left := x;
  StemLabelT.Top := y;
  x := StemLabelT.Left + StemLabelT.Width;

  StemLabelE := TNewStaticText.Create(WizardForm);
  StemLabelE.Parent := WizardForm.InstallingPage;
  StemLabelE.AutoSize := True;
  StemLabelE.Font.Style := [fsBold];
  StemLabelE.Font.Size := 11;
  StemLabelE.Font.Color := RGBColor(150, 100, 255);
  StemLabelE.Caption := 'E';
  StemLabelE.Left := x;
  StemLabelE.Top := y;
  x := StemLabelE.Left + StemLabelE.Width;

  StemLabelM := TNewStaticText.Create(WizardForm);
  StemLabelM.Parent := WizardForm.InstallingPage;
  StemLabelM.AutoSize := True;
  StemLabelM.Font.Style := [fsBold];
  StemLabelM.Font.Size := 11;
  StemLabelM.Font.Color := RGBColor(100, 255, 150);
  StemLabelM.Caption := 'M';
  StemLabelM.Left := x;
  StemLabelM.Top := y;
  x := StemLabelM.Left + StemLabelM.Width;

  StemLabelWerk := TNewStaticText.Create(WizardForm);
  StemLabelWerk.Parent := WizardForm.InstallingPage;
  StemLabelWerk.AutoSize := True;
  StemLabelWerk.Font.Style := [fsBold];
  StemLabelWerk.Font.Size := 11;
  StemLabelWerk.Font.Style := [fsBold];
  StemLabelWerk.Font.Color := RGBColor(30, 30, 30);
  StemLabelWerk.Caption := 'werk';
  StemLabelWerk.Left := x;
  StemLabelWerk.Top := y;
  x := StemLabelWerk.Left + StemLabelWerk.Width;

  StatusSuffixLabel := TNewStaticText.Create(WizardForm);
  StatusSuffixLabel.Parent := WizardForm.InstallingPage;
  StatusSuffixLabel.AutoSize := True;
  StatusSuffixLabel.Font.Size := 11;
  StatusSuffixLabel.Font.Style := [fsBold];
  StatusSuffixLabel.Font.Color := RGBColor(30, 30, 30);
  StatusSuffixLabel.Caption := ' runtime...';
  StatusSuffixLabel.Left := x;
  StatusSuffixLabel.Top := y;

  LogMemo := TNewMemo.Create(WizardForm);
  LogMemo.Parent := WizardForm.InstallingPage;
  LogMemo.Left := 0;
  LogMemo.Top := ScaleY(70);
  LogMemo.Width := WizardForm.InstallingPage.ClientWidth;
  LogMemo.Height := WizardForm.InstallingPage.ClientHeight - LogMemo.Top;
  LogMemo.ScrollBars := ssVertical;
  LogMemo.ReadOnly := True;
  LogMemo.WordWrap := True;
  LogMemo.TabStop := True;
  LogMemo.Enabled := True;
  LogMemo.Font.Name := 'Consolas';
  LogMemo.Font.Size := 9;
  LogMemo.Lines.Text := 'Preparing bootstrap log...';

  LogTimerId := 0;
  LogTimerProc := 0;
  LastProgress := -1;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpInstalling then
  begin
    LastLogText := '';
    LastProgress := 0;
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
