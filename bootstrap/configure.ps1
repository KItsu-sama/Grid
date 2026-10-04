#/// configure.ps1 - configure Syncthing and the personal grid
Set-StrictMode -Version Latest

function Read-GridDeviceDocument {
    param([Parameter(Mandatory = $true)]$Context)
    if (Test-Path -LiteralPath $Context.DevicePath) {
        return (ConvertFrom-GridJson -Path $Context.DevicePath -Label 'device.json')
    }
    return $null
}

function Get-GridTailscaleEmailFromFile {
    param([Parameter(Mandatory = $true)]$Context)
    $path = Join-Path $Context.BootstrapRoot 'tailscale.txt'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $value = (Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    return $value
}

function Save-GridDeviceDocument {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$DeviceId,
        [bool]$IsMain
    )
    $existing = Read-GridDeviceDocument -Context $Context
    $role = [string](Get-GridProperty $Context.Settings.device 'role' 'development')
    $syncEnabled = [bool](Get-GridProperty $Context.Settings.syncthing 'enabled' $true)
    $tailscaleEmail = Get-GridTailscaleEmailFromFile -Context $Context
    $gridDeviceId = [string](Get-GridProperty $existing 'gridDeviceId' '')
    if ([string]::IsNullOrWhiteSpace($gridDeviceId)) {
        $gridDeviceId = [guid]::NewGuid().ToString('N')
    }
    $gridRole = [string](Get-GridProperty $Context.Settings.device 'role' '').ToUpperInvariant()
    if ($IsMain) {
        $gridRole = 'MAIN'
    } elseif ($gridRole -notin @('WORKER', 'CLIENT')) {
        $gridRole = 'CLIENT'
    }
    $doc = [pscustomobject]@{
        schemaVersion     = 1
        gridDeviceId      = $gridDeviceId
        gridRole          = $gridRole
        deviceName        = $Context.DeviceName
        role              = $role
        isMain            = $IsMain
        isRoot            = [bool]$Context.IsRoot
        mode              = $Context.Mode
        syncEnabled       = $syncEnabled
        syncthingDeviceId = $DeviceId
        gridRoot          = $Context.GridRoot
        tailscaleEmail    = $tailscaleEmail
        updatedAt         = (Get-GridNowUtc)
    }
    if ($null -ne $existing) {
        $created = Get-GridProperty $existing 'createdAt'
        if ($created) { $doc | Add-Member -NotePropertyName createdAt -NotePropertyValue $created }
    } else {
        $doc | Add-Member -NotePropertyName createdAt -NotePropertyValue (Get-GridNowUtc)
    }
    Write-GridJsonAtomic -Path $Context.DevicePath -InputObject $doc
    return $doc
}

function Find-GridSyncManifestPath {
    param([Parameter(Mandatory = $true)]$Context)
    $paths = @(
        $Context.SyncConfigPath,
        (Get-GridUsbSyncConfigPath -Context $Context)
    )
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Read-GridSyncManifest {
    param([Parameter(Mandatory = $true)][string]$Path)
    $doc = ConvertFrom-GridJson -Path $Path -Label 'syncconfig.json'
    $schema = Get-GridProperty $doc 'schemaVersion' 1
    if ([int]$schema -ne 1) {
        throw "Unsupported syncconfig schemaVersion '$schema' in $Path."
    }
    return $doc
}

function Get-GridSyncFolders {
    param(
        [Parameter(Mandatory = $true)]$Context,
        $Manifest
    )
    if ($null -eq $Manifest) {
        $path = Find-GridSyncManifestPath -Context $Context
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $Manifest = Read-GridSyncManifest -Path $path
        }
    }
    if ($null -eq $Manifest) {
        return @(Get-GridEnabledFolders -Context $Context)
    }
    $folders = @()
    foreach ($folder in @(Get-GridProperty $Manifest 'folders' @())) {
        if (-not [bool](Get-GridProperty $folder 'enabled' $true)) { continue }
        $id = [string](Get-GridProperty $folder 'id')
        $name = [string](Get-GridProperty $folder 'name')
        if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($name)) {
            throw 'Every enabled syncconfig folder must have a non-empty id and name.'
        }
        $folders += [pscustomobject]@{
            id = $id
            name = $name
            enabled = $true
            type = [string](Get-GridProperty $folder 'type' 'sendreceive')
        }
    }
    if ($folders.Count -eq 0) { throw 'The seed syncconfig manifest contains no enabled folders.' }
    return $folders
}

