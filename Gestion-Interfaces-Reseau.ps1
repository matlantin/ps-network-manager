#Requires -RunAsAdministrator
#Requires -Version 7.0
<#
    Gestionnaire d'Interfaces Réseau
    Script interactif de gestion des interfaces réseau Windows (IPv4 uniquement).
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Force l'UTF-8 en sortie pour que les caractères accentués s'affichent correctement,
# quel que soit l'hôte (Windows Terminal, conhost, ISE...).
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$OutputEncoding = [System.Text.Encoding]::UTF8

#region Banner

function Show-Banner {
    Clear-Host
    $banner = @"

  _   _      _                      _      ___       _             __
 | \ | | ___| |___      _____  _ __| | __ |_ _|_ __ | |_ ___ _ __ / _| __ _  ___ ___  ___
 |  \| |/ _ \ __\ \ /\ / / _ \| '__| |/ /  | || '_ \| __/ _ \ '__| |_ / _' |/ __/ _ \/ __|
 | |\  |  __/ |_ \ V  V / (_) | |  |   <   | || | | | ||  __/ |  |  _| (_| | (_|  __/\__ \
 |_| \_|\___|\__| \_/\_/ \___/|_|  |_|\_\ |___|_| |_|\__\___|_|  |_|  \__,_|\___\___||___/

              G E S T I O N N A I R E   D ' I N T E R F A C E S   R É S E A U
"@
    Write-Host $banner -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Bienvenue ! Ce script interactif permet de configurer les interfaces réseau de cette machine." -ForegroundColor Gray
    Write-Host "  Il fournit également des presets de configuration IP et des outils de diagnostic réseau." -ForegroundColor Gray
    Write-Host "  Astuce : dans les menus, utilisez les flèches Haut/Bas puis Entrée." -ForegroundColor DarkGray
    Write-Host "  Pour les questions, Entrée seule conserve la valeur actuelle affichée." -ForegroundColor DarkGray
    Write-Host ""
}

#endregion

#region Helpers génériques

# Saisie ligne par ligne gérée caractère par caractère (comme Show-ArrowMenu) afin de pouvoir
# intercepter la touche Échap. Retourne $null si Échap est pressée, sinon la chaîne saisie
# (éventuellement vide si Entrée seule).
function Read-HostWithEscape {
    param([string]$Prompt, [string]$Default = '')
    [Console]::CursorVisible = $true
    Write-Host -NoNewline "$Prompt : "
    $sb = [System.Text.StringBuilder]::new($Default)
    if ($Default) { [Console]::Write($Default) }
    while ($true) {
        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'Escape' { Write-Host ""; return $null }
            'Enter' { Write-Host ""; return $sb.ToString() }
            'Backspace' {
                if ($sb.Length -gt 0) {
                    $sb.Length -= 1
                    [Console]::Write("`b `b")
                }
            }
            default {
                if (-not [char]::IsControl($key.KeyChar)) {
                    [void]$sb.Append($key.KeyChar)
                    [Console]::Write($key.KeyChar)
                }
            }
        }
    }
}

function Read-WithDefault {
    param(
        [string]$Prompt,
        [string]$Default
    )
    [Console]::CursorVisible = $true
    $displayDefault = if ([string]::IsNullOrWhiteSpace($Default)) { "aucune" } else { $Default }
    $inputValue = Read-Host "$Prompt [$displayDefault]"
    if ([string]::IsNullOrWhiteSpace($inputValue)) { return $Default }
    return $inputValue
}

function Wait-EnterOrEscape {
    param([string]$Message = "Appuyez sur Entrée ou Échap pour revenir au menu principal")
    Write-Host "`n$Message" -ForegroundColor DarkGray
    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'Enter' -or $key.Key -eq 'Escape') { break }
    }
}

function Read-YesNo {
    param(
        [string]$Prompt,
        [bool]$Default
    )
    [Console]::CursorVisible = $true
    $yn = if ($Default) { "O/n" } else { "o/N" }
    while ($true) {
        $inputValue = Read-Host "$Prompt [$yn]"
        if ([string]::IsNullOrWhiteSpace($inputValue)) { return $Default }
        switch -Regex ($inputValue) {
            '^[oOyY]$' { return $true }
            '^[nN]$'   { return $false }
            default    { Write-Host "  Réponse invalide (o/O/y/Y ou n/N)." -ForegroundColor Yellow }
        }
    }
}

function Test-IPv4Address {
    param([string]$InputValue)
    if ([string]::IsNullOrWhiteSpace($InputValue)) { return $true }
    $addr = $null
    return ([System.Net.IPAddress]::TryParse($InputValue, [ref]$addr)) -and ($addr.AddressFamily -eq 'InterNetwork')
}

# Retourne $true si la saisie est le jeton d'effacement "x", uniquement pertinent
# quand une valeur actuelle existe déjà (sinon "x" serait une simple saisie invalide).
function Test-ClearToken {
    param([string]$InputValue)
    return $InputValue -match '^(?i:x)$'
}

function Read-IPv4WithDefault {
    param(
        [string]$Prompt,
        [string]$Default,
        [bool]$AllowEmpty = $true
    )
    $hasCurrent = -not [string]::IsNullOrWhiteSpace($Default)
    $displayPrompt = if ($hasCurrent) { "$Prompt (x = supprimer la valeur actuelle)" } else { $Prompt }
    while ($true) {
        $val = Read-WithDefault -Prompt $displayPrompt -Default $Default
        if ($hasCurrent -and (Test-ClearToken -InputValue $val)) { return '' }
        if ($AllowEmpty -and [string]::IsNullOrWhiteSpace($val)) { return $val }
        if (Test-IPv4Address -InputValue $val) { return $val }
        Write-Host "  Adresse IPv4 invalide (ex: 192.168.1.10)." -ForegroundColor Yellow
    }
}

# Convertit une saisie de masque en longueur de prefixe (0-32). Accepte le format
# CIDR ("/24" ou "24") ou le format decimal pointe ("255.255.255.0"). Retourne $null
# si invalide (format incorrect, ou masque decimal non contigu comme 255.0.255.0).
function ConvertTo-PrefixLength {
    param([string]$InputValue)
    $v = $InputValue.Trim()
    if ($v.StartsWith('/')) { $v = $v.Substring(1) }

    if ($v -match '^\d{1,2}$') {
        $n = [int]$v
        if ($n -ge 0 -and $n -le 32) { return $n }
        return $null
    }

    $addr = $null
    if (-not ([System.Net.IPAddress]::TryParse($v, [ref]$addr)) -or $addr.AddressFamily -ne 'InterNetwork') { return $null }
    $bytes = $addr.GetAddressBytes()
    $maskValue = ([uint32]$bytes[0] -shl 24) -bor ([uint32]$bytes[1] -shl 16) -bor ([uint32]$bytes[2] -shl 8) -bor [uint32]$bytes[3]

    # Un masque valide est une suite de 1 contigus suivie de 0 (ex: 11111111.11111111.11111111.00000000)
    $prefixLength = 0
    $seenZero = $false
    for ($i = 31; $i -ge 0; $i--) {
        $bit = ($maskValue -shr $i) -band 1
        if ($bit -eq 1) {
            if ($seenZero) { return $null }
            $prefixLength++
        } else {
            $seenZero = $true
        }
    }
    return $prefixLength
}

function Read-SubnetMaskWithDefault {
    param([string]$Prompt, [int]$DefaultPrefixLength = 24)
    while ($true) {
        $val = Read-WithDefault -Prompt $Prompt -Default "$DefaultPrefixLength"
        $prefix = ConvertTo-PrefixLength -InputValue $val
        if ($null -ne $prefix) { return $prefix }
        Write-Host "  Masque invalide. Attendu : /24 ou 255.255.255.0" -ForegroundColor Yellow
    }
}

# Adresse IP et masque demandes en deux etapes separees (plutot qu'un seul champ CIDR),
# le masque acceptant le format CIDR ou decimal pointe. Retourne toujours une chaine
# "ip/prefixe" (ou '' si l'utilisateur efface via 'x' quand AllowClear est actif).
function Read-CidrWithDefault {
    param(
        [string]$Prompt,
        [string]$Default,
        [bool]$AllowClear = $false
    )
    $hasCurrent = $AllowClear -and (-not [string]::IsNullOrWhiteSpace($Default))

    $defaultIp = ''
    $defaultPrefix = 24
    if ($Default -match '^(?<ip>(\d{1,3}\.){3}\d{1,3})/(?<prefix>\d{1,2})$') {
        $defaultIp = $Matches.ip
        $defaultPrefix = [int]$Matches.prefix
    }

    $ipDisplayPrompt = if ($hasCurrent) { "$Prompt (x = supprimer)" } else { $Prompt }
    while ($true) {
        $ipVal = Read-WithDefault -Prompt $ipDisplayPrompt -Default $defaultIp
        if ($hasCurrent -and (Test-ClearToken -InputValue $ipVal)) { return '' }
        if (-not [string]::IsNullOrWhiteSpace($ipVal) -and (Test-IPv4Address -InputValue $ipVal)) { break }
        Write-Host "  Adresse IPv4 invalide (ex: 192.168.1.10)." -ForegroundColor Yellow
    }

    $prefix = Read-SubnetMaskWithDefault -Prompt "  Masque de sous-réseau (CIDR /24 ou décimal 255.255.255.0)" -DefaultPrefixLength $defaultPrefix
    return "$ipVal/$prefix"
}

# Verifie que la passerelle appartient au meme sous-reseau que l'adresse IP/masque
# donnee. Sans ce controle, une passerelle hors sous-reseau est acceptee par
# New-NetIPAddress qui echoue ensuite silencieusement, laissant l'interface sans IP
# statique valide et disparaitre en APIPA (169.254.x.x).
function Test-GatewayInSubnet {
    param([string]$IpCidr, [string]$Gateway)
    if ([string]::IsNullOrWhiteSpace($Gateway)) { return $true }
    if ($IpCidr -notmatch '^(?<ip>(\d{1,3}\.){3}\d{1,3})/(?<prefix>\d{1,2})$') { return $true }

    $ipAddr = $null
    $gwAddr = $null
    if (-not ([System.Net.IPAddress]::TryParse($Matches.ip, [ref]$ipAddr))) { return $true }
    if (-not ([System.Net.IPAddress]::TryParse($Gateway, [ref]$gwAddr))) { return $true }

    $prefix = [int]$Matches.prefix
    $maskValue = if ($prefix -eq 0) { [uint32]0 } else { [uint32]::MaxValue -shl (32 - $prefix) }

    $ipBytes = $ipAddr.GetAddressBytes()
    $gwBytes = $gwAddr.GetAddressBytes()
    $ipValue = ([uint32]$ipBytes[0] -shl 24) -bor ([uint32]$ipBytes[1] -shl 16) -bor ([uint32]$ipBytes[2] -shl 8) -bor [uint32]$ipBytes[3]
    $gwValue = ([uint32]$gwBytes[0] -shl 24) -bor ([uint32]$gwBytes[1] -shl 16) -bor ([uint32]$gwBytes[2] -shl 8) -bor [uint32]$gwBytes[3]

    return ($ipValue -band $maskValue) -eq ($gwValue -band $maskValue)
}

