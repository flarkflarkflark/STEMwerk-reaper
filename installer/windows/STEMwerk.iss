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
#define OutputSuffix GetEnv('STEMWERK_OUTPUT_SUFFIX')

#define ModelPayloadSubdir GetEnv('STEMWERK_MODEL_PAYLOAD_SUBDIR')
#if ModelPayloadSubdir == ""
  #define ModelPayloadSubdir "models"
#endif

#define WheelPayloadSubdir GetEnv('STEMWERK_WHEEL_PAYLOAD_SUBDIR')
#if WheelPayloadSubdir == ""
  #define WheelPayloadSubdir "wheels"
#endif

#if BundleRuntime == "1"
  #define MinimumFreeSpaceMB "12288"
  #define ExtraDiskSpaceRequiredBytes "2147483648"
#else
  #define MinimumFreeSpaceMB "3072"
  #define ExtraDiskSpaceRequiredBytes "3221225472"
#endif

[Setup]
AppId={{9A6BDA0D-6A2A-4B36-9C3B-1D4C77E5D0A3}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} v{#MyAppVersion}
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
#if FileExists('..\assets\stemwerk-wizard-small-opt-stemwerk-colors-v2-centered-widewerk.bmp')
WizardSmallImageFile=..\assets\stemwerk-wizard-small-opt-stemwerk-colors-v2-centered-widewerk.bmp
#endif
DefaultDirName={userappdata}\REAPER\Scripts\STEMwerk-reaper
DefaultGroupName=STEMwerk
DisableProgramGroupPage=yes
OutputDir=dist
OutputBaseFilename=STEMwerk-Setup-{#MyAppVersion}{#OutputSuffix}
Compression=lzma
SolidCompression=yes
WizardStyle=classic
PrivilegesRequired=lowest
DisableWelcomePage=no
LicenseFile=STEMwerk_License_Agreement.txt
ShowLanguageDialog=auto
LanguageDetectionMethod=uilanguage
UsePreviousLanguage=yes
ExtraDiskSpaceRequired={#ExtraDiskSpaceRequiredBytes}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "dutch"; MessagesFile: "compiler:Languages\Dutch.isl"
Name: "german"; MessagesFile: "compiler:Languages\German.isl"

[CustomMessages]
english.TaskCleanupRuntime=Before setup: clean previous runtime state/logs/.venv/cache
english.TaskCleanupModels=Also remove cached models (larger re-download on first use)
english.RunOpenGuide=Open Windows setup guide
english.RunOpenLog=Open setup log

dutch.TaskCleanupRuntime=Voor setup: verwijder vorige runtime-state/logs/.venv/cache
dutch.TaskCleanupModels=Verwijder ook modelcache (grotere herdownload bij eerste gebruik)
dutch.RunOpenGuide=Open Windows setup-handleiding
dutch.RunOpenLog=Open setup-log

german.TaskCleanupRuntime=Vor Setup: vorherigen Runtime-Status/Logs/.venv/Cache bereinigen
german.TaskCleanupModels=Auch Modell-Cache entfernen (größerer Re-Download bei erster Nutzung)
german.RunOpenGuide=Windows-Setup-Anleitung öffnen
german.RunOpenLog=Setup-Log öffnen

[Tasks]
Name: "cleanup_runtime"; Description: "{cm:TaskCleanupRuntime}"; Flags: unchecked
#if BundleRuntime != "1"
Name: "cleanup_models"; Description: "{cm:TaskCleanupModels}"; Flags: unchecked
#endif

[Files]
; Core files needed to run in REAPER
Source: "..\..\scripts\reaper\*"; DestDir: "{app}"; Excludes: "*.bak,*.bak2,*.pyc,sync_to_reaper.sh,STEMwerk_Enable_Debug.lua,STEMwerk_Disable_Debug.lua,STEMwerk_Set_FFmpegPath.lua,STEMwerk_Set_PythonPath.lua,STEMwerk_separate.lua,__pycache__\*,vendor\stemwerk-core\build\*,vendor\stemwerk-core\src\*.egg-info\*"; Flags: recursesubdirs createallsubdirs ignoreversion
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
Source: "payload\{#WheelPayloadSubdir}\*"; DestDir: "{app}\_bundled\wheels"; Flags: recursesubdirs createallsubdirs ignoreversion skipifsourcedoesntexist
Source: "payload\{#ModelPayloadSubdir}\*"; DestDir: "{localappdata}\STEMwerk\models"; Flags: recursesubdirs createallsubdirs ignoreversion skipifsourcedoesntexist
#endif

; Helpful docs
Source: "STEMwerk_Windows_Setup_Guide.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "STEMwerk_Windows_Setup_Guide.nl.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "STEMwerk_Windows_Setup_Guide.de.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\THIRD_PARTY_NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "STEMwerk_License_Agreement.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\TODO.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "STEMwerk_Installer_Windows.ps1"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\STEMwerk\Open install folder"; Filename: "{app}"
Name: "{userprograms}\STEMwerk\{cm:RunOpenGuide}"; Filename: "{code:GetLocalizedGuidePath}"
Name: "{userprograms}\STEMwerk\License agreement"; Filename: "{app}\STEMwerk_License_Agreement.txt"

[Run]
Filename: "{code:GetLocalizedGuidePath}"; Description: "{cm:RunOpenGuide}"; Flags: postinstall shellexec skipifsilent
Filename: "{sys}\notepad.exe"; Parameters: """{localappdata}\STEMwerk\logs\bootstrap.log"""; Description: "{cm:RunOpenLog}"; Flags: postinstall skipifsilent unchecked
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -NoProfile -File ""{app}\STEMwerk_Installer_Windows.ps1""{code:GetInstallerScriptArgs}"; StatusMsg: "Preparing STEMwerk runtime..."; Flags: runhidden waituntilterminated

[Code]
var
  WelcomeTitlePrefixLabel: TNewStaticText;
  WelcomeTitleStemS: TNewStaticText;
  WelcomeTitleStemT: TNewStaticText;
  WelcomeTitleStemE: TNewStaticText;
  WelcomeTitleStemM: TNewStaticText;
  WelcomeTitleSuffixLabel: TNewStaticText;
  WelcomeInfoLabel: TNewStaticText;
  TasksBrandLabel: TNewStaticText;
  TasksInfoLabel: TNewStaticText;
  TasksWelcomeLabel: TNewStaticText;
  TasksWelcomeSubLabel: TNewStaticText;
  LogMemo: TNewMemo;
  StatusPrefixLabel: TNewStaticText;
  StatusStemS: TNewStaticText;
  StatusStemT: TNewStaticText;
  StatusStemE: TNewStaticText;
  StatusStemM: TNewStaticText;
  StatusSuffixLabel: TNewStaticText;
  FinishedPrefixLabel: TNewStaticText;
  FinishedBrandLabel: TNewStaticText;
  StatusDetailLabel: TNewStaticText;
  ProgressOverlayLabel: TNewStaticText;
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
  UninstallCleanupRuntime: Boolean;
  UninstallCleanupModels: Boolean;

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

function GetLocalizedGuidePath(Param: string): string;
var
  BasePath: string;
  CandidatePath: string;
begin
  BasePath := ExpandConstant('{app}');
  CandidatePath := BasePath + '\STEMwerk_Windows_Setup_Guide.md';

  if ActiveLanguage = 'dutch' then
    CandidatePath := BasePath + '\STEMwerk_Windows_Setup_Guide.nl.md'
  else if ActiveLanguage = 'german' then
    CandidatePath := BasePath + '\STEMwerk_Windows_Setup_Guide.de.md';

  if FileExists(CandidatePath) then
    Result := CandidatePath
  else
    Result := BasePath + '\STEMwerk_Windows_Setup_Guide.md';
end;

function GetRuntimeBasePath: string;
begin
  Result := ExpandConstant('{localappdata}\STEMwerk');
end;

procedure CleanupRuntimeArtifacts(RemoveModels: Boolean);
var
  RuntimeBase: string;
begin
  RuntimeBase := GetRuntimeBasePath;

  if DirExists(RuntimeBase + '\state') then
    DelTree(RuntimeBase + '\state', True, True, True);
  if DirExists(RuntimeBase + '\logs') then
    DelTree(RuntimeBase + '\logs', True, True, True);
  if DirExists(RuntimeBase + '\.venv') then
    DelTree(RuntimeBase + '\.venv', True, True, True);
  if DirExists(RuntimeBase + '\.venv-gpu') then
    DelTree(RuntimeBase + '\.venv-gpu', True, True, True);
  if DirExists(RuntimeBase + '\cache') then
    DelTree(RuntimeBase + '\cache', True, True, True);
  if DirExists(RuntimeBase + '\tmp') then
    DelTree(RuntimeBase + '\tmp', True, True, True);
  if DirExists(RuntimeBase + '\temp') then
    DelTree(RuntimeBase + '\temp', True, True, True);
  if DirExists(RuntimeBase + '\bin') then
    DelTree(RuntimeBase + '\bin', True, True, True);
  if DirExists(RuntimeBase + '\ffmpeg') then
    DelTree(RuntimeBase + '\ffmpeg', True, True, True);
  if DirExists(RuntimeBase + '\python') then
    DelTree(RuntimeBase + '\python', True, True, True);

  if RemoveModels and DirExists(RuntimeBase + '\models') then
    DelTree(RuntimeBase + '\models', True, True, True);
end;

function GetInstallerScriptArgs(Param: string): string;
begin
  Result := '';
  if WizardIsTaskSelected('cleanup_runtime') then
    Result := Result + ' -CleanRuntime';
  #if BundleRuntime != "1"
  if WizardIsTaskSelected('cleanup_models') then
    Result := Result + ' -CleanModels';
  #endif
end;

function LText(const EnText, NlText, DeText: string): string;
begin
  if ActiveLanguage = 'dutch' then
    Result := NlText
  else if ActiveLanguage = 'german' then
    Result := DeText
  else
    Result := EnText;
end;

function VersionTag: string;
begin
  Result := 'v{#MyAppVersion}';
end;

procedure ApplyUnifiedWizardBranding;
begin
  if WizardForm.WizardBitmapImage <> nil then
  begin
    WizardForm.WizardBitmapImage.Visible := True;
    WizardForm.WizardBitmapImage.SendToBack;
  end;
end;

function BuildFinishedSummaryText: string;
var
  CleanupLines: string;
begin
  CleanupLines := '';
  if WizardIsTaskSelected('cleanup_runtime') then
    CleanupLines := CleanupLines + LText(
      '- Cleared previous runtime state/logs/.venv/cache before setup.',
      '- Vorige runtime state/logs/.venv/cache opgeschoond voor setup.',
      '- Vorherigen Runtime-Status/Logs/.venv/Cache vor dem Setup bereinigt.') + #13#10;
  #if BundleRuntime != "1"
  if WizardIsTaskSelected('cleanup_models') then
    CleanupLines := CleanupLines + LText(
      '- Cleared cached models folder before setup.',
      '- Modelcache-map opgeschoond voor setup.',
      '- Modell-Cache-Ordner vor dem Setup bereinigt.') + #13#10;
  #endif
  if CleanupLines = '' then
    CleanupLines := LText(
      '- Kept existing runtime cache and models.',
      '- Bestaande runtime-cache en modellen behouden.',
      '- Vorhandener Runtime-Cache und Modelle beibehalten.') + #13#10;

  Result :=
    LText('STEMwerk setup completed.', 'STEMwerk setup voltooid.', 'STEMwerk Setup abgeschlossen.') +
    ' (' + VersionTag + ')' + #13#10 + #13#10 +
    LText('What was done:', 'Wat is gedaan:', 'Was wurde gemacht:') + #13#10 +
    LText('- Installed/updated REAPER scripts in:', '- REAPER scripts geinstalleerd/bijgewerkt in:', '- REAPER-Skripte installiert/aktualisiert in:') + #13#10 +
    '  ' + ExpandConstant('{app}') + #13#10 +
    CleanupLines +
    LText('- Prepared runtime at %LOCALAPPDATA%\STEMwerk via bootstrap.',
      '- Runtime onder %LOCALAPPDATA%\STEMwerk voorbereid via bootstrap.',
      '- Runtime unter %LOCALAPPDATA%\STEMwerk per Bootstrap vorbereitet.') + #13#10 + #13#10 +
    LText('Setup log:', 'Setup-log:', 'Setup-Log:') + #13#10 +
    '  ' + GetLogPath;
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
  Result := LText(
    'First-time setup can take several minutes.',
    'De eerste setup kan enkele minuten duren.',
    'Die erste Einrichtung kann mehrere Minuten dauern.') + #13#10 +
    LText(
      'STEMwerk prepares the runtime, creates the Python environment, checks FFmpeg, and installs the core packages.',
      'STEMwerk bereidt de runtime voor, maakt de Python-omgeving aan, controleert FFmpeg en installeert kernpakketten.',
      'STEMwerk bereitet die Runtime vor, erstellt die Python-Umgebung, prüft FFmpeg und installiert Kernpakete.');
end;

function ExtractingStatusDetailText: string;
begin
  Result := LText(
    'Extracting installer components.',
    'Installercomponenten worden uitgepakt.',
    'Installer-Komponenten werden entpackt.') + #13#10 +
    LText(
      'This can take a few minutes on slower disks.',
      'Dit kan enkele minuten duren op tragere schijven.',
      'Dies kann auf langsameren Laufwerken einige Minuten dauern.');
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

function LocalizeStatusDetail(const Detail: string): string;
var
  Prefix, Suffix, PolicyValue: string;
begin
  Result := Detail;
  if Detail = '' then
    Exit;

  if Detail = 'Applying requested pre-setup cleanup.' then
    Result := LText(
      'Applying requested pre-setup cleanup.',
      'Gevraagde opschoning voor de setup wordt toegepast.',
      'Angeforderte Vorab-Bereinigung wird angewendet.')
  else if Detail = 'Removed previous runtime state/logs/venv/cache folders.' then
    Result := LText(
      'Removed previous runtime state/logs/venv/cache folders.',
      'Vorige runtime state/logs/venv/cache-mappen verwijderd.',
      'Vorherige Runtime-Status/Logs/venv/Cache-Ordner entfernt.')
  else if Detail = 'Removed cached models folder (%LOCALAPPDATA%\\STEMwerk\\models).' then
    Result := LText(
      'Removed cached models folder (%LOCALAPPDATA%\\STEMwerk\\models).',
      'Gecachte modellenmap verwijderd (%LOCALAPPDATA%\\STEMwerk\\models).',
      'Zwischengespeicherter Modellordner entfernt (%LOCALAPPDATA%\\STEMwerk\\models).')
  else if Detail = 'Keeping existing runtime cache and model folders.' then
    Result := LText(
      'Keeping existing runtime cache and model folders.',
      'Bestaande runtime-cache en modelmappen blijven behouden.',
      'Bestehender Runtime-Cache und Modellordner werden beibehalten.')
  else if Detail = 'Installing audio-separator into the venv. This can take several minutes on slower systems or VMs.' then
    Result := LText(
      'Installing audio-separator into the venv. This can take several minutes on slower systems or VMs.',
      'Audio-separator wordt in de venv geinstalleerd. Dit kan enkele minuten duren op tragere systemen of VM''s.',
      'Audio-separator wird in die venv installiert. Das kann auf langsameren Systemen oder VMs einige Minuten dauern.')
  else if Detail = 'Installing audio-separator into the venv. Pip may still be resolving dependencies or unpacking wheels.' then
    Result := LText(
      'Installing audio-separator into the venv. Pip may still be resolving dependencies or unpacking wheels.',
      'Audio-separator wordt in de venv geinstalleerd. Pip kan nog afhankelijkheden oplossen of wheels uitpakken.',
      'Audio-separator wird in die venv installiert. Pip loest moeglicherweise noch Abhaengigkeiten auf oder entpackt Wheels.')
  else if Detail = 'Installing DirectML runtime packages (torch-directml and onnxruntime-directml).' then
    Result := LText(
      'Installing DirectML runtime packages (torch-directml and onnxruntime-directml).',
      'DirectML-runtimepakketten worden geinstalleerd (torch-directml en onnxruntime-directml).',
      'DirectML-Runtimepakete werden installiert (torch-directml und onnxruntime-directml).')
  else if Detail = 'Installing CUDA-enabled PyTorch packages into the venv.' then
    Result := LText(
      'Installing CUDA-enabled PyTorch packages into the venv.',
      'CUDA-geschikte PyTorch-pakketten worden in de venv geinstalleerd.',
      'CUDA-faehige PyTorch-Pakete werden in die venv installiert.')
  else if Detail = 'Installing the ONNX Runtime package required by the separator backend.' then
    Result := LText(
      'Installing the ONNX Runtime package required by the separator backend.',
      'Het ONNX Runtime-pakket dat nodig is voor de separator-backend wordt geinstalleerd.',
      'Das fuer das Separator-Backend benoetigte ONNX-Runtime-Paket wird installiert.')
  else if Detail = 'Installing the bundled stemwerk-core package into the Python environment.' then
    Result := LText(
      'Installing the bundled stemwerk-core package into the Python environment.',
      'Het meegeleverde stemwerk-core-pakket wordt in de Python-omgeving geinstalleerd.',
      'Das gebuendelte stemwerk-core-Paket wird in die Python-Umgebung installiert.')
  else if Detail = 'Creating the Python virtual environment used by STEMwerk.' then
    Result := LText(
      'Creating the Python virtual environment used by STEMwerk.',
      'De door STEMwerk gebruikte Python-virtualenv wordt aangemaakt.',
      'Die von STEMwerk verwendete Python-virtuelle Umgebung wird erstellt.')
  else if Detail = 'Installing Python for the STEMwerk runtime.' then
    Result := LText(
      'Installing Python for the STEMwerk runtime.',
      'Python voor de STEMwerk-runtime wordt geinstalleerd.',
      'Python fuer die STEMwerk-Runtime wird installiert.')
  else if Detail = 'Installing separator runtime packages.' then
    Result := LText(
      'Installing separator runtime packages.',
      'Separator-runtimepakketten worden geinstalleerd.',
      'Separator-Runtimepakete werden installiert.')
  else if Detail = 'samplerate dependency is missing. Attempting automatic repair.' then
    Result := LText(
      'samplerate dependency is missing. Attempting automatic repair.',
      'De samplerate-afhankelijkheid ontbreekt. Automatisch herstel wordt geprobeerd.',
      'Die samplerate-Abhaengigkeit fehlt. Automatische Reparatur wird versucht.')
  else if Detail = 'samplerate is still missing. Separation may fail for some models; check bootstrap.log for details.' then
    Result := LText(
      'samplerate is still missing. Separation may fail for some models; check bootstrap.log for details.',
      'samplerate ontbreekt nog steeds. Separatie kan voor sommige modellen mislukken; zie bootstrap.log voor details.',
      'samplerate fehlt weiterhin. Die Separation kann bei einigen Modellen fehlschlagen; siehe bootstrap.log fuer Details.')
  else
  begin
    Prefix := 'PowerShell policy is restrictive (';
    Suffix := '). Manual script runs may need CurrentUser RemoteSigned.';
    if (Pos(Prefix, Detail) = 1) and
       (Length(Detail) > Length(Prefix) + Length(Suffix)) and
       (Copy(Detail, Length(Detail) - Length(Suffix) + 1, Length(Suffix)) = Suffix) then
    begin
      PolicyValue := Copy(Detail, Length(Prefix) + 1,
        Length(Detail) - Length(Prefix) - Length(Suffix));
      Result := LText(
        'PowerShell policy is restrictive (' + PolicyValue + '). Manual script runs may need CurrentUser RemoteSigned.',
        'PowerShell-beleid is restrictief (' + PolicyValue + '). Voor handmatige script-runs is mogelijk CurrentUser RemoteSigned nodig.',
        'PowerShell-Richtlinie ist restriktiv (' + PolicyValue + '). Fuer manuelle Skriptstarts kann CurrentUser RemoteSigned noetig sein.');
    end;
  end;
end;

function FilterVisibleLogText(const Text: string): string;
var
  Remaining: string;
  Line: string;
  EolPos: Integer;
  Marker: string;
begin
  Result := '';
  Remaining := Text;
  Marker := 'STEMWERK_STATUS detail=';

  while Remaining <> '' do
  begin
    EolPos := Pos(#13#10, Remaining);
    if EolPos > 0 then
    begin
      Line := Copy(Remaining, 1, EolPos - 1);
      Delete(Remaining, 1, EolPos + 1);
    end
    else
    begin
      EolPos := Pos(#10, Remaining);
      if EolPos > 0 then
      begin
        Line := Copy(Remaining, 1, EolPos - 1);
        Delete(Remaining, 1, EolPos);
      end
      else
      begin
        Line := Remaining;
        Remaining := '';
      end;
    end;

    if Copy(Line, 1, Length(Marker)) <> Marker then
    begin
      if Result <> '' then
        Result := Result + #13#10;
      Result := Result + Line;
    end;
  end;
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

procedure UpdateProgressOverlay(WaitingForBootstrap: Boolean);
var
  CaptionText: string;
begin
  if ProgressOverlayLabel = nil then Exit;
  if WaitingForBootstrap then
    CaptionText := LText(
      'Extracting installer components...',
      'Installercomponenten worden uitgepakt...',
      'Installer-Komponenten werden entpackt...')
  else
    CaptionText := '';

  if CaptionText = '' then
  begin
    ProgressOverlayLabel.Visible := False;
    Exit;
  end;

  ProgressOverlayLabel.Caption := CaptionText;
  ProgressOverlayLabel.Left := WizardForm.ProgressGauge.Left +
    (WizardForm.ProgressGauge.Width - ProgressOverlayLabel.Width) div 2;
  ProgressOverlayLabel.Top := WizardForm.ProgressGauge.Top + ScaleY(3);
  ProgressOverlayLabel.Visible := True;
  ProgressOverlayLabel.BringToFront;
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
  Path, Text, VisibleText, Detail: string;
  WaitingForBootstrap: Boolean;
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
  WaitingForBootstrap := Text = '';
  if Text = '' then
    Text := LText(
              'Extracting installer components...',
              'Installercomponenten worden uitgepakt...',
              'Installer-Komponenten werden entpackt...') + #13#10 +
            LText(
              'Waiting for bootstrap log at:',
              'Wachten op bootstrap-log op:',
              'Warte auf Bootstrap-Log unter:') + #13#10 + Path + #13#10 +
            LText(
              'Installer will update this view automatically... after extraction.',
              'Installer werkt dit venster automatisch bij... na het uitpakken.',
              'Der Installer aktualisiert diese Ansicht automatisch... nach dem Entpacken.');
  VisibleText := FilterVisibleLogText(Text);
  if VisibleText <> LastLogText then
  begin
    LastLogText := VisibleText;
    if WasAtBottom or (LogMemo.Lines.Count = 0) then
    begin
      LogMemo.Lines.Text := VisibleText;
      if LogMemo.Handle <> 0 then
        SendMessage(LogMemo.Handle, WM_VSCROLL, SB_BOTTOM, 0);
    end;
  end;
  Detail := ExtractStatusDetail(Text);
  if StatusDetailLabel <> nil then
  begin
    if WaitingForBootstrap then
      StatusDetailLabel.Caption := ExtractingStatusDetailText
    else if Detail <> '' then
      StatusDetailLabel.Caption := LText('Current task:', 'Huidige taak:', 'Aktuelle Aufgabe:') + #13#10 +
        LocalizeStatusDetail(Detail) + #13#10 +
        LText(
          'Package installation can take several minutes...',
          'Pakketinstallatie kan enkele minuten duren...',
          'Die Paketinstallation kann mehrere Minuten dauern...')
    else
      StatusDetailLabel.Caption := DefaultStatusDetailText;
  end;
  UpdateProgressOverlay(WaitingForBootstrap);
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
  WelcomeX: Integer;
  WelcomeY: Integer;
  WelcomeTitleY: Integer;
  TasksX: Integer;
  TasksY: Integer;
  TasksWelcomeStemS: TNewStaticText;
  TasksWelcomeStemT: TNewStaticText;
  TasksWelcomeStemE: TNewStaticText;
  TasksWelcomeStemM: TNewStaticText;
  TasksWelcomeSuffixLabel: TNewStaticText;
begin
  WelcomeX := ScaleX(16);
  WelcomeTitleY := ScaleY(16);
  WizardForm.Caption := '{#MyAppName} Setup ' + VersionTag;
  ApplyUnifiedWizardBranding;

  if WizardForm.WelcomeLabel1 <> nil then
  begin
    WelcomeX := WizardForm.WelcomeLabel1.Left;
    WelcomeTitleY := WizardForm.WelcomeLabel1.Top;
    WizardForm.WelcomeLabel1.Visible := False;

    WelcomeTitlePrefixLabel := TNewStaticText.Create(WizardForm);
    WelcomeTitlePrefixLabel.Parent := WizardForm.WelcomePage;
    WelcomeTitlePrefixLabel.AutoSize := True;
    WelcomeTitlePrefixLabel.Font.Size := 15;
    WelcomeTitlePrefixLabel.Font.Style := [fsBold];
    WelcomeTitlePrefixLabel.Font.Color := RGBColor(20, 20, 20);
    WelcomeTitlePrefixLabel.Caption := LText('Welcome to ', 'Welkom bij ', 'Willkommen bei ');
    WelcomeTitlePrefixLabel.Left := WelcomeX;
    WelcomeTitlePrefixLabel.Top := WelcomeTitleY;
    x := WelcomeTitlePrefixLabel.Left + WelcomeTitlePrefixLabel.Width;

    WelcomeTitleStemS := TNewStaticText.Create(WizardForm);
    WelcomeTitleStemS.Parent := WizardForm.WelcomePage;
    WelcomeTitleStemS.AutoSize := True;
    WelcomeTitleStemS.Font.Size := 15;
    WelcomeTitleStemS.Font.Style := [fsBold];
    WelcomeTitleStemS.Font.Color := RGBColor(255, 100, 100);
    WelcomeTitleStemS.Caption := 'S';
    WelcomeTitleStemS.Left := x;
    WelcomeTitleStemS.Top := WelcomeTitleY;
    x := WelcomeTitleStemS.Left + WelcomeTitleStemS.Width;

    WelcomeTitleStemT := TNewStaticText.Create(WizardForm);
    WelcomeTitleStemT.Parent := WizardForm.WelcomePage;
    WelcomeTitleStemT.AutoSize := True;
    WelcomeTitleStemT.Font.Size := 15;
    WelcomeTitleStemT.Font.Style := [fsBold];
    WelcomeTitleStemT.Font.Color := RGBColor(100, 200, 255);
    WelcomeTitleStemT.Caption := 'T';
    WelcomeTitleStemT.Left := x;
    WelcomeTitleStemT.Top := WelcomeTitleY;
    x := WelcomeTitleStemT.Left + WelcomeTitleStemT.Width;

    WelcomeTitleStemE := TNewStaticText.Create(WizardForm);
    WelcomeTitleStemE.Parent := WizardForm.WelcomePage;
    WelcomeTitleStemE.AutoSize := True;
    WelcomeTitleStemE.Font.Size := 15;
    WelcomeTitleStemE.Font.Style := [fsBold];
    WelcomeTitleStemE.Font.Color := RGBColor(150, 100, 255);
    WelcomeTitleStemE.Caption := 'E';
    WelcomeTitleStemE.Left := x;
    WelcomeTitleStemE.Top := WelcomeTitleY;
    x := WelcomeTitleStemE.Left + WelcomeTitleStemE.Width;

    WelcomeTitleStemM := TNewStaticText.Create(WizardForm);
    WelcomeTitleStemM.Parent := WizardForm.WelcomePage;
    WelcomeTitleStemM.AutoSize := True;
    WelcomeTitleStemM.Font.Size := 15;
    WelcomeTitleStemM.Font.Style := [fsBold];
    WelcomeTitleStemM.Font.Color := RGBColor(100, 255, 150);
    WelcomeTitleStemM.Caption := 'M';
    WelcomeTitleStemM.Left := x;
    WelcomeTitleStemM.Top := WelcomeTitleY;
    x := WelcomeTitleStemM.Left + WelcomeTitleStemM.Width;

    WelcomeTitleSuffixLabel := TNewStaticText.Create(WizardForm);
    WelcomeTitleSuffixLabel.Parent := WizardForm.WelcomePage;
    WelcomeTitleSuffixLabel.AutoSize := True;
    WelcomeTitleSuffixLabel.Font.Size := 15;
    WelcomeTitleSuffixLabel.Font.Style := [fsBold];
    WelcomeTitleSuffixLabel.Font.Color := RGBColor(20, 20, 20);
    WelcomeTitleSuffixLabel.Caption := 'werk SETUP';
    WelcomeTitleSuffixLabel.Left := x;
    WelcomeTitleSuffixLabel.Top := WelcomeTitleY;
  end;

  if WizardForm.WelcomeLabel2 <> nil then
    WizardForm.WelcomeLabel2.Visible := False;

  if WelcomeTitlePrefixLabel <> nil then
    WelcomeY := WelcomeTitlePrefixLabel.Top + WelcomeTitlePrefixLabel.Height + ScaleY(8)
  else
    WelcomeY := WizardForm.WelcomeLabel1.Top + WizardForm.WelcomeLabel1.Height + ScaleY(8);

  WelcomeInfoLabel := TNewStaticText.Create(WizardForm);
  WelcomeInfoLabel.Parent := WizardForm.WelcomePage;
  WelcomeInfoLabel.AutoSize := False;
  WelcomeInfoLabel.WordWrap := True;
  WelcomeInfoLabel.Font.Size := 9;
  WelcomeInfoLabel.Font.Color := RGBColor(80, 80, 80);
  WelcomeInfoLabel.Left := WelcomeX;
  WelcomeInfoLabel.Top := WelcomeY;
  WelcomeInfoLabel.Width := WizardForm.WelcomePage.ClientWidth - WelcomeX - ScaleX(10);
  WelcomeInfoLabel.Height := ScaleY(120);
  WelcomeInfoLabel.Caption :=
    LText('Version: ', 'Versie: ', 'Version: ') + VersionTag + #13#10 + #13#10 +
    LText(
      'This installer will guide you through a clean STEMwerk setup.',
      'Deze installer begeleidt je door een schone STEMwerk setup.',
      'Dieser Installer führt durch ein sauberes STEMwerk Setup.') + #13#10 + #13#10 +
    LText(
      'In the next steps it will:',
      'In de volgende stappen zal het:',
      'In den nächsten Schritten wird:') + #13#10 +
    LText(
      '- Copy/update the REAPER STEMwerk scripts.',
      '- De REAPER STEMwerk scripts kopieren/bijwerken.',
      '- Die REAPER STEMwerk Skripte kopieren/aktualisieren.') + #13#10 +
    LText(
      '- Optionally clean previous runtime/model cache if you select those tasks.',
      '- Optioneel oude runtime/modelcache opschonen als je die taken aanvinkt.',
      '- Optional alten Runtime-/Modell-Cache bereinigen, wenn diese Aufgaben ausgewählt sind.') + #13#10 +
    LText(
      '- Prepare the local Python runtime and verify backend dependencies.',
      '- De lokale Python runtime voorbereiden en backend-afhankelijkheden verifieren.',
      '- Die lokale Python Runtime vorbereiten und Backend-Abhängigkeiten prüfen.') + #13#10 + #13#10 +
    LText(
      'Tip: after setup, use "Open setup log" to review exactly what was done.',
      'Tip: gebruik na setup "Open setup-log" om precies te zien wat is gedaan.',
      'Tipp: Nach dem Setup "Setup-Log öffnen" nutzen, um genau zu sehen, was gemacht wurde.');

  if WizardForm.SelectTasksLabel <> nil then
  begin
    TasksWelcomeLabel := TNewStaticText.Create(WizardForm);
    TasksWelcomeLabel.Parent := WizardForm.SelectTasksPage;
    TasksWelcomeLabel.AutoSize := True;
    TasksWelcomeLabel.Font.Size := 14;
    TasksWelcomeLabel.Font.Style := [fsBold];
    TasksWelcomeLabel.Font.Color := RGBColor(30, 30, 30);
    TasksWelcomeLabel.Caption := LText('Welcome to ', 'Welkom bij ', 'Willkommen beim ');
    TasksWelcomeLabel.Left := WizardForm.SelectTasksLabel.Left;
    TasksWelcomeLabel.Top := WizardForm.SelectTasksLabel.Top;
    x := TasksWelcomeLabel.Left + TasksWelcomeLabel.Width;

    TasksWelcomeStemS := TNewStaticText.Create(WizardForm);
    TasksWelcomeStemS.Parent := WizardForm.SelectTasksPage;
    TasksWelcomeStemS.AutoSize := True;
    TasksWelcomeStemS.Font.Size := 14;
    TasksWelcomeStemS.Font.Style := [fsBold];
    TasksWelcomeStemS.Font.Color := RGBColor(255, 100, 100);
    TasksWelcomeStemS.Caption := 'S';
    TasksWelcomeStemS.Left := x;
    TasksWelcomeStemS.Top := TasksWelcomeLabel.Top;
    x := TasksWelcomeStemS.Left + TasksWelcomeStemS.Width;

    TasksWelcomeStemT := TNewStaticText.Create(WizardForm);
    TasksWelcomeStemT.Parent := WizardForm.SelectTasksPage;
    TasksWelcomeStemT.AutoSize := True;
    TasksWelcomeStemT.Font.Size := 14;
    TasksWelcomeStemT.Font.Style := [fsBold];
    TasksWelcomeStemT.Font.Color := RGBColor(100, 200, 255);
    TasksWelcomeStemT.Caption := 'T';
    TasksWelcomeStemT.Left := x;
    TasksWelcomeStemT.Top := TasksWelcomeLabel.Top;
    x := TasksWelcomeStemT.Left + TasksWelcomeStemT.Width;

    TasksWelcomeStemE := TNewStaticText.Create(WizardForm);
    TasksWelcomeStemE.Parent := WizardForm.SelectTasksPage;
    TasksWelcomeStemE.AutoSize := True;
    TasksWelcomeStemE.Font.Size := 14;
    TasksWelcomeStemE.Font.Style := [fsBold];
    TasksWelcomeStemE.Font.Color := RGBColor(150, 100, 255);
    TasksWelcomeStemE.Caption := 'E';
    TasksWelcomeStemE.Left := x;
    TasksWelcomeStemE.Top := TasksWelcomeLabel.Top;
    x := TasksWelcomeStemE.Left + TasksWelcomeStemE.Width;

    TasksWelcomeStemM := TNewStaticText.Create(WizardForm);
    TasksWelcomeStemM.Parent := WizardForm.SelectTasksPage;
    TasksWelcomeStemM.AutoSize := True;
    TasksWelcomeStemM.Font.Size := 14;
    TasksWelcomeStemM.Font.Style := [fsBold];
    TasksWelcomeStemM.Font.Color := RGBColor(100, 255, 150);
    TasksWelcomeStemM.Caption := 'M';
    TasksWelcomeStemM.Left := x;
    TasksWelcomeStemM.Top := TasksWelcomeLabel.Top;
    x := TasksWelcomeStemM.Left + TasksWelcomeStemM.Width;

    TasksWelcomeSuffixLabel := TNewStaticText.Create(WizardForm);
    TasksWelcomeSuffixLabel.Parent := WizardForm.SelectTasksPage;
    TasksWelcomeSuffixLabel.AutoSize := True;
    TasksWelcomeSuffixLabel.Font.Size := 14;
    TasksWelcomeSuffixLabel.Font.Style := [fsBold];
    TasksWelcomeSuffixLabel.Font.Color := RGBColor(30, 30, 30);
    TasksWelcomeSuffixLabel.Caption := 'werk SETUP';
    TasksWelcomeSuffixLabel.Left := x;
    TasksWelcomeSuffixLabel.Top := TasksWelcomeLabel.Top;

    TasksWelcomeSubLabel := TNewStaticText.Create(WizardForm);
    TasksWelcomeSubLabel.Parent := WizardForm.SelectTasksPage;
    TasksWelcomeSubLabel.AutoSize := True;
    TasksWelcomeSubLabel.Font.Size := 9;
    TasksWelcomeSubLabel.Font.Color := RGBColor(80, 80, 80);
    TasksWelcomeSubLabel.Caption := LText(
      'Choose cleanup options for old runtime files before continuing.',
      'Kies opschoonopties voor oude runtimebestanden voordat je doorgaat.',
      'Vor dem Fortfahren Bereinigungsoptionen für alte Runtime-Dateien wählen.');
    TasksWelcomeSubLabel.Left := TasksWelcomeLabel.Left;
    TasksWelcomeSubLabel.Top := TasksWelcomeLabel.Top + TasksWelcomeLabel.Height + ScaleY(4);

    WizardForm.SelectTasksLabel.Font.Size := 10;
    WizardForm.SelectTasksLabel.Font.Style := [fsBold];
    WizardForm.SelectTasksLabel.Caption := LText(
      'Cleanup options before setup. Select what should be removed from previous installs.',
      'Opschoonopties voor setup. Kies wat verwijderd moet worden van eerdere installaties.',
      'Bereinigungsoptionen vor dem Setup. Auswählen, was von früheren Installationen entfernt werden soll.');
    WizardForm.SelectTasksLabel.Top := TasksWelcomeSubLabel.Top + TasksWelcomeSubLabel.Height + ScaleY(10);
  end;

  TasksX := WizardForm.SelectTasksLabel.Left;
  TasksY := WizardForm.SelectTasksLabel.Top + WizardForm.SelectTasksLabel.Height + ScaleY(8);

  TasksBrandLabel := TNewStaticText.Create(WizardForm);
  TasksBrandLabel.Parent := WizardForm.SelectTasksPage;
  TasksBrandLabel.AutoSize := True;
  TasksBrandLabel.Font.Size := 13;
  TasksBrandLabel.Font.Style := [fsBold];
  TasksBrandLabel.Font.Color := RGBColor(35, 35, 35);
  TasksBrandLabel.Caption := LText('STEMwerk cleanup', 'STEMwerk opschonen', 'STEMwerk bereinigen');
  TasksBrandLabel.Left := TasksX;
  TasksBrandLabel.Top := TasksY;

  TasksInfoLabel := TNewStaticText.Create(WizardForm);
  TasksInfoLabel.Parent := WizardForm.SelectTasksPage;
  TasksInfoLabel.AutoSize := True;
  TasksInfoLabel.Font.Size := 8;
  TasksInfoLabel.Font.Color := RGBColor(95, 95, 95);
  TasksInfoLabel.Caption := LText(
    'Safe defaults: keep models unchecked unless you want a full clean reset.',
    'Veilige standaard: laat modellen uitgevinkt tenzij je een volledige schone reset wilt.',
    'Sichere Standardwerte: Modelle abgewählt lassen, außer bei gewünschtem Komplett-Reset.');
  TasksInfoLabel.Left := TasksX;
  TasksInfoLabel.Top := TasksY + ScaleY(20);

  if WizardForm.TasksList <> nil then
    WizardForm.TasksList.Top := TasksInfoLabel.Top + TasksInfoLabel.Height + ScaleY(10);

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
  StatusSuffixLabel.Caption := 'werk runtime ' + VersionTag;
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

  ProgressOverlayLabel := TNewStaticText.Create(WizardForm);
  ProgressOverlayLabel.Parent := WizardForm.InstallingPage;
  ProgressOverlayLabel.AutoSize := True;
  ProgressOverlayLabel.Font.Size := 9;
  ProgressOverlayLabel.Font.Style := [fsBold];
  ProgressOverlayLabel.Font.Color := RGBColor(30, 30, 30);
  ProgressOverlayLabel.Caption := LText(
    'Extracting installer components...',
    'Installercomponenten worden uitgepakt...',
    'Installer-Komponenten werden entpackt...');
  ProgressOverlayLabel.Left := WizardForm.ProgressGauge.Left +
    (WizardForm.ProgressGauge.Width - ProgressOverlayLabel.Width) div 2;
  ProgressOverlayLabel.Top := WizardForm.ProgressGauge.Top + ScaleY(3);
  ProgressOverlayLabel.Visible := False;

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
  LogMemo.Lines.Text := LText(
    'Extracting installer components...',
    'Installercomponenten worden uitgepakt...',
    'Installer-Komponenten werden entpackt...');

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
    FinishedPrefixLabel.Caption := LText('Completing the ', 'Afronden van ', 'Abschluss des ');
    FinishedPrefixLabel.Left := x;
    FinishedPrefixLabel.Top := y;
    x := FinishedPrefixLabel.Left + FinishedPrefixLabel.Width;

    FinishedBrandLabel := TNewStaticText.Create(WizardForm);
    FinishedBrandLabel.Parent := WizardForm.FinishedPage;
    FinishedBrandLabel.AutoSize := True;
    FinishedBrandLabel.Font.Size := 12;
    FinishedBrandLabel.Font.Style := [fsBold];
    FinishedBrandLabel.Font.Color := RGBColor(30, 30, 30);
    FinishedBrandLabel.Caption := LText('STEMwerk Setup Wizard', 'STEMwerk Setup Wizard', 'STEMwerk Setup-Assistent') + ' ' + VersionTag;
    FinishedBrandLabel.Left := x;
    FinishedBrandLabel.Top := y;
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  ApplyUnifiedWizardBranding;
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
  begin
    if LogTimerId <> 0 then
    begin
      KillTimer(0, LogTimerId);
      LogTimerId := 0;
    end;
    if CurPageID = wpFinished then
    begin
      if WizardForm.FinishedLabel <> nil then
        WizardForm.FinishedLabel.Caption := BuildFinishedSummaryText;
    end;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  FreeMB: Cardinal;
  TotalMB: Cardinal;
  RequiredMB: Cardinal;
  RuntimePath: string;
  PromptText: string;
begin
  Result := '';
  RuntimePath := GetRuntimeBasePath;
  RequiredMB := {#MinimumFreeSpaceMB};

  if GetSpaceOnDisk(RuntimePath, True, FreeMB, TotalMB) then
  begin
    if FreeMB < RequiredMB then
    begin
      PromptText := LText(
        'Low free disk space detected for STEMwerk runtime setup.' + #13#10 + #13#10 +
        'Runtime path: ' + RuntimePath + #13#10 +
        'Required (recommended): ' + IntToStr(RequiredMB) + ' MB' + #13#10 +
        'Currently free: ' + IntToStr(FreeMB) + ' MB' + #13#10 + #13#10 +
        'Continue anyway?',
        'Er is weinig vrije schijfruimte voor STEMwerk runtime setup.' + #13#10 + #13#10 +
        'Runtime-pad: ' + RuntimePath + #13#10 +
        'Vereist (aanbevolen): ' + IntToStr(RequiredMB) + ' MB' + #13#10 +
        'Nu vrij: ' + IntToStr(FreeMB) + ' MB' + #13#10 + #13#10 +
        'Toch doorgaan?',
        'Wenig freier Speicherplatz für das STEMwerk Runtime-Setup erkannt.' + #13#10 + #13#10 +
        'Runtime-Pfad: ' + RuntimePath + #13#10 +
        'Erforderlich (empfohlen): ' + IntToStr(RequiredMB) + ' MB' + #13#10 +
        'Aktuell frei: ' + IntToStr(FreeMB) + ' MB' + #13#10 + #13#10 +
        'Trotzdem fortfahren?');

      if SuppressibleMsgBox(PromptText, mbConfirmation, MB_YESNO, IDNO) = IDNO then
        Result := LText(
          'Installation canceled due to low free disk space.',
          'Installatie geannuleerd door te weinig vrije schijfruimte.',
          'Installation wegen zu wenig freiem Speicherplatz abgebrochen.');
    end;
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

function InitializeUninstall: Boolean;
begin
  Result := True;

  MsgBox(
    LText(
      'Uninstall always removes STEMwerk scripts from the REAPER Scripts folder.' + #13#10 + #13#10 +
      'Next you can choose whether runtime components should also be removed.',
      'De-installatie verwijdert altijd STEMwerk scripts uit de REAPER Scripts-map.' + #13#10 + #13#10 +
      'Hierna kies je of runtime-componenten ook verwijderd moeten worden.',
      'Die Deinstallation entfernt immer STEMwerk Skripte aus dem REAPER-Scripts-Ordner.' + #13#10 + #13#10 +
      'Als Nächstes kann gewählt werden, ob Runtime-Komponenten ebenfalls entfernt werden sollen.'),
    mbInformation, MB_OK);

  UninstallCleanupRuntime :=
    MsgBox(
      LText('Also remove runtime environment under:',
        'Ook runtime-omgeving verwijderen onder:',
        'Runtime-Umgebung ebenfalls entfernen unter:') + #13#10 +
      GetRuntimeBasePath + #13#10 + #13#10 +
      LText('This removes logs/cache and local runtime folders (.venv, python, ffmpeg, bin).',
        'Dit verwijdert logs/cache en lokale runtime-mappen (.venv, python, ffmpeg, bin).',
        'Dies entfernt Logs/Cache und lokale Runtime-Ordner (.venv, python, ffmpeg, bin).'),
      mbConfirmation, MB_YESNO) = IDYES;

  UninstallCleanupModels := False;
  if UninstallCleanupRuntime then
  begin
    UninstallCleanupModels :=
      MsgBox(
        LText('Also remove cached AI models?',
          'Ook gecachete AI-modellen verwijderen?',
          'Auch zwischengespeicherte AI-Modelle entfernen?') + #13#10 +
        LText('This frees disk space but requires re-download on first use.',
          'Dit maakt schijfruimte vrij maar vereist herdownload bij eerste gebruik.',
          'Das schafft Speicherplatz, erfordert aber einen erneuten Download bei erster Nutzung.'),
        mbConfirmation, MB_YESNO) = IDYES;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    if UninstallCleanupRuntime then
      CleanupRuntimeArtifacts(UninstallCleanupModels);
  end;
end;
