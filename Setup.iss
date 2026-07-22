; Script Inno Setup pour Gestion Interfaces Réseau
; Compilation : ISCC.exe Setup.iss  (genere Installer\ps-network-manager.exe)
; Necessite Inno Setup 6 : https://jrsoftware.org/isinfo.php ou "winget install JRSoftware.InnoSetup"

#define MyAppName "Gestion Interfaces Réseau"
#define MyAppVersion "1.4.0"
#define MyScriptFile "Gestion-Interfaces-Reseau.ps1"

[Setup]
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={localappdata}\NetIfaceManager
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableWelcomePage=no
OutputDir=Installer
OutputBaseFilename=ps-network-manager
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
// Renvoie False si la lecture/ecriture echoue ou si le bit n'a pas ete
// applique (certains antivirus/EDR reecrivent ou bloquent ce type de
// modification, car c'est aussi une technique utilisee par des malwares).
function SetRunAsAdminFlag(const LnkPath: string): Boolean;
var
  Data: AnsiString;
  FlagOffset: Integer;
  Verify: AnsiString;
begin
  Result := False;
  if not LoadStringFromFile(LnkPath, Data) then Exit;
  FlagOffset := $15 + 1; // index 1-based
  if Length(Data) < FlagOffset then Exit;
  Data[FlagOffset] := Chr(Ord(Data[FlagOffset]) or $20);
  if not SaveStringToFile(LnkPath, Data, False) then Exit;
  // Relecture pour s'assurer que le bit est bien reste positionne
  if not LoadStringFromFile(LnkPath, Verify) then Exit;
  if Length(Verify) < FlagOffset then Exit;
  Result := (Ord(Verify[FlagOffset]) and $20) <> 0;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    if not SetRunAsAdminFlag(ExpandConstant('{userdesktop}\{#MyAppName}.lnk')) then
      MsgBox('Le raccourci a ete cree, mais son option "Executer en tant qu''administrateur" n''a pas pu etre activee automatiquement (un antivirus ou une protection systeme a probablement bloque la modification).' + #13#10 + #13#10 +
        'Pour l''activer manuellement : clic droit sur le raccourci du Bureau > Proprietes > Avance... > cochez "Executer en tant qu''administrateur".',
        mbInformation, MB_OK);
  end;
end;
