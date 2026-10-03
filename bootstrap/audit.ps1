#/// audit.ps1 - audit the health of the personal grid
Set-StrictMode -Version Latest

function New-GridCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][string]$Reason,
        [switch]$Pending,
        [ValidateSet('setup', 'online')][string]$Scope = 'setup'
    )
    return [pscustomobject]@{
        name   = $Name
        passed = $Passed
        pending = [bool]$Pending
        reason = $Reason
        scope  = $Scope
    }
}

function Get-GridFolderSyncIssue {
    param($Status)
    if ($null -eq $Status) { return 'folder status unavailable' }

    $state = [string](Get-GridProperty $Status 'state')
    $need = Get-GridProperty $Status 'needTotalItems'
    $pullErrors = Get-GridProperty $Status 'pullErrors'
    if ([string]::IsNullOrWhiteSpace($state) -or $null -eq $need -or $null -eq $pullErrors) {
        return 'folder status response is missing state, needTotalItems, or pullErrors'
    }

    if ($state -in @('scanning', 'syncing') -and [long]$pullErrors -eq 0) {
        return "pending: state=$state needTotalItems=$need pullErrors=$pullErrors"
    }
    if ($state -ne 'idle' -or [long]$need -ne 0 -or [long]$pullErrors -ne 0) {
        return "state=$state needTotalItems=$need pullErrors=$pullErrors"
    }
    return $null
}

function Get-GridFolderSharingIssue {
    param($FolderConfig, [string[]]$ConnectedPeerIds)
    if ($null -eq $FolderConfig) { return 'folder is not configured in Syncthing' }
    if (@($ConnectedPeerIds).Count -eq 0) { return 'no connected peer to verify folder sharing against' }

    $folderPeerIds = @(
        (Get-GridProperty $FolderConfig 'devices' @()) |
            ForEach-Object { [string](Get-GridProperty $_ 'deviceID') }
    )
    foreach ($peerId in $ConnectedPeerIds) {
        if ($folderPeerIds -contains $peerId) { return $null }
    }
    return 'folder is not shared with a connected peer'
}

