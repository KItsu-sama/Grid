#/ bootstrap/tailscale.ps1 - manage the Tailscale binary and service for the personal grid
Set-StrictMode -Version Latest

function Get-GridPackageManifest {
    param([Parameter(Mandatory = $true)]$Context)
    $path = Join-Path $Context.BootstrapRoot 'packages\manifest.json'
    return (ConvertFrom-GridJson -Path $path -Label 'packages/manifest.json')
}

function Get-GridHostArch {
    param($Environment)
    if ($null -ne $Environment -and $null -ne $Environment.Architecture) {
        return [string]$Environment.Architecture
    }
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -eq 'AMD64') { return 'amd64' }
    if ($arch -eq 'ARM64') { return 'arm64' }
    return 'amd64'
}

function Find-GridPackageSpec {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Arch
    )
    if ([string]::IsNullOrWhiteSpace($Arch)) {
        $Arch = Get-GridHostArch -Environment (Get-GridProperty $Context 'Environment')
    }
    $manifest = Get-GridPackageManifest -Context $Context
    $matches = @($manifest.packages | Where-Object { $_.id -eq $Id -and $_.arch -eq $Arch })
    if ($matches.Count -eq 0) {
        throw "No package spec for id='$Id' arch='$Arch' in packages/manifest.json. A different architecture package is never substituted."
    }
    return $matches[0]
}

function Resolve-GridPackageFile {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Spec
    )
    $name = [string]$Spec.file
    $candidates = @(
        (Join-Path $Context.BootstrapRoot "packages\$name")
    )
    if (-not [string]::IsNullOrWhiteSpace($Context.GridRoot)) {
        $candidates += (Join-Path $Context.GridRoot "packages\$name")
    }
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }
    return $null
}

function Test-GridPackageHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Spec
    )
    $expected = ([string]$Spec.sha256).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($expected) -or $expected -eq 'replace_me') {
        throw @"
Package '$($Spec.file)' is present but has no pinned SHA-256 in packages/manifest.json.

Replace REPLACE_ME with the file hash, then rerun setup. Unverified installers are never executed.
"@
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "SHA-256 mismatch for $($Spec.file). Expected $expected, computed $actual. The file was not installed."
    }
}

function Copy-GridVerifiedPackage {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Spec
    )
    if ([string]::IsNullOrWhiteSpace($Context.GridRoot)) { return }
    $cache = Join-Path $Context.GridRoot 'packages'
    Initialize-GridDirectory -Path $cache
    $dest = Join-Path $cache $Spec.file
    if ($Path.ToLowerInvariant() -ne $dest.ToLowerInvariant()) {
        Copy-Item -LiteralPath $Path -Destination $dest -Force
    }
}

function Get-GridVerifiedPackagePath {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Id
    )
    $spec = Find-GridPackageSpec -Context $Context -Id $Id
    $path = Resolve-GridPackageFile -Context $Context -Spec $spec
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw @"
Missing offline package for '$Id'.

Expected file: $($spec.file)
Looked in: $($Context.BootstrapRoot)\packages and $($Context.GridRoot)\packages

Copy the vendor file onto the USB, set its SHA-256 in packages\manifest.json, and rerun. Setup will not download it automatically.
"@
    }
    Test-GridPackageHash -Path $path -Spec $spec
    Copy-GridVerifiedPackage -Context $Context -Path $path -Spec $spec
    return [pscustomobject]@{ Path = $path; Spec = $spec }
}

function Get-GridTailscaleAddress {
    $exe = Get-Command 'tailscale.exe' -ErrorAction SilentlyContinue
    if ($null -eq $exe) { return $null }
    try {
        $ip = & $exe.Source ip -4 2>$null | Select-Object -First 1
        if (-not [string]::IsNullOrWhiteSpace($ip)) { return $ip.Trim() }
    } catch {
    }
    return $null
}