function Test-GridManifestHasSecrets {
    param([Parameter(Mandatory = $true)]$Manifest)
    $json = ConvertTo-GridJson -InputObject $Manifest
    if ($json -match '(?i)(apikey|apiKey|authkey|auth-key|privateKey|privatekey)') {
        throw 'Refusing to write syncconfig.json because it would contain a key/secret field. The seed manifest must only contain device IDs and folder presets.'
    }
}

function New-GridSyncManifest {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$DeviceId
    )
    $example = ConvertFrom-GridJson -Path (Get-GridExampleSyncConfigPath -Context $Context) -Label 'syncconfig.example.json'
    $example.seedDevice.name = $Context.DeviceName
    $example.seedDevice.deviceId = $DeviceId
    $device = Read-GridDeviceDocument -Context $Context
    $example.seedDevice.gridDeviceId = [string](Get-GridProperty $device 'gridDeviceId' '')
    $example.folders = @(
        foreach ($folder in Get-GridEnabledFolders -Context $Context) {
            [pscustomobject]@{
                id = [string]$folder.id
                name = [string]$folder.name
                type = [string](Get-GridProperty $folder 'type' 'sendreceive')
            }
        }
    )
    $example.syncPeers = @()
    Test-GridManifestHasSecrets -Manifest $example
    Write-GridJsonAtomic -Path $Context.SyncConfigPath -InputObject $example
    $usb = Get-GridUsbSyncConfigPath -Context $Context
    try {
        Write-GridJsonAtomic -Path $usb -InputObject $example
        Write-GridLog -Context $Context -Message "Wrote seed manifest to $usb (gitignored) and $($Context.SyncConfigPath)"
    } catch {
        Write-GridLog -Level WARN -Context $Context -Message "Seed manifest saved under GridRoot but USB copy failed ($usb): $($_.Exception.Message). Copy $($Context.SyncConfigPath) onto the USB before setting up another node."
    }
    return $example
}

function Resolve-GridSyncManifest {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$DeviceId
    )
    $path = Find-GridSyncManifestPath -Context $Context
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        $manifest = Read-GridSyncManifest -Path $path
        $seedId = [string](Get-GridProperty $manifest.seedDevice 'deviceId')
        if ([string]::IsNullOrWhiteSpace($seedId)) {
            throw "Manifest at $path has an empty seedDevice.deviceId."
        }
        if ($path -ne $Context.SyncConfigPath) {
            Write-GridJsonAtomic -Path $Context.SyncConfigPath -InputObject $manifest
        }
        return $manifest
    }
    $deviceDoc = Read-GridDeviceDocument -Context $Context
    $savedId = [string](Get-GridProperty $deviceDoc 'syncthingDeviceId')
    if ($null -ne $deviceDoc -and -not [string]::IsNullOrWhiteSpace($savedId)) {
        $manifest = [pscustomobject]@{
            schemaVersion = 1
            gridName = 'PersonalGrid'
            seedDevice = [pscustomobject]@{ name = [string](Get-GridProperty $deviceDoc 'deviceName' 'seed'); deviceId = $savedId }
            syncPeers = @()
            folders = @(
                foreach ($folder in Get-GridEnabledFolders -Context $Context) {
                    [pscustomobject]@{
                        id = [string]$folder.id
                        name = [string]$folder.name
                        type = [string](Get-GridProperty $folder 'type' 'sendreceive')
                    }
                }
            )
        }
        Write-GridJsonAtomic -Path $Context.SyncConfigPath -InputObject $manifest
        return $manifest
    }
    if ($Context.SeedRequested -or [bool](Get-GridProperty $Context.Settings.device 'isMain' $false)) {
        return (New-GridSyncManifest -Context $Context -DeviceId $DeviceId)
    }
    if ($Context.NonInteractive) {
        throw @"
No seed manifest was found.

Copy syncconfig.json from the first (seed) node onto this USB at:
  $($Context.BootstrapRoot)\config\syncconfig.json

Do not run setup without that file on a second computer — a missing manifest is not a new seed. To create the first node, rerun: .\Grid.ps1 setup -Seed
"@
    }
    Write-Host ''
    Write-Host 'No seed manifest (config/syncconfig.json) was found.'
    Write-Host 'Create THIS computer as the Grid seed? [Y/N]'
    $answer = Read-Host
    if ($answer -match '^(y|yes)$') {
        return (New-GridSyncManifest -Context $Context -DeviceId $DeviceId)
    }
    throw @"
