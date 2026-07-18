#Requires -Version 7.0
<#
    Installation de Gestion-Interfaces-Reseau :
    - Copie le script dans %LOCALAPPDATA%\NetIfaceManager (independant du dossier source)
    - Cree le raccourci Bureau pointant vers cette copie (Windows Terminal + pwsh eleve)
    - Icone imageres.dll index 170

    A executer depuis le dossier contenant Gestion-Interfaces-Reseau.ps1 (ex: apres avoir
    copie/clone ce dossier sur une nouvelle machine). Peut etre relance pour mettre a jour
    l'installation (ecrase la copie et le raccourci existants).
#>

$ErrorActionPreference = 'Stop'

$sourceScript = Join-Path $PSScriptRoot 'Gestion-Interfaces-Reseau.ps1'
if (-not (Test-Path $sourceScript)) {
    throw "Introuvable : $sourceScript"
}

$installDir = Join-Path $env:LOCALAPPDATA 'NetIfaceManager'
if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}

$installedScript = Join-Path $installDir 'Gestion-Interfaces-Reseau.ps1'
Copy-Item -Path $sourceScript -Destination $installedScript -Force

$wtCommand = Get-Command wt.exe -ErrorAction SilentlyContinue
$wtPath = if ($wtCommand) { $wtCommand.Source } else {
    Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
}

$desktopPath = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktopPath 'Gestion Interfaces Reseau.lnk'

$ws = New-Object -ComObject WScript.Shell
$shortcut = $ws.CreateShortcut($lnkPath)
$shortcut.TargetPath = $wtPath
$shortcut.Arguments = "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$installedScript`""
$shortcut.WorkingDirectory = $installDir
$shortcut.IconLocation = 'C:\Windows\System32\imageres.dll,170'
$shortcut.Save()

# Positionne le flag "Executer en tant qu'administrateur" (byte a l'offset 0x15)
$bytes = [System.IO.File]::ReadAllBytes($lnkPath)
$bytes[0x15] = $bytes[0x15] -bor 0x20
[System.IO.File]::WriteAllBytes($lnkPath, $bytes)

Write-Host "Script installe   : $installedScript" -ForegroundColor Green
Write-Host "Raccourci cree    : $lnkPath" -ForegroundColor Green
Write-Host "Cible raccourci   : $wtPath"
Write-Host "Icone             : imageres.dll,170"
