; Script Inno Setup pour Gestion Interfaces Réseau
; Compilation : ISCC.exe Setup.iss  (genere Output\Installateur-Gestion-Interfaces-Reseau.exe)
; Necessite Inno Setup 6 : https://jrsoftware.org/isinfo.php ou "winget install JRSoftware.InnoSetup"

#define MyAppName "Gestion Interfaces Réseau"
#define MyAppVersion "1.2.0"
#define MyScriptFile "Gestion-Interfaces-Reseau.ps1"

[Setup]
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={localappdata}\NetIfaceManager
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableWelcomePage=no
OutputDir=Output
OutputBaseFilename=Install-Gestion-Reseau
Compression=lzma
SolidCompression=yes
PrivilegesRequired=lowest
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={sys}\imageres.dll,170
DisableFinishedPage=no

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Files]
Source: "{#MyScriptFile}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userdesktop}\{#MyAppName}"; Filename: "{code:GetWtPath}"; \
    Parameters: "pwsh -NoProfile -ExecutionPolicy Bypass -File ""{app}\{#MyScriptFile}"""; \
    WorkingDir: "{app}"; IconFilename: "{sys}\imageres.dll"; IconIndex: 170

[Code]
function GetWtPath(Param: string): string;
var
  AliasPath: string;
begin
  AliasPath := ExpandConstant('{localappdata}\Microsoft\WindowsApps\wt.exe');
  if FileExists(AliasPath) then
    Result := AliasPath
  else
    Result := 'wt.exe';
end;

// Positionne le flag "Executer en tant qu'administrateur" sur le raccourci
// (byte a l'offset 0x15, meme mecanisme que Installer.ps1). Passe par une
// AnsiString (non terminee par un caractere nul) pour manipuler le binaire
// sans risque, TFileStream.ReadBuffer/WriteBuffer n'etant pas exploitables
// depuis le Pascal Script d'Inno Setup.
procedure SetRunAsAdminFlag(const LnkPath: string);
var
  Data: AnsiString;
  FlagOffset: Integer;
begin
  if not LoadStringFromFile(LnkPath, Data) then Exit;
  FlagOffset := $15 + 1; // index 1-based
  if Length(Data) < FlagOffset then Exit;
  Data[FlagOffset] := Chr(Ord(Data[FlagOffset]) or $20);
  SaveStringToFile(LnkPath, Data, False);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    SetRunAsAdminFlag(ExpandConstant('{userdesktop}\{#MyAppName}.lnk'));
end;
