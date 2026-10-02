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

    It 'rejects folders that are still syncing or scanning' {
        foreach ($state in @('syncing', 'scanning')) {
            $status = [pscustomobject]@{ state = $state; needTotalItems = 0; pullErrors = 0 }
            (Get-GridFolderSyncIssue -Status $status) | Should Match "state=$state"
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