function Invoke-GridAudit {
    param([Parameter(Mandatory = $true)]$Context)
    $checks = New-Object System.Collections.Generic.List[object]

    $rootOk = -not [string]::IsNullOrWhiteSpace($Context.GridRoot) -and (Test-Path -LiteralPath $Context.GridRoot)
    $checks.Add((New-GridCheck -Name 'grid-root' -Passed $rootOk -Reason $(if ($rootOk) { $Context.GridRoot } else { 'GridRoot missing' }))) | Out-Null

    $deviceOk = (Test-Path -LiteralPath $Context.DevicePath)
    $checks.Add((New-GridCheck -Name 'device-json' -Passed $deviceOk -Reason $(if ($deviceOk) { $Context.DevicePath } else { 'device.json missing' }))) | Out-Null

    $idOk = Get-GridSyncthingIdentityExists -Context $Context
    $checks.Add((New-GridCheck -Name 'syncthing-identity' -Passed $idOk -Reason $(if ($idOk) { 'cert/key present under .grid\syncthing' } else { 'Syncthing identity files missing' }))) | Out-Null

    $binOk = (Test-Path -LiteralPath $Context.SyncthingBin)
    $checks.Add((New-GridCheck -Name 'syncthing-binary' -Passed $binOk -Reason $(if ($binOk) { $Context.SyncthingBin } else { 'bin\syncthing.exe missing' }))) | Out-Null

    $folderFail = @()
    if ($rootOk) {
        foreach ($folder in Get-GridSyncFolders -Context $Context) {
            $p = Get-GridFolderPath -Context $Context -Folder $folder
            if (-not (Test-Path -LiteralPath $p)) { $folderFail += $folder.name }
        }
    }
    $foldersOk = ($folderFail.Count -eq 0 -and $rootOk)
    $checks.Add((New-GridCheck -Name 'sync-folders' -Passed $foldersOk -Reason $(if ($foldersOk) { 'enabled folders exist' } else { 'missing: ' + ($folderFail -join ', ') }))) | Out-Null

    $tsEnabled = [bool](Get-GridProperty $Context.Settings.tailscale 'enabled' $true)
    $ts = Get-GridTailscaleStatus
    $tsInstalled = $ts.Installed
    $tsBackend = if ($tsEnabled) { Get-GridTailscaleBackendState } else { 'disabled' }
    $tsConnected = (-not $tsEnabled) -or ($tsBackend -eq 'Running')
    $checks.Add((New-GridCheck -Name 'tailscale-installed' -Passed (-not $tsEnabled -or $tsInstalled) -Reason $(if ($tsInstalled) { 'Tailscale present' } else { 'Tailscale not installed' }))) | Out-Null
    $checks.Add((New-GridCheck -Name 'tailscale-connected' -Passed $tsConnected -Reason "backend=$tsBackend address=$(Get-GridTailscaleAddress)" -Scope online)) | Out-Null

    $apiOk = $false
    $myId = $null
    $peerConfigured = $false
    $peerConnected = $false
    $connectedPeerIds = @()
    $syncthingConfig = $null
    $peerReason = 'peer not evaluated'
    $folderSyncOk = $false
    $folderSyncPending = $false
    $folderSyncReason = 'folder sync not evaluated'
    $manifestPath = Find-GridSyncManifestPath -Context $Context
    $isMain = $false
    $seedId = $null
    try {
        if ($binOk -and $idOk) {
            $status = Wait-GridSyncthingReady -Context $Context -TimeoutSeconds 20
            $apiOk = $true
            $myId = [string](Get-GridProperty $status 'myID')
            if (-not [string]::IsNullOrWhiteSpace($manifestPath)) {
                $manifest = Read-GridSyncManifest -Path $manifestPath
                $seedId = [string]$manifest.seedDevice.deviceId
                $isMain = ($seedId -eq $myId)
                if ($isMain) {
                    $syncthingConfig = Get-GridSyncthingConfig -Context $Context
                    $others = @($syncthingConfig.devices | Where-Object { [string]$_.deviceID -ne $myId })
                    if ($others.Count -eq 0) {
                        $peerConfigured = $false
                        $peerConnected = $false
                        $peerReason = 'seed has no additional peer yet'
                    } else {
                        $peerConfigured = $true
                        $conn = Invoke-GridSyncthingApi -Context $Context -Method GET -Path '/rest/system/connections'
                        foreach ($d in $others) {
                            $p = Get-GridProperty $conn.connections ([string]$d.deviceID)
                            if ([bool](Get-GridProperty $p 'connected' $false)) { $connectedPeerIds += [string]$d.deviceID }
                        }
                        $peerConnected = ($connectedPeerIds.Count -gt 0)
                        $peerReason = $(if ($peerConnected) { 'at least one configured peer is connected' } else { 'configured peer(s) not connected' })
                    }
                } else {
                    $peerConfigured = -not [string]::IsNullOrWhiteSpace($seedId)
                    $conn = Invoke-GridSyncthingApi -Context $Context -Method GET -Path '/rest/system/connections'
                    $p = Get-GridProperty $conn.connections $seedId
                    $peerConnected = [bool](Get-GridProperty $p 'connected' $false)
                    if ($peerConnected) { $connectedPeerIds += $seedId }
                    $peerReason = $(if ($peerConnected) { "connected to seed $seedId" } else { "seed $seedId not connected; approve this device ID on the seed" })
                }
            } else {
                $peerReason = 'seed manifest missing'
            }
            $bad = @()
            $pendingFolders = @()
            if ($null -eq $syncthingConfig) { $syncthingConfig = Get-GridSyncthingConfig -Context $Context }
            foreach ($folder in Get-GridSyncFolders -Context $Context) {
                $id = [string]$folder.id
                try {
                    $configuredFolder = @($syncthingConfig.folders | Where-Object { [string]$_.id -eq $id }) | Select-Object -First 1
                    $sharingIssue = Get-GridFolderSharingIssue -FolderConfig $configuredFolder -ConnectedPeerIds $connectedPeerIds
                    if ($null -ne $sharingIssue) {
                        $bad += "$id ($sharingIssue)"
                        continue
                    }
                    $encodedId = [System.Uri]::EscapeDataString($id)
                    $folderStatus = Invoke-GridSyncthingApi -Context $Context -Method GET -Path "/rest/db/status?folder=$encodedId"
                    $issue = Get-GridFolderSyncIssue -Status $folderStatus
                    if ($null -ne $issue -and $issue.StartsWith('pending:')) {
                        $pendingFolders += "$id ($issue)"
                    } elseif ($null -ne $issue) {
                        $bad += "$id ($issue)"
                    }
                } catch {
                    $bad += "$id ($($_.Exception.Message))"
                }
            }
            $folderSyncOk = ($bad.Count -eq 0 -and $pendingFolders.Count -eq 0)
            $folderSyncPending = ($bad.Count -eq 0 -and $pendingFolders.Count -gt 0)
            if ($folderSyncOk) {
                $folderSyncReason = 'all enabled folders are idle, complete, and have no pull errors'
            } elseif ($folderSyncPending) {
                $folderSyncReason = $pendingFolders -join ', '
            } else {
                $folderSyncReason = $bad -join ', '
            }
        }
    } catch {
        $apiOk = $false
        $peerReason = $_.Exception.Message
    }

    $checks.Add((New-GridCheck -Name 'syncthing-api' -Passed $apiOk -Reason $(if ($apiOk) { "GUI $($Context.GuiAddress) myID=$myId" } else { 'local Syncthing API not reachable' }) -Scope online)) | Out-Null
    $checks.Add((New-GridCheck -Name 'required-peer-configured' -Passed $peerConfigured -Reason $peerReason -Scope online)) | Out-Null
    $checks.Add((New-GridCheck -Name 'required-peer-connected' -Passed $peerConnected -Reason $peerReason -Scope online)) | Out-Null
    $checks.Add((New-GridCheck -Name 'folder-sync' -Passed $folderSyncOk -Pending:$folderSyncPending -Reason $folderSyncReason -Scope online)) | Out-Null

    $setupChecks = @($checks | Where-Object { $_.scope -eq 'setup' })
    $onlineChecks = @($checks | Where-Object { $_.scope -eq 'online' })
    $setupComplete = @($setupChecks | Where-Object { -not $_.passed -and -not $_.pending }).Count -eq 0
    $failedChecks = @($checks | Where-Object { -not $_.passed -and -not $_.pending })
    $pendingChecks = @($checks | Where-Object { $_.pending })
    $gridOnline = $setupComplete -and (@($failedChecks | Where-Object { $_.scope -eq 'online' }).Count -eq 0) -and (@($pendingChecks | Where-Object { $_.scope -eq 'online' }).Count -eq 0)

    $failedSetup = @($setupChecks | Where-Object { -not $_.passed -and -not $_.pending })
    $failedOnline = @($onlineChecks | Where-Object { -not $_.passed -and -not $_.pending })
    $overall = 'failed'
    if ($setupComplete -and $gridOnline) { $overall = 'healthy' }
    elseif ($setupComplete -and $failedOnline.Count -eq 0 -and $pendingChecks.Count -gt 0) { $overall = 'pending' }
    elseif ($setupComplete) { $overall = 'degraded' }

    return [pscustomobject]@{
        overall       = $overall
        setupComplete = $setupComplete
        gridOnline    = $gridOnline
        checks        = @($checks.ToArray())
        failedSetup   = @($failedSetup)
        failedOnline  = @($failedOnline)
        pendingChecks = @($pendingChecks)
        deviceId      = $myId
        isMain        = $isMain
        gridRoot      = $Context.GridRoot
        mode          = $Context.Mode
    }
}

function Write-GridAuditReport {
    param([Parameter(Mandatory = $true)]$Audit)
    Write-Host ''
    Write-Host "Mode: $($Audit.mode)"
    Write-Host "GridRoot: $($Audit.gridRoot)"
    Write-Host "Overall: $($Audit.overall)"
    Write-Host "Setup complete: $($Audit.setupComplete)"
    Write-Host "Grid online: $($Audit.gridOnline)"
    foreach ($c in $Audit.checks) {
        $mark = if ($c.pending) { 'PENDING' } elseif ($c.passed) { 'PASS' } else { 'FAIL' }
        Write-Host ("  [{0}] {1} ({2}) - {3}" -f $mark, $c.name, $c.scope, $c.reason)
    }
    if ($Audit.gridOnline) {
        Write-Host ''
        Write-Host 'PERSONAL GRID ONLINE'
    } else {
        Write-Host ''
        Write-Host 'PERSONAL GRID NOT ONLINE'
        if ($Audit.overall -eq 'pending') {
            Write-Host 'Folder scanning or synchronization is still in progress; rerun audit after it settles.'
        } elseif ($Audit.setupComplete) {
            Write-Host 'Local setup is saved. An offline peer or incomplete pairing degrades health without resetting identity.'
        }
    }
}
