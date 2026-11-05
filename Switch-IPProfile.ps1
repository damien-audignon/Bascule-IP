#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Interface graphique pour basculer une carte réseau entre DHCP et des profils d'IP fixe enregistrés.

.DESCRIPTION
    Ouvre une fenêtre (Windows Forms) qui permet, sur la carte réseau choisie :
      - de passer en DHCP et de voir l'adresse reçue (attente active, détection APIPA 169.254.x.x) ;
      - d'enregistrer des profils d'IP fixe (nom, IP, masque, passerelle, DNS) ;
      - d'appliquer un profil par double-clic (ou bouton « Appliquer ») ;
      - de dupliquer un profil (Ctrl+D ou bouton) pour n'en changer que le nom et un octet ;
      - de renommer (F2 ou bouton), réordonner et supprimer les profils ;
      - de tester une adresse par ping (ex. : l'IP par défaut d'un équipement neuf).

    Les profils sont enregistrés dans un fichier JSON (par défaut Profils-IP.json à côté du script),
    conservé d'une ouverture à l'autre. La version précédente est gardée en .bak à chaque enregistrement.
    La configuration de la carte avant chaque changement est écrite dans le journal (retour arrière).

    Impact : changer l'adressage coupe les connexions en cours sur cette carte (RDP, RustDesk, partages).

.PARAMETER InterfaceAlias
    Nom de la carte à présélectionner (ex. : "Ethernet 2"). Par défaut : la première carte physique connectée.

.PARAMETER ProfilePath
    Fichier JSON des profils. Par défaut : Profils-IP.json dans le dossier du script (kit portable, clé USB).

.PARAMETER LogPath
    Dossier du journal. Par défaut : %ProgramData%\Scripts\Logs.

.PARAMETER DhcpTimeout
    Durée maximale (en secondes) d'attente d'une adresse DHCP avant d'afficher un avertissement (5 à 120).

.EXAMPLE
    .\Switch-IPProfile.ps1 -WhatIf
    Ouvre l'interface en simulation : aucune modification de la carte, les actions sont journalisées.

.EXAMPLE
    .\Switch-IPProfile.ps1 -InterfaceAlias 'Ethernet 2' -Verbose
    Ouvre l'interface sur la carte « Ethernet 2 » (adaptateur USB par exemple), avec le détail du journal en console.

.EXAMPLE
    .\Lancer-BasculeIP.cmd
    Usage courant : le lanceur demande l'élévation UAC et masque la console.

.NOTES
    Auteur  : Damien Audignon
    Version : 1.1 (2026-11-05) - ajout de la duplication de profil
              1.0 (2026-11-04) - version initiale
    Droits  : administrateur local (modification de l'adressage IP de la carte)
    Testé   : Windows PowerShell 5.1 (compatible PowerShell 7)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateNotNullOrEmpty()]
    [string]$InterfaceAlias,

    [ValidateNotNullOrEmpty()]
    [string]$ProfilePath,

    [ValidateNotNullOrEmpty()]
    [string]$LogPath = (Join-Path $env:ProgramData 'Scripts\Logs'),

    [ValidateRange(5, 120)]
    [int]$DhcpTimeout = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Initialisation
# $PSScriptRoot est vide dans param() sous 5.1 lancé avec -File : on le résout ici.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ProfilePath) { $ProfilePath = Join-Path $scriptDir 'Profils-IP.json' }

# Les gestionnaires d'événements de la fenêtre ont besoin de $PSCmdlet pour ShouldProcess (-WhatIf).
$script:Cmdlet     = $PSCmdlet
$script:Simulation = [bool]$WhatIfPreference
$script:AppTitle   = 'Bascule IP'
# Profil d'origine d'une duplication en cours (la copie sera rangée juste en dessous).
$script:DuplicateSource = $null
#endregion

#region Journalisation
$scriptName = [IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)
$logFile    = Join-Path $LogPath ('{0}_{1:yyyyMMdd}.log' -f $scriptName, (Get-Date))

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    # -WhatIf:$false : le journal doit être écrit même en simulation
    Add-Content -Path $logFile -Value $line -Encoding UTF8 -WhatIf:$false
    Write-Verbose $line
}

if (-not (Test-Path -Path $LogPath)) {
    New-Item -Path $LogPath -ItemType Directory -Force -WhatIf:$false | Out-Null
}
#endregion

#region Fonctions d'adressage (validation et calculs)
function Test-IPv4Address {
    # TryParse seul accepte « 10 » ou « 10.1 » : on impose aussi les 4 octets.
    param([string]$Address)
    if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
    if ($Address -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $false }
    foreach ($octet in $Matches[1..4]) { if ([int]$octet -gt 255) { return $false } }
    return $true
}

function ConvertTo-PrefixLength {
    # Accepte « 24 », « /24 » ou « 255.255.255.0 » et renvoie la longueur de préfixe.
    param([Parameter(Mandatory)][string]$Mask)
    $value = $Mask.Trim().TrimStart('/')
    if ($value -match '^\d{1,2}$') {
        $prefix = [int]$value
        if ($prefix -lt 1 -or $prefix -gt 32) { throw "Préfixe invalide : /$prefix (attendu 1 à 32)." }
        return $prefix
    }
    if (-not (Test-IPv4Address $value)) { throw "Masque invalide : '$Mask' (ex. : 255.255.255.0 ou 24)." }
    $bits = ($value.Split('.') | ForEach-Object { [Convert]::ToString([int]$_, 2).PadLeft(8, '0') }) -join ''
    # Un masque valide est une suite de 1 puis de 0 (pas de « trou »).
    if ($bits -notmatch '^1+0*$') { throw "Masque non contigu : '$Mask'." }
    return ($bits.ToCharArray() | Where-Object { $_ -eq '1' }).Count
}

function ConvertTo-SubnetMask {
    param([Parameter(Mandatory)][ValidateRange(0, 32)][int]$PrefixLength)
    $octets = for ($i = 0; $i -lt 4; $i++) {
        $n = [Math]::Max(0, [Math]::Min(8, $PrefixLength - (8 * $i)))
        [int](256 - [Math]::Pow(2, 8 - $n))
    }
    return ($octets -join '.')
}

function ConvertTo-UInt32Address {
    param([Parameter(Mandatory)][string]$Address)
    $b = ([System.Net.IPAddress]::Parse($Address)).GetAddressBytes()
    return ([uint64]$b[0] * 16777216) + ([uint64]$b[1] * 65536) + ([uint64]$b[2] * 256) + [uint64]$b[3]
}

