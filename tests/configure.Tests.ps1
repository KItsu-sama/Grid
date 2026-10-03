#requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Get-ChildItem -LiteralPath (Join-Path $root 'bootstrap') -Filter '*.ps1' | Sort-Object Name | ForEach-Object {
    . $_.FullName
}

function New-TestConfigureContext {
    param([Parameter(Mandatory = $true)][string]$Name)
    $bootstrapRoot = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Path (Join-Path $bootstrapRoot 'config') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'config\grid.example.json') -Destination (Join-Path $bootstrapRoot 'config\grid.example.json') -Force
    Copy-Item -LiteralPath (Join-Path $root 'config\syncconfig.example.json') -Destination (Join-Path $bootstrapRoot 'config\syncconfig.example.json') -Force
    $context = New-GridContext -LauncherRoot $bootstrapRoot -Command 'setup'
    Set-GridContextRoot -Context $context -GridRoot (Join-Path $TestDrive "$Name-grid") | Out-Null
    $context.Settings.syncthing.folders = @(
        [pscustomobject]@{ id = 'local-only'; name = 'LocalOnly'; enabled = $true; type = 'sendreceive' }
    )
    return $context
}

Describe 'Syncthing configuration' {
    It 'uses the seed manifest folders instead of local folder IDs' {
        $context = New-TestConfigureContext -Name 'manifest-folders'
        $manifest = [pscustomobject]@{
            schemaVersion = 1
            seedDevice = [pscustomobject]@{ name = 'Seed'; deviceId = 'SEED-ID' }
            folders = @([pscustomobject]@{ id = 'shared-id'; name = 'Shared'; type = 'sendreceive' })
        }
        Write-GridJsonAtomic -Path $context.SyncConfigPath -InputObject $manifest
        Mock Invoke-GridSyncthingApi {
            [pscustomobject]@{ id = 'default'; label = 'default'; path = ''; type = 'sendreceive'; maxConflicts = 10; devices = @() }
        }
        $config = [pscustomobject]@{ folders = @() }
        $result = Set-GridSyncthingFolders -Context $context -Config $config -Manifest $manifest -LocalId 'LOCAL-ID'
        $result.folders.Count | Should Be 1
        $result.folders[0].id | Should Be 'shared-id'
        $result.folders[0].label | Should Be 'Shared'
        $result.folders[0].type | Should Be 'sendonly'
        $result.folders[0].maxConflicts | Should Be 10
        (Test-Path -LiteralPath (Join-Path (Get-GridSyncRoot -Context $context) 'Shared')) | Should Be $true
        Assert-MockCalled Invoke-GridSyncthingApi -Times 1 -ParameterFilter { $Path -eq '/rest/config/defaults/folder' }
    }

    It 'approves the named peer and shares only manifest folders on the seed' {
        $context = New-TestConfigureContext -Name 'approve-peer'
        $context.CanBeMain = $true
        $script:testSeedId = 'AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA'
        $script:testPeerId = 'BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB'
        $manifest = [pscustomobject]@{
            schemaVersion = 1
            seedDevice = [pscustomobject]@{ name = 'Seed'; deviceId = $script:testSeedId }
            folders = @([pscustomobject]@{ id = 'shared-id'; name = 'Shared'; type = 'sendreceive' })
        }
        Write-GridJsonAtomic -Path $context.SyncConfigPath -InputObject $manifest
        $script:testSyncthingConfig = [pscustomobject]@{
            devices = @()
            folders = @([pscustomobject]@{ id = 'shared-id'; devices = @() })
        }
        $script:savedSyncthingConfig = $null
        Mock Get-GridSyncthingDeviceId { $script:testSeedId }
        Mock Get-GridSyncthingConfig { $script:testSyncthingConfig }
        Mock Save-GridSyncthingConfig { $script:savedSyncthingConfig = $Config }
        Mock Write-GridLog {}

        Add-GridSyncthingPeer -Context $context -PeerId $script:testPeerId -PeerName 'Laptop'

        @($script:savedSyncthingConfig.devices | Where-Object { $_.deviceID -eq $script:testPeerId }).Count | Should Be 1
        @($script:savedSyncthingConfig.folders[0].devices | Where-Object { $_.deviceID -eq $script:testPeerId }).Count | Should Be 1
        $script:savedSyncthingConfig.devices[0].autoAcceptFolders | Should Be $false
    }

    It 'refuses peer approval when can_be_main is false' {
        $context = New-TestConfigureContext -Name 'unauthorized-approval'
        $manifest = [pscustomobject]@{
            schemaVersion = 1
            seedDevice = [pscustomobject]@{ name = 'Seed'; deviceId = 'SEED-ID' }
            folders = @([pscustomobject]@{ id = 'shared-id'; name = 'Shared'; type = 'sendreceive' })
        }
        Write-GridJsonAtomic -Path $context.SyncConfigPath -InputObject $manifest
        { Add-GridSyncthingPeer -Context $context -PeerId 'BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB' -PeerName 'Laptop' } | Should Throw 'can_be_main is false'
    }

    It 'preserves previously approved seed peers during folder repair' {
        $context = New-TestConfigureContext -Name 'repair-seed-shares'
        $context.CanBeMain = $true
        $seedId = 'LOCAL-ID'
        $peerId = 'BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB'
        $manifest = [pscustomobject]@{
            schemaVersion = 1
            seedDevice = [pscustomobject]@{ name = 'Seed'; deviceId = $seedId }
            folders = @([pscustomobject]@{ id = 'shared-id'; name = 'Shared'; type = 'sendreceive' })
        }
        $existingFolder = [pscustomobject]@{
            id = 'shared-id'
            path = ''
            label = ''
            type = 'sendreceive'
            paused = $false
            devices = @([pscustomobject]@{ deviceID = $seedId }, [pscustomobject]@{ deviceID = $peerId })
        }
        $config = [pscustomobject]@{ folders = @($existingFolder) }

        $result = Set-GridSyncthingFolders -Context $context -Config $config -Manifest $manifest -LocalId $seedId

        @($result.folders[0].devices | Where-Object { $_.deviceID -eq $peerId }).Count | Should Be 1
        $result.folders[0].type | Should Be 'sendreceive'
    }

    It 'does not broaden peer shares between seed folders during repair' {
        $context = New-TestConfigureContext -Name 'repair-folder-acls'
        $context.CanBeMain = $true
        $seedId = 'LOCAL-ID'
        $peerA = 'BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB'
        $peerB = 'CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC'
        $manifest = [pscustomobject]@{
            schemaVersion = 1
            seedDevice = [pscustomobject]@{ name = 'Seed'; deviceId = $seedId }
            folders = @(
                [pscustomobject]@{ id = 'folder-a'; name = 'FolderA'; type = 'sendreceive' },
                [pscustomobject]@{ id = 'folder-b'; name = 'FolderB'; type = 'sendreceive' }
            )
        }
        $config = [pscustomobject]@{
            folders = @(
                [pscustomobject]@{ id = 'folder-a'; path = ''; label = ''; type = 'sendreceive'; paused = $false; devices = @([pscustomobject]@{ deviceID = $seedId }, [pscustomobject]@{ deviceID = $peerA }) },
                [pscustomobject]@{ id = 'folder-b'; path = ''; label = ''; type = 'sendreceive'; paused = $false; devices = @([pscustomobject]@{ deviceID = $seedId }, [pscustomobject]@{ deviceID = $peerB }) }
            )
        }

        $result = Set-GridSyncthingFolders -Context $context -Config $config -Manifest $manifest -LocalId $seedId

        @($result.folders[0].devices | Where-Object { $_.deviceID -eq $peerA }).Count | Should Be 1
        @($result.folders[0].devices | Where-Object { $_.deviceID -eq $peerB }).Count | Should Be 0
        @($result.folders[1].devices | Where-Object { $_.deviceID -eq $peerB }).Count | Should Be 1
        @($result.folders[1].devices | Where-Object { $_.deviceID -eq $peerA }).Count | Should Be 0
    }
}