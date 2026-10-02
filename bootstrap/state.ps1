Set-StrictMode -Version Latest

function New-GridInstallState {
    return [pscustomobject]@{
        schemaVersion = 1
        updatedAt     = (Get-GridNowUtc)
        stages        = [pscustomobject]@{
            prepare    = [pscustomobject]@{ status = 'pending' }
            tailscale  = [pscustomobject]@{ status = 'pending' }
            syncthing  = [pscustomobject]@{ status = 'pending' }
            configure  = [pscustomobject]@{ status = 'pending' }
            startup    = [pscustomobject]@{ status = 'pending' }
            audit      = [pscustomobject]@{ status = 'pending' }
        }
    }
}

function Read-GridInstallState {
    param([Parameter(Mandatory = $true)]$Context)
    if ([string]::IsNullOrWhiteSpace($Context.StatePath) -or -not (Test-Path -LiteralPath $Context.StatePath)) {
        return (New-GridInstallState)
    }
    try {
        $state = ConvertFrom-GridJson -Path $Context.StatePath -Label 'install-state.json'
    } catch {
        throw "Install state is unreadable ($($Context.StatePath)): $($_.Exception.Message). Fix or remove the file; it will not be silently replaced."
    }
    $schema = Get-GridProperty $state 'schemaVersion' 1
    if ([int]$schema -ne 1) {
        throw "Unsupported install-state schemaVersion '$schema' in $($Context.StatePath)."
    }
    if ($null -eq (Get-GridProperty $state 'stages')) {
        $state | Add-Member -NotePropertyName stages -NotePropertyValue (New-GridInstallState).stages -Force
    }
    return $state
}

function Write-GridInstallState {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$State
    )
    $State.updatedAt = Get-GridNowUtc
    Write-GridJsonAtomic -Path $Context.StatePath -InputObject $State
}

function Get-GridStageRecord {
    param($State, [string]$Name)
    $stages = Get-GridProperty $State 'stages'
    $record = Get-GridProperty $stages $Name
    if ($null -eq $record) {
        return [pscustomobject]@{ status = 'pending' }
    }
    return $record
}

function Test-GridStageCompleted {
    param($State, [string]$Name)
    $record = Get-GridStageRecord -State $State -Name $Name
    return (([string](Get-GridProperty $record 'status')) -eq 'completed')
}

function Set-GridStageStatus {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('pending', 'running', 'completed', 'failed')][string]$Status,
        [string]$ErrorMessage
    )
    $stages = Get-GridProperty $State 'stages'
    if ($null -eq $stages) {
        $State | Add-Member -NotePropertyName stages -NotePropertyValue ([pscustomobject]@{}) -Force
        $stages = $State.stages
    }
    $record = [pscustomobject]@{
        status = $Status
    }
    if ($Status -eq 'running') {
        $record | Add-Member -NotePropertyName startedAt -NotePropertyValue (Get-GridNowUtc)
    }
    if ($Status -eq 'completed') {
        $record | Add-Member -NotePropertyName completedAt -NotePropertyValue (Get-GridNowUtc)
    }
    if ($Status -eq 'failed') {
        $record | Add-Member -NotePropertyName failedAt -NotePropertyValue (Get-GridNowUtc)
        if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
            $record | Add-Member -NotePropertyName error -NotePropertyValue $ErrorMessage
        }
    }
    $stages | Add-Member -NotePropertyName $Name -NotePropertyValue $record -Force
    Write-GridInstallState -Context $Context -State $State
}

function Invoke-GridStage {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [switch]$Force
    )
    if (-not $Force -and (Test-GridStageCompleted -State $State -Name $Name)) {
        Write-GridLog -Context $Context -Message "Stage '$Name' already completed; skipping."
        return
    }
    Set-GridStageStatus -Context $Context -State $State -Name $Name -Status running
    try {
        & $Action
        Set-GridStageStatus -Context $Context -State $State -Name $Name -Status completed
    } catch {
        Set-GridStageStatus -Context $Context -State $State -Name $Name -Status failed -ErrorMessage $_.Exception.Message
        throw
    }
}