function Test-SameSubnet {
    param([string]$Address, [string]$Other, [int]$PrefixLength)
    $size = [Math]::Pow(2, 32 - $PrefixLength)
    return [Math]::Floor((ConvertTo-UInt32Address $Address) / $size) -eq [Math]::Floor((ConvertTo-UInt32Address $Other) / $size)
}
#endregion

#region Profils (création, lecture et enregistrement du fichier JSON)
function Get-PropertyValue {
    # Lecture tolérante d'une propriété JSON (StrictMode lève une erreur si elle manque).
    param($InputObject, [string]$Name)
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function New-IPProfile {
    # Valide les saisies et construit un profil. Lève une exception au message lisible si une valeur est fausse.
    param(
        [string]$Name, [string]$Address, [string]$Mask,
        [string]$Gateway, [string[]]$Dns
    )
    $Name = "$Name".Trim(); $Address = "$Address".Trim(); $Gateway = "$Gateway".Trim()
    if (-not $Name) { throw 'Le nom du profil est obligatoire.' }
    if (-not (Test-IPv4Address $Address)) { throw "Adresse IP invalide : '$Address'." }
    if ([string]::IsNullOrWhiteSpace($Mask)) { throw 'Le masque est obligatoire (ex. : 255.255.255.0 ou 24).' }
    $prefix = ConvertTo-PrefixLength -Mask $Mask

    # Adresse réseau ou broadcast : Windows la refuserait ou elle ne fonctionnerait pas.
    if ($prefix -le 30) {
        $size = [Math]::Pow(2, 32 - $prefix)
        $rest = (ConvertTo-UInt32Address $Address) % $size
        if ($rest -eq 0)         { throw "$Address est l'adresse du réseau /$prefix, pas une adresse d'hôte." }
        if ($rest -eq $size - 1) { throw "$Address est l'adresse de broadcast du réseau /$prefix." }
    }
    if ($Gateway) {
        if (-not (Test-IPv4Address $Gateway)) { throw "Passerelle invalide : '$Gateway'." }
        # Windows accepte une passerelle hors réseau, mais c'est presque toujours une faute de frappe.
        if (-not (Test-SameSubnet $Address $Gateway $prefix)) { throw "La passerelle $Gateway n'est pas dans le réseau de $Address/$prefix." }
        if ($Gateway -eq $Address) { throw "La passerelle ne peut pas être l'adresse du poste." }
    }
    $dnsList = @($Dns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    foreach ($server in $dnsList) {
        if (-not (Test-IPv4Address $server)) { throw "Serveur DNS invalide : '$server'." }
    }
    [PSCustomObject]@{
        Nom        = $Name
        IP         = $Address
        Prefixe    = $prefix
        Passerelle = $Gateway
        Dns        = [string[]]$dnsList
    }
}

function Import-IPProfile {
    param([Parameter(Mandatory)][string]$Path)
    $list = New-Object 'System.Collections.Generic.List[object]'
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Aucun fichier de profils ($Path) : liste vide."
        return , $list
    }
    $raw = [IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) { return , $list }
    $data = ConvertFrom-Json -InputObject $raw
    foreach ($item in @(Get-PropertyValue $data 'Profils')) {
        if ($null -eq $item) { continue }
        try {
            # On revalide : le fichier a pu être modifié à la main.
            $list.Add((New-IPProfile -Name (Get-PropertyValue $item 'Nom') -Address (Get-PropertyValue $item 'IP') `
                        -Mask ([string](Get-PropertyValue $item 'Prefixe')) -Gateway (Get-PropertyValue $item 'Passerelle') `
                        -Dns @(Get-PropertyValue $item 'Dns')))
        }
        catch {
            Write-Log "Profil ignoré dans $Path : $($_.Exception.Message)" -Level WARN
        }
    }
    Write-Log "$($list.Count) profil(s) chargé(s) depuis $Path"
    return , $list
}

function Export-IPProfile {
    # Écriture dans un fichier temporaire puis remplacement : un plantage ne laisse pas un JSON tronqué.
    # La version précédente est conservée en .bak (retour arrière en cas de mauvaise manipulation).
    param([Parameter(Mandatory)][string]$Path)
    $document = [PSCustomObject]@{
        Version = 1
        Modifie = (Get-Date).ToString('s')
        Profils = [object[]]$script:Profiles.ToArray()
    }
    $json = ConvertTo-Json -InputObject $document -Depth 5
    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder)) {
        New-Item -Path $folder -ItemType Directory -Force -WhatIf:$false | Out-Null
    }
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, "$Path.bak") }
    else { [IO.File]::Move($tmp, $Path) }
    Write-Log "Profils enregistrés ($($script:Profiles.Count)) dans $Path"
}

function Test-ProfileNameUsed {
    param([string]$Name, $Except)
    foreach ($p in $script:Profiles) {
        if (-not [object]::ReferenceEquals($p, $Except) -and $p.Nom -ieq $Name.Trim()) { return $true }
    }
    return $false
}

function Format-ProfileSummary {
    param($IPProfile)
    $dns = if (@($IPProfile.Dns).Count) { @($IPProfile.Dns) -join ', ' } else { 'auto' }
    '{0}/{1} passerelle={2} DNS={3}' -f $IPProfile.IP, $IPProfile.Prefixe, $(if ($IPProfile.Passerelle) { $IPProfile.Passerelle } else { 'aucune' }), $dns
}
#endregion

#region Lecture et modification de la carte réseau
function Get-AdapterIPConfig {
    param([Parameter(Mandatory)][string]$Alias)
    $adapter = Get-NetAdapter -Name $Alias
    $idx     = $adapter.ifIndex

    $ipIf = Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    $addresses = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object {
            [PSCustomObject]@{ IP = $_.IPAddress; Prefix = [int]$_.PrefixLength; Origin = [string]$_.PrefixOrigin; State = [string]$_.AddressState }
        })
    $gateways = @(Get-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty NextHop -Unique)
    $dns = @(Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty ServerAddresses)

    # DNS saisis à la main : valeur NameServer de l'interface dans le registre (vide = DNS automatiques).
    $dnsStatic = $false
    try {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($adapter.InterfaceGuid)"
        $dnsStatic = -not [string]::IsNullOrWhiteSpace([string](Get-ItemPropertyValue -Path $regPath -Name 'NameServer'))
    }
    catch { $dnsStatic = $false }

    # Serveur DHCP et date du bail : seulement exposés par WMI.
    $dhcpServer = $null; $leaseObtained = $null
    $wmi = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex = $idx" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($wmi -and $wmi.DHCPEnabled -and $wmi.DHCPServer -and $wmi.DHCPServer -ne '255.255.255.255') {
        $dhcpServer = $wmi.DHCPServer; $leaseObtained = $wmi.DHCPLeaseObtained
    }

    [PSCustomObject]@{
        Alias         = $adapter.Name
        Index         = $idx
        Description   = $adapter.InterfaceDescription
        Status        = [string]$adapter.Status
        Mac           = $adapter.MacAddress
        Dhcp          = [bool]($ipIf -and [string]$ipIf.Dhcp -eq 'Enabled')
        Addresses     = $addresses
        Gateways      = $gateways
        Dns           = $dns
        DnsStatic     = $dnsStatic
        DhcpServer    = $dhcpServer
        LeaseObtained = $leaseObtained
    }
}