function Get-GridTailscaleBackendState {
    $exe = Get-Command 'tailscale.exe' -ErrorAction SilentlyContinue
    if ($null -eq $exe) { return 'missing' }
    try {
        $json = & $exe.Source status --json 2>$null | Out-String
        if ([string]::IsNullOrWhiteSpace($json)) { return 'unknown' }
        $obj = $json | ConvertFrom-Json
        $backend = Get-GridProperty $obj 'BackendState'
        if ($null -ne $backend) { return [string]$backend }
    } catch {
    }
    return 'unknown'
}

function Start-GridTailscaleService {
    $status = Get-GridTailscaleStatus
    if (-not $status.Service.Installed) { return $status }
    if ($status.Service.Status -ne 'Running') {
        try {
            Start-Service -Name $status.Service.Name -ErrorAction Stop
        } catch {
            throw "Tailscale service '$($status.Service.Name)' is installed but could not be started: $($_.Exception.Message)"
        }
    }
    return (Get-GridTailscaleStatus)
}

function Invoke-GridTailscaleLogin {
    param([Parameter(Mandatory = $true)]$Context)
    $exe = Get-Command 'tailscale.exe' -ErrorAction SilentlyContinue
    if ($null -eq $exe) { throw 'tailscale.exe is not on PATH after install.' }
    $interactive = [bool](Get-GridProperty $Context.Settings.tailscale 'authenticateInteractively' $true)
    $backend = Get-GridTailscaleBackendState
    if ($backend -eq 'Running') {
        Write-GridLog -Context $Context -Message 'Tailscale is already authenticated; leaving the existing tailnet connection unchanged.'
        return
    }
    if (-not $interactive) {
        Write-GridLog -Level WARN -Context $Context -Message "Tailscale backend state is '$backend' and interactive login is disabled."
        return
    }
    Write-GridLog -Context $Context -Message 'Launching Tailscale interactive login. Complete sign-in in the vendor UI. Existing connections are not logged out.'
    Start-Process -FilePath $exe.Source -ArgumentList @('login') -Wait | Out-Null
}

function Install-GridTailscalePackage {
    param([Parameter(Mandatory = $true)]$Context)
    $pkg = Get-GridVerifiedPackagePath -Context $Context -Id 'tailscale'
    Write-GridLog -Context $Context -Message "Installing verified Tailscale package $($pkg.Spec.file)"

    $kind = [string]$pkg.Spec.kind
    $file = $pkg.Path
    $args = @('/quiet')
    if ($pkg.Path.EndsWith('.msi', [System.StringComparison]::OrdinalIgnoreCase) -or $kind -eq 'msi') {
        $file = 'msiexec.exe'
        $args = @('/i', $pkg.Path, '/qn')
    }

    $p = Start-Process -FilePath $file -ArgumentList $args -Wait -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        throw "Tailscale installer exited with code $($p.ExitCode)."
    }
}

function Invoke-GridTailscaleStage {
    param([Parameter(Mandatory = $true)]$Context)
    if (-not [bool](Get-GridProperty $Context.Settings.tailscale 'enabled' $true)) {
        Write-GridLog -Context $Context -Message 'Tailscale disabled in config; skipping.'
        return
    }
    $status = Get-GridTailscaleStatus
    if ($status.Installed) {
        Write-GridLog -Context $Context -Message 'Existing Tailscale installation detected; it will not be reinstalled or logged out.'
    } else {
        Install-GridTailscalePackage -Context $Context
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
        $status = Get-GridTailscaleStatus
        if (-not $status.Installed) {
            throw 'Tailscale package ran but tailscale.exe / service was not detected.'
        }
    }
    Start-GridTailscaleService | Out-Null
    Invoke-GridTailscaleLogin -Context $Context
    $addr = Get-GridTailscaleAddress
    $backend = Get-GridTailscaleBackendState
    Write-GridLog -Context $Context -Message "Tailscale state=$backend address=$addr"
}
