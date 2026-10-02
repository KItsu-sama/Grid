Set-StrictMode -Version Latest

function Test-GridInternet {
    $targets = @('1.1.1.1', '8.8.8.8')
    foreach ($t in $targets) {
        try {
            if (Test-Connection -ComputerName $t -Count 1 -Quiet -ErrorAction Stop) {
                return $true
            }
        } catch {
        }
    }
    return $false
}

function Get-GridLogicalDrives {
    try {
        return @(Get-CimInstance -ClassName Win32_LogicalDisk)
    } catch {
        return @(Get-WmiObject -Class Win32_LogicalDisk)
    }
}

function ConvertTo-GridDriveInfo {
    param(
        [Parameter(Mandatory = $true)]$Disk,
        [string]$LauncherRoot
    )
    $letter = [string]$Disk.DeviceID
    $type = [int]$Disk.DriveType
    $kind = switch ($type) {
        2 { 'removable' }
        3 { 'fixed' }
        4 { 'network' }
        5 { 'cdrom' }
        default { 'other' }
    }
    $free = 0L
    if ($null -ne $Disk.FreeSpace) { $free = [int64]$Disk.FreeSpace }
    $onLauncher = $false
    if (-not [string]::IsNullOrWhiteSpace($LauncherRoot) -and $LauncherRoot.Length -ge 2) {
        $launchDrive = $LauncherRoot.Substring(0, 2)
        if ($launchDrive.ToUpperInvariant() -eq $letter.ToUpperInvariant()) {
            $onLauncher = $true
        }
    }
    return [pscustomobject]@{
        DeviceId          = $letter
        DriveType         = $type
        Kind              = $kind
        FreeBytes         = $free
        IsFixed           = ($type -eq 3)
        IsRemovable       = ($type -eq 2)
        IsNetwork         = ($type -eq 4)
        ContainsLauncher  = $onLauncher
        EligiblePersistent = $false
    }
}

function Get-GridCandidateDrives {
    param(
        [Parameter(Mandatory = $true)]$Context,
        $Disks
    )
    if ($null -eq $Disks) {
        $Disks = Get-GridLogicalDrives
    }
    $min = [int64]$Context.Settings.persistent.minimumFreeBytes
    $result = @()
    foreach ($disk in @($Disks)) {
        $info = ConvertTo-GridDriveInfo -Disk $disk -LauncherRoot $Context.BootstrapRoot
        $info.EligiblePersistent = (
            $info.IsFixed -and
            -not $info.IsRemovable -and
            -not $info.IsNetwork -and
            $info.FreeBytes -ge $min
        )
        $result += $info
    }
    return $result
}

function Select-GridTargetDrive {
    param(
        [Parameter(Mandatory = $true)]$Context,
        $Drives
    )
    $persistent = $Context.Settings.persistent
    $targetPath = $Context.TargetPathHint
    if ([string]::IsNullOrWhiteSpace($targetPath)) {
        $targetPath = [string](Get-GridProperty $persistent 'targetPath')
    }
    if (-not [string]::IsNullOrWhiteSpace($targetPath)) {
        return [pscustomobject]@{
            Strategy = 'manual-path'
            GridRoot = [System.IO.Path]::GetFullPath($targetPath)
            Drive    = $null
        }
    }
    if ($null -eq $Drives) {
        $Drives = Get-GridCandidateDrives -Context $Context
    }
    $wanted = [string]$persistent.targetDrive
    $folder = [string]$persistent.targetFolder
    if ([string]::IsNullOrWhiteSpace($folder)) { $folder = 'PersonalGrid' }
    if ($wanted.ToUpperInvariant() -ne 'AUTO' -and -not [string]::IsNullOrWhiteSpace($wanted)) {
        $letter = $wanted.TrimEnd('\').TrimEnd('/')
        if ($letter.Length -eq 1) { $letter = "${letter}:" }
        $match = @($Drives | Where-Object { $_.DeviceId.ToUpperInvariant() -eq $letter.ToUpperInvariant() })
        if ($match.Count -eq 0) {
            throw "Configured targetDrive '$wanted' was not found."
        }
        $drive = $match[0]
        if (-not $drive.EligiblePersistent) {
            throw "Configured targetDrive '$wanted' is not an eligible fixed local disk with enough free space."
        }
        return [pscustomobject]@{
            Strategy = 'configured-drive'
            GridRoot = Join-Path $drive.DeviceId $folder
            Drive    = $drive
        }
    }
    $eligible = @($Drives | Where-Object { $_.EligiblePersistent } | Sort-Object FreeBytes -Descending)
    if ($eligible.Count -eq 0) {
        throw "No eligible fixed local drive has at least $($Context.Settings.persistent.minimumFreeBytes) free bytes. Removable and network drives are excluded."
    }
    $best = $eligible[0]
    return [pscustomobject]@{
        Strategy = 'auto-most-free'
        GridRoot = Join-Path $best.DeviceId $folder
        Drive    = $best
    }
}

function Get-GridServiceState {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        return [pscustomobject]@{ Installed = $false; Status = 'missing'; Name = $Name }
    }
    return [pscustomobject]@{ Installed = $true; Status = [string]$svc.Status; Name = $svc.Name }
}

function Get-GridTailscaleStatus {
    $cmd = Get-Command 'tailscale.exe' -ErrorAction SilentlyContinue
    $svc = Get-GridServiceState -Name 'Tailscale'
    $ipn = Get-GridServiceState -Name 'TailscaleIpnSvc'
    if (-not $svc.Installed) { $svc = $ipn }
    return [pscustomobject]@{
        CommandPath = if ($cmd) { [string]$cmd.Source } else { $null }
        Installed   = ($null -ne $cmd -or $svc.Installed)
        Service     = $svc
    }
}

