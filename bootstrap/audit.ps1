Set-StrictMode -Version Latest

function New-GridCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][string]$Reason,
        [ValidateSet('setup', 'online')][string]$Scope = 'setup'
    )
    return [pscustomobject]@{
        name   = $Name
        passed = $Passed
        reason = $Reason
        scope  = $Scope
    }
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
        foreach ($folder in Get-GridEnabledFolders -Context $Context) {
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
    $peerReason = 'peer not evaluated'
    $folderSyncOk = $false
    $folderSyncReason = 'folder sync not evaluated'
    $manifestPath = Find-GridSyncManifestPath -Context $Context
    $isMain = $false
    $seedId = $null
    try {
        if ($binOk -and $idOk) {
            Start-GridSyncthing -Context $Context
            $status = Wait-GridSyncthingReady -Context $Context -TimeoutSeconds 20
            $apiOk = $true
            $myId = [string](Get-GridProperty $status 'myID')
            if (-not [string]::IsNullOrWhiteSpace($manifestPath)) {
                $manifest = Read-GridSyncManifest -Path $manifestPath
                $seedId = [string]$manifest.seedDevice.deviceId
                $isMain = ($seedId -eq $myId)
                if ($isMain) {
                    $cfg = Get-GridSyncthingConfig -Context $Context
                    $others = @($cfg.devices | Where-Object { [string]$_.deviceID -ne $myId })
                    if ($others.Count -eq 0) {
                        $peerConfigured = $false
                        $peerConnected = $false
                        $peerReason = 'seed has no additional peer yet'
                    } else {
                        $peerConfigured = $true
                        $conn = Invoke-GridSyncthingApi -Context $Context -Method GET -Path '/rest/system/connections'
                        $any = $false
                        foreach ($d in $others) {
                            $p = Get-GridProperty $conn.connections ([string]$d.deviceID)
                            if ([bool](Get-GridProperty $p 'connected' $false)) { $any = $true }
                        }
                        $peerConnected = $any
                        $peerReason = $(if ($any) { 'at least one configured peer is connected' } else { 'configured peer(s) not connected' })
                    }
                } else {
                    $peerConfigured = -not [string]::IsNullOrWhiteSpace($seedId)
                    $conn = Invoke-GridSyncthingApi -Context $Context -Method GET -Path '/rest/system/connections'
                    $p = Get-GridProperty $conn.connections $seedId
                    $peerConnected = [bool](Get-GridProperty $p 'connected' $false)
                    $peerReason = $(if ($peerConnected) { "connected to seed $seedId" } else { "seed $seedId not connected; approve this device ID on the seed" })
                }
            } else {
                $peerReason = 'seed manifest missing'
            }
            try {
                $sg = Invoke-GridSyncthingApi -Context $Context -Method GET -Path '/rest/stats/folder'
                $bad = @()
                foreach ($folder in Get-GridEnabledFolders -Context $Context) {
                    $id = [string]$folder.id
                    $entry = Get-GridProperty $sg $id
                    if ($null -eq $entry) { $bad += "$id (not in stats)" }
                }
                $folderSyncOk = ($bad.Count -eq 0)
                $folderSyncReason = $(if ($folderSyncOk) { 'folder IDs present in Syncthing stats' } else { ($bad -join ', ') })
            } catch {
                $folderSyncReason = $_.Exception.Message
            }
        }
    } catch {
        $apiOk = $false
        $peerReason = $_.Exception.Message
    }

    $checks.Add((New-GridCheck -Name 'syncthing-api' -Passed $apiOk -Reason $(if ($apiOk) { "GUI $($Context.GuiAddress) myID=$myId" } else { 'local Syncthing API not reachable' }) -Scope online)) | Out-Null
    $checks.Add((New-GridCheck -Name 'required-peer-configured' -Passed $peerConfigured -Reason $peerReason -Scope online)) | Out-Null
    $checks.Add((New-GridCheck -Name 'required-peer-connected' -Passed $peerConnected -Reason $peerReason -Scope online)) | Out-Null
    $checks.Add((New-GridCheck -Name 'folder-sync' -Passed $folderSyncOk -Reason $folderSyncReason -Scope online)) | Out-Null

    $setupChecks = @($checks | Where-Object { $_.scope -eq 'setup' })
    $onlineChecks = @($checks | Where-Object { $_.scope -eq 'online' })
    $setupComplete = @($setupChecks | Where-Object { -not $_.passed }).Count -eq 0
    $gridOnline = $setupComplete -and (@($onlineChecks | Where-Object { -not $_.passed }).Count -eq 0)

    $failedSetup = @($setupChecks | Where-Object { -not $_.passed })
    $failedOnline = @($onlineChecks | Where-Object { -not $_.passed })
    $overall = 'failed'
    if ($setupComplete -and $gridOnline) { $overall = 'healthy' }
    elseif ($setupComplete) { $overall = 'degraded' }

    return [pscustomobject]@{
        overall       = $overall
        setupComplete = $setupComplete
        gridOnline    = $gridOnline
        checks        = @($checks)
        failedSetup   = $failedSetup
        failedOnline  = $failedOnline
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
        $mark = if ($c.passed) { 'PASS' } else { 'FAIL' }
        Write-Host ("  [{0}] {1} ({2}) - {3}" -f $mark, $c.name, $c.scope, $c.reason)
    }
    if ($Audit.gridOnline) {
        Write-Host ''
        Write-Host 'PERSONAL GRID ONLINE'
    } else {
        Write-Host ''
        Write-Host 'PERSONAL GRID NOT ONLINE'
        if ($Audit.setupComplete) {
            Write-Host 'Local setup is saved. An offline peer or incomplete pairing degrades health without resetting identity.'
        }
    }
}