# Menu générique navigable aux flèches Haut/Bas + Entrée. Retourne l'index choisi (-1 si Échap).
function Show-ArrowMenu {
    param(
        [string]$Title,
        [string[]]$Items,
        [int]$DefaultIndex = 0,
        [switch]$TitleAtBottom
    )
    $selected = [Math]::Max(0, [Math]::Min($DefaultIndex, $Items.Count - 1))
    $width = [Math]::Max(40, [Console]::WindowWidth - 2)

    Write-Host ""
    if ($Title -and -not $TitleAtBottom) { Write-Host $Title -ForegroundColor DarkGray }
    [Console]::CursorVisible = $false

    # Couleur de repos de chaque ligne, precalculee une seule fois (en-tetes === en DarkCyan).
    $baseColors = @($Items | ForEach-Object { if ($_ -match '^===') { 'DarkCyan' } else { 'Gray' } })

    $writeLine = {
        param($i, [bool]$InPlace)
        $marker = if ($i -eq $selected) { ">" } else { " " }
        $line = " $marker $($Items[$i])"
        if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }
        $line = $line.PadRight($width)
        $colors = if ($i -eq $selected) { @{ ForegroundColor = 'Black'; BackgroundColor = 'Cyan' } }
                  else { @{ ForegroundColor = $baseColors[$i] } }
        Write-Host $line -NoNewline:$InPlace @colors
    }

    $top = 0
    $extraLines = 0
    try {
        # Premier dessin complet, avec sauts de ligne pour laisser le defilement naturel se
        # produire, puis calcul de la position du haut du menu a partir de la position finale
        # du curseur : reste juste meme si l'affichage a fait defiler la fenetre.
        for ($i = 0; $i -lt $Items.Count; $i++) { & $writeLine $i $false }
        if ($TitleAtBottom -and $Title) {
            Write-Host ""
            Write-Host $Title -ForegroundColor DarkGray
            $extraLines = 2
        }
        $top = [Console]::CursorTop - $Items.Count - $extraLines

        while ($true) {
            # Curseur gare a un endroit fixe pour eviter tout "saut" visuel entre les frappes.
            [Console]::SetCursorPosition(0, $top)
            $key = [Console]::ReadKey($true)
            $previous = $selected
            switch ($key.Key) {
                'UpArrow'    { $selected = ($selected - 1 + $Items.Count) % $Items.Count }
                'DownArrow'  { $selected = ($selected + 1) % $Items.Count }
                'Enter'      { return $selected }
                'Spacebar'   { return $selected }
                'Escape'     { return -1 }
            }
            if ($selected -ne $previous) {
                # Ne redessine que les deux lignes concernees (ancienne et nouvelle selection)
                # au lieu de la liste entiere : la navigation reste fluide sur les grands menus.
                [Console]::SetCursorPosition(0, $top + $previous)
                & $writeLine $previous $true
                [Console]::SetCursorPosition(0, $top + $selected)
                & $writeLine $selected $true
            }
        }
    } finally {
        # Ne pas reafficher le curseur texte ici : le faire systematiquement au retour
        # provoquait un saut visible pile au moment de valider (Entree/Espace), avant meme
        # que l'ecran suivant ne soit dessine. Ce sont les fonctions de saisie
        # (Read-WithDefault, Read-YesNo, Read-HostWithEscape) qui le reactivent elles-memes.
        [Console]::CursorVisible = $false
        # Replace le curseur SOUS le menu : le laisser gare en haut faisait ecrire la suite
        # de l'affichage par-dessus les lignes du menu (surimpressions constatees).
        [Console]::SetCursorPosition(0, $top + $Items.Count + $extraLines)
        Write-Host ""
    }
}

#endregion

#region Accès données réseau