function Get-GridSyncthingProcess {
    param([string]$GridHome)
    $procs = @(Get-Process -Name 'syncthing' -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($GridHome)) { return $procs }
    $homeFull = [System.IO.Path]::GetFullPath($GridHome)
    $owned = @()
    foreach ($p in $procs) {
        try {
            $cl = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)").CommandLine
            if ($cl -and $cl.ToLowerInvariant().Contains($homeFull.ToLowerInvariant())) {
                $owned += $p
            }
        } catch {
        }
    }
    return $owned
}

function Find-GridInstallations {
    param(
        [Parameter(Mandatory = $true)]$Context,
        $Drives
    )
    if ($null -eq $Drives) {
        $Drives = Get-GridCandidateDrives -Context $Context
    }
    $folder = [string]$Context.Settings.persistent.targetFolder
    if ([string]::IsNullOrWhiteSpace($folder)) { $folder = 'PersonalGrid' }
    $found = @()
    foreach ($drive in @($Drives | Where-Object { $_.IsFixed })) {
        $root = Join-Path $drive.DeviceId $folder
        $device = Join-Path $root '.grid\device.json'
        $state = Join-Path $root '.grid\install-state.json'
        if ((Test-Path -LiteralPath $device) -or (Test-Path -LiteralPath $state)) {
            $found += [pscustomobject]@{
                GridRoot   = $root
                DevicePath = $device
                StatePath  = $state
                Drive      = $drive.DeviceId
            }
        }
    }
    $hint = $Context.TargetPathHint
    if ([string]::IsNullOrWhiteSpace($hint)) {
        $hint = [string](Get-GridProperty $Context.Settings.persistent 'targetPath')
    }
    if (-not [string]::IsNullOrWhiteSpace($hint)) {
        $root = [System.IO.Path]::GetFullPath($hint)
        $device = Join-Path $root '.grid\device.json'
        $state = Join-Path $root '.grid\install-state.json'
        $already = @($found | Where-Object { $_.GridRoot.ToLowerInvariant() -eq $root.ToLowerInvariant() })
        if ($already.Count -eq 0 -and ((Test-Path -LiteralPath $device) -or (Test-Path -LiteralPath $state))) {
            $found += [pscustomobject]@{
                GridRoot   = $root
                DevicePath = $device
                StatePath  = $state
                Drive      = $root.Substring(0, 2)
            }
        }
    }
    return $found
}

function Get-GridWindowsInfo {
    $os = $null
    try { $os = Get-CimInstance Win32_OperatingSystem } catch { $os = Get-WmiObject Win32_OperatingSystem }
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -eq 'AMD64') { $arch = 'amd64' }
    elseif ($arch -eq 'ARM64') { $arch = 'arm64' }
    else { $arch = $arch.ToLowerInvariant() }
    return [pscustomobject]@{
        Caption        = [string]$os.Caption
        Version        = [string]$os.Version
        Architecture   = $arch
        ComputerName   = $env:COMPUTERNAME
        IsWindows      = ($env:OS -eq 'Windows_NT')
    }
}

function Get-GridEnvironment {
    param(
        [Parameter(Mandatory = $true)]$Context,
        $Disks
    )
    $windows = Get-GridWindowsInfo
    $drives = Get-GridCandidateDrives -Context $Context -Disks $Disks
    return [pscustomobject]@{
        Windows        = $windows
        BootstrapRoot  = $Context.BootstrapRoot
        Drives         = $drives
        Internet       = Test-GridInternet
        Tailscale      = Get-GridTailscaleStatus
        Installations  = Find-GridInstallations -Context $Context -Drives $drives
        Architecture   = $windows.Architecture
    }
}

function Resolve-GridRuntime {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Environment
    )
    if ($Context.Mode -eq 'temporary') {
        Set-GridContextRoot -Context $Context -GridRoot $Context.TemporaryRuntime | Out-Null
        $Context | Add-Member -NotePropertyName Environment -NotePropertyValue $Environment -Force
        $Context | Add-Member -NotePropertyName TemporaryUnsupported -NotePropertyValue $true -Force
        return $Context
    }
    $existing = @($Environment.Installations)
    if ($existing.Count -gt 0 -and [string]::IsNullOrWhiteSpace($Context.TargetPathHint)) {
        Set-GridContextRoot -Context $Context -GridRoot $existing[0].GridRoot | Out-Null
    } else {
        $choice = Select-GridTargetDrive -Context $Context -Drives $Environment.Drives
        Set-GridContextRoot -Context $Context -GridRoot $choice.GridRoot | Out-Null
        $Context | Add-Member -NotePropertyName DriveSelection -NotePropertyValue $choice -Force
    }
    $Context | Add-Member -NotePropertyName Environment -NotePropertyValue $Environment -Force
    $Context | Add-Member -NotePropertyName TemporaryUnsupported -NotePropertyValue $false -Force
    return $Context
}

function Assert-GridModeSupported {
    param([Parameter(Mandatory = $true)]$Context)
    if ($Context.Mode -eq 'temporary') {
        throw @"
Temporary USB mode is not supported in this release.

GridRoot would be: $($Context.GridRoot)

Persistent setup stores runtime state on a local fixed drive. Temporary mode will later reuse these modules with a USB runtime directory. Tailscale is a system-installed network client; this release will not add or remove it as part of a disposable USB session.
"@
    }
}