function Format-ConfigSummary {
    param($Config)
    if (-not $Config) { return '(inconnue)' }
    $ips = if ($Config.Addresses.Count) { ($Config.Addresses | ForEach-Object { '{0}/{1}' -f $_.IP, $_.Prefix }) -join ', ' } else { 'aucune' }
    'mode={0} IP={1} passerelle={2} DNS={3}{4}' -f $(if ($Config.Dhcp) { 'DHCP' } else { 'fixe' }), $ips,
        $(if ($Config.Gateways.Count) { $Config.Gateways -join ', ' } else { 'aucune' }),
        $(if ($Config.Dns.Count) { $Config.Dns -join ', ' } else { 'aucun' }),
        $(if ($Config.DnsStatic) { ' (DNS fixes)' } else { '' })
}

function Start-DhcpRenew {
    # ipconfig /renew lancé à part : il peut bloquer jusqu'à 1 min sans serveur DHCP, la fenêtre reste réactive.
    param([Parameter(Mandatory)][string]$Alias)
    $ipconfig = Join-Path $env:SystemRoot 'System32\ipconfig.exe'
    Start-Process -FilePath $ipconfig -ArgumentList ('/renew "{0}"' -f $Alias) -WindowStyle Hidden | Out-Null
}

function Set-AdapterDhcp {
    # Renvoie : 'Appliqué', 'Renouvellement' (déjà en DHCP) ou 'Simulation'.
    param([Parameter(Mandatory)][string]$Alias)
    $cfg = Get-AdapterIPConfig -Alias $Alias
    $staticGateway = $cfg.Gateways.Count -gt 0 -and -not $cfg.Dhcp

    # Idempotence : déjà en DHCP avec des DNS automatiques -> simple renouvellement du bail.
    if ($cfg.Dhcp -and -not $cfg.DnsStatic -and -not $staticGateway) {
        if (-not $script:Cmdlet.ShouldProcess($Alias, 'Renouveler le bail DHCP')) { return 'Simulation' }
        if ($cfg.Status -eq 'Up') { Start-DhcpRenew -Alias $Alias }
        Write-Log "'$Alias' déjà en DHCP : renouvellement du bail demandé"
        return 'Renouvellement'
    }

    # SÉCURITÉ : changement d'adressage, coupe les connexions en cours sur cette carte.
    if (-not $script:Cmdlet.ShouldProcess($Alias, 'Passer en DHCP (IP, passerelle et DNS automatiques)')) { return 'Simulation' }
    Write-Log "Avant passage en DHCP sur '$Alias' : $(Format-ConfigSummary $cfg)"

    # La passerelle fixe resterait en plus de celle du DHCP : on la retire, ainsi que les IP fixes.
    Remove-NetRoute -InterfaceIndex $cfg.Index -DestinationPrefix '0.0.0.0/0' -Confirm:$false -ErrorAction SilentlyContinue
    if (-not $cfg.Dhcp) {
        Remove-NetIPAddress -InterfaceIndex $cfg.Index -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
    }
    Set-NetIPInterface -InterfaceIndex $cfg.Index -AddressFamily IPv4 -Dhcp Enabled
    Set-DnsClientServerAddress -InterfaceIndex $cfg.Index -ResetServerAddresses
    if ($cfg.Status -eq 'Up') { Start-DhcpRenew -Alias $Alias }
    Write-Log "'$Alias' passée en DHCP"
    return 'Appliqué'
}

function Set-AdapterStaticIP {
    # Renvoie : 'Appliqué', 'Inchangé' (déjà dans cette configuration) ou 'Simulation'.
    param([Parameter(Mandatory)][string]$Alias, [Parameter(Mandatory)]$IPProfile)
    $cfg = Get-AdapterIPConfig -Alias $Alias
    $wantedDns = @($IPProfile.Dns)

    # Idempotence : même IP, même masque, même passerelle et mêmes DNS -> rien à faire.
    $same = (-not $cfg.Dhcp) -and $cfg.Addresses.Count -eq 1 -and
        $cfg.Addresses[0].IP -eq $IPProfile.IP -and $cfg.Addresses[0].Prefix -eq $IPProfile.Prefixe -and
        (($cfg.Gateways -join ',') -eq [string]$IPProfile.Passerelle) -and
        ((-not $wantedDns.Count -and -not $cfg.DnsStatic) -or (($cfg.Dns -join ',') -eq ($wantedDns -join ',')))
    if ($same) {
        Write-Log "'$Alias' déjà configurée avec le profil '$($IPProfile.Nom)' : aucune modification"
        return 'Inchangé'
    }

    # SÉCURITÉ : changement d'adressage, coupe les connexions en cours sur cette carte.
    if (-not $script:Cmdlet.ShouldProcess($Alias, "Appliquer le profil '$($IPProfile.Nom)' : $(Format-ProfileSummary $IPProfile)")) {
        return 'Simulation'
    }
    Write-Log "Avant application du profil '$($IPProfile.Nom)' sur '$Alias' : $(Format-ConfigSummary $cfg)"

    # Ordre imposé : sans retrait préalable de la route par défaut et des anciennes IP,
    # New-NetIPAddress échoue (« DefaultGateway already exists », conflit DHCP / magasin persistant).
    Remove-NetRoute -InterfaceIndex $cfg.Index -DestinationPrefix '0.0.0.0/0' -Confirm:$false -ErrorAction SilentlyContinue
    Set-NetIPInterface -InterfaceIndex $cfg.Index -AddressFamily IPv4 -Dhcp Disabled
    Remove-NetIPAddress -InterfaceIndex $cfg.Index -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue

    $newIp = @{
        InterfaceIndex = $cfg.Index
        AddressFamily  = 'IPv4'
        IPAddress      = $IPProfile.IP
        PrefixLength   = $IPProfile.Prefixe
    }
    if ($IPProfile.Passerelle) { $newIp.DefaultGateway = $IPProfile.Passerelle }
    New-NetIPAddress @newIp | Out-Null

    if ($wantedDns.Count) { Set-DnsClientServerAddress -InterfaceIndex $cfg.Index -ServerAddresses $wantedDns }
    else { Set-DnsClientServerAddress -InterfaceIndex $cfg.Index -ResetServerAddresses }

    Write-Log "Profil '$($IPProfile.Nom)' appliqué sur '$Alias' : $(Format-ProfileSummary $IPProfile)"
    return 'Appliqué'
}
#endregion