Setup stopped so a second seed is not created by accident.

Copy the seed node's gitignored config/syncconfig.json onto this bootstrap, then rerun .\Grid.ps1 setup
"@
}

function Show-GridDeviceId {
    param(
        [Parameter(Mandatory = $true)][string]$DeviceId,
        [bool]$IsSeed
    )
    Write-Host ''
    Write-Host '============================================================'
    if ($IsSeed) {
        Write-Host '  SEED NODE Syncthing device ID'
    } else {
        Write-Host '  THIS NODE Syncthing device ID'
        Write-Host '  Approve this ID once on the seed node.'
    }
    Write-Host "  $DeviceId"
    Write-Host '============================================================'
    Write-Host 'A device ID identifies a node; it does not authorize it.'
    Write-Host ''
}

function Get-GridSyncthingConfig {
    param([Parameter(Mandatory = $true)]$Context)
    return (Invoke-GridSyncthingApi -Context $Context -Method GET -Path '/rest/config')
}

function Get-GridSyncthingFolderDefaults {
    param([Parameter(Mandatory = $true)]$Context)
    $defaults = Invoke-GridSyncthingApi -Context $Context -Method GET -Path '/rest/config/defaults/folder'
    if ($null -eq $defaults) {
        throw 'Syncthing did not return /rest/config/defaults/folder; refusing to create an incomplete folder config.'
    }
    return $defaults
}

function Save-GridSyncthingConfig {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Config
    )
    Invoke-GridSyncthingApi -Context $Context -Method PUT -Path '/rest/config' -Body $Config | Out-Null
}

function Set-GridSyncthingLocalGui {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Config
    )
    $gui = Get-GridProperty $Config 'gui'
    if ($null -eq $gui) { return $Config }
    $gui | Add-Member -NotePropertyName address -NotePropertyValue $Context.GuiAddress -Force
    $gui | Add-Member -NotePropertyName insecureSkipHostcheck -NotePropertyValue $true -Force
    return $Config
}

function Set-GridSyncthingDevices {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$LocalId
    )
    $devices = @()
    if ($null -ne (Get-GridProperty $Config 'devices')) {
        $devices = @($Config.devices)
    }
    $toAdd = @(
        [pscustomobject]@{ Id = $LocalId; Name = $Context.DeviceName }
    )
    $seedId = [string]$Manifest.seedDevice.deviceId
    $seedName = [string](Get-GridProperty $Manifest.seedDevice 'name' 'seed')
    if (-not [string]::IsNullOrWhiteSpace($seedId) -and $seedId -ne $LocalId) {
        $toAdd += [pscustomobject]@{ Id = $seedId; Name = $seedName }
    }
    foreach ($entry in $toAdd) {
        if ([string]::IsNullOrWhiteSpace($entry.Id)) { continue }
        $existing = @($devices | Where-Object { [string]$_.deviceID -eq $entry.Id })
        if ($existing.Count -gt 0) {
            $existing[0].name = $entry.Name
            continue
        }
        $devices += [pscustomobject]@{
            deviceID               = $entry.Id
            name                   = $entry.Name
            introducer             = $false
            skipIntroductionRemovals = $false
            paused                 = $false
            autoAcceptFolders      = $false
        }
        if ($entry.Id -ne $LocalId) {
            Write-GridLog -Context $Context -Message "Configured peer device $($entry.Name) ($($entry.Id)). It still must be approved on the other node."
        }
    }
    $Config.devices = $devices
    return $Config
}

