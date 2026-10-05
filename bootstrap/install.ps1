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
        $existing = Read-GridDeviceDocument -Context $Context
        if ([string]::IsNullOrWhiteSpace([string](Get-GridProperty $existing 'gridDeviceId' ''))) {
            $existing | Add-Member -NotePropertyName gridDeviceId -NotePropertyValue ([guid]::NewGuid().ToString('N')) -Force
            $gridRole = [string](Get-GridProperty $Context.Settings.device 'role' '').ToUpperInvariant()
            if ([bool](Get-GridProperty $existing 'isMain' $false)) { $gridRole = 'MAIN' }
            elseif ($gridRole -notin @('WORKER', 'CLIENT')) { $gridRole = 'CLIENT' }
            $existing | Add-Member -NotePropertyName gridRole -NotePropertyValue $gridRole -Force
            Write-GridJsonAtomic -Path $Context.DevicePath -InputObject $existing
        }
        return
    }
    $gridRole = [string](Get-GridProperty $Context.Settings.device 'role' '').ToUpperInvariant()
    $isMain = [bool](Get-GridProperty $Context.Settings.device 'isMain' $false)
    if ($isMain) { $gridRole = 'MAIN' }
    elseif ($gridRole -notin @('WORKER', 'CLIENT')) { $gridRole = 'CLIENT' }
    $device = [pscustomobject]@{
        schemaVersion = 1
        gridDeviceId  = [guid]::NewGuid().ToString('N')
        gridRole      = $gridRole
        deviceName    = $Context.DeviceName
        role          = [string](Get-GridProperty $Context.Settings.device 'role' 'development')
        isMain        = $isMain
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
    Initialize-GridDirectory -Path (Join-Path $dest 'agent')
    Copy-Item -LiteralPath (Join-Path $Context.BootstrapRoot 'Grid.ps1') -Destination (Join-Path $dest 'Grid.ps1') -Force
    $nativeAgent = Join-Path $Context.BootstrapRoot 'agent\bin\grid-agent.exe'
    if (Test-Path -LiteralPath $nativeAgent -PathType Leaf) {
        $snapshotAgentBin = Join-Path $dest 'agent\bin'
        Initialize-GridDirectory -Path $snapshotAgentBin
        Copy-Item -LiteralPath $nativeAgent -Destination (Join-Path $snapshotAgentBin 'grid-agent.exe') -Force
    }
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

function Test-GridAgentPortListening {
    param([Parameter(Mandatory = $true)][int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    $pending = $null
    try {
        $pending = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne(500)) { return $false }
        $client.EndConnect($pending)
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $pending) { $pending.AsyncWaitHandle.Close() }
        $client.Dispose()
    }
}

function Stop-GridAgent {
    param([Parameter(Mandatory = $true)]$Context)
    $agentState = Join-Path $Context.GridRoot '.grid\agent'
    $port = 8765
    $configPath = Join-Path $agentState 'config.json'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $agentConfig = ConvertFrom-GridJson -Path $configPath -Label 'agent config.json'
            $configuredPort = [int](Get-GridProperty $agentConfig 'local_port' $port)
            if ($configuredPort -ge 1 -and $configuredPort -le 65535) { $port = $configuredPort }
        } catch {
            throw "Cannot safely stop Grid Agent because its local config is invalid: $($_.Exception.Message)"
        }
    }
    if (-not (Test-GridAgentPortListening -Port $port)) { return }

    $tokenPath = Join-Path $agentState 'admin.token'
    if (-not (Test-Path -LiteralPath $tokenPath -PathType Leaf)) {
        throw "Grid Agent is listening on port $port but its admin token is missing; refusing to remove runtime state."
    }
    $token = (Get-Content -LiteralPath $tokenPath -Raw -ErrorAction Stop).Trim()
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'Grid Agent admin token is empty; refusing to remove runtime state.'
    }
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$port/shutdown" -Method Post `
            -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 3 -ErrorAction Stop | Out-Null
    } catch {
        if (-not (Test-GridAgentPortListening -Port $port)) { return }
        throw "Could not request a safe Grid Agent shutdown: $($_.Exception.Message)"
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Test-GridAgentPortListening -Port $port)) { return }
        Start-Sleep -Milliseconds 200
    }
    throw "Grid Agent did not stop listening on port $port; refusing to remove runtime state."
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
    Stop-GridAgent -Context $Context
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
