#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('setup', 'start', 'stop', 'status', 'audit', 'repair', 'preflight', 'uninstall', 'approve-peer')]
    [string]$Command = 'status',

    [ValidateSet('persistent', 'temporary')]
    [string]$Mode,

    [string]$TargetPath,

    [switch]$Seed,

    [switch]$NonInteractive,

    [switch]$RemoveData,

    [switch]$RemoveDefaultSync,

    [string]$PeerId,

    [string]$PeerName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:GridBootstrapRoot = $PSScriptRoot
Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'bootstrap') -Filter '*.ps1' | Sort-Object Name | ForEach-Object {
    . $_.FullName
}

function Initialize-GridCommandContext {
    Assert-GridWindowsHost
    $ctx = New-GridContext -LauncherRoot $script:GridBootstrapRoot -Command $Command -Mode $Mode -TargetPath $TargetPath -Seed:$Seed -NonInteractive:$NonInteractive
    if ($Command -eq 'preflight') {
        return (Initialize-GridPreflightContext -Context $ctx)
    }
    $envInfo = Get-GridEnvironment -Context $ctx
    return (Resolve-GridRuntime -Context $ctx -Environment $envInfo)
}

function Invoke-GridSetup {
    param($Context, [switch]$Repair)
    Assert-GridModeSupported -Context $Context
    if (($Context.SeedRequested -or [bool](Get-GridProperty $Context.Settings.device 'isMain' $false)) -and -not [bool]$Context.CanBeMain) {
        throw 'This device is not authorized to become the Grid main. Set can_be_main=true only on the trusted main device.'
    }
    $state = Read-GridInstallState -Context $Context
    Invoke-GridStage -Context $Context -State $state -Name 'prepare' -Force:$Repair -Action {
        Initialize-GridInstallation -Context $Context -State $state
        if ($Repair) { Repair-GridInstallationFiles -Context $Context }
    }
    Invoke-GridStage -Context $Context -State $state -Name 'tailscale' -Force:$Repair -Action {
        Invoke-GridTailscaleStage -Context $Context
    }
    Invoke-GridStage -Context $Context -State $state -Name 'syncthing' -Force:$Repair -Action {
        Initialize-GridSyncthingIdentity -Context $Context | Out-Null
    }
    Invoke-GridStage -Context $Context -State $state -Name 'configure' -Force:$Repair -Action {
        Invoke-GridConfigureStage -Context $Context
    }
    Invoke-GridStage -Context $Context -State $state -Name 'startup' -Force:$Repair -Action {
        Invoke-GridStartupStage -Context $Context
    }
    Invoke-GridStage -Context $Context -State $state -Name 'audit' -Force -Action {
        $audit = Invoke-GridAudit -Context $Context
        Write-GridAuditReport -Audit $audit
        if ($audit.overall -eq 'failed') {
            throw 'Audit failed. Local state was not discarded; run .\Grid.ps1 repair or .\Grid.ps1 audit after fixing the reported checks.'
        }
    }
}

function Invoke-GridStart {
    param($Context)
    Assert-GridModeSupported -Context $Context
    if (-not (Test-Path -LiteralPath $Context.DevicePath)) {
        throw "No persistent installation at $($Context.GridRoot). Run .\Grid.ps1 setup first."
    }
    Start-GridTailscaleService | Out-Null
    Start-GridSyncthing -Context $Context
    $audit = Invoke-GridAudit -Context $Context
    Complete-GridAuditCommand -Audit $audit
}

function Invoke-GridStop {
    param($Context)
    Assert-GridModeSupported -Context $Context
    Stop-GridSyncthing -Context $Context
    Write-GridLog -Context $Context -Message 'Stopped Grid-owned Syncthing. Tailscale was left running (system service / existing tailnet).'
}

function Invoke-GridUninstall {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [switch]$RemoveData,
        [switch]$RemoveDefaultSync
    )
    Assert-GridModeSupported -Context $Context
    Uninstall-GridInstallation -Context $Context -RemoveData:$RemoveData -RemoveDefaultSync:$RemoveDefaultSync
}

function Invoke-GridApprovePeer {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$PeerId,
        [string]$PeerName
    )
    Assert-GridModeSupported -Context $Context
    if (-not [bool]$Context.CanBeMain) {
        throw 'This device cannot approve peers because can_be_main is false.'
    }
    if (-not (Test-Path -LiteralPath $Context.DevicePath)) {
        throw "No local Grid installation at $($Context.GridRoot). Run setup first."
    }
    if ([string]::IsNullOrWhiteSpace($PeerName)) { $PeerName = 'Grid peer' }
    Start-GridSyncthing -Context $Context
    Add-GridSyncthingPeer -Context $Context -PeerId $PeerId -PeerName $PeerName
}

function Complete-GridAuditCommand {
    param([Parameter(Mandatory = $true)]$Audit)
    Write-GridAuditReport -Audit $Audit
    if ($Audit.overall -eq 'failed' -or $Audit.overall -eq 'degraded') {
        exit 1
    }
}

function Invoke-GridPreflight {
    param([Parameter(Mandatory = $true)]$Context)
    $report = Get-GridPreflightReport -Context $Context
    Write-GridPreflightReport -Report $report
    if ($report.overall -eq 'blocked') {
        throw 'Preflight found blockers. Resolve the items marked BLOCKER and rerun.'
    }
    return $report
}

try {
    $context = Initialize-GridCommandContext
    Write-GridLog -Context $context -Message "Command=$Command mode=$($context.Mode) bootstrap=$($context.BootstrapRoot) gridRoot=$($context.GridRoot)"

    switch ($Command) {
        'setup'  { Invoke-GridSetup -Context $context }
        'repair' { Invoke-GridSetup -Context $context -Repair }
        'preflight' { Invoke-GridPreflight -Context $context | Out-Null }
        'uninstall' { Invoke-GridUninstall -Context $context -RemoveData:$RemoveData -RemoveDefaultSync:$RemoveDefaultSync }
        'approve-peer' { Invoke-GridApprovePeer -Context $context -PeerId $PeerId -PeerName $PeerName }
        'start'  { Invoke-GridStart -Context $context }
        'stop'   { Invoke-GridStop -Context $context }
        'status' {
            Assert-GridModeSupported -Context $context
            $audit = Invoke-GridAudit -Context $context
            Complete-GridAuditCommand -Audit $audit
        }
        'audit' {
            Assert-GridModeSupported -Context $context
            $audit = Invoke-GridAudit -Context $context
            Complete-GridAuditCommand -Audit $audit
            $audit
        }
    }
} catch {
    Write-GridLog -Level ERROR -Message $_.Exception.Message
    exit 1
}