function Set-GridSyncthingFolders {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$LocalId
    )
    $folders = @()
    if ($null -ne (Get-GridProperty $Config 'folders')) {
        $folders = @($Config.folders)
    }
    $seedId = [string]$Manifest.seedDevice.deviceId
    $wanted = Get-GridSyncFolders -Context $Context -Manifest $Manifest
    foreach ($folder in $wanted) {
        $id = [string]$folder.id
        $shareWith = @($LocalId)
        if (-not [string]::IsNullOrWhiteSpace($seedId) -and $seedId -ne $LocalId) {
            $shareWith += $seedId
        }
        $path = Get-GridFolderPath -Context $Context -Folder $folder
        $folderType = [string](Get-GridProperty $folder 'type' 'sendreceive')
        if ($seedId -ne $LocalId -and -not [bool]$Context.CanBeMain) {
            $folderType = 'sendonly'
        }
        Initialize-GridDirectory -Path $path
        $existing = @($folders | Where-Object { [string]$_.id -eq $id })
        if ($seedId -eq $LocalId -and $existing.Count -gt 0) {
            foreach ($device in @((Get-GridProperty $existing[0] 'devices' @()))) {
                $deviceId = [string](Get-GridProperty $device 'deviceID')
                if (-not [string]::IsNullOrWhiteSpace($deviceId) -and $shareWith -notcontains $deviceId) {
                    $shareWith += $deviceId
                }
            }
        }
        $devices = @()
        foreach ($did in $shareWith) {
            $devices += [pscustomobject]@{ deviceID = $did; introducedBy = '' }
        }
        if ($existing.Count -gt 0) {
            $existing[0].path = $path
            $existing[0].label = [string]$folder.name
            $existing[0].type = $folderType
            $existing[0].paused = $false
            $existing[0].devices = $devices
        } else {
            $newFolder = Get-GridSyncthingFolderDefaults -Context $Context
            $newFolder | Add-Member -NotePropertyName id -NotePropertyValue $id -Force
            $newFolder | Add-Member -NotePropertyName label -NotePropertyValue ([string]$folder.name) -Force
            $newFolder | Add-Member -NotePropertyName path -NotePropertyValue $path -Force
            $newFolder | Add-Member -NotePropertyName type -NotePropertyValue $folderType -Force
            $newFolder | Add-Member -NotePropertyName devices -NotePropertyValue $devices -Force
            $newFolder | Add-Member -NotePropertyName paused -NotePropertyValue $false -Force
            $folders += $newFolder
        }
    }
    $Config.folders = $folders
    return $Config
}

function Wait-GridPeerConnection {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$PeerId,
        [int]$TimeoutSeconds = 600
    )
    if ([string]::IsNullOrWhiteSpace($PeerId)) { return $false }
    Write-GridLog -Context $Context -Message "Waiting up to ${TimeoutSeconds}s for Syncthing connection to $PeerId (approve this node on the peer if you have not)."
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $remaining = [Math]::Max(1, [Math]::Min(5, [Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds)))
            $conn = Invoke-GridSyncthingApi -Context $Context -Method GET -Path '/rest/system/connections' -TimeoutSec $remaining -RetryCount 0
            $connections = Get-GridProperty $conn 'connections'
            if ($null -ne $connections) {
                $peer = Get-GridProperty $connections $PeerId
                $connected = [bool](Get-GridProperty $peer 'connected' $false)
                if ($connected) {
                    Write-GridLog -Context $Context -Message "Connected to peer $PeerId"
                    return $true
                }
            }
        } catch {
        }
        Start-Sleep -Seconds 5
    }
    Write-GridLog -Level WARN -Context $Context -Message "Peer $PeerId is not connected yet. Setup is saved; rerun status/audit after you approve the device ID on the other node."
    return $false
}