#region Interface : outils communs
function Enable-DpiAwareness {
    # Sans cela, Windows étire la fenêtre à 125/150 % et le texte est flou. Non bloquant en cas d'échec.
    try {
        if (-not ('BasculeIP.Dpi' -as [type])) {
            Add-Type -Namespace BasculeIP -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
        }
        [void][BasculeIP.Dpi]::SetProcessDPIAware()
    }
    catch { Write-Log "Mode haute résolution non activé : $($_.Exception.Message)" -Level WARN }
}

function New-UiControl {
    param(
        [Parameter(Mandatory)][string]$Type,
        [int]$X, [int]$Y, [int]$Width, [int]$Height,
        [string]$Text, $Parent
    )
    $control = New-Object "System.Windows.Forms.$Type"
    $control.Location = New-Object System.Drawing.Point($X, $Y)
    $control.Size     = New-Object System.Drawing.Size($Width, $Height)
    if ($Text) { $control.Text = $Text }
    if ($Parent) { $Parent.Controls.Add($control) }
    return $control
}

function Show-Message {
    param([string]$Text, [ValidateSet('Information', 'Warning', 'Error', 'Question')][string]$Icon = 'Information',
        [ValidateSet('OK', 'YesNo')][string]$Buttons = 'OK')
    return [System.Windows.Forms.MessageBox]::Show($script:Form, $Text, $script:AppTitle,
        [System.Windows.Forms.MessageBoxButtons]::$Buttons, [System.Windows.Forms.MessageBoxIcon]::$Icon)
}

function Set-Status {
    param([string]$Text)
    $script:StatusLabel.Text = $Text
    [System.Windows.Forms.Application]::DoEvents()
}

function Invoke-UiAction {
    # Toute action de l'interface passe par ici : une erreur s'affiche et se journalise sans fermer la fenêtre.
    param([Parameter(Mandatory)][scriptblock]$Action)
    $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try { & $Action }
    catch {
        Write-Log "Erreur : $($_.Exception.Message)" -Level ERROR
        Set-Status "Erreur : $($_.Exception.Message)"
        [void](Show-Message -Text $_.Exception.Message -Icon Error)
    }
    finally { $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default }
}

function Get-SelectedAlias {
    $i = $script:CboAdapter.SelectedIndex
    if ($i -lt 0) { return $null }
    return $script:AdapterNames[$i]
}

function Get-SelectedProfile {
    if ($script:LvProfiles.SelectedItems.Count -eq 0) { return $null }
    return $script:LvProfiles.SelectedItems[0].Tag
}

