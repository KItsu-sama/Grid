# bootstrap/trust.ps1
# Manage local permission to become the Grid main node.

function Test-GridElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Set-GridMainPermission {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][bool]$Allow
    )

    if (-not (Test-GridElevated)) {
        throw 'Trust changes require an elevated PowerShell. Reopen PowerShell as Administrator and retry.'
    }

    if (-not $Allow -and
        [bool](Get-GridProperty $Context.Settings.device 'isMain' $false)) {
        throw 'Cannot revoke main permission while device.isMain is true. Migrate the main role first.'
    }

    if ($Allow) {
        Write-Host ''
        Write-Host 'You are authorizing THIS Windows installation to become Grid main.' -ForegroundColor Yellow
        Write-Host 'Only do this on a computer you control.'
        $confirmation = Read-Host 'Type ALLOW MAIN to continue'

        if ($confirmation -cne 'ALLOW MAIN') {
            Write-Host 'Cancelled. No configuration changed.' -ForegroundColor Yellow
            return $false
        }
    } else {
        $confirmation = Read-Host 'Type DENY MAIN to revoke main permission'
        if ($confirmation -cne 'DENY MAIN') {
            Write-Host 'Cancelled. No configuration changed.' -ForegroundColor Yellow
            return $false
        }
    }

    $settingsPath = Join-Path $Context.BootstrapRoot 'config\grid.json'

    # Work with the validated settings already loaded by Grid.
    $settings = $Context.Settings
    $settings | Add-Member -MemberType NoteProperty `
        -Name can_be_main -Value $Allow -Force

    # Preserve other settings and write atomically.
    Write-GridJsonAtomic -Path $settingsPath -InputObject $settings

    $Context.SettingsPath = $settingsPath
    $Context.UsedExample = $false
    $Context.CanBeMain = $Allow

    Write-Host ''
    if ($Allow) {
        Write-Host 'Main permission enabled in config\grid.json.' -ForegroundColor Green
        Write-Host 'This authorizes the device; it does not automatically install Grid.' -ForegroundColor Cyan
    } else {
        Write-Host 'Main permission disabled.' -ForegroundColor Green
    }

    return $true
}

function Invoke-GridTrust {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [string[]]$Arguments = @()
    )

    $action = 'status'
    if ($Arguments.Count -gt 0 -and
        -not [string]::IsNullOrWhiteSpace($Arguments[0])) {
        $action = $Arguments[0].Trim().ToLowerInvariant()
    }

    switch ($action) {
        'status' {
            Write-Host 'Grid main-node permission'
            Write-Host "Configuration: $($Context.SettingsPath)"
            Write-Host "Can become main: $($Context.CanBeMain)"
            Write-Host "Configured as main: $([bool](Get-GridProperty $Context.Settings.device 'isMain' $false))"
        }

        'allow-main' {
            Set-GridMainPermission -Context $Context -Allow $true | Out-Null
        }

        'deny-main' {
            Set-GridMainPermission -Context $Context -Allow $false | Out-Null
        }

        default {
            throw "Unknown trust action '$action'. Use status, allow-main, or deny-main."
        }
    }
}
