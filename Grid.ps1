#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('setup', 'start', 'stop', 'status', 'audit', 'repair', 'preflight')]
    [string]$Command = 'status',

    [ValidateSet('persistent', 'temporary')]
    [string]$Mode,

    [string]$TargetPath,

    [switch]$Seed,

    [switch]$NonInteractive
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
    Invoke-GridTailscaleStage -Context $Context
    Start-GridSyncthing -Context $Context
    $audit = Invoke-GridAudit -Context $Context
    Write-GridAuditReport -Audit $audit
}

function Invoke-GridStop {
    param($Context)
    Assert-GridModeSupported -Context $Context
    Stop-GridSyncthing -Context $Context
    Write-GridLog -Context $Context -Message 'Stopped Grid-owned Syncthing. Tailscale was left running (system service / existing tailnet).'
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
        'start'  { Invoke-GridStart -Context $context }
        'stop'   { Invoke-GridStop -Context $context }
        'status' {
            Assert-GridModeSupported -Context $context
            $audit = Invoke-GridAudit -Context $context
            Write-GridAuditReport -Audit $audit
        }
        'audit' {
            Assert-GridModeSupported -Context $context
            $audit = Invoke-GridAudit -Context $context
            Write-GridAuditReport -Audit $audit
            $audit
        }
    }
} catch {
    Write-GridLog -Level ERROR -Message $_.Exception.Message
    exit 1
}