function Get-FieldProfile {
    New-IPProfile -Name $script:TxtName.Text -Address $script:TxtIp.Text -Mask $script:TxtMask.Text `
        -Gateway $script:TxtGateway.Text -Dns @($script:TxtDns1.Text, $script:TxtDns2.Text)
}
#endregion

#region Interface : mise à jour de l'affichage
function Update-AdapterList {
    param([string]$Select)
    # Cartes connectées et physiques en premier : c'est presque toujours celle qu'on veut.
    $adapters = @(Get-NetAdapter | Sort-Object @{ Expression = { $_.Status -ne 'Up' } },
        @{ Expression = { -not $_.HardwareInterface } }, Name)
    $script:AdapterNames = @($adapters | ForEach-Object { $_.Name })
    $script:CboAdapter.BeginUpdate()
    $script:CboAdapter.Items.Clear()
    foreach ($a in $adapters) {
        $state = switch ([string]$a.Status) { 'Up' { 'connectée' } 'Disconnected' { 'câble débranché' } 'Disabled' { 'désactivée' } default { [string]$a.Status } }
        [void]$script:CboAdapter.Items.Add(('{0}  —  {1}  ({2})' -f $a.Name, $a.InterfaceDescription, $state))
    }
    $script:CboAdapter.EndUpdate()
    if (-not $adapters.Count) { Set-Status 'Aucune carte réseau trouvée.'; return }
    $index = if ($Select) { [array]::IndexOf($script:AdapterNames, $Select) } else { -1 }
    $script:CboAdapter.SelectedIndex = [Math]::Max(0, $index)
}

function Update-ConfigDisplay {
    $alias = Get-SelectedAlias
    if (-not $alias) { return }
    $cfg = Get-AdapterIPConfig -Alias $alias
    $script:CurrentConfig = $cfg

    $main  = @($cfg.Addresses | Where-Object { $_.IP -notlike '169.254.*' })
    $apipa = @($cfg.Addresses | Where-Object { $_.IP -like '169.254.*' })
    $mode  = if ($cfg.Dhcp) { 'DHCP' } else { 'IP fixe' }
    $lbl   = $script:LblIp

    if ($main.Count) {
        $lbl.Text = '{0} : {1} /{2}' -f $mode, $main[0].IP, $main[0].Prefix
        $lbl.ForeColor = if ($cfg.Dhcp) { [System.Drawing.Color]::ForestGreen } else { [System.Drawing.Color]::RoyalBlue }
        if ($main[0].State -eq 'Duplicate') {
            $lbl.Text += '  (CONFLIT : adresse déjà utilisée)'
            $lbl.ForeColor = [System.Drawing.Color]::Firebrick
        }
        elseif ($main[0].State -eq 'Tentative') { $lbl.Text += '  (vérification en cours…)' }
    }
    elseif ($cfg.Status -ne 'Up') {
        $lbl.Text = "$mode : carte non connectée"
        $lbl.ForeColor = [System.Drawing.Color]::Gray
    }
    elseif ($apipa.Count) {
        $lbl.Text = 'DHCP : aucune réponse ({0})' -f $apipa[0].IP
        $lbl.ForeColor = [System.Drawing.Color]::DarkOrange
    }
    else {
        $lbl.Text = "$mode : aucune adresse IPv4"
        $lbl.ForeColor = [System.Drawing.Color]::Gray
    }

    $prefix = if ($main.Count) { $main[0].Prefix } elseif ($apipa.Count) { $apipa[0].Prefix } else { $null }
    $lines = @(
        'Mode         : {0}' -f $(if ($cfg.Dhcp) { 'DHCP (adresse automatique)' } else { 'IP fixe' })
        'Adresse(s)   : {0}' -f $(if ($cfg.Addresses.Count) { ($cfg.Addresses | ForEach-Object { '{0}/{1}' -f $_.IP, $_.Prefix }) -join ', ' } else { '-' })
        'Masque       : {0}' -f $(if ($null -ne $prefix) { ConvertTo-SubnetMask $prefix } else { '-' })
        'Passerelle   : {0}' -f $(if ($cfg.Gateways.Count) { $cfg.Gateways -join ', ' } else { '-' })
        'DNS          : {0}{1}' -f $(if ($cfg.Dns.Count) { $cfg.Dns -join ', ' } else { '-' }), $(if ($cfg.DnsStatic) { '  (fixes)' } else { '' })
        'Serveur DHCP : {0}' -f $(if ($cfg.DhcpServer) { '{0}  (bail du {1:dd/MM HH:mm})' -f $cfg.DhcpServer, $cfg.LeaseObtained } else { '-' })
        'MAC          : {0}' -f $cfg.Mac
    )
    $script:TxtDetails.Text = $lines -join "`r`n"
}

function Update-ProfileList {
    param([int]$SelectIndex = -1)
    $lv = $script:LvProfiles
    $lv.BeginUpdate()
    $lv.Items.Clear()
    foreach ($p in $script:Profiles) {
        $item = New-Object System.Windows.Forms.ListViewItem -ArgumentList ([string]$p.Nom)
        [void]$item.SubItems.Add($p.IP)
        [void]$item.SubItems.Add(('{0} (/{1})' -f (ConvertTo-SubnetMask $p.Prefixe), $p.Prefixe))
        [void]$item.SubItems.Add($(if ($p.Passerelle) { $p.Passerelle } else { '-' }))
        [void]$item.SubItems.Add($(if (@($p.Dns).Count) { @($p.Dns) -join ', ' } else { 'auto' }))
        $item.Tag = $p
        [void]$lv.Items.Add($item)
    }
    $lv.EndUpdate()
    if ($SelectIndex -ge 0 -and $SelectIndex -lt $lv.Items.Count) {
        $lv.Items[$SelectIndex].Selected = $true
        $lv.Items[$SelectIndex].EnsureVisible()
    }
}
#endregion

#region Interface : actions
function Start-DhcpWait {
    $script:DhcpWaitStart = Get-Date
    Set-Status "Attente d'une adresse DHCP…"
    $script:DhcpTimer.Start()
}

function Invoke-DhcpAction {
    $alias = Get-SelectedAlias
    if (-not $alias) { return }
    $script:DhcpTimer.Stop()
    $result = Set-AdapterDhcp -Alias $alias
    switch ($result) {
        'Simulation' { Set-Status "Simulation : '$alias' aurait été passée en DHCP (aucune modification)." }
        default {
            Update-ConfigDisplay
            if ($script:CurrentConfig.Status -eq 'Up') { Start-DhcpWait }
            else { Set-Status "DHCP activé sur '$alias' : l'adresse sera demandée au branchement du câble." }
        }
    }
}

function Invoke-ApplyProfileAction {
    $p = Get-SelectedProfile
    if (-not $p) { [void](Show-Message 'Sélectionnez un profil dans la liste.' -Icon Warning); return }
    $alias = Get-SelectedAlias
    if (-not $alias) { return }
    $script:DhcpTimer.Stop()
    Set-Status "Application du profil '$($p.Nom)' sur '$alias'…"
    $result = Set-AdapterStaticIP -Alias $alias -IPProfile $p
    Update-ConfigDisplay
    switch ($result) {
        'Simulation' { Set-Status "Simulation : le profil '$($p.Nom)' aurait été appliqué (aucune modification)." }
        'Inchangé'   { Set-Status "'$alias' est déjà configurée avec le profil '$($p.Nom)'." }
        default      { Set-Status "Profil '$($p.Nom)' appliqué sur '$alias' : $(Format-ProfileSummary $p)" }
    }
}

function Set-ProfileField {
    # Recopie un profil dans le formulaire (sélection, duplication).
    param([Parameter(Mandatory)]$IPProfile, [string]$Name = $IPProfile.Nom)
    $script:TxtName.Text    = $Name
    $script:TxtIp.Text      = $IPProfile.IP
    $script:TxtMask.Text    = ConvertTo-SubnetMask $IPProfile.Prefixe
    $script:TxtGateway.Text = $IPProfile.Passerelle
    $script:TxtDns1.Text    = if (@($IPProfile.Dns).Count -ge 1) { @($IPProfile.Dns)[0] } else { '' }
    $script:TxtDns2.Text    = if (@($IPProfile.Dns).Count -ge 2) { @($IPProfile.Dns)[1] } else { '' }
}

function Copy-SelectedProfile {
    # Duplique le profil sélectionné dans le formulaire, sans l'enregistrer tout de suite :
    # on change le nom et un octet, puis « Ajouter ». Annuler = « Vider », rien n'est créé.
    $p = Get-SelectedProfile
    if (-not $p) { throw 'Sélectionnez le profil à dupliquer.' }
    $base = "$($p.Nom) - copie"
    $name = $base; $n = 2
    while (Test-ProfileNameUsed -Name $name) { $name = "$base $n"; $n++ }

    $script:DuplicateSource = $p
    # Désélection : « Mettre à jour la sélection » ne peut plus écraser l'original par erreur.
    $script:LvProfiles.SelectedItems.Clear()
    Set-ProfileField -IPProfile $p -Name $name
    [void]$script:TxtName.Focus()
    $script:TxtName.SelectAll()
    Set-Status "Copie de '$($p.Nom)' : modifiez le nom et l'adresse, puis « Ajouter » (rangée sous l'original)."
}

function Invoke-AddProfileAction {
    $p = Get-FieldProfile
    if (Test-ProfileNameUsed -Name $p.Nom) { throw "Un profil nommé '$($p.Nom)' existe déjà." }
    # Une copie est rangée juste sous son original, sinon le profil va en fin de liste.
    $source = if ($script:DuplicateSource) { $script:Profiles.IndexOf($script:DuplicateSource) } else { -1 }
    if ($source -ge 0) { $index = $source + 1; $script:Profiles.Insert($index, $p) }
    else { $script:Profiles.Add($p); $index = $script:Profiles.Count - 1 }
    $script:DuplicateSource = $null
    Export-IPProfile -Path $ProfilePath
    Update-ProfileList -SelectIndex $index
    Write-Log "Profil ajouté : '$($p.Nom)' ($(Format-ProfileSummary $p))"
    Set-Status "Profil '$($p.Nom)' enregistré."
}

function Invoke-UpdateProfileAction {
    $old = Get-SelectedProfile
    if (-not $old) { throw 'Sélectionnez le profil à mettre à jour.' }
    $p = Get-FieldProfile
    if (Test-ProfileNameUsed -Name $p.Nom -Except $old) { throw "Un autre profil s'appelle déjà '$($p.Nom)'." }
    $i = $script:Profiles.IndexOf($old)
    $script:Profiles[$i] = $p
    Export-IPProfile -Path $ProfilePath
    Update-ProfileList -SelectIndex $i
    Set-Status "Profil '$($p.Nom)' mis à jour."
}

function Remove-SelectedProfile {
    $p = Get-SelectedProfile
    if (-not $p) { return }
    # SÉCURITÉ : suppression confirmée ; la version précédente du fichier reste dans le .bak.
    $answer = Show-Message "Supprimer le profil '$($p.Nom)' ($(Format-ProfileSummary $p)) ?" -Icon Question -Buttons YesNo
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $i = $script:Profiles.IndexOf($p)
    [void]$script:Profiles.Remove($p)
    Export-IPProfile -Path $ProfilePath
    Update-ProfileList -SelectIndex ([Math]::Min($i, $script:Profiles.Count - 1))
    Write-Log "Profil supprimé : '$($p.Nom)' ($(Format-ProfileSummary $p))"
    Set-Status "Profil '$($p.Nom)' supprimé."
}

function Move-SelectedProfile {
    param([ValidateSet(-1, 1)][int]$Offset)
    $p = Get-SelectedProfile
    if (-not $p) { return }
    $i = $script:Profiles.IndexOf($p)
    $j = $i + $Offset
    if ($j -lt 0 -or $j -ge $script:Profiles.Count) { return }
    $script:Profiles.RemoveAt($i)
    $script:Profiles.Insert($j, $p)
    Export-IPProfile -Path $ProfilePath
    Update-ProfileList -SelectIndex $j
}

function Copy-CurrentConfigToField {
    # Pré-remplit le formulaire avec la configuration actuelle (pour l'enregistrer comme profil).
    $cfg = $script:CurrentConfig
    if (-not $cfg) { return }
    $main = @($cfg.Addresses | Where-Object { $_.IP -notlike '169.254.*' })
    if (-not $main.Count) { throw "La carte n'a pas d'adresse IPv4 utilisable à copier." }
    $script:TxtName.Text    = ''
    $script:TxtIp.Text      = $main[0].IP
    $script:TxtMask.Text    = ConvertTo-SubnetMask $main[0].Prefix
    $script:TxtGateway.Text = if ($cfg.Gateways.Count) { $cfg.Gateways[0] } else { '' }
    $script:TxtDns1.Text    = if ($cfg.Dns.Count -ge 1) { $cfg.Dns[0] } else { '' }
    $script:TxtDns2.Text    = if ($cfg.Dns.Count -ge 2) { $cfg.Dns[1] } else { '' }
    [void]$script:TxtName.Focus()
    Set-Status 'Configuration actuelle copiée : donnez un nom puis cliquez sur « Ajouter ».'
}

function Test-HostReachable {
    $target = $script:TxtPing.Text.Trim()
    if (-not $target) { return }
    $ping = New-Object System.Net.NetworkInformation.Ping
    try {
        $reply = $ping.Send($target, 1000)
        if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
            $script:LblPing.Text = '{0} répond ({1} ms)' -f $target, $reply.RoundtripTime
            $script:LblPing.ForeColor = [System.Drawing.Color]::ForestGreen
        }
        else {
            $script:LblPing.Text = '{0} : pas de réponse ({1})' -f $target, $reply.Status
            $script:LblPing.ForeColor = [System.Drawing.Color]::Firebrick
        }
    }
    catch {
        $script:LblPing.Text = '{0} : {1}' -f $target, $_.Exception.GetBaseException().Message
        $script:LblPing.ForeColor = [System.Drawing.Color]::Firebrick
    }
    finally { $ping.Dispose() }
}
#endregion

#region Construction de la fenêtre
function New-MainForm {
    $fontUi   = New-Object System.Drawing.Font('Segoe UI', 9)
    $fontBold = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

    $form = New-Object System.Windows.Forms.Form
    $form.SuspendLayout()
    # Coordonnées pensées à 96 ppp : WinForms les met à l'échelle de l'écran (125 %, 150 %…).
    $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    $form.AutoScaleMode   = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.Text            = $script:AppTitle + $(if ($script:Simulation) { '  [SIMULATION -WhatIf : aucune modification]' } else { '' })
    $form.ClientSize      = New-Object System.Drawing.Size(780, 622)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $form.MaximizeBox     = $false
    $form.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Font            = $fontUi
    $form.KeyPreview      = $true
    $script:Form = $form

    # --- Choix de la carte ---
    [void](New-UiControl Label 12 16 90 20 'Carte réseau :' $form)
    $cbo = New-UiControl ComboBox 105 12 540 24 $null $form
    $cbo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $script:CboAdapter = $cbo
    $btnRefresh = New-UiControl Button 655 11 113 26 'Actualiser' $form

    # --- Configuration actuelle ---
    $grpCurrent = New-UiControl GroupBox 12 46 756 168 'Configuration actuelle' $form
    $script:LblIp = New-UiControl Label 12 22 505 30 '' $grpCurrent
    $script:LblIp.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $txtDetails = New-UiControl TextBox 12 56 505 102 '' $grpCurrent
    $txtDetails.Multiline = $true
    $txtDetails.ReadOnly  = $true
    $txtDetails.Font      = New-Object System.Drawing.Font('Consolas', 9)
    $script:TxtDetails = $txtDetails
    $btnDhcp  = New-UiControl Button 530 22 212 42 'Passer en DHCP' $grpCurrent
    $btnDhcp.Font = $fontBold
    $btnRenew = New-UiControl Button 530 72 212 30 'Renouveler le bail DHCP' $grpCurrent
    $btnCopy  = New-UiControl Button 530 110 212 30 'Copier dans le formulaire ↓' $grpCurrent

    # --- Profils ---
    $grpProfiles = New-UiControl GroupBox 12 222 756 332 'Profils IP fixes  —  double-clic pour appliquer, F2 pour renommer' $form
    $lv = New-UiControl ListView 12 22 600 192 $null $grpProfiles
    $lv.View          = [System.Windows.Forms.View]::Details
    $lv.FullRowSelect = $true
    $lv.MultiSelect   = $false
    $lv.HideSelection = $false
    $lv.LabelEdit     = $true
    $lv.GridLines     = $true
    # Les largeurs de colonnes ne suivent pas la mise à l'échelle automatique : on les ajuste nous-mêmes.
    $graphics = $form.CreateGraphics(); $scale = $graphics.DpiX / 96; $graphics.Dispose()
    foreach ($col in @(@('Nom', 150), @('Adresse IP', 110), @('Masque', 130), @('Passerelle', 100), @('DNS', 106))) {
        [void]$lv.Columns.Add($col[0], [int]($col[1] * $scale))
    }
    $script:LvProfiles = $lv

    $btnApply     = New-UiControl Button 622 22 120 36 'Appliquer' $grpProfiles
    $btnApply.Font = $fontBold
    $btnDuplicate = New-UiControl Button 622 64 120 26 'Dupliquer (Ctrl+D)' $grpProfiles
    $btnRename    = New-UiControl Button 622 94 120 26 'Renommer (F2)' $grpProfiles
    $btnUp        = New-UiControl Button 622 124 120 26 'Monter ▲' $grpProfiles
    $btnDown      = New-UiControl Button 622 154 120 26 'Descendre ▼' $grpProfiles
    $btnDelete    = New-UiControl Button 622 188 120 26 'Supprimer' $grpProfiles

    $fields = @(
        @{ Var = 'TxtName';    Label = 'Nom';        X = 12;  W = 140 }
        @{ Var = 'TxtIp';      Label = 'Adresse IP'; X = 162; W = 110 }
        @{ Var = 'TxtMask';    Label = 'Masque';     X = 282; W = 110 }
        @{ Var = 'TxtGateway'; Label = 'Passerelle'; X = 402; W = 110 }
        @{ Var = 'TxtDns1';    Label = 'DNS 1';      X = 522; W = 110 }
        @{ Var = 'TxtDns2';    Label = 'DNS 2';      X = 642; W = 100 }
    )
    foreach ($f in $fields) {
        [void](New-UiControl Label $f.X 224 $f.W 18 $f.Label $grpProfiles)
        Set-Variable -Scope Script -Name $f.Var -Value (New-UiControl TextBox $f.X 243 $f.W 23 '' $grpProfiles) -WhatIf:$false
    }
    $btnAdd    = New-UiControl Button 12 282 140 32 'Ajouter' $grpProfiles
    $btnAdd.Font = $fontBold
    $btnUpdate = New-UiControl Button 162 282 190 32 'Mettre à jour la sélection' $grpProfiles
    $btnClear  = New-UiControl Button 362 282 90 32 'Vider' $grpProfiles
    $hint = New-UiControl Label 462 284 285 30 "Masque : 255.255.255.0 ou 24. Passerelle et DNS facultatifs." $grpProfiles
    $hint.ForeColor = [System.Drawing.Color]::DimGray

    # --- Test de joignabilité ---
    [void](New-UiControl Label 12 568 140 20 'Tester une IP (ping) :' $form)
    $script:TxtPing = New-UiControl TextBox 155 565 140 23 '' $form
    $btnPing = New-UiControl Button 302 564 80 26 'Ping' $form
    $script:LblPing = New-UiControl Label 392 568 376 20 '' $form

    # --- Barre d'état ---
    $status = New-Object System.Windows.Forms.StatusStrip
    $script:StatusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $script:StatusLabel.Spring    = $true
    $script:StatusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    [void]$status.Items.Add($script:StatusLabel)
    $form.Controls.Add($status)

    # --- Minuterie d'attente DHCP (la fenêtre reste utilisable pendant l'attente) ---
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1500
    $script:DhcpTimer = $timer
    $timer.Add_Tick({
            try {
                Update-ConfigDisplay
                $elapsed = ((Get-Date) - $script:DhcpWaitStart).TotalSeconds
                $got = @($script:CurrentConfig.Addresses | Where-Object { $_.IP -notlike '169.254.*' -and $_.Origin -eq 'Dhcp' -and $_.State -eq 'Preferred' })
                # 3 s minimum : laisse au renouvellement le temps de remplacer un ancien bail.
                if ($got.Count -and $elapsed -ge 3) {
                    $script:DhcpTimer.Stop()
                    Set-Status ('Adresse DHCP reçue : {0}/{1}' -f $got[0].IP, $got[0].Prefix)
                    Write-Log ("Adresse DHCP reçue sur '{0}' : {1}" -f $script:CurrentConfig.Alias, (Format-ConfigSummary $script:CurrentConfig))
                }
                elseif ($elapsed -ge $DhcpTimeout) {
                    $script:DhcpTimer.Stop()
                    Set-Status "Aucune adresse DHCP après $DhcpTimeout s : pas de serveur DHCP sur ce réseau ? (passer sur un profil fixe)"
                    Write-Log "Pas de réponse DHCP sur '$($script:CurrentConfig.Alias)' après $DhcpTimeout s" -Level WARN
                }
                else { Set-Status ("Attente d'une adresse DHCP… {0} s" -f [int]$elapsed) }
            }
            catch {
                $script:DhcpTimer.Stop()
                Write-Log "Erreur pendant l'attente DHCP : $($_.Exception.Message)" -Level ERROR
                Set-Status "Erreur : $($_.Exception.Message)"
            }
        })

    # --- Événements ---
    $cbo.Add_SelectedIndexChanged({ $script:DhcpTimer.Stop(); Invoke-UiAction { Update-ConfigDisplay; Set-Status "Carte '$(Get-SelectedAlias)' sélectionnée." } })
    $btnRefresh.Add_Click({ Invoke-UiAction { Update-AdapterList -Select (Get-SelectedAlias) } })
    $btnDhcp.Add_Click({ Invoke-UiAction { Invoke-DhcpAction } })
    $btnRenew.Add_Click({
            Invoke-UiAction {
                $alias = Get-SelectedAlias
                if (-not $script:CurrentConfig.Dhcp) { throw "'$alias' est en IP fixe : utilisez « Passer en DHCP »." }
                if ($script:CurrentConfig.Status -ne 'Up') { throw "'$alias' n'est pas connectée." }
                if ($script:Cmdlet.ShouldProcess($alias, 'Renouveler le bail DHCP')) {
                    Write-Log "Renouvellement du bail DHCP demandé sur '$alias'"
                    Start-DhcpRenew -Alias $alias
                    Start-DhcpWait
                }
                else { Set-Status 'Simulation : bail DHCP non renouvelé.' }
            }
        })
    $btnCopy.Add_Click({ Invoke-UiAction { Copy-CurrentConfigToField } })
    $btnApply.Add_Click({ Invoke-UiAction { Invoke-ApplyProfileAction } })
    $lv.Add_DoubleClick({ Invoke-UiAction { Invoke-ApplyProfileAction } })
    $lv.Add_SelectedIndexChanged({
            $p = Get-SelectedProfile
            if (-not $p) { return }
            # Remplit le formulaire : permet de modifier un profil puis « Mettre à jour la sélection ».
            $script:DuplicateSource = $null
            Set-ProfileField -IPProfile $p
        })
    $lv.Add_KeyDown({
            param($s, $e)
            if ($e.Control -and $e.KeyCode -eq 'D') { $e.SuppressKeyPress = $true; Invoke-UiAction { Copy-SelectedProfile }; return }
            switch ($e.KeyCode) {
                'F2'     { if ($script:LvProfiles.SelectedItems.Count) { $script:LvProfiles.SelectedItems[0].BeginEdit() } }
                'Delete' { Invoke-UiAction { Remove-SelectedProfile } }
                'Return' { Invoke-UiAction { Invoke-ApplyProfileAction } }
            }
        })
    $lv.Add_AfterLabelEdit({
            param($s, $e)
            Invoke-UiAction {
                if ($null -eq $e.Label) { return }   # édition annulée (Échap)
                $p = $script:Profiles[$e.Item]
                $newName = $e.Label.Trim()
                if (-not $newName) { $e.CancelEdit = $true; throw 'Le nom ne peut pas être vide.' }
                if (Test-ProfileNameUsed -Name $newName -Except $p) { $e.CancelEdit = $true; throw "Un profil s'appelle déjà '$newName'." }
                $oldName = $p.Nom
                $p.Nom = $newName
                Export-IPProfile -Path $ProfilePath
                $script:TxtName.Text = $newName
                Write-Log "Profil renommé : '$oldName' -> '$newName'"
                Set-Status "Profil renommé en '$newName'."
            }
        })
    $btnRename.Add_Click({
            if ($script:LvProfiles.SelectedItems.Count) { [void]$script:LvProfiles.Focus(); $script:LvProfiles.SelectedItems[0].BeginEdit() }
        })
    $btnDuplicate.Add_Click({ Invoke-UiAction { Copy-SelectedProfile } })
    $btnUp.Add_Click({ Invoke-UiAction { Move-SelectedProfile -Offset -1 } })
    $btnDown.Add_Click({ Invoke-UiAction { Move-SelectedProfile -Offset 1 } })
    $btnDelete.Add_Click({ Invoke-UiAction { Remove-SelectedProfile } })
    $btnAdd.Add_Click({ Invoke-UiAction { Invoke-AddProfileAction } })
    $btnUpdate.Add_Click({ Invoke-UiAction { Invoke-UpdateProfileAction } })
    $btnClear.Add_Click({
            foreach ($t in @($script:TxtName, $script:TxtIp, $script:TxtMask, $script:TxtGateway, $script:TxtDns1, $script:TxtDns2)) { $t.Text = '' }
            $script:DuplicateSource = $null
            $script:LvProfiles.SelectedItems.Clear()
            [void]$script:TxtName.Focus()
        })
    $btnPing.Add_Click({ Invoke-UiAction { Test-HostReachable } })
    $script:TxtPing.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Return') { $e.SuppressKeyPress = $true; Invoke-UiAction { Test-HostReachable } } })
    $form.Add_FormClosing({ $script:DhcpTimer.Stop() })

    $form.ResumeLayout($true)
    return $form
}
#endregion

#region Traitement principal
Write-Log ("Début par {0}\{1} sur {2} - profils : {3} - carte demandée : {4} - simulation : {5}" -f `
        $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME, $ProfilePath, $(if ($InterfaceAlias) { $InterfaceAlias } else { '(auto)' }), $script:Simulation)
