Set-StrictMode -Version Latest

function Initialize-GridPreflightContext {
    param([Parameter(Mandatory = $true)]$Context)
    $windows = Get-GridWindowsInfo
    $drives = Get-GridCandidateDrives -Context $Context
    $environment = [pscustomobject]@{
        Windows       = $windows
        Drives        = $drives
        Tailscale     = Get-GridTailscaleStatus
        Installations = Find-GridInstallations -Context $Context -Drives $drives
        Architecture  = $windows.Architecture
    }
    $Context | Add-Member -NotePropertyName Environment -NotePropertyValue $environment -Force
    try {
        Resolve-GridRuntime -Context $Context -Environment $environment | Out-Null
    } catch {
        $Context | Add-Member -NotePropertyName RuntimeResolutionError -NotePropertyValue $_.Exception.Message -Force
    }
    return $Context
}

function New-GridPreflightCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('ready', 'action', 'optional', 'blocker')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Reason
    )
    return [pscustomobject]@{ name = $Name; status = $Status; reason = $Reason }
}

function Test-GridPreflightPackage {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Id
    )
    try {
        $spec = Find-GridPackageSpec -Context $Context -Id $Id
        $path = Resolve-GridPackageFile -Context $Context -Spec $spec
        if ([string]::IsNullOrWhiteSpace($path)) {
            $cache = if ([string]::IsNullOrWhiteSpace($Context.GridRoot)) { '<GridRoot>' } else { Join-Path $Context.GridRoot 'packages' }
            return (New-GridPreflightCheck -Name "$Id installer" -Status blocker -Reason "Missing $($spec.file). Place the verified vendor installer in packages\ or $cache.")
        }
        Test-GridPackageHash -Path $path -Spec $spec
        return (New-GridPreflightCheck -Name "$Id installer" -Status ready -Reason "Found and SHA-256 verified: $path")
    } catch {
        return (New-GridPreflightCheck -Name "$Id installer" -Status blocker -Reason $_.Exception.Message)
    }
}

