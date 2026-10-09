#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('setup', 'start', 'stop', 'status', 'audit', 'repair', 'preflight', 'uninstall', 'approve-peer', 'agent')]
    [string]$Command = 'status',

    [ValidateSet('persistent', 'temporary')]
    [string]$Mode,

    [string]$TargetPath,

    [switch]$Seed,

    [switch]$NonInteractive,

    [switch]$RemoveData,

    [switch]$RemoveDefaultSync,

    [string]$PeerId,

    [string]$PeerName,

    [string]$GridDeviceId,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$AgentArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'

$script:GridBootstrapRoot = $PSScriptRoot
Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'bootstrap') -Filter '*.ps1' | Sort-Object Name | ForEach-Object {
    . $_.FullName
}

function Initialize-GridCommandContext {
    Assert-GridWindowsHost

    $ctx = New-GridContext `
        -LauncherRoot $script:GridBootstrapRoot `
        -Command $Command `
        -Mode $Mode `
        -TargetPath $TargetPath `
        -Seed:$Seed `
        -NonInteractive:$NonInteractive

    $ctx | Add-Member -MemberType NoteProperty `
        -Name SeedRequested `
        -Value ([bool]$Seed) `
        -Force

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
        [string]$PeerName,
        [string]$GridDeviceId
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
    Add-GridSyncthingPeer -Context $Context -PeerId $PeerId -PeerName $PeerName -GridDeviceId $GridDeviceId
}

function Invoke-GridAgentCommand {
    param([Parameter(Mandatory = $true)]$Context, [string[]]$Arguments)
    Assert-GridModeSupported -Context $Context
    $agentRoot = Join-Path $script:GridBootstrapRoot 'agent'
    $nativeAgent = Join-Path $agentRoot 'bin\grid-agent.exe'
    if (-not (Test-Path -LiteralPath $nativeAgent -PathType Leaf)) {
        throw "Native Grid Agent executable is missing: $nativeAgent. Build it with agent\build.ps1."
    }

    $oldGridRoot = $env:PERSONAL_GRID_ROOT
    $oldStateDir = $env:GRID_STATE_DIR
    try {
        $env:PERSONAL_GRID_ROOT = $Context.GridRoot
        $env:GRID_STATE_DIR = Join-Path $Context.GridRoot '.grid\agent'
        & $nativeAgent @Arguments
        if ($LASTEXITCODE -ne 0) { throw "Grid Agent command failed with exit code $LASTEXITCODE." }
    } finally {
        $env:PERSONAL_GRID_ROOT = $oldGridRoot
        $env:GRID_STATE_DIR = $oldStateDir
    }
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
        'approve-peer' { Invoke-GridApprovePeer -Context $context -PeerId $PeerId -PeerName $PeerName -GridDeviceId $GridDeviceId }
        'agent' { Invoke-GridAgentCommand -Context $context -Arguments $AgentArgs }
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
    $err = $_

    Write-Host ''
    Write-Host '========== GRID ERROR ==========' -ForegroundColor Red
    Write-Host $err.Exception.Message -ForegroundColor Red

    if ($err.InvocationInfo -and $err.InvocationInfo.ScriptName) {
        Write-Host "File: $($err.InvocationInfo.ScriptName)" -ForegroundColor Yellow
        Write-Host "Line: $($err.InvocationInfo.ScriptLineNumber)" -ForegroundColor Yellow
        Write-Host "Code: $($err.InvocationInfo.Line.Trim())" -ForegroundColor DarkYellow
    }

    if (-not [string]::IsNullOrWhiteSpace($err.ScriptStackTrace)) {
        Write-Host ''
        Write-Host 'Stack trace:' -ForegroundColor Yellow
        Write-Host $err.ScriptStackTrace
    }

    try {
        Write-GridLog -Level ERROR -Message (
            "$($err.Exception.Message)`n$($err.ScriptStackTrace)"
        )
    } catch {
        Write-Host "Could not write to the Grid log: $($_.Exception.Message)" `
            -ForegroundColor DarkYellow
    }

    Write-Host '================================' -ForegroundColor Red
    exit 1
}