function Invoke-GridConfigureStage {
    param([Parameter(Mandatory = $true)]$Context)
    $deviceId = Get-GridSyncthingDeviceId -Context $Context
    $manifest = Resolve-GridSyncManifest -Context $Context -DeviceId $deviceId
    $seedId = [string]$manifest.seedDevice.deviceId
    $isMain = ($seedId -eq $deviceId)
    if (($Context.SeedRequested -or $isMain) -and -not [bool]$Context.CanBeMain) {
        throw 'This device is not authorized to become or act as the Grid main. Set can_be_main=true only on the trusted main device.'
    }
    if ($Context.SeedRequested -and -not $isMain) {
        throw "This node used -Seed but the existing manifest seed ID is $seedId, which does not match $deviceId. Remove -Seed and pair as a second node, or copy the correct seed identity."
    }
    Show-GridDeviceId -DeviceId $deviceId -IsSeed $isMain
    Save-GridDeviceDocument -Context $Context -DeviceId $deviceId -IsMain $isMain | Out-Null
    $config = Get-GridSyncthingConfig -Context $Context
    $config = Set-GridSyncthingLocalGui -Context $Context -Config $config
    $config = Set-GridSyncthingDevices -Context $Context -Config $config -Manifest $manifest -LocalId $deviceId
    $config = Set-GridSyncthingFolders -Context $Context -Config $config -Manifest $manifest -LocalId $deviceId
    Save-GridSyncthingConfig -Context $Context -Config $config
    Protect-GridSensitivePath -Path $Context.SyncthingHome
    Copy-GridBootstrapSnapshot -Context $Context
    if (-not $isMain) {
        Wait-GridPeerConnection -Context $Context -PeerId $seedId | Out-Null
    } else {
        Write-GridLog -Context $Context -Message 'This node is the seed. Transfer config/syncconfig.json with the USB to additional machines. Approve their device IDs here once.'
    }
}

function Set-GridSyncPeerAssociation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$SyncthingDeviceId,
        [Parameter(Mandatory = $true)][string]$PeerName,
        [string]$GridDeviceId
    )
    $peers = @((Get-GridProperty $Manifest 'syncPeers' @()))
    $peer = @($peers | Where-Object { [string]$_.syncthingDeviceId -eq $SyncthingDeviceId }) | Select-Object -First 1
    if ($null -eq $peer) {
        $peer = [pscustomobject]@{ name = $PeerName; syncthingDeviceId = $SyncthingDeviceId; gridDeviceId = $GridDeviceId }
        $peers += $peer
    } else {
        $peer.name = $PeerName
        if (-not [string]::IsNullOrWhiteSpace($GridDeviceId)) { $peer.gridDeviceId = $GridDeviceId }
    }
    $Manifest | Add-Member -NotePropertyName syncPeers -NotePropertyValue $peers -Force
    Test-GridManifestHasSecrets -Manifest $Manifest
    Write-GridJsonAtomic -Path $Context.SyncConfigPath -InputObject $Manifest
    $usbPath = Get-GridUsbSyncConfigPath -Context $Context
    if ([System.IO.Path]::GetFullPath($usbPath) -ne [System.IO.Path]::GetFullPath($Context.SyncConfigPath)) {
        try {
            Write-GridJsonAtomic -Path $usbPath -InputObject $Manifest
        } catch {
            Write-GridLog -Level WARN -Context $Context -Message "Sync peer association saved under GridRoot but USB manifest update failed ($usbPath)."
        }
    }
}

