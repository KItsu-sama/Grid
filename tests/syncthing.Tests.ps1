#requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Get-ChildItem -LiteralPath (Join-Path $root 'bootstrap') -Filter '*.ps1' | Sort-Object Name | ForEach-Object {
    . $_.FullName
}

Describe 'Syncthing launch arguments' {
    It 'quotes a home path with spaces and disables automatic upgrades' {
        $testRoot = Join-Path $TestDrive 'syncthing-launcher'
        New-Item -ItemType Directory -Path (Join-Path $testRoot 'config') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $root 'config\grid.example.json') -Destination (Join-Path $testRoot 'config\grid.example.json') -Force
        $context = New-GridContext -LauncherRoot $testRoot -Command 'start'
        Set-GridContextRoot -Context $context -GridRoot (Join-Path $TestDrive 'Personal Grid') | Out-Null
        New-Item -ItemType Directory -Path (Split-Path -Parent $context.SyncthingBin) -Force | Out-Null
        Set-Content -LiteralPath $context.SyncthingBin -Value 'binary' -Encoding UTF8
        $script:syncthingStartArguments = @()
        Mock Get-GridSyncthingProcess { @() }
        Mock Start-Process { $script:syncthingStartArguments = @($ArgumentList) }
        Mock Wait-GridSyncthingReady {}

        Start-GridSyncthing -Context $context

        $script:syncthingStartArguments[0] | Should Be "--home=`"$($context.SyncthingHome)`""
        (@($script:syncthingStartArguments) -contains '--no-upgrade') | Should Be $true
        (@($script:syncthingStartArguments) -contains '--no-restart') | Should Be $true
    }
}

Describe 'Syncthing REST recovery' {
    It 'retries a dropped GET connection once using the requested timeout' {
        $context = [pscustomobject]@{ GuiAddress = '127.0.0.1:8384' }
        $script:apiAttempts = 0
        $script:observedTimeout = 0
        Mock Get-GridSyncthingApiKey { 'test-key' }
        Mock Invoke-WebRequest {
            $script:apiAttempts++
            $script:observedTimeout = $TimeoutSec
            if ($script:apiAttempts -eq 1) { throw (New-Object System.Net.WebException 'connection dropped') }
            [pscustomobject]@{ Content = '{"myID":"DEVICE-ID"}' }
        }

        $status = Invoke-GridSyncthingApi -Context $context -Method GET -Path '/rest/system/status' -TimeoutSec 2

        $status.myID | Should Be 'DEVICE-ID'
        $script:apiAttempts | Should Be 2
        $script:observedTimeout | Should Be 2
    }

    It 'does not retry config writes after a dropped connection' {
        $context = [pscustomobject]@{ GuiAddress = '127.0.0.1:8384' }
        $script:apiAttempts = 0
        Mock Get-GridSyncthingApiKey { 'test-key' }
        Mock Invoke-WebRequest {
            $script:apiAttempts++
            throw (New-Object System.Net.WebException 'connection dropped')
        }

        { Invoke-GridSyncthingApi -Context $context -Method PUT -Path '/rest/config' -Body ([pscustomobject]@{}) -TimeoutSec 2 } | Should Throw 'connection dropped'
        $script:apiAttempts | Should Be 1
    }
}

Describe 'Syncthing shutdown' {
    It 'requests graceful shutdown and avoids force-stop when the process exits' {
        $context = [pscustomobject]@{ SyncthingHome = 'C:\Grid\Syncthing'; GuiAddress = '127.0.0.1:8384' }
        $script:shutdownPath = $null
        Mock Get-GridSyncthingProcess { @([pscustomobject]@{ Id = 12345 }) }
        Mock Invoke-GridSyncthingApi { $script:shutdownPath = $Path }
        Mock Get-Process { $null }
        Mock Stop-Process { throw 'gracefully stopped process must not be force-stopped' }

        Stop-GridSyncthing -Context $context

        $script:shutdownPath | Should Be '/rest/system/shutdown'
        Assert-MockCalled Stop-Process -Times 0
    }

    It 'uses forced stop only after the graceful timeout expires' {
        $context = [pscustomobject]@{ SyncthingHome = 'C:\Grid\Syncthing'; GuiAddress = '127.0.0.1:8384' }
        $script:stopRequested = $false
        Mock Get-GridSyncthingProcess { @([pscustomobject]@{ Id = 12345 }) }
        Mock Invoke-GridSyncthingApi { $script:stopRequested = $true; throw 'API unavailable' }
        Mock Get-Process { [pscustomobject]@{ Id = 12345 } }
        Mock Stop-Process {}
        Mock Write-GridLog {}

        Stop-GridSyncthing -Context $context -GraceSeconds 0

        $script:stopRequested | Should Be $true
        Assert-MockCalled Stop-Process -Times 1 -ParameterFilter { $Force -eq $true }
    }
}