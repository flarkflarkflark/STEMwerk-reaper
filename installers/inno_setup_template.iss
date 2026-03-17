; Inno Setup script template for STEMwerk Windows installer
; Replace {#AppExe} with the built exe name when packaging.

[Setup]
AppName=STEMwerk Installer
AppVersion=0.1
DefaultDirName={pf}\STEMwerk
DisableProgramGroupPage=yes

[Files]
; Include the packaged exe and installers folder
Source: "dist\STEMwerkInstaller.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "installers\*"; DestDir: "{app}\installers"; Flags: recursesubdirs createallsubdirs

[Icons]
Name: "{group}\STEMwerk Installer"; Filename: "{app}\STEMwerkInstaller.exe"
Name: "{group}\Uninstall STEMwerk Installer"; Filename: "{uninstallexe}"