# Récupère l'état de toutes les interfaces en un nombre CONSTANT d'appels CIM (5 au total),
# plutôt qu'un aller-retour par interface et par type d'info (IP/route/DNS/DHCP) comme avant.
# C'était la cause principale de la latence à l'ouverture des menus.
function Get-NetworkInterfacesInfo {
    param([string[]]$ExcludeNames = @())

    $adapters = @(Get-NetAdapter | Sort-Object ifIndex)
    if ($ExcludeNames -and $ExcludeNames.Count -gt 0) {
        $adapters = @($adapters | Where-Object { $ExcludeNames -notcontains $_.Name })
    }
    if ($adapters.Count -eq 0) { return @() }

    $allIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $allRoutes = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
    $allDns = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $allIpIface = Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue

    $ipByIndex = @{}
    foreach ($ip in $allIp) {
        if (-not $ipByIndex.ContainsKey($ip.InterfaceIndex)) { $ipByIndex[$ip.InterfaceIndex] = [System.Collections.Generic.List[object]]::new() }
        $ipByIndex[$ip.InterfaceIndex].Add($ip)
    }
    $routeByIndex = @{}
    foreach ($r in $allRoutes) { $routeByIndex[$r.InterfaceIndex] = $r }
    $dnsByIndex = @{}
    foreach ($d in $allDns) { $dnsByIndex[$d.InterfaceIndex] = $d }
    $ipIfaceByIndex = @{}
    foreach ($i in $allIpIface) { $ipIfaceByIndex[$i.InterfaceIndex] = $i }

    foreach ($a in $adapters) {
        $ipConfig = $ipByIndex[$a.ifIndex]
        $route = $routeByIndex[$a.ifIndex]
        $dns = $dnsByIndex[$a.ifIndex]
        $ipIface = $ipIfaceByIndex[$a.ifIndex]

        $ipList = @(if ($ipConfig) { $ipConfig | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" } } else { @() })
        $dnsList = @(if ($dns) { $dns.ServerAddresses } else { @() })
        $gateway = if ($route) { $route.NextHop } else { $null }

        [PSCustomObject]@{
            IfIndex               = $a.ifIndex
            Name                  = $a.Name
            InterfaceDescription  = $a.InterfaceDescription
            Status                = $a.Status
            MacAddress            = $a.MacAddress
            IPAddresses           = $ipList
            Gateway               = $gateway
            DnsServers            = $dnsList
            Dhcp                  = if ($ipIface) { $ipIface.Dhcp } else { 'Unknown' }
        }
    }
}

function Format-InterfaceLine {
    param($Iface)
    $etat = if ($Iface.Status -eq 'Up') { 'Activée   ' } else { 'Désactivée' }
    $ip = if ($Iface.IPAddresses.Count -gt 0) { $Iface.IPAddresses -join ', ' } else { '(aucune)' }
    "{0,-22} ({1})  [{2}]  IP: {3}" -f $Iface.Name, $Iface.InterfaceDescription, $etat, $ip
}

function Format-ByteSize {
    param([double]$Bytes)
    $units = 'o', 'Ko', 'Mo', 'Go', 'To'
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt $units.Count - 1) {
        $Bytes /= 1024
        $i++
    }
    "{0:N2} {1}" -f $Bytes, $units[$i]
}

function Format-Rate {
    param([double]$BytesPerSecond)
    "{0}/s" -f (Format-ByteSize $BytesPerSecond)
}

#endregion

#region Assistant de configuration d'une interface

function New-InterfacePlan {
    param($Current, $PresetOverride = $null)

    $isEnabled = $Current.Status -eq 'Up'
    $wantEnabled = Read-YesNo -Prompt "Activer l'interface '$($Current.Name)' ?" -Default $isEnabled

    $plan = [PSCustomObject]@{
        IfIndex              = $Current.IfIndex
        Name                 = $Current.Name
        CurrentEnabled       = $isEnabled
        NewEnabledState      = $wantEnabled
        ConfigureIP          = $false
        Mode                 = $null
        PrimaryIP            = $null
        ExtraIPs             = @()
        Gateway              = $null
        DnsPrimary           = $null
        DnsSecondary         = $null
        AutoApply            = $false
        SkipSavePresetPrompt = $false
    }

    if (-not $wantEnabled) {
        return $plan
    }

    $plan.ConfigureIP = $true

    # Valeurs par defaut des prompts IP ci-dessous : celles de l'interface actuelle,
    # sauf si l'utilisateur choisit de charger un preset (les presets ne sont jamais
    # lies a une interface, ils fournissent juste un jeu de defauts alternatif).
    $ipDefaults = [PSCustomObject]@{
        DhcpState    = $Current.Dhcp
        PrimaryIP    = if ($Current.IPAddresses.Count -gt 0) { $Current.IPAddresses[0] } else { '' }
        ExtraIPs     = if ($Current.IPAddresses.Count -gt 1) { $Current.IPAddresses[1..($Current.IPAddresses.Count - 1)] } else { @() }
        Gateway      = $Current.Gateway
        DnsPrimary   = if ($Current.DnsServers.Count -gt 0) { $Current.DnsServers[0] } else { '' }
        DnsSecondary = if ($Current.DnsServers.Count -gt 1) { $Current.DnsServers[1] } else { '' }
    }

    $preset = $PresetOverride
    if (-not $preset -and (Read-YesNo -Prompt "Charger la configuration IP depuis un preset ?" -Default $false)) {
        $preset = Select-Preset
    }
    if ($preset) {
        # Sauver le preset système DHCP tel quel n'a aucun intérêt : jamais propose.
        if ($preset.IsBuiltin) { $plan.SkipSavePresetPrompt = $true }

        $loadModeItems = @('Charger immédiatement', 'Valider la configuration du preset')
        $loadModeChoice = Show-ArrowMenu -Title "Comment charger le preset '$($preset.Name)' ?" -Items $loadModeItems -DefaultIndex 0
        if ($loadModeChoice -eq 0) {
            # Applique le preset sans repasser par les prompts Mode/IP/Passerelle/DNS,
            # ni par la confirmation finale ni par la proposition de sauvegarde en preset.
            $plan.AutoApply = $true
            $plan.SkipSavePresetPrompt = $true
            $plan.Mode = $preset.Mode
            if ($preset.Mode -eq 'Static') {
                $plan.PrimaryIP = $preset.PrimaryIP
                $plan.ExtraIPs = @($preset.ExtraIPs)
                $plan.Gateway = $preset.Gateway
                if (-not (Test-GatewayInSubnet -IpCidr $plan.PrimaryIP -Gateway $plan.Gateway)) {
                    Write-Host "  Passerelle du preset hors sous-réseau : ignorée." -ForegroundColor Yellow
                    $plan.Gateway = ''
                }
            }
            $plan.DnsPrimary = $preset.DnsPrimary
            $plan.DnsSecondary = $preset.DnsSecondary
            return $plan
        }

        $ipDefaults = [PSCustomObject]@{
            DhcpState    = if ($preset.Mode -eq 'DHCP') { 'Enabled' } else { 'Disabled' }
            PrimaryIP    = $preset.PrimaryIP
            ExtraIPs     = @($preset.ExtraIPs)
            Gateway      = $preset.Gateway
            DnsPrimary   = $preset.DnsPrimary
            DnsSecondary = $preset.DnsSecondary
        }
    }

    $defaultMode = if ($ipDefaults.DhcpState -eq 'Enabled') { 'DHCP' } else { 'Static' }
    $config = Read-IPv4Config -DefaultMode $defaultMode -DefaultPrimaryIP $ipDefaults.PrimaryIP -DefaultExtraIPs $ipDefaults.ExtraIPs `
        -DefaultGateway $ipDefaults.Gateway -DefaultDnsPrimary $ipDefaults.DnsPrimary -DefaultDnsSecondary $ipDefaults.DnsSecondary -InterfaceLabel $Current.Name

    $plan.Mode = $config.Mode
    $plan.PrimaryIP = $config.PrimaryIP
    $plan.ExtraIPs = $config.ExtraIPs
    $plan.Gateway = $config.Gateway
    $plan.DnsPrimary = $config.DnsPrimary
    $plan.DnsSecondary = $config.DnsSecondary

    return $plan
}

# Rassemble les prompts Mode/IP/IPs supplementaires/Passerelle/DNS partages entre
# l'assistant d'interface (New-InterfacePlan) et l'edition d'un preset (Edit-Preset).
function Read-IPv4Config {
    param(
        [string]$DefaultMode,
        [string]$DefaultPrimaryIP,
        [string[]]$DefaultExtraIPs = @(),
        [string]$DefaultGateway,
        [string]$DefaultDnsPrimary,
        [string]$DefaultDnsSecondary,
        [string]$InterfaceLabel = ''
    )

    $result = [PSCustomObject]@{
        Mode         = $null
        PrimaryIP    = ''
        ExtraIPs     = @()
        Gateway      = ''
        DnsPrimary   = ''
        DnsSecondary = ''
    }

    $currentModeIndex = if ($DefaultMode -eq 'DHCP') { 0 } else { 1 }
    $titleSuffix = if ($InterfaceLabel) { " pour '$InterfaceLabel'" } else { '' }
    $choice = Show-ArrowMenu -Title "Mode d'adressage IP$titleSuffix :" -Items @('DHCP (automatique)', 'IP statique') -DefaultIndex $currentModeIndex

    if ($choice -eq 0) {
        $result.Mode = 'DHCP'
    } else {
        $result.Mode = 'Static'
        $result.PrimaryIP = Read-CidrWithDefault -Prompt "Adresse IP + masque (CIDR)" -Default $DefaultPrimaryIP

        $extras = New-Object System.Collections.Generic.List[string]
        foreach ($e in $DefaultExtraIPs) {
            $kept = Read-CidrWithDefault -Prompt "Adresse IP supplémentaire existante" -Default $e -AllowClear $true
            if (-not [string]::IsNullOrWhiteSpace($kept)) {
                $extras.Add($kept)
            }
        }

        while (Read-YesNo -Prompt "Ajouter une adresse IP supplémentaire ?" -Default $false) {
            $extraIp = Read-CidrWithDefault -Prompt "  Adresse IP supplémentaire (CIDR)" -Default ''
            $extras.Add($extraIp)
        }
        $result.ExtraIPs = $extras.ToArray()

        while ($true) {
            $result.Gateway = Read-IPv4WithDefault -Prompt "Passerelle par défaut" -Default $DefaultGateway
            if (Test-GatewayInSubnet -IpCidr $result.PrimaryIP -Gateway $result.Gateway) { break }
            Write-Host "  La passerelle n'est pas dans le même sous-réseau que l'adresse IP ($($result.PrimaryIP))." -ForegroundColor Yellow
        }
    }

    $result.DnsPrimary = Read-IPv4WithDefault -Prompt "Serveur DNS primaire" -Default $DefaultDnsPrimary
    $result.DnsSecondary = Read-IPv4WithDefault -Prompt "Serveur DNS secondaire" -Default $DefaultDnsSecondary

    return $result
}

function Format-OrDefault {
    param($Value, [string]$DefaultLabel)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $DefaultLabel }
    return $Value
}

function Show-PlanSummary {
    param($Current, $Plan)

    Write-Host ""
    Write-Host "===== Résumé des modifications : $($Plan.Name) =====" -ForegroundColor Cyan

    $etatAvant = if ($Plan.CurrentEnabled) { 'Activée' } else { 'Désactivée' }
    $etatApres = if ($Plan.NewEnabledState) { 'Activée' } else { 'Désactivée' }
    Write-Host ("  État        : {0} -> {1}" -f $etatAvant, $etatApres)

    if (-not $Plan.NewEnabledState) {
        Write-Host ""
        return
    }

    # Vocabulaire homogene : l'etat CIM ('Enabled'/'Disabled') est traduit dans les memes
    # termes que le mode cible, plutot que d'afficher "Enabled -> Static".
    $modeAvant = switch ($Current.Dhcp) { 'Enabled' { 'DHCP' } 'Disabled' { 'Statique' } default { "$_" } }
    $modeApres = if ($Plan.Mode -eq 'DHCP') { 'DHCP' } else { 'Statique' }
    Write-Host ("  Mode IP     : {0} -> {1}" -f $modeAvant, $modeApres)

    if ($Plan.Mode -eq 'Static') {
        $ipAvant = if ($Current.IPAddresses.Count -gt 0) { $Current.IPAddresses -join ', ' } else { '(aucune)' }
        $ipApres = (@($Plan.PrimaryIP) + $Plan.ExtraIPs) -join ', '
        Write-Host ("  Adresse(s)  : {0} -> {1}" -f $ipAvant, $ipApres)
        Write-Host ("  Passerelle  : {0} -> {1}" -f (Format-OrDefault $Current.Gateway '(aucune)'), (Format-OrDefault $Plan.Gateway '(aucune)'))
    }

    Write-Host ("  DNS primaire   : {0} -> {1}" -f (Format-OrDefault ($Current.DnsServers | Select-Object -First 1) '(aucun)'), (Format-OrDefault $Plan.DnsPrimary '(aucun)'))
    Write-Host ("  DNS secondaire : {0} -> {1}" -f (Format-OrDefault ($Current.DnsServers | Select-Object -Skip 1 -First 1) '(aucun)'), (Format-OrDefault $Plan.DnsSecondary '(aucun)'))
    Write-Host ""
}

function Invoke-ApplyPlan {
    param($Plan)

    try {
        if (-not $Plan.NewEnabledState) {
            if ($Plan.CurrentEnabled) {
                Disable-NetAdapter -Name $Plan.Name -Confirm:$false
            }
            Write-Host "Interface '$($Plan.Name)' désactivée." -ForegroundColor Green
            return $true
        }

        if (-not $Plan.CurrentEnabled) {
            Enable-NetAdapter -Name $Plan.Name -Confirm:$false
            Start-Sleep -Seconds 2
        }

        # Bascule le mode DHCP/Statique AVANT de nettoyer l'ancienne config IPv4 : si le
        # nettoyage a lieu pendant que le DHCP est encore actif, le client DHCP peut
        # reinstaller silencieusement l'IP/route qu'on vient de supprimer, provoquant un
        # conflit ("Instance DefaultGateway already exists") au moment d'ajouter la nouvelle.
        if ($Plan.Mode -eq 'DHCP') {
            Set-NetIPInterface -InterfaceIndex $Plan.IfIndex -Dhcp Enabled
        } else {
            Set-NetIPInterface -InterfaceIndex $Plan.IfIndex -Dhcp Disabled
        }

        Get-NetIPAddress -InterfaceIndex $Plan.IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetRoute -InterfaceIndex $Plan.IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' } |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

        if ($Plan.Mode -eq 'Static') {
            $primary = $Plan.PrimaryIP -split '/'
            $ipParams = @{
                InterfaceIndex = $Plan.IfIndex
                IPAddress      = $primary[0]
                PrefixLength   = [int]$primary[1]
            }
            if (-not [string]::IsNullOrWhiteSpace($Plan.Gateway)) {
                $ipParams.DefaultGateway = $Plan.Gateway
            }
            New-NetIPAddress @ipParams | Out-Null

            foreach ($extra in $Plan.ExtraIPs) {
                $parts = $extra -split '/'
                New-NetIPAddress -InterfaceIndex $Plan.IfIndex -IPAddress $parts[0] -PrefixLength ([int]$parts[1]) | Out-Null
            }
        }

        $dnsServers = @($Plan.DnsPrimary, $Plan.DnsSecondary | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($dnsServers.Count -gt 0) {
            Set-DnsClientServerAddress -InterfaceIndex $Plan.IfIndex -ServerAddresses $dnsServers
        } else {
            Set-DnsClientServerAddress -InterfaceIndex $Plan.IfIndex -ResetServerAddresses
        }

        Write-Host "Configuration appliquée avec succès sur '$($Plan.Name)'." -ForegroundColor Green
        return $true
    } catch {
        Write-Host "Erreur lors de l'application de la configuration : $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Start-InterfaceWizard {
    param($Current, $PresetOverride = $null)

    Clear-Host
    Write-Host "=== Configuration de l'interface : $($Current.Name) ===" -ForegroundColor Cyan
    Write-Host ""

    $plan = New-InterfacePlan -Current $Current -PresetOverride $PresetOverride
    Show-PlanSummary -Current $Current -Plan $plan

    # "Charger immédiatement" un preset applique sans repasser par la confirmation.
    $confirmed = $plan.AutoApply -or (Read-YesNo -Prompt "Confirmer et appliquer ces modifications ?" -Default $false)

    if ($confirmed) {
        $applied = Invoke-ApplyPlan -Plan $plan
        if ($applied -and $plan.ConfigureIP -and -not $plan.SkipSavePresetPrompt) {
            Invoke-SavePresetPrompt -Plan $plan
        }
    } else {
        Write-Host "Modifications annulées." -ForegroundColor Yellow
    }

    Wait-EnterOrEscape
}

#endregion

#region Presets de configuration IP

# Les presets ne sont jamais lies a une interface : ils ne contiennent que la config IP
# (mode, adresse(s), passerelle, DNS), reutilisable sur n'importe quelle interface.
# Un fichier JSON par preset dans %LOCALAPPDATA%\NetIfaceManager\Presets\.
# Le preset "DHCP (automatique)" est code en dur (jamais un fichier) pour qu'il soit
# toujours disponible et ne puisse pas etre supprime/renomme par erreur.

function Get-PresetsDir {
    Join-Path $env:LOCALAPPDATA 'NetIfaceManager\Presets'
}

function Get-BuiltinDhcpPreset {
    [PSCustomObject]@{
        Name         = 'DHCP (automatique)'
        Mode         = 'DHCP'
        PrimaryIP    = ''
        ExtraIPs     = @()
        Gateway      = ''
        DnsPrimary   = ''
        DnsSecondary = ''
        IsBuiltin    = $true
        FilePath     = $null
    }
}

function Test-PresetNameReserved {
    param([string]$Name)
    $Name.Trim() -eq (Get-BuiltinDhcpPreset).Name
}

function Get-SafePresetFileName {
    param([string]$Name)
    $invalidChars = [Regex]::Escape([string]::new([System.IO.Path]::GetInvalidFileNameChars()))
    ($Name -replace "[$invalidChars]", '_') + '.json'
}

function Get-AllPresets {
    $dir = Get-PresetsDir
    $custom = @()
    if (Test-Path $dir) {
        $custom = @(Get-ChildItem -Path $dir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $json = Get-Content -Path $_.FullName -Raw | ConvertFrom-Json
                [PSCustomObject]@{
                    Name         = $json.Name
                    Mode         = $json.Mode
                    PrimaryIP    = $json.PrimaryIP
                    ExtraIPs     = @($json.ExtraIPs)
                    Gateway      = $json.Gateway
                    DnsPrimary   = $json.DnsPrimary
                    DnsSecondary = $json.DnsSecondary
                    IsBuiltin    = $false
                    FilePath     = $_.FullName
                }
            } catch { $null }
        } | Where-Object { $_ })
    }
    @(Get-BuiltinDhcpPreset) + @($custom | Sort-Object Name)
}

function Format-PresetLine {
    param($Preset)
    if ($Preset.Mode -eq 'DHCP') {
        $detail = 'DHCP (automatique)'
    } else {
        $detail = "Statique {0}" -f $Preset.PrimaryIP
        if ($Preset.ExtraIPs.Count -gt 0) { $detail += " (+$($Preset.ExtraIPs.Count) IP suppl.)" }
        if (-not [string]::IsNullOrWhiteSpace($Preset.Gateway)) { $detail += " -> $($Preset.Gateway)" }
    }
    "{0,-28} {1}" -f $Preset.Name, $detail
}

function Select-Preset {
    $presets = @(Get-AllPresets)
    $items = @($presets | ForEach-Object { Format-PresetLine -Preset $_ })
    $items += "<< Annuler"
    $choice = Show-ArrowMenu -Title "Sélectionnez un preset :" -Items $items -DefaultIndex 0
    if ($choice -lt 0 -or $choice -eq $items.Count - 1) { return $null }
    return $presets[$choice]
}

function Save-Preset {
    param([string]$Name, $Data)
    $dir = Get-PresetsDir
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir (Get-SafePresetFileName -Name $Name)
    [PSCustomObject]@{
        Name         = $Name
        Mode         = $Data.Mode
        PrimaryIP    = $Data.PrimaryIP
        ExtraIPs     = @($Data.ExtraIPs)
        Gateway      = $Data.Gateway
        DnsPrimary   = $Data.DnsPrimary
        DnsSecondary = $Data.DnsSecondary
    } | ConvertTo-Json | Set-Content -Path $path -Encoding UTF8
}

function Remove-PresetFile {
    param($Preset)
    if ($Preset.FilePath -and (Test-Path $Preset.FilePath)) {
        Remove-Item -Path $Preset.FilePath -Force
    }
}

function Rename-PresetFile {
    param($Preset, [string]$NewName)
    Save-Preset -Name $NewName -Data $Preset
    if ($Preset.FilePath -and (Test-Path $Preset.FilePath)) {
        Remove-Item -Path $Preset.FilePath -Force
    }
}

function Invoke-SavePresetPrompt {
    param($Plan)
    if (-not (Read-YesNo -Prompt "Sauver cette configuration IP comme preset ?" -Default $false)) { return }

    while ($true) {
        $name = Read-HostWithEscape -Prompt "Nom du preset"
        if ($null -eq $name) { return }
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        if (Test-PresetNameReserved -Name $name) {
            Write-Host "  Ce nom est réservé au preset système 'DHCP (automatique)'." -ForegroundColor Yellow
            continue
        }

        $existingPath = Join-Path (Get-PresetsDir) (Get-SafePresetFileName -Name $name)
        if ((Test-Path $existingPath) -and -not (Read-YesNo -Prompt "Un preset '$name' existe déjà. Écraser ?" -Default $false)) {
            continue
        }

        Save-Preset -Name $name -Data $Plan
        Write-Host "Preset '$name' enregistré." -ForegroundColor Green
        return
    }
}

#endregion

#region Préférences utilisateur (interfaces masquées)

# Sauvegarde locale par utilisateur (%LOCALAPPDATA%\NetIfaceManager\config.json).
# Les interfaces masquées sont identifiées par leur Name : simple et lisible,
# mais à reconfigurer si l'interface est renommée manuellement dans Windows.
function Get-ConfigPath {
    Join-Path $env:LOCALAPPDATA 'NetIfaceManager\config.json'
}

function Get-HiddenInterfaceNames {
    $path = Get-ConfigPath
    if (-not (Test-Path $path)) { return @() }
    try {
        $json = Get-Content -Path $path -Raw | ConvertFrom-Json
        return @($json.HiddenInterfaces)
    } catch {
        return @()
    }
}

function Save-HiddenInterfaceNames {
    param([string[]]$Names)
    $path = Get-ConfigPath
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [PSCustomObject]@{ HiddenInterfaces = @($Names) } | ConvertTo-Json | Set-Content -Path $path -Encoding UTF8
}

function Get-VisibleInterfaces {
    # @() autour de l'appel : un tableau vide renvoyé par une fonction est aplati en
    # $null par le pipeline de sortie (cas du premier lancement, sans config.json) —
    # sans ce wrap, $null atteindrait -ExcludeNames et ferait planter .Count plus loin.
    $hidden = @(Get-HiddenInterfaceNames)
    @(Get-NetworkInterfacesInfo -ExcludeNames $hidden)
}

#endregion

#region Menus principaux

function Show-InterfaceSelectionScreen {
    $interfaces = @(Get-VisibleInterfaces)
    if ($interfaces.Count -eq 0) {
        Write-Host "Aucune interface réseau visible (vérifiez le menu Options)." -ForegroundColor Red
        Wait-EnterOrEscape -Message "Appuyez sur Entrée ou Échap pour continuer"
        return
    }

    Clear-Host
    Write-Host "=== Sélectionnez une interface à gérer ===" -ForegroundColor Cyan
    $items = @($interfaces | ForEach-Object { Format-InterfaceLine -Iface $_ })
    $items += "<< Retour au menu principal"

    $choice = Show-ArrowMenu -Items $items -DefaultIndex 0

    if ($choice -lt 0 -or $choice -eq $items.Count - 1) { return }

    Start-InterfaceWizard -Current $interfaces[$choice]
}

function Show-OptionsMenu {
    $lastIndex = 0
    # Les interfaces sont interrogees une seule fois : basculer la visibilite ne change que
    # le fichier de preferences, pas le materiel — inutile de refaire les requetes CIM a
    # chaque bascule.
    $allIfaces = @(Get-NetworkInterfacesInfo)
    if ($allIfaces.Count -eq 0) {
        Write-Host "Aucune interface réseau trouvée." -ForegroundColor Red
        Wait-EnterOrEscape -Message "Appuyez sur Entrée ou Échap pour continuer"
        return
    }

    while ($true) {
        $hidden = @(Get-HiddenInterfaceNames)

        Clear-Host
        Write-Host "=== Options : interfaces visibles dans les listes ===" -ForegroundColor Cyan
        Write-Host "  Sélectionnez une interface pour basculer Masquer/Afficher." -ForegroundColor DarkGray
        Write-Host ("  Fichier de config : {0}" -f (Get-ConfigPath)) -ForegroundColor DarkGray
        Write-Host ""

        $items = @($allIfaces | ForEach-Object {
            $state = if ($hidden -contains $_.Name) { 'Masquée' } else { 'Visible' }
            "[{0,-7}] {1}" -f $state, (Format-InterfaceLine -Iface $_)
        })
        $items += "<< Retour au menu principal"

        $choice = Show-ArrowMenu -Title "Utilisez Haut/Bas, Entrée ou Espace pour basculer :" -Items $items -DefaultIndex $lastIndex
        if ($choice -lt 0 -or $choice -eq $items.Count - 1) { return }
        $lastIndex = $choice

        $target = $allIfaces[$choice]
        if ($hidden -contains $target.Name) {
            $newHidden = @($hidden | Where-Object { $_ -ne $target.Name })
        } else {
            $newHidden = @($hidden) + $target.Name
        }
        Save-HiddenInterfaceNames -Names $newHidden
    }
}

function Invoke-FlushDns {
    Clear-Host
    Write-Host "=== Vider le cache DNS (équivalent ipconfig /flushdns) ===" -ForegroundColor Cyan
    Write-Host ""
    try {
        Clear-DnsClientCache -ErrorAction Stop
        Write-Host "Cache DNS vidé avec succès." -ForegroundColor Green
    } catch {
        Write-Host "Erreur lors du vidage du cache DNS : $($_.Exception.Message)" -ForegroundColor Red
    }
    Wait-EnterOrEscape
}

function Invoke-DhcpReleaseRenew {
    $interfaces = @(Get-VisibleInterfaces)
    if ($interfaces.Count -eq 0) {
        Write-Host "Aucune interface réseau visible (vérifiez le menu Options)." -ForegroundColor Red
        Wait-EnterOrEscape -Message "Appuyez sur Entrée ou Échap pour continuer"
        return
    }

    Clear-Host
    Write-Host "=== DHCP : Release / Renew ===" -ForegroundColor Cyan
    $items = @($interfaces | ForEach-Object { Format-InterfaceLine -Iface $_ })
    $items += "<< Retour au menu principal"

    $ifaceChoice = Show-ArrowMenu -Title "Sélectionnez une interface :" -Items $items -DefaultIndex 0
    if ($ifaceChoice -lt 0 -or $ifaceChoice -eq $items.Count - 1) { return }
    $target = $interfaces[$ifaceChoice]

    $actionItems = @(
        'Release (libérer le bail DHCP)',
        'Renew (renouveler le bail DHCP)',
        'Release puis Renew (recommandé)'
    )
    $actionChoice = Show-ArrowMenu -Title "Action DHCP pour '$($target.Name)' :" -Items $actionItems -DefaultIndex 2
    if ($actionChoice -lt 0) { return }

    Write-Host ""
    try {
        if ($actionChoice -eq 0 -or $actionChoice -eq 2) {
            Write-Host "Libération du bail DHCP ($($target.Name))..." -ForegroundColor Yellow
            & ipconfig /release "$($target.Name)" | Out-Null
        }
        if ($actionChoice -eq 1 -or $actionChoice -eq 2) {
            Write-Host "Renouvellement du bail DHCP ($($target.Name))..." -ForegroundColor Yellow
            & ipconfig /renew "$($target.Name)" | Out-Null
        }
        Write-Host "Terminé." -ForegroundColor Green
    } catch {
        Write-Host "Erreur : $($_.Exception.Message)" -ForegroundColor Red
    }

    Wait-EnterOrEscape
}

function Invoke-PublicIpLookup {
    Clear-Host
    Write-Host "=== IP publique (ifconfig.co) ===" -ForegroundColor Cyan
    Write-Host ""
    try {
        $info = Invoke-RestMethod -Uri 'https://ifconfig.co/json' -TimeoutSec 10 -ErrorAction Stop
        Write-Host ("  IP           : {0}" -f $info.ip)
        Write-Host ("  Pays         : {0}" -f $info.country)
        Write-Host ("  Code postal  : {0}" -f $info.zip_code)
        Write-Host ("  Ville        : {0}" -f $info.city)
        Write-Host ("  ASN Org      : {0}" -f $info.asn_org)
        Write-Host ("  Hostname     : {0}" -f $info.hostname)
    } catch {
        Write-Host "Erreur lors de la récupération de l'IP publique : $($_.Exception.Message)" -ForegroundColor Red
    }
    Wait-EnterOrEscape
}

# Le Clear-Host et l'entete ne sont affiches qu'une seule fois, avant la boucle : on ne veut
# surtout pas effacer le resultat d'une commande juste avant de redemander une nouvelle cible.
function Invoke-DnsLookup {
    Clear-Host
    Write-Host "=== Résolution DNS (équivalent nslookup) ===" -ForegroundColor Cyan
    Write-Host "  Échap pour revenir au menu principal." -ForegroundColor DarkGray
    Write-Host ""

    $dnsServer = Read-HostWithEscape -Prompt "Serveur DNS à interroger (Entrée = résolveur par défaut du système)"
    if ($null -eq $dnsServer) { return }
    if ([string]::IsNullOrWhiteSpace($dnsServer)) {
        $dnsServer = $null
    } else {
        Write-Host "  Requêtes envoyées à : $dnsServer" -ForegroundColor DarkGray
    }
    Write-Host ""

    while ($true) {
        $target = Read-HostWithEscape -Prompt "Nom d'hôte ou domaine à résoudre"
        if ($null -eq $target) { return }
        if ([string]::IsNullOrWhiteSpace($target)) { continue }

        Write-Host ""
        try {
            if ($dnsServer) {
                Resolve-DnsName -Name $target -Server $dnsServer -ErrorAction Stop | Format-Table -AutoSize | Out-String | Write-Host
            } else {
                Resolve-DnsName -Name $target -ErrorAction Stop | Format-Table -AutoSize | Out-String | Write-Host
            }
        } catch {
            Write-Host "Erreur lors de la résolution DNS : $($_.Exception.Message)" -ForegroundColor Red
        }
        Write-Host ""
    }
}

# Lance un executable externe en console partagee et attend sa fin, en laissant
# Echap l'interrompre a tout moment (le processus est alors tue). Utilise par
# ping -t (infini par nature) et tracert (long a terminer).
function Wait-ProcessOrEscape {
    param([string]$FilePath, [string[]]$ArgumentList)
    $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -PassThru
    while (-not $proc.HasExited) {
        if ([Console]::KeyAvailable -and ([Console]::ReadKey($true).Key -eq 'Escape')) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            break
        }
        Start-Sleep -Milliseconds 100
    }
}

function Invoke-PingHost {
    Clear-Host
    Write-Host "=== Ping (continu, équivalent ping -t) ===" -ForegroundColor Cyan
    Write-Host "  Échap pour arrêter le ping en cours ou revenir au menu principal." -ForegroundColor DarkGray
    Write-Host ""
    while ($true) {
        $target = Read-HostWithEscape -Prompt "Hôte ou adresse IP à pinguer"
        if ($null -eq $target) { return }
        if ([string]::IsNullOrWhiteSpace($target)) { continue }

        Write-Host ""
        Write-Host "Ping vers $target (Échap pour arrêter)..." -ForegroundColor Yellow
        Write-Host ""

        Wait-ProcessOrEscape -FilePath ping.exe -ArgumentList @('-t', $target)
        Write-Host ""
    }
}

function Invoke-TracertHost {
    Clear-Host
    Write-Host "=== Tracert ===" -ForegroundColor Cyan
    Write-Host "  Échap pour interrompre le tracé en cours ou revenir au menu principal." -ForegroundColor DarkGray
    Write-Host ""
    while ($true) {
        $target = Read-HostWithEscape -Prompt "Hôte ou adresse IP à tracer"
        if ($null -eq $target) { return }
        if ([string]::IsNullOrWhiteSpace($target)) { continue }

        Write-Host ""
        Wait-ProcessOrEscape -FilePath tracert.exe -ArgumentList @($target)
        Write-Host ""
    }
}

function Invoke-NetworkDiagnostic {
    Clear-Host
    Write-Host "=== Diagnostic réseau rapide ===" -ForegroundColor Cyan
    Write-Host "  Teste la passerelle, un serveur DNS public et la résolution de noms." -ForegroundColor DarkGray
    Write-Host ""

    function Show-DiagStep {
        param([string]$Label, [scriptblock]$Test)
        Write-Host -NoNewline ("  {0,-40}: " -f $Label)
        try {
            if (& $Test) {
                Write-Host "OK" -ForegroundColor Green
            } else {
                Write-Host "Échec" -ForegroundColor Red
            }
        } catch {
            Write-Host "Échec ($($_.Exception.Message))" -ForegroundColor Red
        }
    }

    $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object -Property RouteMetric | Select-Object -First 1
    $gateway = if ($route) { $route.NextHop } else { $null }

    if ($gateway) {
        Show-DiagStep -Label "Passerelle par défaut ($gateway)" -Test { Test-Connection -TargetName $gateway -Count 2 -Quiet -ErrorAction Stop }
    } else {
        Write-Host ("  {0,-40}: " -f "Passerelle par défaut") -NoNewline
        Write-Host "introuvable (aucune route par défaut)" -ForegroundColor Yellow
    }

    Show-DiagStep -Label "Serveur DNS public (1.1.1.1)" -Test { Test-Connection -TargetName '1.1.1.1' -Count 2 -Quiet -ErrorAction Stop }
    Show-DiagStep -Label "Résolution DNS (www.google.com)" -Test { [bool](Resolve-DnsName -Name 'www.google.com' -ErrorAction Stop) }

    Wait-EnterOrEscape
}

function Invoke-InterfaceStatistics {
    $interfaces = @(Get-VisibleInterfaces)
    if ($interfaces.Count -eq 0) {
        Write-Host "Aucune interface réseau visible (vérifiez le menu Options)." -ForegroundColor Red
        Wait-EnterOrEscape -Message "Appuyez sur Entrée ou Échap pour continuer"
        return
    }

    Clear-Host
    Write-Host "=== Statistiques d'interface en direct ===" -ForegroundColor Cyan
    $items = @($interfaces | ForEach-Object { Format-InterfaceLine -Iface $_ })
    $items += "<< Retour au menu principal"
    $choice = Show-ArrowMenu -Title "Sélectionnez une interface :" -Items $items -DefaultIndex 0
    if ($choice -lt 0 -or $choice -eq $items.Count - 1) { return }
    $target = $interfaces[$choice]

    Clear-Host
    Write-Host "=== Statistiques : $($target.Name) ===" -ForegroundColor Cyan
    Write-Host "  Échap pour revenir au menu principal. Rafraîchi chaque seconde." -ForegroundColor DarkGray
    Write-Host ""
    $top = [Console]::CursorTop
    [Console]::CursorVisible = $false

    $prevStats = $null
    $prevTime = $null
    try {
        while ($true) {
            try {
                $stats = Get-NetAdapterStatistics -Name $target.Name -ErrorAction Stop
            } catch {
                [Console]::SetCursorPosition(0, $top)
                Write-Host "Erreur : $($_.Exception.Message)".PadRight(70) -ForegroundColor Red
                break
            }
            $now = Get-Date
            $rxRate = 0; $txRate = 0
            if ($prevStats -and $prevTime) {
                $elapsed = ($now - $prevTime).TotalSeconds
                if ($elapsed -gt 0) {
                    $rxRate = [Math]::Max(0, ($stats.ReceivedBytes - $prevStats.ReceivedBytes) / $elapsed)
                    $txRate = [Math]::Max(0, ($stats.SentBytes - $prevStats.SentBytes) / $elapsed)
                }
            }

            [Console]::SetCursorPosition(0, $top)
            $lines = @(
                ("  Reçu total       : {0}" -f (Format-ByteSize $stats.ReceivedBytes))
                ("  Envoyé total     : {0}" -f (Format-ByteSize $stats.SentBytes))
                ("  Débit entrant    : {0}" -f (Format-Rate $rxRate))
                ("  Débit sortant    : {0}" -f (Format-Rate $txRate))
                ("  Paquets reçus    : {0}" -f $stats.ReceivedUnicastPackets)
                ("  Paquets envoyés  : {0}" -f $stats.SentUnicastPackets)
                ("  Erreurs (in/out) : {0} / {1}" -f $stats.ReceivedPacketErrors, $stats.OutboundPacketErrors)
                ("  Rejetés (in/out) : {0} / {1}" -f $stats.ReceivedDiscardedPackets, $stats.OutboundDiscardedPackets)
            )
            foreach ($line in $lines) { Write-Host $line.PadRight(60) }

            $prevStats = $stats
            $prevTime = $now

            $escaped = $false
            $waited = 0
            while ($waited -lt 1000) {
                if ([Console]::KeyAvailable -and ([Console]::ReadKey($true).Key -eq 'Escape')) { $escaped = $true; break }
                Start-Sleep -Milliseconds 100
                $waited += 100
            }
            if ($escaped) { break }
        }
    } finally {
        [Console]::CursorVisible = $true
        Write-Host ""
    }
}

function Invoke-NetworkProfileManager {
    Clear-Host
    Write-Host "=== Profil réseau (Public / Privé) ===" -ForegroundColor Cyan
    Write-Host ""

    $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
    if ($profiles.Count -eq 0) {
        Write-Host "Aucun profil réseau trouvé." -ForegroundColor Red
        Wait-EnterOrEscape -Message "Appuyez sur Entrée ou Échap pour continuer"
        return
    }

    $items = @($profiles | ForEach-Object { "{0,-25} [{1}]" -f $_.InterfaceAlias, $_.NetworkCategory })
    $items += "<< Retour au menu principal"
    $choice = Show-ArrowMenu -Title "Sélectionnez une interface :" -Items $items -DefaultIndex 0
    if ($choice -lt 0 -or $choice -eq $items.Count - 1) { return }
    $target = $profiles[$choice]

    if ($target.NetworkCategory -eq 'DomainAuthenticated') {
        Write-Host "`nCette interface est gérée par le domaine (DomainAuthenticated) : catégorie non modifiable manuellement." -ForegroundColor Yellow
        Wait-EnterOrEscape -Message "Appuyez sur Entrée ou Échap pour continuer"
        return
    }

    $catItems = @('Public', 'Privé')
    $currentIndex = if ($target.NetworkCategory -eq 'Private') { 1 } else { 0 }
    $catChoice = Show-ArrowMenu -Title "Nouvelle catégorie pour '$($target.InterfaceAlias)' :" -Items $catItems -DefaultIndex $currentIndex
    if ($catChoice -lt 0) { return }

    $newCategory = if ($catChoice -eq 1) { 'Private' } else { 'Public' }
    try {
        Set-NetConnectionProfile -InterfaceIndex $target.InterfaceIndex -NetworkCategory $newCategory -ErrorAction Stop
        Write-Host "`nCatégorie mise à jour : $newCategory" -ForegroundColor Green
    } catch {
        Write-Host "`nErreur : $($_.Exception.Message)" -ForegroundColor Red
    }

    Wait-EnterOrEscape
}

