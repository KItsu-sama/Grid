#/ bootstrap/load.ps1 - load the personal grid bootstrap environment
Set-StrictMode -Version Latest

$script:GridSupportedSchema = 1
$script:GridRedactPattern = '(?i)(api[_-]?key|auth[_-]?key|password|secret|private[_-]?key)\s*[:=]\s*\S+'

function Get-GridNowUtc {
    return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function ConvertFrom-GridJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Label not found: $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "$Label is empty: $Path"
    }
    try {
        return $raw | ConvertFrom-Json
    } catch {
        throw "$Label is not valid JSON ($Path): $($_.Exception.Message)"
    }
}

function ConvertTo-GridJson {
    param([Parameter(Mandatory = $true)]$InputObject)
    return ($InputObject | ConvertTo-Json -Depth 12)
}

function Write-GridJsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$InputObject
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json = ConvertTo-GridJson -InputObject $InputObject
    $temp = "$Path.tmp"
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($temp, $json, $utf8NoBom)
    if (Test-Path -LiteralPath $Path) {
        Move-Item -LiteralPath $temp -Destination $Path -Force
    } else {
        Move-Item -LiteralPath $temp -Destination $Path
    }
}

function Protect-GridSensitivePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $Path /inheritance:r /grant:r "${user}:(OI)(CI)F" | Out-Null
}

function Write-GridLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        $Context
    )
    $redacted = [regex]::Replace($Message, $script:GridRedactPattern, '$1=***')
    $line = "$(Get-GridNowUtc) [$Level] $redacted"
    Write-Host $line
    if ($null -ne $Context -and -not [string]::IsNullOrWhiteSpace($Context.LogPath)) {
        $logDir = Split-Path -Parent $Context.LogPath
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -LiteralPath $Context.LogPath -Value $line -Encoding UTF8
    }
}

function Get-GridProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    return $prop.Value
}

function Test-GridSettings {
    param(
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)][string]$SourcePath
    )
    $schema = Get-GridProperty $Settings 'schemaVersion'
    if ($null -eq $schema) {
        throw "Config missing schemaVersion: $SourcePath"
    }
    if ([int]$schema -ne $script:GridSupportedSchema) {
        throw "Unsupported config schemaVersion '$schema' in $SourcePath. Supported: $($script:GridSupportedSchema). The file was not changed."
    }
    foreach ($name in @('defaultMode', 'persistent', 'device', 'tailscale', 'syncthing')) {
        if ($null -eq (Get-GridProperty $Settings $name)) {
            throw "Config missing required property '$name': $SourcePath"
        }
    }
    $isRootRaw = Get-GridProperty $Settings 'is_root'
    $isRootAlt = Get-GridProperty $Settings 'isRoot'
    if ($null -ne $isRootRaw -and $isRootRaw -notin @($true, $false)) {
        throw "Config is_root must be true or false: $SourcePath"
    }
    if ($null -ne $isRootAlt -and $isRootAlt -notin @($true, $false)) {
        throw "Config isRoot must be true or false: $SourcePath"
    }
    $canBeMain = Get-GridProperty $Settings 'can_be_main' $false
    if ($canBeMain -notin @($true, $false)) {
        throw "Config can_be_main must be true or false: $SourcePath"
    }
    if ([bool](Get-GridProperty $Settings.device 'isMain' $false) -and -not [bool]$canBeMain) {
        throw "Config device.isMain requires can_be_main=true: $SourcePath"
    }
    $mode = [string](Get-GridProperty $Settings 'defaultMode')
    if (@('persistent', 'temporary') -notcontains $mode) {
        throw "Config defaultMode must be 'persistent' or 'temporary': $SourcePath"
    }
    $persistent = Get-GridProperty $Settings 'persistent'
    foreach ($name in @('targetDrive', 'targetFolder', 'minimumFreeBytes')) {
        if ($null -eq (Get-GridProperty $persistent $name)) {
            throw "Config missing persistent.${name}: $SourcePath"
        }
    }
    $st = Get-GridProperty $Settings 'syncthing'
    if ($null -eq (Get-GridProperty $st 'folders')) {
        throw "Config missing syncthing.folders: $SourcePath"
    }
}

function Import-GridSettings {
    param([Parameter(Mandatory = $true)][string]$BootstrapRoot)
    $userPath = Join-Path $BootstrapRoot 'config\grid.json'
    $examplePath = Join-Path $BootstrapRoot 'config\grid.example.json'
    if (Test-Path -LiteralPath $userPath) {
        $settings = ConvertFrom-GridJson -Path $userPath -Label 'grid.json'
        Test-GridSettings -Settings $settings -SourcePath $userPath
        return [pscustomobject]@{ Settings = $settings; SourcePath = $userPath; UsedExample = $false }
    }
    $settings = ConvertFrom-GridJson -Path $examplePath -Label 'grid.example.json'
    Test-GridSettings -Settings $settings -SourcePath $examplePath
    return [pscustomobject]@{ Settings = $settings; SourcePath = $examplePath; UsedExample = $true }
}

