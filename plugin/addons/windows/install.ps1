# Cache Clock: Windows widget add-on installer (optional).
#   Install:    powershell -ExecutionPolicy Bypass -File install.ps1
#   Uninstall:  powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
# /cache-clock:setup runs this for you. Without it, the plugin still starts the widget from its
# own folder at each session start. Installing adds a stable copy in %LOCALAPPDATA%\CacheClock,
# Start menu and Startup shortcuts, and starts it. Plugin updates refresh the copy (launch.ps1).

param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # plugin root
$dest = Join-Path $env:LOCALAPPDATA 'CacheClock'
$startup = [Environment]::GetFolderPath('Startup')
$programs = [Environment]::GetFolderPath('Programs')
$lnkName = 'Cache Clock.lnk'

function Stop-Widget {
    $pidFile = Join-Path $HOME '.cache-clock\widget.pid'
    if (Test-Path $pidFile) {
        $p = 0; [void][int]::TryParse((Get-Content $pidFile -Raw).Trim(), [ref]$p)
        if ($p) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
    }
}

if ($Uninstall) {
    Stop-Widget
    Remove-Item (Join-Path $startup $lnkName), (Join-Path $programs $lnkName) -ErrorAction SilentlyContinue
    Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'Cache Clock widget removed. Your data folder (%USERPROFILE%\.cache-clock) was left in place.'
    return
}

Stop-Widget
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'CacheClock.ps1') $dest -Force
Copy-Item (Join-Path $root '.claude-plugin\plugin.json') $dest -Force   # version, for the widget and plugin sync
Get-ChildItem $dest -Filter *.ps1 | Unblock-File

$widget = Join-Path $dest 'CacheClock.ps1'
$launchArgs = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$widget`""
$shell = New-Object -ComObject WScript.Shell
foreach ($dir in @($startup, $programs)) {
    $lnk = $shell.CreateShortcut((Join-Path $dir $lnkName))
    $lnk.TargetPath = 'powershell.exe'
    $lnk.Arguments = $launchArgs
    $lnk.WindowStyle = 7   # minimized
    $lnk.IconLocation = 'shell32.dll,265'
    $lnk.Description = 'Prompt-cache countdown for Claude'
    $lnk.Save()
}
Write-Host "Widget installed to $dest (starts with Windows; also in the Start menu as 'Cache Clock')."

Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $launchArgs
