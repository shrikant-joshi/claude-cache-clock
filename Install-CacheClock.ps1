# Cache Clock installer for Windows.
#   Install:            powershell -ExecutionPolicy Bypass -File .\Install-CacheClock.ps1
#   Also add status line (Claude Code): add -StatusLine
#   Uninstall:          powershell -ExecutionPolicy Bypass -File .\Install-CacheClock.ps1 -Uninstall
#   From WSL or Git Bash, use install.sh instead (it calls this script).
# Copies the widget to %LOCALAPPDATA%\CacheClock, adds Start menu + Startup shortcuts, and starts it.

param([switch]$StatusLine, [switch]$Uninstall, [switch]$NoPluginHint)
$ErrorActionPreference = 'Stop'

$src = Join-Path $PSScriptRoot 'plugin'
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
    Write-Host 'Cache Clock removed. Your data folder (%USERPROFILE%\.cache-clock) was left in place.'
    Write-Host 'In Claude Code, also run: /plugin uninstall cache-clock@cache-clock'
    return
}

Stop-Widget
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Copy-Item (Join-Path $src 'widget\CacheClock.ps1') $dest -Force
Copy-Item (Join-Path $src 'scripts\common.ps1') $dest -Force
Copy-Item (Join-Path $src 'scripts\statusline.ps1') $dest -Force
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

$slCmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + ((Join-Path $dest 'statusline.ps1') -replace '\\', '/') + '"'
if ($StatusLine) {
    $settingsPath = Join-Path $HOME '.claude\settings.json'
    $settings = $null
    if (Test-Path $settingsPath) { $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json }
    if ($settings -and $settings.PSObject.Properties['statusLine']) {
        Write-Host 'You already have a Claude Code status line, so I left it alone. To use this one, set:' -ForegroundColor Yellow
        Write-Host "  `"statusLine`": { `"type`": `"command`", `"command`": `"$($slCmd -replace '"','\"')`" }"
    } else {
        if (-not $settings) { $settings = [pscustomobject]@{} }
        if (Test-Path $settingsPath) { Copy-Item $settingsPath "$settingsPath.bak" -Force }
        New-Item -ItemType Directory -Path (Split-Path $settingsPath) -Force | Out-Null
        $settings | Add-Member -NotePropertyName statusLine -NotePropertyValue ([pscustomobject]@{ type = 'command'; command = $slCmd }) -Force
        [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
        Write-Host "Status line added to $settingsPath (backup: settings.json.bak)."
    }
}

Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $launchArgs
if ($NoPluginHint) { return }
Write-Host ''
Write-Host 'Next, in Claude Code, add the plugin:' -ForegroundColor Cyan
Write-Host "  /plugin marketplace add `"$PSScriptRoot`""
Write-Host '  /plugin install cache-clock@cache-clock'
