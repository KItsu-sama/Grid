#/ bootstrap/install.ps1 - install the personal grid and bootstrap the environment
Set-StrictMode -Version Latest

function New-GridVersionFile {
    param([Parameter(Mandatory = $true)]$Context)
    $version = [pscustomobject]@{
        schemaVersion = 1
        product       = 'PersonalGrid'
        bootstrap     = '1.0.0-persistent'
        writtenAt     = (Get-GridNowUtc)
        mode          = $Context.Mode
        gridRoot      = $Context.GridRoot
    }
    Write-GridJsonAtomic -Path (Join-Path $Context.GridRoot '.grid\version.json') -InputObject $version
}

function Initialize-GridDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Initialize-GridFolderLayout {
    param([Parameter(Mandatory = $true)]$Context)
    Initialize-GridDirectory -Path $Context.GridRoot
    Initialize-GridDirectory -Path (Join-Path $Context.GridRoot '.grid')
    Initialize-GridDirectory -Path (Join-Path $Context.GridRoot '.grid\logs')
    Initialize-GridDirectory -Path $Context.SyncthingHome
    Initialize-GridDirectory -Path (Join-Path $Context.GridRoot 'bin')
    Initialize-GridDirectory -Path (Join-Path $Context.GridRoot 'packages')
    Initialize-GridDirectory -Path (Get-GridSyncRoot -Context $Context)
    foreach ($folder in Get-GridSyncFolders -Context $Context) {
        Initialize-GridDirectory -Path (Get-GridFolderPath -Context $Context -Folder $folder)
    }
}

function Write-GridDeviceStub {
    param([Parameter(Mandatory = $true)]$Context)
    if (Test-Path -LiteralPath $Context.DevicePath) {
        return
    }
    $device = [pscustomobject]@{
        schemaVersion = 1
        deviceName    = $Context.DeviceName
        role          = [string](Get-GridProperty $Context.Settings.device 'role' 'development')
        isMain        = [bool](Get-GridProperty $Context.Settings.device 'isMain' $false)
        mode          = $Context.Mode
        syncEnabled   = [bool](Get-GridProperty $Context.Settings.syncthing 'enabled' $true)
        gridRoot      = $Context.GridRoot
        createdAt     = (Get-GridNowUtc)
    }
    Write-GridJsonAtomic -Path $Context.DevicePath -InputObject $device
}

function Copy-GridBootstrapSnapshot {
    param([Parameter(Mandatory = $true)]$Context)
    $dest = Join-Path $Context.GridRoot '.grid\bootstrap'
    if ([System.IO.Path]::GetFullPath($Context.BootstrapRoot).TrimEnd('\') -eq [System.IO.Path]::GetFullPath($dest).TrimEnd('\')) {
        return
    }
    Initialize-GridDirectory -Path $dest
    Initialize-GridDirectory -Path (Join-Path $dest 'bootstrap')
    Initialize-GridDirectory -Path (Join-Path $dest 'config')
    Initialize-GridDirectory -Path (Join-Path $dest 'packages')
    Copy-Item -LiteralPath (Join-Path $Context.BootstrapRoot 'Grid.ps1') -Destination (Join-Path $dest 'Grid.ps1') -Force
    Get-ChildItem -LiteralPath (Join-Path $Context.BootstrapRoot 'bootstrap') -Filter '*.ps1' | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path (Join-Path $dest 'bootstrap') $_.Name) -Force
    }
    Get-ChildItem -LiteralPath (Join-Path $Context.BootstrapRoot 'config') -Filter '*.example.json' | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path (Join-Path $dest 'config') $_.Name) -Force
    }
    $snapshotGridConfig = Join-Path $dest 'config\grid.json'
    $snapshotSettings = (ConvertTo-GridJson -InputObject $Context.Settings) | ConvertFrom-Json
    $snapshotSettings.persistent.targetPath = $Context.GridRoot
    Write-GridJsonAtomic -Path $snapshotGridConfig -InputObject $snapshotSettings
    $snapshotSyncConfig = Join-Path $dest 'config\syncconfig.json'
    Remove-Item -LiteralPath $snapshotSyncConfig -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Context.SyncConfigPath) {
        Copy-Item -LiteralPath $Context.SyncConfigPath -Destination $snapshotSyncConfig -Force
    }
    $packageManifest = Join-Path $Context.BootstrapRoot 'packages\manifest.json'
    if (Test-Path -LiteralPath $packageManifest) {
        Copy-Item -LiteralPath $packageManifest -Destination (Join-Path $dest 'packages\manifest.json') -Force
    }
    foreach ($packageRoot in @((Join-Path $Context.BootstrapRoot 'packages'), (Join-Path $Context.GridRoot 'packages'))) {
        if (Test-Path -LiteralPath $packageRoot) {
            Get-ChildItem -LiteralPath $packageRoot -File -ErrorAction SilentlyContinue | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path (Join-Path $dest 'packages') $_.Name) -Force
            }
        }
    }
}