function Get-GridPreflightReport {
    param([Parameter(Mandatory = $true)]$Context)
    $checks = New-Object System.Collections.Generic.List[object]
    $environment = Get-GridProperty $Context 'Environment'
    $windows = Get-GridProperty $environment 'Windows'
    if ($null -ne $windows -and -not [bool](Get-GridProperty $windows 'IsWindows' $true)) {
        $checks.Add((New-GridPreflightCheck -Name 'Windows host' -Status blocker -Reason 'The bootstrap requires Windows.')) | Out-Null
    } else {
        $checks.Add((New-GridPreflightCheck -Name 'Windows host' -Status ready -Reason 'Windows detected.')) | Out-Null
    }

    if ([bool]$Context.UsedExample) {
        $checks.Add((New-GridPreflightCheck -Name 'Configuration' -Status action -Reason 'Using config\grid.example.json defaults. Create config\grid.json only to override settings; no credentials belong there.')) | Out-Null
    } else {
        $checks.Add((New-GridPreflightCheck -Name 'Configuration' -Status ready -Reason "Validated config: $($Context.SettingsPath)")) | Out-Null
    }

    if ($Context.Mode -eq 'temporary') {
        $checks.Add((New-GridPreflightCheck -Name 'Runtime mode' -Status blocker -Reason 'Temporary mode is not supported in this release. Use persistent mode.')) | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Context.GridRoot)) {
        $checks.Add((New-GridPreflightCheck -Name 'Persistent storage' -Status ready -Reason "Selected GridRoot: $($Context.GridRoot)")) | Out-Null
    } else {
        $reason = [string](Get-GridProperty $Context 'RuntimeResolutionError' 'No eligible persistent storage target was selected.')
        $checks.Add((New-GridPreflightCheck -Name 'Persistent storage' -Status blocker -Reason $reason)) | Out-Null
    }

    $tailscaleEnabled = [bool](Get-GridProperty $Context.Settings.tailscale 'enabled' $true)
    $tailscale = Get-GridProperty $environment 'Tailscale'
    if (-not $tailscaleEnabled) {
        $checks.Add((New-GridPreflightCheck -Name 'Tailscale' -Status ready -Reason 'Disabled in configuration.')) | Out-Null
    } elseif ($null -eq $tailscale -or -not [bool](Get-GridProperty $tailscale 'Installed' $false)) {
        $checks.Add((Test-GridPreflightPackage -Context $Context -Id 'tailscale')) | Out-Null
            $checks.Add((New-GridPreflightCheck -Name 'Tailscale sign-in' -Status action -Reason "First sign-in needs internet and opens Tailscale's own UI. Use an identity authorized for your tailnet; Google/Gmail is only used if your tailnet offers it. Personal Grid does not collect or store those credentials.")) | Out-Null
    } else {
        $backend = 'unknown'
        try { $backend = Get-GridTailscaleBackendState } catch { }
        if ($backend -eq 'Running') {
            $checks.Add((New-GridPreflightCheck -Name 'Tailscale' -Status ready -Reason 'Installed and authenticated.')) | Out-Null
        } else {
            $checks.Add((New-GridPreflightCheck -Name 'Tailscale' -Status action -Reason "Installed. If needed, sign-in requires internet and opens Tailscale's own UI. No credentials are stored by Personal Grid.")) | Out-Null
        }
    }

    $syncthingEnabled = [bool](Get-GridProperty $Context.Settings.syncthing 'enabled' $true)
    $syncthingInstalled = -not [string]::IsNullOrWhiteSpace([string]$Context.SyncthingBin) -and (Test-Path -LiteralPath $Context.SyncthingBin)
    if (-not $syncthingEnabled) {
        $checks.Add((New-GridPreflightCheck -Name 'Syncthing' -Status ready -Reason 'Disabled in configuration.')) | Out-Null
    } elseif ($syncthingInstalled) {
        $checks.Add((New-GridPreflightCheck -Name 'Syncthing installer' -Status ready -Reason 'Syncthing binary already exists under GridRoot.')) | Out-Null
    } else {
        $checks.Add((Test-GridPreflightPackage -Context $Context -Id 'syncthing')) | Out-Null
    }

    $isSeed = [bool]$Context.SeedRequested -or [bool]$Context.IsRoot -or [bool](Get-GridProperty $Context.Settings.device 'isMain' $false)
    if ($isSeed) {
        $checks.Add((New-GridPreflightCheck -Name 'Pairing data' -Status ready -Reason 'This setup is marked as the seed; it will generate syncconfig.json.')) | Out-Null
    } else {
        $manifestPath = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$Context.GridRoot)) {
            $manifestPath = Find-GridSyncManifestPath -Context $Context
        } else {
            $usbManifest = Get-GridUsbSyncConfigPath -Context $Context
            if (Test-Path -LiteralPath $usbManifest) { $manifestPath = $usbManifest }
        }
        if ([string]::IsNullOrWhiteSpace($manifestPath)) {
            $checks.Add((New-GridPreflightCheck -Name 'Pairing data' -Status blocker -Reason 'No seed config/syncconfig.json found. Copy it from the seed node, or run preflight and setup with -Seed for the first node.')) | Out-Null
        } else {
            try {
                $manifest = Read-GridSyncManifest -Path $manifestPath
                $seedId = [string](Get-GridProperty $manifest.seedDevice 'deviceId')
                if ([string]::IsNullOrWhiteSpace($seedId)) { throw 'The seedDevice.deviceId value is empty.' }
                $checks.Add((New-GridPreflightCheck -Name 'Pairing data' -Status ready -Reason "Seed manifest found: $manifestPath")) | Out-Null
            } catch {
                $checks.Add((New-GridPreflightCheck -Name 'Pairing data' -Status blocker -Reason $_.Exception.Message)) | Out-Null
            }
        }
    }

    $emailPath = Join-Path $Context.BootstrapRoot 'tailscale.txt'
    $emailReason = if (Test-Path -LiteralPath $emailPath) { 'Optional account-email metadata file found; its contents are not shown and it is not used to sign in.' } else { 'Optional only. Tailscale sign-in does not require this file.' }
    $checks.Add((New-GridPreflightCheck -Name 'Tailscale email metadata' -Status optional -Reason $emailReason)) | Out-Null

    $overall = if (@($checks | Where-Object { $_.status -eq 'blocker' }).Count -gt 0) { 'blocked' } else { 'ready' }
    return [pscustomobject]@{ overall = $overall; checks = @($checks.ToArray()) }
}

function Write-GridPreflightReport {
    param([Parameter(Mandatory = $true)]$Report)
    Write-Host 'Personal Grid setup preflight'
    foreach ($check in $Report.checks) {
        Write-Host "[$($check.status.ToUpperInvariant())] $($check.name): $($check.reason)"
    }
    Write-Host "Overall: $($Report.overall.ToUpperInvariant())"
}