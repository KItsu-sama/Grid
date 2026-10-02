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
    foreach ($folder in Get-GridEnabledFolders -Context $Context) {
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
    Initialize-GridDirectory -Path $dest
    Initialize-GridDirectory -Path (Join-Path $dest 'bootstrap')
    Initialize-GridDirectory -Path (Join-Path $dest 'config')
    Copy-Item -LiteralPath (Join-Path $Context.BootstrapRoot 'Grid.ps1') -Destination (Join-Path $dest 'Grid.ps1') -Force
    Get-ChildItem -LiteralPath (Join-Path $Context.BootstrapRoot 'bootstrap') -Filter '*.ps1' | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path (Join-Path $dest 'bootstrap') $_.Name) -Force
    }
    Get-ChildItem -LiteralPath (Join-Path $Context.BootstrapRoot 'config') -Filter '*.example.json' | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path (Join-Path $dest 'config') $_.Name) -Force
    }
}

function Reset-GridRootData {
    param([Parameter(Mandatory = $true)]$Context)
    $paths = @(
        (Join-Path $Context.GridRoot '.grid'),
        (Join-Path $Context.GridRoot 'bin'),
        (Join-Path $Context.GridRoot 'ZinoSync'),
        (Join-Path $Context.GridRoot 'state')
    )
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
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
    if ($Context.IsRoot) {
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
