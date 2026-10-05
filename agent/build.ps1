Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$go = Get-Command go.exe -ErrorAction SilentlyContinue
if ($null -eq $go) {
    throw 'Go 1.26 or newer is required to build the native Grid Agent.'
}

Push-Location $PSScriptRoot
try {
    & $go.Source test ./...
    if ($LASTEXITCODE -ne 0) { throw "Go tests failed with exit code $LASTEXITCODE." }

    $outputDirectory = Join-Path $PSScriptRoot 'bin'
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    $output = Join-Path $outputDirectory 'grid-agent.exe'
    & $go.Source build -trimpath -ldflags '-s -w' -o $output .\cmd\grid-agent
    if ($LASTEXITCODE -ne 0) { throw "Go build failed with exit code $LASTEXITCODE." }

    Write-Output "Built $output"
} finally {
    Pop-Location
}
