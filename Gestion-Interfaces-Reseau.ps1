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
    Write-Host "  Il fournit également des outils de diagnostic réseau (IP publique, ping, tracert, nslookup)." -ForegroundColor Gray
    Write-Host "  Astuce : dans les menus, utilisez les flèches Haut/Bas puis Entrée." -ForegroundColor DarkGray
    Write-Host "  Pour les questions, Entrée seule conserve la valeur actuelle affichée." -ForegroundColor DarkGray
    Write-Host ""
    Read-Host "  Appuyez sur Entrée pour continuer" | Out-Null
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
    $top = [Console]::CursorTop
    [Console]::CursorVisible = $false

    try {
        while ($true) {
            [Console]::SetCursorPosition(0, $top)
            for ($i = 0; $i -lt $Items.Count; $i++) {
                $marker = if ($i -eq $selected) { ">" } else { " " }
                $line = " $marker $($Items[$i])"
                if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }
                $line = $line.PadRight($width)
                if ($i -eq $selected) {
                    Write-Host $line -ForegroundColor Black -BackgroundColor Cyan
                } elseif ($Items[$i] -match '^===') {
                    Write-Host $line -ForegroundColor DarkCyan
                } else {
                    Write-Host $line -ForegroundColor Gray
                }
            }
            if ($TitleAtBottom -and $Title) {
                Write-Host ""
                Write-Host $Title -ForegroundColor DarkGray
            }
            # Repositionne le curseur texte a un endroit fixe (au lieu de le laisser
            # apres la derniere ligne) pour eviter qu'il ne "saute" visuellement entre
            # le haut et le bas de la liste a chaque redessin.
            [Console]::SetCursorPosition(0, $top)
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'    { $selected = ($selected - 1 + $Items.Count) % $Items.Count }
                'DownArrow'  { $selected = ($selected + 1) % $Items.Count }
                'Enter'      { return $selected }
                'Spacebar'   { return $selected }
                'Escape'     { return -1 }
            }
        }
    } finally {
        # Ne pas reafficher le curseur texte ici : le faire systematiquement au retour
        # provoquait un saut visible pile au moment de valider (Entree/Espace), avant meme
        # que l'ecran suivant ne soit dessine. Ce sont les fonctions de saisie
        # (Read-WithDefault, Read-YesNo, Read-HostWithEscape) qui le reactivent elles-memes.
        [Console]::CursorVisible = $false
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
    if ($ExcludeNames.Count -gt 0) {
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

    Write-Host ("  Mode IP     : {0} -> {1}" -f $Current.Dhcp, $Plan.Mode)

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

    Read-Host "`nAppuyez sur Entrée pour revenir au menu principal" | Out-Null
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
    $hidden = Get-HiddenInterfaceNames
    @(Get-NetworkInterfacesInfo -ExcludeNames $hidden)
}

#endregion

#region Menus principaux

function Show-InterfaceSelectionScreen {
    $interfaces = @(Get-VisibleInterfaces)
    if ($interfaces.Count -eq 0) {
        Write-Host "Aucune interface réseau visible (vérifiez le menu Options)." -ForegroundColor Red
        Read-Host "Appuyez sur Entrée pour continuer" | Out-Null
        return
    }

    Clear-Host
    Write-Host "=== Sélectionnez une interface à gérer ===" -ForegroundColor Cyan
    $items = @($interfaces | ForEach-Object { Format-InterfaceLine -Iface $_ })
    $items += "<< Retour au menu principal"

    $choice = Show-ArrowMenu -Title "Utilisez Haut/Bas puis Entrée :" -Items $items -DefaultIndex 0

    if ($choice -lt 0 -or $choice -eq $items.Count - 1) { return }

    Start-InterfaceWizard -Current $interfaces[$choice]
}

function Show-OptionsMenu {
    $lastIndex = 0
    while ($true) {
        $hidden = @(Get-HiddenInterfaceNames)
        $allIfaces = @(Get-NetworkInterfacesInfo)

        Clear-Host
        Write-Host "=== Options : interfaces visibles dans les listes ===" -ForegroundColor Cyan
        Write-Host "  Sélectionnez une interface pour basculer Masquer/Afficher." -ForegroundColor DarkGray
        Write-Host ("  Fichier de config : {0}" -f (Get-ConfigPath)) -ForegroundColor DarkGray
        Write-Host ""

        if ($allIfaces.Count -eq 0) {
            Write-Host "Aucune interface réseau trouvée." -ForegroundColor Red
            Read-Host "Appuyez sur Entrée pour continuer" | Out-Null
            return
        }

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
    Read-Host "`nAppuyez sur Entrée pour revenir au menu principal" | Out-Null
}

function Invoke-DhcpReleaseRenew {
    $interfaces = @(Get-VisibleInterfaces)
    if ($interfaces.Count -eq 0) {
        Write-Host "Aucune interface réseau visible (vérifiez le menu Options)." -ForegroundColor Red
        Read-Host "Appuyez sur Entrée pour continuer" | Out-Null
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

    Read-Host "`nAppuyez sur Entrée pour revenir au menu principal" | Out-Null
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
    while ($true) {
        $target = Read-HostWithEscape -Prompt "Nom d'hôte ou domaine à résoudre"
        if ($null -eq $target) { return }
        if ([string]::IsNullOrWhiteSpace($target)) { continue }

        Write-Host ""
        try {
            Resolve-DnsName -Name $target -ErrorAction Stop | Format-Table -AutoSize | Out-String | Write-Host
        } catch {
            Write-Host "Erreur lors de la résolution DNS : $($_.Exception.Message)" -ForegroundColor Red
        }
        Write-Host ""
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

        $proc = Start-Process -FilePath ping.exe -ArgumentList @('-t', $target) -NoNewWindow -PassThru
        while (-not $proc.HasExited) {
            if ([Console]::KeyAvailable -and ([Console]::ReadKey($true).Key -eq 'Escape')) {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                break
            }
            Start-Sleep -Milliseconds 100
        }
        Write-Host ""
    }
}

function Invoke-TracertHost {
    Clear-Host
    Write-Host "=== Tracert ===" -ForegroundColor Cyan
    Write-Host "  Échap pour revenir au menu principal." -ForegroundColor DarkGray
    Write-Host ""
    while ($true) {
        $target = Read-HostWithEscape -Prompt "Hôte ou adresse IP à tracer"
        if ($null -eq $target) { return }
        if ([string]::IsNullOrWhiteSpace($target)) { continue }

        Write-Host ""
        & tracert.exe $target
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
        Read-Host "Appuyez sur Entrée pour continuer" | Out-Null
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
        Read-Host "Appuyez sur Entrée pour continuer" | Out-Null
        return
    }

    $items = @($profiles | ForEach-Object { "{0,-25} [{1}]" -f $_.InterfaceAlias, $_.NetworkCategory })
    $items += "<< Retour au menu principal"
    $choice = Show-ArrowMenu -Title "Sélectionnez une interface :" -Items $items -DefaultIndex 0
    if ($choice -lt 0 -or $choice -eq $items.Count - 1) { return }
    $target = $profiles[$choice]

    if ($target.NetworkCategory -eq 'DomainAuthenticated') {
        Write-Host "`nCette interface est gérée par le domaine (DomainAuthenticated) : catégorie non modifiable manuellement." -ForegroundColor Yellow
        Read-Host "Appuyez sur Entrée pour continuer" | Out-Null
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

        $rows = @($connections | ForEach-Object {
            $procName = try { (Get-Process -Id $_.OwningProcess -ErrorAction Stop).ProcessName } catch { '?' }
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

function Invoke-ConfigExport {
    Clear-Host
    Write-Host "=== Résumé de la configuration réseau ===" -ForegroundColor Cyan
    Write-Host ""

    $interfaces = @(Get-VisibleInterfaces)
    if ($interfaces.Count -eq 0) {
        Write-Host "Aucune interface réseau visible (vérifiez le menu Options)." -ForegroundColor Red
        Read-Host "Appuyez sur Entrée pour continuer" | Out-Null
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
        Read-Host "Appuyez sur Entrée pour continuer" | Out-Null
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

    $customPresets = @($Presets | Where-Object { -not $_.IsBuiltin })
    if ($customPresets.Count -eq 0) {
        Write-Host "`nAucun preset personnalisé à exporter (le preset DHCP système n'est pas un fichier)." -ForegroundColor Yellow
        Read-Host "Appuyez sur Entrée pour continuer" | Out-Null
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

    Read-Host "Appuyez sur Entrée pour continuer" | Out-Null
}

function Invoke-PresetsImport {
    Clear-Host
    Write-Host "=== Importer des presets depuis un .zip ===" -ForegroundColor Cyan
    Write-Host ""

    $zipPath = Read-HostWithEscape -Prompt "Chemin du fichier .zip à importer"
    if ($null -eq $zipPath) { return }
    if ([string]::IsNullOrWhiteSpace($zipPath) -or -not (Test-Path $zipPath)) {
        Write-Host "Fichier introuvable." -ForegroundColor Red
        Read-Host "Appuyez sur Entrée pour continuer" | Out-Null
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

    Read-Host "`nAppuyez sur Entrée pour continuer" | Out-Null
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

    # Precharge les modules reseau maintenant plutot qu'au premier clic sur "Gerer une
    # interface" : PowerShell ne les charge en memoire qu'au premier appel a une de leurs
    # cmdlets, ce qui causait un petit ralentissement perceptible a la premiere ouverture
    # du menu. Le cout total est identique, mais absorbe ici pendant l'affichage de la banniere.
    Import-Module -Name NetAdapter, NetTCPIP, DnsClient -ErrorAction SilentlyContinue

    # Chaque entree est soit un separateur visuel (Header/Blank, jamais d'Action -> no-op
    # si selectionnee), soit un item actionnable identifie par son nom (evite une dependance
    # fragile a la position numerique quand la liste est reorganisee).
    $menuEntries = @(
        [PSCustomObject]@{ Type = 'Header'; Label = '=== Gestion des interfaces ===' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'Modifier une interface réseau'; Action = 'ManageInterface' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'Presets'; Action = 'Presets' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'DHCP : Release / Renew'; Action = 'Dhcp' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'Profil réseau (Public / Privé)'; Action = 'Profile' }
        [PSCustomObject]@{ Type = 'Blank'; Label = '' }
        [PSCustomObject]@{ Type = 'Header'; Label = '=== Outils de diagnostic ===' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'État des interfaces'; Action = 'ConfigExport' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'Diagnostic réseau rapide'; Action = 'Diagnostic' }
        [PSCustomObject]@{ Type = 'Item'; Label = "Statistiques d'interface en direct"; Action = 'Stats' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'Quelle est mon IP publique ?'; Action = 'PublicIp' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'Résolution DNS (nslookup)'; Action = 'Dns' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'Ping'; Action = 'Ping' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'Traceroute (tracert)'; Action = 'Tracert' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'Connexions actives (netstat)'; Action = 'Connections' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'Réseaux Wi-Fi à proximité'; Action = 'Wifi' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'Vider le cache DNS (flushdns)'; Action = 'FlushDns' }
        [PSCustomObject]@{ Type = 'Blank'; Label = '' }
        [PSCustomObject]@{ Type = 'Header'; Label = '=== Options ===' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'Masquer/afficher des interfaces'; Action = 'Options' }
        [PSCustomObject]@{ Type = 'Blank'; Label = '' }
        [PSCustomObject]@{ Type = 'Header'; Label = '===' }
        [PSCustomObject]@{ Type = 'Item'; Label = 'Quitter'; Action = 'Quit' }
    )

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
            Write-Host "`nÀ bientôt !" -ForegroundColor Cyan
            return
        }

        $entry = $menuEntries[$choice]
        $lastIndex = $choice
        if ($entry.Type -ne 'Item') { continue }

        switch ($entry.Action) {
            'ManageInterface' { Show-InterfaceSelectionScreen }
            'Presets'         { Show-PresetsMenu }
            'Dhcp'            { Invoke-DhcpReleaseRenew }
            'Profile'         { Invoke-NetworkProfileManager }
            'ConfigExport'    { Invoke-ConfigExport }
            'Diagnostic'      { Invoke-NetworkDiagnostic }
            'Stats'           { Invoke-InterfaceStatistics }
            'PublicIp'        { Invoke-PublicIpLookup }
            'Dns'             { Invoke-DnsLookup }
            'Ping'            { Invoke-PingHost }
            'Tracert'         { Invoke-TracertHost }
            'Connections'     { Invoke-ActiveConnections }
            'Wifi'            { Invoke-WifiScan }
            'FlushDns'        { Invoke-FlushDns }
            'Options'         { Show-OptionsMenu }
            'Quit'            { Write-Host "`nÀ bientôt !" -ForegroundColor Cyan; return }
        }
    }
}

#endregion

Start-MainLoop
