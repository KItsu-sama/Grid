#requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Get-ChildItem -LiteralPath (Join-Path $root 'bootstrap') -Filter '*.ps1' | Sort-Object Name | ForEach-Object {
    . $_.FullName
}

Describe 'Syncthing folder health' {
    It 'accepts only idle folders with no items needed and no pull errors' {
        $status = [pscustomobject]@{ state = 'idle'; needTotalItems = 0; pullErrors = 0 }
        $issue = Get-GridFolderSyncIssue -Status $status
        $issue | Should Be $null
    }

    It 'reports syncing and scanning folders as pending' {
        foreach ($state in @('syncing', 'scanning')) {
            $status = [pscustomobject]@{ state = $state; needTotalItems = 0; pullErrors = 0 }
            (Get-GridFolderSyncIssue -Status $status) | Should Match "pending: state=$state"
        }
    }

    It 'rejects incomplete and errored folders' {
        $incomplete = [pscustomobject]@{ state = 'idle'; needTotalItems = 2; pullErrors = 0 }
        (Get-GridFolderSyncIssue -Status $incomplete) | Should Match 'needTotalItems=2'

        $errored = [pscustomobject]@{ state = 'idle'; needTotalItems = 0; pullErrors = 1 }
        (Get-GridFolderSyncIssue -Status $errored) | Should Match 'pullErrors=1'
    }

    It 'rejects missing or incomplete status responses' {
        (Get-GridFolderSyncIssue -Status $null) | Should Be 'folder status unavailable'
        $incomplete = [pscustomobject]@{ state = 'idle'; needTotalItems = 0 }
        (Get-GridFolderSyncIssue -Status $incomplete) | Should Match 'missing'
    }

    It 'requires each folder to be shared with a connected peer' {
        $folder = [pscustomobject]@{ devices = @([pscustomobject]@{ deviceID = 'peer-a' }) }
        (Get-GridFolderSharingIssue -FolderConfig $folder -ConnectedPeerIds @('peer-a')) | Should Be $null
        (Get-GridFolderSharingIssue -FolderConfig $folder -ConnectedPeerIds @('peer-b')) | Should Match 'not shared'
        (Get-GridFolderSharingIssue -FolderConfig $null -ConnectedPeerIds @('peer-a')) | Should Match 'not configured'
    }
}

Describe 'Grid audit lifecycle' {
    It 'does not start Syncthing and reports initial scanning as pending' {
        $bootstrapRoot = Join-Path $TestDrive 'audit-bootstrap'
        New-Item -ItemType Directory -Path (Join-Path $bootstrapRoot 'config') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $root 'config\grid.example.json') -Destination (Join-Path $bootstrapRoot 'config\grid.example.json') -Force
        $context = New-GridContext -LauncherRoot $bootstrapRoot -Command 'audit'
        $gridRoot = Join-Path $TestDrive 'audit-grid'
        Set-GridContextRoot -Context $context -GridRoot $gridRoot | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $context.SyncthingHome 'unused') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $gridRoot 'ZinoSync\Shared') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $gridRoot 'bin') -Force | Out-Null
        Set-Content -LiteralPath $context.DevicePath -Value '{}' -Encoding UTF8
        Set-Content -LiteralPath $context.SyncthingBin -Value 'binary' -Encoding UTF8
        $script:auditSeedId = 'AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA'
        $script:auditPeerId = 'BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB'
        $context.Settings.tailscale.enabled = $true
        $context.Settings.syncthing.folders = @([pscustomobject]@{ id = 'local-only'; name = 'LocalOnly'; enabled = $true })
        $manifest = [pscustomobject]@{
            schemaVersion = 1
            seedDevice = [pscustomobject]@{ name = 'Seed'; deviceId = $script:auditSeedId }
            folders = @([pscustomobject]@{ id = 'shared-id'; name = 'Shared'; type = 'sendreceive' })
        }
        Write-GridJsonAtomic -Path $context.SyncConfigPath -InputObject $manifest
        $script:auditConfig = [pscustomobject]@{
            devices = @([pscustomobject]@{ deviceID = $script:auditPeerId })
            folders = @([pscustomobject]@{ id = 'shared-id'; devices = @([pscustomobject]@{ deviceID = $script:auditPeerId }) })
        }
        Mock Get-GridSyncthingIdentityExists { $true }
        Mock Get-GridTailscaleStatus { [pscustomobject]@{ Installed = $true } }
        Mock Get-GridTailscaleBackendState { 'Running' }
        Mock Get-GridTailscaleAddress { '100.64.0.1' }
        Mock Wait-GridSyncthingReady { [pscustomobject]@{ myID = $script:auditSeedId } }
        Mock Get-GridSyncthingConfig { $script:auditConfig }
        Mock Invoke-GridSyncthingApi {
            if ($Path -eq '/rest/system/connections') {
                $connections = [pscustomobject]@{}
                $connections | Add-Member -NotePropertyName $script:auditPeerId -NotePropertyValue ([pscustomobject]@{ connected = $true })
                return [pscustomobject]@{ connections = $connections }
            }
            return [pscustomobject]@{ state = 'scanning'; needTotalItems = 0; pullErrors = 0 }
        }
        Mock Start-GridSyncthing { throw 'audit must not start Syncthing' }

        $audit = Invoke-GridAudit -Context $context

        $audit.overall | Should Be 'pending'
        $audit.gridOnline | Should Be $false
        ($audit.checks | Where-Object { $_.name -eq 'folder-sync' }).pending | Should Be $true
        Assert-MockCalled Start-GridSyncthing -Times 0
    }
}