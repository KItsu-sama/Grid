Set-StrictMode -Version Latest

function Get-GridStartupShortcutPath {
    $startup = [Environment]::GetFolderPath('Startup')
    return (Join-Path $startup 'PersonalGrid-Syncthing.lnk')
}

function Register-GridSyncthingStartup {
    param([Parameter(Mandatory = $true)]$Context)
    $autostart = [bool](Get-GridProperty $Context.Settings.persistent 'autostart' $true)
    if (-not $autostart) {
        Write-GridLog -Context $Context -Message 'persistent.autostart is false; not creating a Startup shortcut.'
        return
    }
    $linkPath = Get-GridStartupShortcutPath
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($linkPath)
    $shortcut.TargetPath = $Context.SyncthingBin
    $shortcut.Arguments = "--home=`"$($Context.SyncthingHome)`" --no-browser --gui-address=$($Context.GuiAddress) --no-restart"
    $shortcut.WorkingDirectory = Split-Path -Parent $Context.SyncthingBin
    $shortcut.WindowStyle = 7
    $shortcut.Description = 'Personal Grid Syncthing (localhost GUI only)'
    $shortcut.Save()
    Write-GridLog -Context $Context -Message "Registered current-user Startup shortcut: $linkPath"
}

function Unregister-GridSyncthingStartup {
    $linkPath = Get-GridStartupShortcutPath
    if (Test-Path -LiteralPath $linkPath) {
        Remove-Item -LiteralPath $linkPath -Force
    }
}

function Invoke-GridStartupStage {
    param([Parameter(Mandatory = $true)]$Context)
    Write-GridLog -Context $Context -Message 'Tailscale continues to run via its Windows service. Syncthing is registered for the current user only.'
    Start-GridTailscaleService | Out-Null
    Register-GridSyncthingStartup -Context $Context
    Start-GridSyncthing -Context $Context
}