function Invoke-ActiveConnections {
    Clear-Host
    Write-Host "=== Connexions actives (équivalent netstat -ano) ===" -ForegroundColor Cyan
    Write-Host ""

    $filterItems = @('Ports en écoute (LISTEN)', 'Connexions établies (ESTABLISHED)', 'Toutes')
    $choice = Show-ArrowMenu -Title "Filtre :" -Items $filterItems -DefaultIndex 0
    if ($choice -lt 0) { return }
    $state = switch ($choice) { 0 { 'Listen' }; 1 { 'Established' }; default { $null } }

    Clear-Host
    Write-Host "=== Connexions actives : $($filterItems[$choice]) ===" -ForegroundColor Cyan
    Write-Host ""

    try {
        $connections = if ($state) {
            Get-NetTCPConnection -State $state -ErrorAction Stop
        } else {
            Get-NetTCPConnection -ErrorAction Stop
        }

        # Un seul Get-Process indexe par PID, au lieu d'un appel par connexion
        # (plusieurs centaines de connexions = plusieurs centaines d'appels evites).
        $procById = @{}
        foreach ($p in Get-Process -ErrorAction SilentlyContinue) { $procById[$p.Id] = $p.ProcessName }

        $rows = @($connections | ForEach-Object {
            $procName = if ($procById.ContainsKey([int]$_.OwningProcess)) { $procById[[int]$_.OwningProcess] } else { '?' }
            [PSCustomObject]@{
                'Local'     = "$($_.LocalAddress):$($_.LocalPort)"
                'Distant'   = "$($_.RemoteAddress):$($_.RemotePort)"
                'État'      = $_.State
                'PID'       = $_.OwningProcess
                'Processus' = $procName
            }
        })

        if ($rows.Count -eq 0) {
            Write-Host "Aucune connexion correspondante." -ForegroundColor Yellow
        } else {
            $rows | Sort-Object 'État', 'Local' | Format-Table -AutoSize | Out-String | Write-Host
        }
    } catch {
        Write-Host "Erreur : $($_.Exception.Message)" -ForegroundColor Red
    }

    Wait-EnterOrEscape
}