try {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    # Chargement explicite des modules réseau hors simulation : sinon, en -WhatIf, leurs alias
    # internes sont « simulés » et la console se remplit de messages WhatIf parasites.
    # Purement cosmétique : un échec ici n'empêche pas le chargement automatique des modules.
    & { $WhatIfPreference = $false; Import-Module -Name NetAdapter, NetTCPIP, DnsClient, CimCmdlets -ErrorAction SilentlyContinue }
    Enable-DpiAwareness
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $script:Profiles = Import-IPProfile -Path $ProfilePath
    $form = New-MainForm
    Update-ProfileList
    Update-AdapterList -Select $InterfaceAlias
    if ($InterfaceAlias -and (Get-SelectedAlias) -ne $InterfaceAlias) {
        Write-Log "Carte '$InterfaceAlias' introuvable : première carte sélectionnée" -Level WARN
    }
    # Trace de départ : sert de retour arrière (configuration d'origine de la carte).
    if ($script:CurrentConfig) { Write-Log "Configuration initiale de '$($script:CurrentConfig.Alias)' : $(Format-ConfigSummary $script:CurrentConfig)" }
    Set-Status $(if ($script:Simulation) { 'Mode simulation : aucune modification ne sera faite.' } else { "Prêt. Profils : $ProfilePath" })

    [void]$form.ShowDialog()

    # Objet résultat : état final de la carte sélectionnée.
    $script:CurrentConfig | Select-Object Alias, Status, Dhcp, @{ n = 'Adresses'; e = { ($_.Addresses | ForEach-Object { '{0}/{1}' -f $_.IP, $_.Prefix }) -join ', ' } },
        @{ n = 'Passerelle'; e = { $_.Gateways -join ', ' } }, @{ n = 'Dns'; e = { $_.Dns -join ', ' } }
}
catch {
    Write-Log "Échec : $($_.Exception.Message)" -Level ERROR
    # La console est masquée par le lanceur : on affiche aussi l'erreur dans une boîte de dialogue.
    try { [void][System.Windows.Forms.MessageBox]::Show("Erreur : $($_.Exception.Message)`r`n`r`nJournal : $logFile", $script:AppTitle) } catch { Write-Verbose 'Boîte de dialogue indisponible' }
    Write-Error $_ -ErrorAction Continue
    exit 1
}
finally {
    if (Test-Path -Path 'Variable:script:Form') { $script:Form.Dispose() }
    Write-Log 'Fin du script'
}
#endregion