function Add-GridSyncthingPeer {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$PeerId,
        [Parameter(Mandatory = $true)][string]$PeerName,
        [string]$GridDeviceId
    )
    if ([string]::IsNullOrWhiteSpace($PeerId) -or $PeerId -notmatch '^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$') {
        throw 'PeerId must be a complete Syncthing device ID.'
    }
    if ([string]::IsNullOrWhiteSpace($PeerName)) { throw 'PeerName cannot be empty.' }
    if (-not [string]::IsNullOrWhiteSpace($GridDeviceId) -and $GridDeviceId -notmatch '^[a-fA-F0-9]{32}$') {
        throw 'GridDeviceId must be a 32-character PersonalGrid device ID.'
    }
    $manifestPath = Find-GridSyncManifestPath -Context $Context
    if ([string]::IsNullOrWhiteSpace($manifestPath)) { throw 'Cannot approve a peer because the seed syncconfig manifest is missing.' }
    $manifest = Read-GridSyncManifest -Path $manifestPath
    if (-not [bool]$Context.CanBeMain) {
        throw 'This device cannot approve peers because can_be_main is false.'
    }
    $localId = Get-GridSyncthingDeviceId -Context $Context
    if ($PeerId -eq $localId) { throw "The peer device ID is this node's own ID." }
    if ([string]$manifest.seedDevice.deviceId -ne $localId) {
        throw 'Peer approval is only available on the seed device named in syncconfig.json.'
    }
    foreach ($mappedPeer in @((Get-GridProperty $manifest 'syncPeers' @()))) {
        $mappedSyncId = [string](Get-GridProperty $mappedPeer 'syncthingDeviceId' '')
        $mappedGridId = [string](Get-GridProperty $mappedPeer 'gridDeviceId' '')
        if ($mappedSyncId -eq $PeerId -and -not [string]::IsNullOrWhiteSpace($mappedGridId) -and
            -not [string]::IsNullOrWhiteSpace($GridDeviceId) -and $mappedGridId -ne $GridDeviceId) {
            throw 'This Syncthing device ID is already associated with a different Grid device ID.'
        }
        if (-not [string]::IsNullOrWhiteSpace($GridDeviceId) -and $mappedGridId -eq $GridDeviceId -and $mappedSyncId -ne $PeerId) {
            throw 'This Grid device ID is already associated with a different Syncthing device ID.'
        }
    }

    $config = Get-GridSyncthingConfig -Context $Context
    $devices = @((Get-GridProperty $config 'devices' @()))
    $existingDevice = @($devices | Where-Object { [string]$_.deviceID -eq $PeerId }) | Select-Object -First 1
    if ($null -eq $existingDevice) {
        $devices += [pscustomobject]@{
            deviceID = $PeerId
            name = $PeerName
            addresses = @('dynamic')
            compression = 'metadata'
            introducer = $false
            skipIntroductionRemovals = $false
            paused = $false
            autoAcceptFolders = $false
        }
    } else {
        $existingDevice.name = $PeerName
    }
    $config.devices = $devices

    $folders = @((Get-GridProperty $config 'folders' @()))
    foreach ($folder in Get-GridSyncFolders -Context $Context -Manifest $manifest) {
        $entry = @($folders | Where-Object { [string]$_.id -eq [string]$folder.id }) | Select-Object -First 1
        if ($null -eq $entry) { throw "Seed folder '$($folder.id)' is not configured locally. Run repair before approving this peer." }
        $folderDevices = @((Get-GridProperty $entry 'devices' @()))
        if (@($folderDevices | Where-Object { [string]$_.deviceID -eq $PeerId }).Count -eq 0) {
            $folderDevices += [pscustomobject]@{ deviceID = $PeerId; introducedBy = '' }
        }
        $entry.devices = $folderDevices
    }
    $config.folders = $folders
    Save-GridSyncthingConfig -Context $Context -Config $config
    Set-GridSyncPeerAssociation -Context $Context -Manifest $manifest -SyncthingDeviceId $PeerId -PeerName $PeerName -GridDeviceId $GridDeviceId
    Write-GridLog -Context $Context -Message "Approved peer $PeerName ($PeerId) and shared the seed manifest folders."
}