function Invoke-WifiScan {
    Clear-Host
    Write-Host "=== Réseaux Wi-Fi à proximité ===" -ForegroundColor Cyan
    Write-Host ""

    # "netsh wlan show networks" ne fait que lire le dernier scan connu du pilote Wi-Fi.
    # Windows limite les scans actifs une fois deja connecte (pour ne pas perturber la
    # connexion en cours), ce qui peut renvoyer une liste perimee ou reduite au reseau
    # actuel. Un premier appel declenche un nouveau scan ; on laisse quelques secondes
    # au pilote pour le terminer avant d'afficher le resultat.
    Write-Host "Scan des réseaux en cours..." -ForegroundColor Yellow
    & netsh wlan show networks | Out-Null
    Start-Sleep -Seconds 4

    Write-Host "--- Interface Wi-Fi actuelle ---" -ForegroundColor DarkGray
    & netsh wlan show interfaces
    Write-Host ""
    Write-Host "--- Réseaux visibles ---" -ForegroundColor DarkGray
    & netsh wlan show networks mode=bssid

    Wait-EnterOrEscape
}

function Invoke-TcpPortTest {
    Clear-Host
    Write-Host "=== Test de port TCP ===" -ForegroundColor Cyan
    Write-Host "  Échap pour revenir au menu principal." -ForegroundColor DarkGray
    Write-Host ""
    $lastTarget = ''
    while ($true) {
        $target = Read-HostWithEscape -Prompt "Hôte ou adresse IP" -Default $lastTarget
        if ($null -eq $target) { return }
        if ([string]::IsNullOrWhiteSpace($target)) { continue }
        $lastTarget = $target

        $portInput = Read-HostWithEscape -Prompt "Port (1-65535)"
        if ($null -eq $portInput) { return }
        $port = 0
        if (-not [int]::TryParse($portInput, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
            Write-Host "  Port invalide." -ForegroundColor Yellow
            continue
        }

        $client = [System.Net.Sockets.TcpClient]::new()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $task = $client.ConnectAsync($target, $port)
            if ($task.Wait(3000) -and $client.Connected) {
                Write-Host ("  {0}:{1} -> OUVERT ({2} ms)" -f $target, $port, $sw.ElapsedMilliseconds) -ForegroundColor Green
            } else {
                Write-Host ("  {0}:{1} -> fermé ou filtré (délai de 3 s dépassé)" -f $target, $port) -ForegroundColor Red
            }
        } catch {
            $reason = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
            Write-Host ("  {0}:{1} -> fermé ({2})" -f $target, $port, $reason) -ForegroundColor Red
        } finally {
            $client.Dispose()
        }
        Write-Host ""
    }
}

