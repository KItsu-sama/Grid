#/ bootstrap/syncthing.ps1 - manage the Syncthing binary and local API for the personal grid
Set-StrictMode -Version Latest

function Get-GridSyncthingIdentityExists {
    param([Parameter(Mandatory = $true)]$Context)
    $cert = Join-Path $Context.SyncthingHome 'cert.pem'
    $key = Join-Path $Context.SyncthingHome 'key.pem'
    return ((Test-Path -LiteralPath $cert) -and (Test-Path -LiteralPath $key))
}

function Install-GridSyncthingBinary {
    param([Parameter(Mandatory = $true)]$Context)
    if (Test-Path -LiteralPath $Context.SyncthingBin) {
        return
    }
    $pkg = Get-GridVerifiedPackagePath -Context $Context -Id 'syncthing'
    $kind = [string]$pkg.Spec.kind
    $binaryName = [string]$pkg.Spec.binaryName

    if ($kind -eq 'portable-exe' -or $pkg.Path.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
        Initialize-GridDirectory -Path (Split-Path -Parent $Context.SyncthingBin)
        Copy-Item -LiteralPath $pkg.Path -Destination $Context.SyncthingBin -Force
        return
    }

    $extract = Join-Path $env:TEMP ("grid-syncthing-" + [guid]::NewGuid().ToString('N'))
    Initialize-GridDirectory -Path $extract
    try {
        Expand-Archive -LiteralPath $pkg.Path -DestinationPath $extract -Force
        $targetName = if ([string]::IsNullOrWhiteSpace($binaryName)) { 'syncthing.exe' } else { $binaryName }
        $exe = Get-ChildItem -Path $extract -Recurse -Filter $targetName | Select-Object -First 1
        if ($null -eq $exe) {
            $fallback = Get-ChildItem -Path $extract -Recurse -Filter 'syncthing.exe' | Select-Object -First 1
            if ($null -eq $fallback) {
                throw "Verified package $($pkg.Spec.file) does not contain $targetName or syncthing.exe."
            }
            $exe = $fallback
        }
        Initialize-GridDirectory -Path (Split-Path -Parent $Context.SyncthingBin)
        Copy-Item -LiteralPath $exe.FullName -Destination $Context.SyncthingBin -Force
    } finally {
        Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-GridSyncthingApiKey {
    param([Parameter(Mandatory = $true)]$Context)
    $xmlPath = Join-Path $Context.SyncthingHome 'config.xml'
    if (-not (Test-Path -LiteralPath $xmlPath)) { return $null }
    [xml]$xml = Get-Content -LiteralPath $xmlPath -Raw -Encoding UTF8
    $key = $xml.configuration.gui.apikey
    if ([string]::IsNullOrWhiteSpace($key)) { return $null }
    return [string]$key
}

function Get-GridSyncthingGuiBase {
    param([Parameter(Mandatory = $true)]$Context)
    return "http://$($Context.GuiAddress)"
}

function Invoke-GridSyncthingApi {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        $Body
    )
    $apiKey = Get-GridSyncthingApiKey -Context $Context
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        throw 'Syncthing API key is not available yet (config.xml missing apikey).'
    }
    $uri = (Get-GridSyncthingGuiBase -Context $Context).TrimEnd('/') + $Path
    $headers = @{ 'X-API-Key' = $apiKey }
    $params = @{
        Uri             = $uri
        Method          = $Method
        Headers         = $headers
        UseBasicParsing = $true
        TimeoutSec      = 15
    }
    if ($null -ne $Body) {
        $params.ContentType = 'application/json'
        $params.Body = (ConvertTo-GridJson -InputObject $Body)
    }
    $resp = Invoke-WebRequest @params
    if ([string]::IsNullOrWhiteSpace($resp.Content)) { return $null }
    try {
        return ($resp.Content | ConvertFrom-Json)
    } catch {
        return $resp.Content
    }
}

function Wait-GridSyncthingReady {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [int]$TimeoutSeconds = 60
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $status = Invoke-GridSyncthingApi -Context $Context -Method GET -Path '/rest/system/status'
            if ($null -ne $status -and -not [string]::IsNullOrWhiteSpace([string](Get-GridProperty $status 'myID'))) {
                return $status
            }
        } catch {
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Syncthing local API was not reachable at $($Context.GuiAddress) within ${TimeoutSeconds}s."
}

function Get-GridSyncthingArguments {
    param([Parameter(Mandatory = $true)]$Context)
    return @(
        "--home=`"$($Context.SyncthingHome)`"",
        '--no-browser',
        "--gui-address=$($Context.GuiAddress)",
        '--no-restart',
        '--no-upgrade'
    )
}

function Start-GridSyncthing {
    param([Parameter(Mandatory = $true)]$Context)
    Install-GridSyncthingBinary -Context $Context
    if (-not (Test-Path -LiteralPath $Context.SyncthingBin)) {
        throw "Syncthing binary missing: $($Context.SyncthingBin)"
    }
    Initialize-GridDirectory -Path $Context.SyncthingHome
    $owned = @(Get-GridSyncthingProcess -GridHome $Context.SyncthingHome)
    if ($owned.Count -gt 0) {
        return
    }
    $argList = Get-GridSyncthingArguments -Context $Context
    Start-Process -FilePath $Context.SyncthingBin -ArgumentList $argList -WindowStyle Hidden | Out-Null
    Wait-GridSyncthingReady -Context $Context | Out-Null
}

function Stop-GridSyncthing {
    param([Parameter(Mandatory = $true)]$Context)
    $owned = @(Get-GridSyncthingProcess -GridHome $Context.SyncthingHome)
    foreach ($p in $owned) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
}

function Get-GridSyncthingDeviceId {
    param([Parameter(Mandatory = $true)]$Context)
    if (Test-Path -LiteralPath $Context.SyncthingBin) {
        try {
            $out = & $Context.SyncthingBin "--home=$($Context.SyncthingHome)" '--device-id' 2>$null
            $id = ($out | Select-Object -First 1)
            if (-not [string]::IsNullOrWhiteSpace($id) -and $id.Trim() -match '-') {
                return $id.Trim()
            }
        } catch {
        }
    }

    try {
        $status = Invoke-GridSyncthingApi -Context $Context -Method GET -Path '/rest/system/status'
        $id = [string](Get-GridProperty $status 'myID')
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            return $id.Trim()
        }
    } catch {
    }

    return $null
}

function Initialize-GridSyncthingIdentity {
    param([Parameter(Mandatory = $true)]$Context)
    $existed = Get-GridSyncthingIdentityExists -Context $Context
    if ($existed) {
        Write-GridLog -Context $Context -Message 'Reusing existing Syncthing identity (cert/key present).'
    }
    Start-GridSyncthing -Context $Context
    $id = Get-GridSyncthingDeviceId -Context $Context
    if ([string]::IsNullOrWhiteSpace($id)) {
        throw 'Syncthing started but no device ID was returned.'
    }
    if ($existed) {
        Write-GridLog -Context $Context -Message "Syncthing device ID unchanged: $id"
    } else {
        Write-GridLog -Context $Context -Message "Syncthing created a new device ID: $id"
    }
    return $id
}
