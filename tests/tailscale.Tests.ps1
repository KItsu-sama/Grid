#requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Get-ChildItem -LiteralPath (Join-Path $root 'bootstrap') -Filter '*.ps1' | Sort-Object Name | ForEach-Object {
    . $_.FullName
}

Describe 'Tailscale install location' {
    It 'installs MSI app files under GridRoot, including paths with spaces' {
        $testRoot = Join-Path $TestDrive 'tailscale-installer'
        New-Item -ItemType Directory -Path (Join-Path $testRoot 'config') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $root 'config\grid.example.json') -Destination (Join-Path $testRoot 'config\grid.example.json') -Force
        $context = New-GridContext -LauncherRoot $testRoot -Command 'setup'
        Set-GridContextRoot -Context $context -GridRoot (Join-Path $TestDrive 'Personal Grid') | Out-Null
        $script:tailscaleInstallFile = $null
        $script:tailscaleInstallArguments = @()
        Mock Get-GridVerifiedPackagePath {
            [pscustomobject]@{
                Path = 'C:\packages\tailscale-setup.msi'
                Spec = [pscustomobject]@{ file = 'tailscale-setup.msi'; kind = 'msi' }
            }
        }
        Mock Initialize-GridDirectory {}
        Mock Write-GridLog {}
        Mock Start-Process {
            $script:tailscaleInstallFile = $FilePath
            $script:tailscaleInstallArguments = @($ArgumentList)
            [pscustomobject]@{ ExitCode = 0 }
        }

        Install-GridTailscalePackage -Context $context

        $script:tailscaleInstallFile | Should Be 'msiexec.exe'
        (@($script:tailscaleInstallArguments) -contains ('INSTALLDIR="{0}"' -f $context.TailscaleInstallDir)) | Should Be $true
        (@($script:tailscaleInstallArguments) -contains ('"{0}"' -f 'C:\packages\tailscale-setup.msi')) | Should Be $true
        Assert-MockCalled Initialize-GridDirectory -Times 1 -ParameterFilter { $Path -eq $context.TailscaleInstallDir }
    }

    It 'refuses a Tailscale EXE installer that cannot guarantee the GridRoot location' {
        $context = [pscustomobject]@{ TailscaleInstallDir = 'C:\GridRoot\bin\tailscale' }
        Mock Get-GridVerifiedPackagePath {
            [pscustomobject]@{
                Path = 'C:\packages\tailscale-setup.exe'
                Spec = [pscustomobject]@{ file = 'tailscale-setup.exe'; kind = 'installer' }
            }
        }
        Mock Write-GridLog {}
        $script:tailscaleExeStarted = $false
        Mock Start-Process { $script:tailscaleExeStarted = $true }

        { Install-GridTailscalePackage -Context $context } | Should Throw 'must be an MSI'
        $script:tailscaleExeStarted | Should Be $false
    }
}