function Invoke-SubnetScan {
    Clear-Host
    Write-Host "=== Scan du sous-réseau ===" -ForegroundColor Cyan
    Write-Host "  Ping parallèle de chaque adresse, puis récupération des MAC (table ARP) et des noms." -ForegroundColor DarkGray
    Write-Host ""

    # Sous-reseau propose par defaut : celui de la premiere interface active avec passerelle
    # (la plus susceptible d'etre le LAN principal), ramene a son adresse de reseau.
    $defaultCidr = ''
    $candidates = @(Get-VisibleInterfaces | Where-Object { $_.Status -eq 'Up' -and $_.IPAddresses.Count -gt 0 -and $_.Gateway })
    if ($candidates.Count -gt 0 -and $candidates[0].IPAddresses[0] -match '^(?<ip>[\d.]+)/(?<prefix>\d+)$') {
        $prefix = [int]$Matches.prefix
        $ipBytes = ([System.Net.IPAddress]::Parse($Matches.ip)).GetAddressBytes()
        $ipValue = ([int64]$ipBytes[0] -shl 24) -bor ([int64]$ipBytes[1] -shl 16) -bor ([int64]$ipBytes[2] -shl 8) -bor [int64]$ipBytes[3]
        $maskValue = if ($prefix -eq 0) { [int64]0 } else { (0xFFFFFFFFL -shl (32 - $prefix)) -band 0xFFFFFFFFL }
        $network = $ipValue -band $maskValue
        $defaultCidr = "{0}.{1}.{2}.{3}/{4}" -f (($network -shr 24) -band 0xFF), (($network -shr 16) -band 0xFF), (($network -shr 8) -band 0xFF), ($network -band 0xFF), $prefix
    }

    $cidr = Read-CidrWithDefault -Prompt "Sous-réseau à scanner" -Default $defaultCidr
    if ($cidr -notmatch '^(?<ip>[\d.]+)/(?<prefix>\d+)$') { return }
    $prefix = [int]$Matches.prefix
    if ($prefix -gt 30) {
        Write-Host "  Préfixe trop étroit (/31 ou /32) : rien à scanner." -ForegroundColor Yellow
        Wait-EnterOrEscape
        return
    }

    $ipBytes = ([System.Net.IPAddress]::Parse($Matches.ip)).GetAddressBytes()
    $ipValue = ([int64]$ipBytes[0] -shl 24) -bor ([int64]$ipBytes[1] -shl 16) -bor ([int64]$ipBytes[2] -shl 8) -bor [int64]$ipBytes[3]
    $maskValue = (0xFFFFFFFFL -shl (32 - $prefix)) -band 0xFFFFFFFFL
    $network = $ipValue -band $maskValue
    $broadcast = $network -bor ((-bnot $maskValue) -band 0xFFFFFFFFL)
    $count = $broadcast - $network - 1

    if ($count -gt 1024 -and -not (Read-YesNo -Prompt "$count adresses à scanner, cela peut prendre du temps. Continuer ?" -Default $false)) {
        return
    }

    $ips = for ($v = $network + 1; $v -lt $broadcast; $v++) {
        "{0}.{1}.{2}.{3}" -f (($v -shr 24) -band 0xFF), (($v -shr 16) -band 0xFF), (($v -shr 8) -band 0xFF), ($v -band 0xFF)
    }

    Write-Host ""
    Write-Host "Scan de $count adresses en cours..." -ForegroundColor Yellow

    # PS7 : ping massivement parallele (64 a la fois, timeout 300 ms), et resolution DNS
    # inversee limitee a 1,5 s uniquement pour les hotes qui repondent.
    $active = @($ips | ForEach-Object -Parallel {
        $ping = [System.Net.NetworkInformation.Ping]::new()
        try {
            $reply = $ping.Send($_, 300)
            if ($reply.Status -eq 'Success') {
                $name = ''
                try {
                    $dnsTask = [System.Net.Dns]::GetHostEntryAsync($_)
                    if ($dnsTask.Wait(1500)) { $name = $dnsTask.Result.HostName }
                } catch {}
                [PSCustomObject]@{ IP = $_; Nom = $name; 'Latence (ms)' = $reply.RoundtripTime }
            }
        } catch {} finally { $ping.Dispose() }
    } -ThrottleLimit 64)

    # Les pings viennent de remplir la table ARP : on y recupere les MAC des hotes trouves.
    $macByIp = @{}
    foreach ($n in (Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        if ($n.LinkLayerAddress -and $n.LinkLayerAddress -ne '00-00-00-00-00-00') {
            $macByIp[$n.IPAddress] = $n.LinkLayerAddress
        }
    }

    Write-Host ""
    if ($active.Count -eq 0) {
        Write-Host "Aucun hôte actif trouvé." -ForegroundColor Yellow
    } else {
        Write-Host "$($active.Count) hôte(s) actif(s) :" -ForegroundColor Green
        $active | ForEach-Object {
            [PSCustomObject]@{
                IP            = $_.IP
                MAC           = if ($macByIp.ContainsKey($_.IP)) { $macByIp[$_.IP] } else { '' }
                Nom           = $_.Nom
                'Latence (ms)' = $_.'Latence (ms)'
            }
        } | Sort-Object { [version]$_.IP } | Format-Table -AutoSize | Out-String | Write-Host
    }

    Wait-EnterOrEscape
}

function Invoke-ArpTable {
    Clear-Host
    Write-Host "=== Table ARP (voisins réseau) ===" -ForegroundColor Cyan
    Write-Host "  Correspondances IP / MAC récemment vues par cette machine." -ForegroundColor DarkGray
    Write-Host ""

    $neighbors = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
        $_.State -in 'Reachable', 'Stale', 'Permanent', 'Delay', 'Probe' -and
        $_.LinkLayerAddress -and
        $_.LinkLayerAddress -ne '00-00-00-00-00-00' -and
        $_.IPAddress -notmatch '^(22[4-9]|23\d)\.' -and
        $_.IPAddress -ne '255.255.255.255'
    })

    if ($neighbors.Count -eq 0) {
        Write-Host "Aucun voisin dans la table ARP." -ForegroundColor Yellow
    } else {
        $neighbors | ForEach-Object {
            [PSCustomObject]@{
                IP        = $_.IPAddress
                MAC       = $_.LinkLayerAddress
                'État'    = $_.State
                Interface = $_.InterfaceAlias
            }
        } | Sort-Object Interface, { [version]$_.IP } | Format-Table -AutoSize | Out-String | Write-Host
    }

    Wait-EnterOrEscape
}

function Invoke-DnsLeakTest {
    Clear-Host
    Write-Host "=== Test de fuite DNS (dnsleak) ===" -ForegroundColor Cyan
    Write-Host "  Compare les serveurs DNS configurés localement avec les résolveurs réellement" -ForegroundColor DarkGray
    Write-Host "  utilisés, tels que vus par les serveurs autoritaires sur Internet." -ForegroundColor DarkGray
    Write-Host ""

    Write-Host "--- Serveurs DNS configurés (interfaces actives) ---" -ForegroundColor DarkCyan
    $ifaces = @(Get-VisibleInterfaces | Where-Object { $_.Status -eq 'Up' -and $_.DnsServers.Count -gt 0 })
    if ($ifaces.Count -eq 0) {
        Write-Host "  (aucun serveur configuré)" -ForegroundColor Yellow
    } else {
        foreach ($i in $ifaces) {
            Write-Host ("  {0,-20} : {1}" -f $i.Name, ($i.DnsServers -join ', '))
        }
    }
    Write-Host ""

    # Le TXT whoami d'Akamai renvoie l'adresse du resolver qui interroge reellement
    # leurs serveurs autoritaires ("ns"), l'IP source de cette requete DNS ("ip") et
    # l'eventuel sous-reseau transmis via EDNS Client Subnet ("ecs").
    Write-Host "--- Résolveur sortant (vu par Akamai) ---" -ForegroundColor DarkCyan
    $akamaiIp = $null
    try {
        $txt = @(Resolve-DnsName -Name 'whoami.ds.akahelp.net' -Type TXT -ErrorAction Stop)
        foreach ($r in $txt) {
            if ($r.PSObject.Properties['Strings'] -and $r.Strings.Count -ge 2) {
                switch ($r.Strings[0]) {
                    'ns'  { Write-Host ("  Résolveur DNS sortant : {0}" -f $r.Strings[1]) }
                    'ip'  { $akamaiIp = $r.Strings[1]; Write-Host ("  IP source de la requête DNS : {0}" -f $akamaiIp) }
                    'ecs' { Write-Host ("  Sous-réseau transmis (ECS) : {0}" -f $r.Strings[1]) -ForegroundColor DarkGray }
                }
            }
        }
        Write-Host ""
        Write-Host "  Le « résolveur DNS sortant » est le serveur qui a réellement transmis votre" -ForegroundColor DarkGray
        Write-Host "  requête à Akamai. L'« IP source » est l'adresse IP de cette requête : votre" -ForegroundColor DarkGray
        Write-Host "  propre IP publique si votre résolveur la transmet telle quelle, sinon celle" -ForegroundColor DarkGray
        Write-Host "  du résolveur lui-même (cas des DNS publics type Cloudflare/Google/VPN)." -ForegroundColor DarkGray
    } catch {
        Write-Host "  Indisponible ($($_.Exception.Message))" -ForegroundColor Yellow
    }
    Write-Host ""

    Write-Host "--- Test de fuite complet (bash.ws) ---" -ForegroundColor DarkCyan
    Write-Host "  Résolution d'une série de sous-domaines uniques, puis interrogation du service..." -ForegroundColor Yellow
    try {
        $id = Invoke-RestMethod -Uri 'https://bash.ws/id' -TimeoutSec 10 -ErrorAction Stop
        1..10 | ForEach-Object {
            Resolve-DnsName -Name "$_.$id.bash.ws" -DnsOnly -ErrorAction SilentlyContinue | Out-Null
        }
        Start-Sleep -Seconds 2
        # Le pipe vers Write-Output force l'enumeration element par element avant le
        # wrap @() : sans lui, Invoke-RestMethod renvoie tout le tableau JSON comme un
        # bloc unique, et @() l'enveloppe une deuxieme fois (Count=1, avec un seul
        # element qui est lui-meme tout le tableau).
        $result = @(Invoke-RestMethod -Uri "https://bash.ws/dnsleak/test/$id`?json" -TimeoutSec 15 -ErrorAction Stop | Write-Output)

        $publicIp = @($result | Where-Object { $_.type -eq 'ip' })
        $dnsSeen = @($result | Where-Object { $_.type -eq 'dns' })
        $conclusion = @($result | Where-Object { $_.type -eq 'conclusion' })

        if ($publicIp.Count -gt 0) {
            Write-Host ""
            Write-Host ("  Votre IP publique (détectée en HTTP, via bash.ws) : {0} ({1}, {2})" -f $publicIp[0].ip, $publicIp[0].country_name, $publicIp[0].asn)
            if ($akamaiIp -and $akamaiIp -ne $publicIp[0].ip) {
                Write-Host "  (différente de l'IP source vue par Akamai plus haut : normal, ce n'est pas la" -ForegroundColor DarkGray
                Write-Host "  même mesure — celle-ci vient d'une requête HTTP directe, pas d'une requête DNS.)" -ForegroundColor DarkGray
            }
        }
        if ($dnsSeen.Count -eq 0) {
            Write-Host "  Aucun résolveur détecté (réessayez)." -ForegroundColor Yellow
        } else {
            Write-Host ""
            Write-Host ("  {0} résolveur(s) DNS sortant(s) détecté(s) (serveurs ayant réellement" -f $dnsSeen.Count)
            Write-Host "  résolu vos requêtes de test, indépendamment de ce que vous avez configuré) :" -ForegroundColor DarkGray
            $dnsSeen | ForEach-Object {
                [PSCustomObject]@{ 'Résolveur' = $_.ip; Pays = $_.country_name; 'Opérateur (ASN)' = $_.asn }
            } | Format-Table -AutoSize | Out-String | Write-Host
        }
        if ($conclusion.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($conclusion[0].ip)) {
            $verdict = switch -Wildcard ($conclusion[0].ip) {
                'DNS may be leaking*' { @{ Text = 'Fuite DNS possible : des résolveurs semblent liés à votre connexion locale.'; Color = 'Yellow' } }
                'DNS is not leaking*' { @{ Text = 'Pas de fuite DNS détectée.'; Color = 'Green' } }
                default               { @{ Text = $conclusion[0].ip; Color = 'Gray' } }
            }
            Write-Host ("  Verdict : {0}" -f $verdict.Text) -ForegroundColor $verdict.Color
            Write-Host "  (La notion de fuite n'a de sens que derrière un VPN : sans VPN, voir les" -ForegroundColor DarkGray
            Write-Host "  résolveurs de votre FAI ou de votre DNS public habituel est normal.)" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  Erreur lors du test : $($_.Exception.Message)" -ForegroundColor Red
    }

    Wait-EnterOrEscape
}

#region Wake-on-LAN

function Get-WolHostsPath {
    Join-Path $env:LOCALAPPDATA 'NetIfaceManager\wol-hosts.json'
}

function Get-WolHosts {
    $path = Get-WolHostsPath
    if (-not (Test-Path $path)) { return @() }
    try {
        @(Get-Content -Path $path -Raw | ConvertFrom-Json)
    } catch {
        @()
    }
}

function Save-WolHosts {
    param($WolHosts)
    $path = Get-WolHostsPath
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ConvertTo-Json -InputObject @($WolHosts) | Set-Content -Path $path -Encoding UTF8
}

function Test-MacAddress {
    param([string]$InputValue)
    $InputValue -match '^([0-9A-Fa-f]{2}[:\-\.]?){5}[0-9A-Fa-f]{2}$'
}

function Send-MagicPacket {
    param([string]$Mac)
    $clean = $Mac -replace '[:\-\.]', ''
    $macBytes = [byte[]]@(for ($i = 0; $i -lt 12; $i += 2) { [Convert]::ToByte($clean.Substring($i, 2), 16) })
    # Magic packet : 6 octets 0xFF suivis de la MAC repetee 16 fois, en broadcast UDP.
    $packet = [byte[]]@((,0xFF * 6) + ($macBytes * 16))
    $udp = [System.Net.Sockets.UdpClient]::new()
    try {
        $udp.EnableBroadcast = $true
        # Ports 9 (discard) et 7 (echo) : les deux conventions les plus repandues.
        foreach ($port in 9, 7) {
            [void]$udp.Send($packet, $packet.Length, [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Broadcast, $port))
        }
    } finally {
        $udp.Dispose()
    }
}

function Invoke-WakeOnLan {
    while ($true) {
        $wolHosts = @(Get-WolHosts)

        Clear-Host
        Write-Host "=== Wake-on-LAN ===" -ForegroundColor Cyan
        Write-Host "  Envoie un magic packet en broadcast pour réveiller une machine du réseau local." -ForegroundColor DarkGray
        Write-Host ""

        $items = @($wolHosts | ForEach-Object { "{0,-25} {1}" -f $_.Name, $_.Mac })
        $items += "Nouvelle adresse MAC..."
        if ($wolHosts.Count -gt 0) { $items += "Supprimer un hôte enregistré" }
        $items += "<< Retour au menu principal"

        $choice = Show-ArrowMenu -Title "Sélectionnez un hôte ou une action :" -Items $items -DefaultIndex 0
        if ($choice -lt 0 -or $choice -eq $items.Count - 1) { return }

        if ($wolHosts.Count -gt 0 -and $choice -eq $items.Count - 2) {
            $delItems = @($wolHosts | ForEach-Object { "{0,-25} {1}" -f $_.Name, $_.Mac }) + '<< Annuler'
            $delChoice = Show-ArrowMenu -Title "Hôte à supprimer :" -Items $delItems -DefaultIndex 0
            if ($delChoice -ge 0 -and $delChoice -lt $wolHosts.Count) {
                Save-WolHosts -WolHosts @($wolHosts | Where-Object { $_ -ne $wolHosts[$delChoice] })
            }
            continue
        }

        if ($choice -lt $wolHosts.Count) {
            $target = $wolHosts[$choice]
            try {
                Send-MagicPacket -Mac $target.Mac
                Write-Host "`nMagic packet envoyé à $($target.Name) ($($target.Mac))." -ForegroundColor Green
            } catch {
                Write-Host "`nErreur lors de l'envoi : $($_.Exception.Message)" -ForegroundColor Red
            }
            Wait-EnterOrEscape -Message "Appuyez sur Entrée ou Échap pour continuer"
            continue
        }

        # "Nouvelle adresse MAC..."
        while ($true) {
            $mac = Read-HostWithEscape -Prompt "Adresse MAC (ex: AA:BB:CC:DD:EE:FF)"
            if ($null -eq $mac) { break }
            if ([string]::IsNullOrWhiteSpace($mac)) { continue }
            if (-not (Test-MacAddress -InputValue $mac)) {
                Write-Host "  Adresse MAC invalide." -ForegroundColor Yellow
                continue
            }

            try {
                Send-MagicPacket -Mac $mac
                Write-Host "Magic packet envoyé ($mac)." -ForegroundColor Green
            } catch {
                Write-Host "Erreur lors de l'envoi : $($_.Exception.Message)" -ForegroundColor Red
                break
            }

            if (Read-YesNo -Prompt "Enregistrer cet hôte pour la prochaine fois ?" -Default $true) {
                $name = Read-HostWithEscape -Prompt "Nom de l'hôte"
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    Save-WolHosts -WolHosts (@($wolHosts) + [PSCustomObject]@{ Name = $name; Mac = $mac.ToUpper() })
                }
            }
            break
        }
    }
}