function Reset-GridRootData {
    param([Parameter(Mandatory = $true)]$Context)
    $paths = @((Join-Path $Context.GridRoot '.grid'))
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $Context.SyncthingBin -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Context.SyncConfigPath) {
        Remove-Item -LiteralPath $Context.SyncConfigPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath (Get-GridUsbSyncConfigPath -Context $Context)) {
        Remove-Item -LiteralPath (Get-GridUsbSyncConfigPath -Context $Context) -Force -ErrorAction SilentlyContinue
    }
    Write-GridLog -Context $Context -Message "Reset stale root data for $($Context.GridRoot) before repopulating the new device identity."
}

function Initialize-GridInstallation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$State
    )
    if ([string]::IsNullOrWhiteSpace($Context.GridRoot)) {
        throw 'GridRoot is not resolved. Load and detect must run first.'
    }
    if ($Context.IsRoot -and -not (Test-Path -LiteralPath $Context.DevicePath)) {
        Reset-GridRootData -Context $Context
    }
    Write-GridLog -Context $Context -Message "Preparing persistent installation at $($Context.GridRoot) (mode=$($Context.Mode))"
    Initialize-GridFolderLayout -Context $Context
    Write-GridDeviceStub -Context $Context
    New-GridVersionFile -Context $Context
    Copy-GridBootstrapSnapshot -Context $Context
    Protect-GridSensitivePath -Path (Join-Path $Context.GridRoot '.grid')
    if (-not (Test-Path -LiteralPath $Context.StatePath)) {
        Write-GridInstallState -Context $Context -State $State
    }
}

function Repair-GridInstallationFiles {
    param([Parameter(Mandatory = $true)]$Context)
    Initialize-GridFolderLayout -Context $Context
    if (-not (Test-Path -LiteralPath $Context.DevicePath)) {
        Write-GridDeviceStub -Context $Context
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Context.GridRoot '.grid\version.json'))) {
        New-GridVersionFile -Context $Context
    }
    Copy-GridBootstrapSnapshot -Context $Context
    Protect-GridSensitivePath -Path (Join-Path $Context.GridRoot '.grid')
}

function Uninstall-GridInstallation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [switch]$RemoveData,
        [switch]$RemoveDefaultSync
    )
    $syncRoot = $null
    $defaultSyncRoot = $null
    if ($RemoveData) {
        $gridRoot = [System.IO.Path]::GetFullPath($Context.GridRoot).TrimEnd('\')
        $syncRoot = [System.IO.Path]::GetFullPath((Get-GridSyncRoot -Context $Context)).TrimEnd('\')
        if (-not $syncRoot.StartsWith($gridRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove sync data outside GridRoot: $syncRoot"
        }
    }
    if ($RemoveDefaultSync) {
        if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { throw 'USERPROFILE is not set; refusing to locate the default Sync folder.' }
        $profileRoot = [System.IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
        $defaultSyncRoot = [System.IO.Path]::GetFullPath((Join-Path $profileRoot 'Sync'))
        if (-not $defaultSyncRoot.StartsWith($profileRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove a Sync folder outside USERPROFILE: $defaultSyncRoot"
        }
        if (Test-Path -LiteralPath $defaultSyncRoot) {
            $syncItem = Get-Item -LiteralPath $defaultSyncRoot -Force
            if (($syncItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to recursively remove a reparse-point Sync folder: $defaultSyncRoot"
            }
        }
    }
    Stop-GridSyncthing -Context $Context
    Unregister-GridSyncthingStartup
    Write-GridLog -Context $Context -Message 'Removing Personal Grid runtime state. Tailscale remains installed and signed in.'
    if (Test-Path -LiteralPath (Join-Path $Context.GridRoot '.grid')) {
        Remove-Item -LiteralPath (Join-Path $Context.GridRoot '.grid') -Recurse -Force
    }
    if (Test-Path -LiteralPath $Context.SyncthingBin) {
        Remove-Item -LiteralPath $Context.SyncthingBin -Force
    }
    $binDirectory = Split-Path -Parent $Context.SyncthingBin
    if ((Test-Path -LiteralPath $binDirectory) -and @(Get-ChildItem -LiteralPath $binDirectory -Force).Count -eq 0) {
        Remove-Item -LiteralPath $binDirectory -Force
    }
    if ($RemoveData) {
        if (Test-Path -LiteralPath $syncRoot) {
            Remove-Item -LiteralPath $syncRoot -Recurse -Force
        }
    }
    if ($RemoveDefaultSync -and (Test-Path -LiteralPath $defaultSyncRoot)) {
        Remove-Item -LiteralPath $defaultSyncRoot -Recurse -Force
    }
}