function New-GridContext {
    param(
        [Parameter(Mandatory = $true)][string]$LauncherRoot,
        [Parameter(Mandatory = $true)][string]$Command,
        [string]$Mode,
        [string]$TargetPath,
        [switch]$Seed,
        [switch]$NonInteractive
    )
    $bootstrapRoot = [System.IO.Path]::GetFullPath($LauncherRoot)
    $loaded = Import-GridSettings -BootstrapRoot $bootstrapRoot
    $resolvedMode = $Mode
    if ([string]::IsNullOrWhiteSpace($resolvedMode)) {
        $resolvedMode = [string]$loaded.Settings.defaultMode
    }
    $resolvedMode = $resolvedMode.ToLowerInvariant()
    if (@('persistent', 'temporary') -notcontains $resolvedMode) {
        throw "Unsupported mode '$resolvedMode'."
    }
    $deviceName = [string](Get-GridProperty $loaded.Settings.device 'name')
    if ([string]::IsNullOrWhiteSpace($deviceName)) {
        $deviceName = $env:COMPUTERNAME
    }
    $isRoot = [bool](Get-GridProperty $loaded.Settings 'is_root')
    if ($null -eq $isRoot -or $isRoot -eq $false) {
        $isRoot = [bool](Get-GridProperty $loaded.Settings 'isRoot')
    }
    $canBeMain = [bool](Get-GridProperty $loaded.Settings 'can_be_main' $false)
    return [pscustomobject]@{
        Command          = $Command
        BootstrapRoot    = $bootstrapRoot
        Settings         = $loaded.Settings
        SettingsPath     = $loaded.SourcePath
        UsedExample      = $loaded.UsedExample
        Mode             = $resolvedMode
        TargetPathHint   = $TargetPath
        SeedRequested    = [bool]$Seed
        NonInteractive   = [bool]$NonInteractive
        IsRoot           = [bool]$isRoot
        CanBeMain        = $canBeMain
        GridRoot         = $null
        StatePath        = $null
        DevicePath       = $null
        SyncConfigPath   = $null
        SyncthingHome    = $null
        SyncthingBin     = $null
        LogPath          = $null
        DeviceName       = $deviceName
        TemporaryRuntime = Join-Path $bootstrapRoot 'PersonalGrid\runtime'
        GuiAddress       = $(
            $g = Get-GridProperty $loaded.Settings.syncthing 'guiAddress'
            if ([string]::IsNullOrWhiteSpace($g)) { '127.0.0.1:8384' } else { [string]$g }
        )
    }
}

function Set-GridContextRoot {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$GridRoot
    )
    $root = [System.IO.Path]::GetFullPath($GridRoot)
    $Context.GridRoot = $root
    $dot = Join-Path $root '.grid'
    $Context.StatePath = Join-Path $dot 'install-state.json'
    $Context.DevicePath = Join-Path $dot 'device.json'
    $Context.SyncConfigPath = Join-Path $dot 'syncconfig.json'
    $Context.SyncthingHome = Join-Path $dot 'syncthing'
    $Context.SyncthingBin = Join-Path $root 'bin\syncthing.exe'
    $Context.LogPath = Join-Path $dot 'logs\grid.log'
    return $Context
}

function Get-GridUsbSyncConfigPath {
    param([Parameter(Mandatory = $true)]$Context)
    return (Join-Path $Context.BootstrapRoot 'config\syncconfig.json')
}

function Get-GridExampleSyncConfigPath {
    param([Parameter(Mandatory = $true)]$Context)
    return (Join-Path $Context.BootstrapRoot 'config\syncconfig.example.json')
}

function Assert-GridWindowsHost {
    if ($env:OS -ne 'Windows_NT') {
        throw 'Personal Grid bootstrap requires Windows.'
    }
}

function Get-GridEnabledFolders {
    param([Parameter(Mandatory = $true)]$Context)
    $folders = @()
    foreach ($folder in @($Context.Settings.syncthing.folders)) {
        $enabled = Get-GridProperty $folder 'enabled' $true
        if ($enabled) { $folders += $folder }
    }
    return $folders
}

function Get-GridSyncRoot {
    param([Parameter(Mandatory = $true)]$Context)
    $name = [string](Get-GridProperty $Context.Settings.syncthing 'rootFolder' 'ZinoSync')
    return (Join-Path $Context.GridRoot $name)
}

function Get-GridFolderPath {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Folder
    )
    return (Join-Path (Get-GridSyncRoot -Context $Context) ([string]$Folder.name))
}