#endregion

function Invoke-ConfigExport {
    Clear-Host
    Write-Host "=== Résumé de la configuration réseau ===" -ForegroundColor Cyan
    Write-Host ""

    $interfaces = @(Get-VisibleInterfaces)
    if ($interfaces.Count -eq 0) {
        Write-Host "Aucune interface réseau visible (vérifiez le menu Options)." -ForegroundColor Red
        Wait-EnterOrEscape -Message "Appuyez sur Entrée ou Échap pour continuer"
        return
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Résumé de configuration réseau - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add("")
    foreach ($iface in $interfaces) {
        $lines.Add("=== $($iface.Name) ($($iface.InterfaceDescription)) ===")
        $lines.Add("  État        : $(if ($iface.Status -eq 'Up') { 'Activée' } else { 'Désactivée' })")
        $lines.Add("  MAC         : $($iface.MacAddress)")
        $lines.Add("  Mode IP     : $($iface.Dhcp)")
        $lines.Add("  Adresse(s)  : $(if ($iface.IPAddresses.Count -gt 0) { $iface.IPAddresses -join ', ' } else { '(aucune)' })")
        $lines.Add("  Passerelle  : $(Format-OrDefault $iface.Gateway '(aucune)')")
        $lines.Add("  DNS         : $(if ($iface.DnsServers.Count -gt 0) { $iface.DnsServers -join ', ' } else { '(aucun)' })")
        $lines.Add("")
    }

    $lines | Write-Host

    if (-not (Read-YesNo -Prompt "Exporter ce résumé dans un fichier texte ?" -Default $false)) {
        return
    }

    $defaultPath = Join-Path ([Environment]::GetFolderPath('Desktop')) ("Resume-Reseau-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $exportPath = Read-WithDefault -Prompt "Chemin du fichier" -Default $defaultPath
    try {
        $lines | Set-Content -Path $exportPath -Encoding UTF8 -ErrorAction Stop
        Write-Host "`nExporté vers : $exportPath" -ForegroundColor Green
    } catch {
        Write-Host "`nErreur lors de l'export : $($_.Exception.Message)" -ForegroundColor Red
    }

    Wait-EnterOrEscape
}

function Show-PresetDetail {
    param($Preset)
    Clear-Host
    Write-Host "=== Détail du preset : $($Preset.Name) ===" -ForegroundColor Cyan
    Write-Host ""
    if ($Preset.Mode -eq 'DHCP') {
        Write-Host "  Mode           : DHCP (automatique)"
    } else {
        Write-Host "  Mode           : Statique"
        Write-Host "  Adresse IP     : $($Preset.PrimaryIP)"
        if ($Preset.ExtraIPs.Count -gt 0) {
            Write-Host "  IP(s) suppl.   : $($Preset.ExtraIPs -join ', ')"
        }
        Write-Host "  Passerelle     : $(Format-OrDefault $Preset.Gateway '(aucune)')"
    }
    Write-Host "  DNS primaire   : $(Format-OrDefault $Preset.DnsPrimary '(aucun)')"
    Write-Host "  DNS secondaire : $(Format-OrDefault $Preset.DnsSecondary '(aucun)')"
    Wait-EnterOrEscape
}

function Invoke-ApplyPresetToInterface {
    param($Preset)

    $interfaces = @(Get-VisibleInterfaces)
    if ($interfaces.Count -eq 0) {
        Write-Host "Aucune interface réseau visible (vérifiez le menu Options)." -ForegroundColor Red
        Wait-EnterOrEscape -Message "Appuyez sur Entrée ou Échap pour continuer"
        return
    }

    Clear-Host
    Write-Host "=== Appliquer le preset '$($Preset.Name)' à une interface ===" -ForegroundColor Cyan
    $items = @($interfaces | ForEach-Object { Format-InterfaceLine -Iface $_ })
    $items += "<< Retour"
    $choice = Show-ArrowMenu -Title "Sélectionnez une interface :" -Items $items -DefaultIndex 0
    if ($choice -lt 0 -or $choice -eq $items.Count - 1) { return }

    Start-InterfaceWizard -Current $interfaces[$choice] -PresetOverride $Preset
}

function Edit-Preset {
    param($Preset)

    Clear-Host
    Write-Host "=== Modifier le preset : $($Preset.Name) ===" -ForegroundColor Cyan
    Write-Host ""

    $config = Read-IPv4Config -DefaultMode $Preset.Mode -DefaultPrimaryIP $Preset.PrimaryIP -DefaultExtraIPs $Preset.ExtraIPs `
        -DefaultGateway $Preset.Gateway -DefaultDnsPrimary $Preset.DnsPrimary -DefaultDnsSecondary $Preset.DnsSecondary

    Write-Host ""
    if (Read-YesNo -Prompt "Enregistrer ces modifications dans le preset '$($Preset.Name)' ?" -Default $true) {
        Save-Preset -Name $Preset.Name -Data $config
        Write-Host "Preset mis à jour." -ForegroundColor Green
        Start-Sleep -Seconds 1
    } else {
        Write-Host "Modifications abandonnées." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }
}

function Show-PresetDetailMenu {
    param($Preset)

    if ($Preset.IsBuiltin) {
        while ($true) {
            Clear-Host
            Write-Host "=== Preset : $($Preset.Name) ===" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "  Preset système (DHCP automatique) : non renommable, non supprimable." -ForegroundColor Yellow
            Write-Host ""

            $actionItems = @('Appliquer à une interface', 'Voir le détail', '<< Retour')
            $actionChoice = Show-ArrowMenu -Title "Action :" -Items $actionItems -DefaultIndex 0
            if ($actionChoice -lt 0 -or $actionChoice -eq 2) { return }

            if ($actionChoice -eq 0) {
                Invoke-ApplyPresetToInterface -Preset $Preset
                return
            } elseif ($actionChoice -eq 1) {
                Show-PresetDetail -Preset $Preset
                # Reboucle sur ce meme sous-menu plutot que de revenir a la liste des presets.
            }
        }
    }

    while ($true) {
        Clear-Host
        Write-Host "=== Preset : $($Preset.Name) ===" -ForegroundColor Cyan
        Write-Host ""

        $actionItems = @('Appliquer à une interface', 'Voir le détail', 'Modifier le preset', 'Renommer', 'Supprimer', '<< Retour')
        $actionChoice = Show-ArrowMenu -Title "Action :" -Items $actionItems -DefaultIndex 0
        if ($actionChoice -lt 0 -or $actionChoice -eq 5) { return }

        if ($actionChoice -eq 0) {
            Invoke-ApplyPresetToInterface -Preset $Preset
            return
        } elseif ($actionChoice -eq 1) {
            Show-PresetDetail -Preset $Preset
            continue
        } elseif ($actionChoice -eq 2) {
            Edit-Preset -Preset $Preset
            return
        } elseif ($actionChoice -eq 3) {
            while ($true) {
                $newName = Read-HostWithEscape -Prompt "Nouveau nom pour '$($Preset.Name)'" -Default $Preset.Name
                if ($null -eq $newName -or [string]::IsNullOrWhiteSpace($newName) -or $newName -eq $Preset.Name) { return }
                if (Test-PresetNameReserved -Name $newName) {
                    Write-Host "  Ce nom est réservé au preset système." -ForegroundColor Yellow
                    continue
                }
                Rename-PresetFile -Preset $Preset -NewName $newName
                Write-Host "Preset renommé en '$newName'." -ForegroundColor Green
                Start-Sleep -Seconds 1
                return
            }
        } elseif ($actionChoice -eq 4) {
            if (Read-YesNo -Prompt "Supprimer définitivement le preset '$($Preset.Name)' ?" -Default $false) {
                Remove-PresetFile -Preset $Preset
                Write-Host "Preset supprimé." -ForegroundColor Green
                Start-Sleep -Seconds 1
            }
            return
        }
    }
}

function Invoke-PresetsExport {
    param($Presets)

    Clear-Host
    Write-Host "=== Exporter les presets (.zip) ===" -ForegroundColor Cyan
    Write-Host ""

    $customPresets = @($Presets | Where-Object { -not $_.IsBuiltin })
    if ($customPresets.Count -eq 0) {
        Write-Host "Aucun preset personnalisé à exporter (le preset DHCP système n'est pas un fichier)." -ForegroundColor Yellow
        Wait-EnterOrEscape -Message "Appuyez sur Entrée ou Échap pour continuer"
        return
    }

    $defaultDir = [Environment]::GetFolderPath('Desktop')
    $destDir = Read-WithDefault -Prompt "Dossier de destination" -Default $defaultDir
    $zipPath = Join-Path $destDir ("Presets-Reseau-{0}.zip" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

    try {
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Compress-Archive -Path $customPresets.FilePath -DestinationPath $zipPath -Force
        Write-Host "`nExporté vers : $zipPath" -ForegroundColor Green
    } catch {
        Write-Host "`nErreur lors de l'export : $($_.Exception.Message)" -ForegroundColor Red
    }

    Wait-EnterOrEscape -Message "Appuyez sur Entrée ou Échap pour continuer"
}

function Invoke-PresetsImport {
    Clear-Host
    Write-Host "=== Importer des presets depuis un .zip ===" -ForegroundColor Cyan
    Write-Host ""

    $zipPath = Read-HostWithEscape -Prompt "Chemin du fichier .zip à importer"
    if ($null -eq $zipPath) { return }
    if ([string]::IsNullOrWhiteSpace($zipPath) -or -not (Test-Path $zipPath)) {
        Write-Host "Fichier introuvable." -ForegroundColor Red
        Wait-EnterOrEscape -Message "Appuyez sur Entrée ou Échap pour continuer"
        return
    }

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("NetIfaceManager-Import-{0}" -f [Guid]::NewGuid())
    try {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force -ErrorAction Stop

        $jsonFiles = @(Get-ChildItem -Path $tempDir -Filter '*.json' -Recurse -ErrorAction SilentlyContinue)
        if ($jsonFiles.Count -eq 0) {
            Write-Host "Aucun preset (.json) trouvé dans cette archive." -ForegroundColor Yellow
        } else {
            $imported = 0
            $skipped = 0
            foreach ($file in $jsonFiles) {
                try {
                    $json = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                    $name = $json.Name
                    if ([string]::IsNullOrWhiteSpace($name)) { $skipped++; continue }

                    if (Test-PresetNameReserved -Name $name) {
                        Write-Host "  '$name' : nom réservé, ignoré." -ForegroundColor Yellow
                        $skipped++
                        continue
                    }

                    $existingPath = Join-Path (Get-PresetsDir) (Get-SafePresetFileName -Name $name)
                    if ((Test-Path $existingPath) -and -not (Read-YesNo -Prompt "Un preset '$name' existe déjà. Écraser ?" -Default $false)) {
                        $skipped++
                        continue
                    }

                    Save-Preset -Name $name -Data $json
                    Write-Host "  '$name' importé." -ForegroundColor Green
                    $imported++
                } catch {
                    Write-Host "  Erreur sur $($file.Name) : $($_.Exception.Message)" -ForegroundColor Red
                    $skipped++
                }
            }
            Write-Host ""
            Write-Host "Import terminé : $imported preset(s) importé(s), $skipped ignoré(s)." -ForegroundColor Cyan
        }
    } catch {
        Write-Host "Erreur lors de l'extraction de l'archive : $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Wait-EnterOrEscape -Message "Appuyez sur Entrée ou Échap pour continuer"
}

function Show-PresetsMenu {
    while ($true) {
        $presets = @(Get-AllPresets)

        Clear-Host
        Write-Host "=== Gestion des presets ===" -ForegroundColor Cyan
        Write-Host ("  Dossier : {0}" -f (Get-PresetsDir)) -ForegroundColor DarkGray
        Write-Host ""

        $items = @($presets | ForEach-Object { Format-PresetLine -Preset $_ })
        $items += "──────────────────────────────────────────"
        $items += "Exporter tous les presets (.zip)"
        $items += "Importer des presets (.zip)"
        $items += "<< Retour au menu principal"

        $choice = Show-ArrowMenu -Title "Sélectionnez un preset ou une action :" -Items $items -DefaultIndex 0
        if ($choice -lt 0 -or $choice -eq $items.Count - 1) { return }
        if ($choice -eq $items.Count - 4) { continue }

        if ($choice -eq $items.Count - 2) {
            Invoke-PresetsImport
            continue
        }
        if ($choice -eq $items.Count - 3) {
            Invoke-PresetsExport -Presets $presets
            continue
        }

        Show-PresetDetailMenu -Preset $presets[$choice]
    }
}

function Start-MainLoop {
    Show-Banner

    # Le prompt est affiche AVANT le prechargement des modules reseau : l'import (~2s a
    # froid) s'execute pendant que l'utilisateur lit la banniere, et une frappe Entree
    # donnee pendant l'import reste dans le tampon console — elle est consommee des la
    # fin du chargement. Le cout de l'autoload est ainsi reellement masque, la ou un
    # Read-Host avant l'import le faisait payer plein pot a la transition vers le menu.
    Write-Host "  Appuyez sur Entrée pour continuer" -ForegroundColor DarkGray
    Import-Module -Name NetAdapter, NetTCPIP, DnsClient -ErrorAction SilentlyContinue
    while ([Console]::ReadKey($true).Key -ne 'Enter') { }

    # Chaque entree est soit un separateur visuel (Header/Blank, jamais d'Action -> no-op
    # si selectionnee), soit un item actionnable identifie par son nom (evite une dependance
    # fragile a la position numerique quand la liste est reorganisee). Les actions "Sub*"
    # ouvrent un sous-menu thematique defini dans $submenus.
    $menuEntries = @(
        [PSCustomObject]@{ Type = 'Header'; Label = '=== Gestion des interfaces ===' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'Modifier une interface réseau'; Action = 'ManageInterface' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'Presets'; Action = 'Presets' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'DHCP : Release / Renew'; Action = 'Dhcp' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'Profil réseau (Public / Privé)'; Action = 'Profile' }
        [PSCustomObject]@{ Type = 'Blank'; Label = '' }
        [PSCustomObject]@{ Type = 'Header'; Label = '=== Outils de diagnostic ===' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'Connectivité                   >'; Action = 'SubConnectivity' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'DNS                            >'; Action = 'SubDns' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'Réseau local                   >'; Action = 'SubLan' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'État & trafic                  >'; Action = 'SubStatus' }
        [PSCustomObject]@{ Type = 'Blank'; Label = '' }
        [PSCustomObject]@{ Type = 'Header'; Label = '=== Options ===' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'Masquer/afficher des interfaces'; Action = 'Options' }
        [PSCustomObject]@{ Type = 'Blank'; Label = '' }
        [PSCustomObject]@{ Type = 'Header'; Label = '===' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'Quitter'; Action = 'Quit' }
    )

    $submenus = @{
        SubConnectivity = @{ Title = 'Connectivité'; Entries = @(
            [PSCustomObject]@{ Label = 'Diagnostic réseau rapide'; Action = 'Diagnostic' }
            [PSCustomObject]@{ Label = 'Ping'; Action = 'Ping' }
            [PSCustomObject]@{ Label = 'Traceroute (tracert)'; Action = 'Tracert' }
            [PSCustomObject]@{ Label = 'Test de port TCP'; Action = 'PortTest' }
        ) }
        SubDns = @{ Title = 'DNS'; Entries = @(
            [PSCustomObject]@{ Label = 'Résolution DNS (nslookup)'; Action = 'Dns' }
            [PSCustomObject]@{ Label = 'Test de fuite DNS (dnsleak)'; Action = 'DnsLeak' }
            [PSCustomObject]@{ Label = 'Vider le cache DNS (flushdns)'; Action = 'FlushDns' }
        ) }
        SubLan = @{ Title = 'Réseau local'; Entries = @(
            [PSCustomObject]@{ Label = 'Scan du sous-réseau'; Action = 'SubnetScan' }
            [PSCustomObject]@{ Label = 'Table ARP (voisins réseau)'; Action = 'Arp' }
            [PSCustomObject]@{ Label = 'Réseaux Wi-Fi à proximité'; Action = 'Wifi' }
            [PSCustomObject]@{ Label = 'Wake-on-LAN'; Action = 'Wol' }
        ) }
        SubStatus = @{ Title = 'État & trafic'; Entries = @(
            [PSCustomObject]@{ Label = 'État des interfaces'; Action = 'ConfigExport' }
            [PSCustomObject]@{ Label = "Statistiques d'interface en direct"; Action = 'Stats' }
            [PSCustomObject]@{ Label = 'Connexions actives (netstat)'; Action = 'Connections' }
            [PSCustomObject]@{ Label = 'Quelle est mon IP publique ?'; Action = 'PublicIp' }
        ) }
    }

    $items = @($menuEntries | ForEach-Object { $_.Label })
    $lastIndex = 0
    for ($i = 0; $i -lt $menuEntries.Count; $i++) {
        if ($menuEntries[$i].Type -eq 'Item') { $lastIndex = $i; break }
    }

    while ($true) {
        Clear-Host
        Write-Host "=== Menu principal ===" -ForegroundColor Cyan
        $choice = Show-ArrowMenu -Items $items -DefaultIndex $lastIndex

        if ($choice -lt 0) {
            Write-Host ""
            if (Read-YesNo -Prompt "Quitter le gestionnaire d'interfaces réseau ?" -Default $false) {
                Write-Host "`nÀ bientôt !" -ForegroundColor Cyan
                return
            }
            continue
        }

        $entry = $menuEntries[$choice]
        $lastIndex = $choice
        if ($entry.Type -ne 'Item') { continue }

        if ($entry.Action -eq 'Quit') {
            Write-Host "`nÀ bientôt !" -ForegroundColor Cyan
            return
        }
        if ($submenus.ContainsKey($entry.Action)) {
            $sm = $submenus[$entry.Action]
            Show-ToolsSubmenu -Title $sm.Title -Entries $sm.Entries
        } else {
            Invoke-ToolAction -Action $entry.Action
        }
    }
}

# Dispatch central : associe chaque nom d'action a sa fonction, partage entre le menu
# principal et les sous-menus thematiques.
function Invoke-ToolAction {
    param([string]$Action)
    switch ($Action) {
        'ManageInterface' { Show-InterfaceSelectionScreen }
        'Presets'         { Show-PresetsMenu }
        'Dhcp'            { Invoke-DhcpReleaseRenew }
        'Profile'         { Invoke-NetworkProfileManager }
        'Diagnostic'      { Invoke-NetworkDiagnostic }
        'Ping'            { Invoke-PingHost }
        'Tracert'         { Invoke-TracertHost }
        'PortTest'        { Invoke-TcpPortTest }
        'Dns'             { Invoke-DnsLookup }
        'DnsLeak'         { Invoke-DnsLeakTest }
        'FlushDns'        { Invoke-FlushDns }
        'SubnetScan'      { Invoke-SubnetScan }
        'Arp'             { Invoke-ArpTable }
        'Wifi'            { Invoke-WifiScan }
        'Wol'             { Invoke-WakeOnLan }
        'ConfigExport'    { Invoke-ConfigExport }
        'Stats'           { Invoke-InterfaceStatistics }
        'Connections'     { Invoke-ActiveConnections }
        'PublicIp'        { Invoke-PublicIpLookup }
        'Options'         { Show-OptionsMenu }
    }
}

# Sous-menu thematique generique : liste d'outils + retour, position memorisee entre
# deux outils tant qu'on reste dans le sous-menu, Echap pour remonter au menu principal.
function Show-ToolsSubmenu {
    param([string]$Title, $Entries)
    $lastIndex = 0
    while ($true) {
        Clear-Host
        Write-Host "=== $Title ===" -ForegroundColor Cyan
        $items = @($Entries | ForEach-Object { $_.Label }) + '<< Retour au menu principal'
        $choice = Show-ArrowMenu -Items $items -DefaultIndex $lastIndex
        if ($choice -lt 0 -or $choice -eq $items.Count - 1) { return }
        $lastIndex = $choice
        Invoke-ToolAction -Action $Entries[$choice].Action
    }
}

#endregion

Start-MainLoop
