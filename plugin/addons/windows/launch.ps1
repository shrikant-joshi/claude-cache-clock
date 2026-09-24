# Cache Clock: Windows widget launcher (the Windows add-on's entry point).
# Called in the background by the plugin's SessionStart hook (cc.sh) from WSL or Git Bash.
#   1. If the widget is installed (%LOCALAPPDATA%\CacheClock, see install.ps1) and this plugin is
#      newer, copy the new widget there and restart it. Upgrade-only, so sessions on different
#      plugin versions don't flip-flop.
#   2. Start the widget unless it's already running.
# Compatible with Windows PowerShell 5.1.

param([string]$DataDir)
$ErrorActionPreference = 'Stop'

if ($DataDir) { $env:CACHE_CLOCK_DIR = $DataDir }
$base = $env:CACHE_CLOCK_DIR
if (-not $base) { $base = Join-Path $HOME '.cache-clock' }
$pidFile = Join-Path $base 'widget.pid'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # plugin root
$dest = Join-Path $env:LOCALAPPDATA 'CacheClock'

function Get-ManifestVersion([string]$path) {
    try { return [version]([string](Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).version) } catch { return $null }
}
function Get-WidgetPid {
    if (-not (Test-Path -LiteralPath $pidFile)) { return 0 }
    $wpid = 0
    [void][int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(), [ref]$wpid)
    if ($wpid -and (Get-Process -Id $wpid -ErrorAction SilentlyContinue)) { return $wpid }
    return 0
}

try {
    if (Test-Path -LiteralPath (Join-Path $dest 'CacheClock.ps1')) {
        $mine = Get-ManifestVersion (Join-Path $root '.claude-plugin\plugin.json')
        $installed = Get-ManifestVersion (Join-Path $dest 'plugin.json')
        if ($mine -and (-not $installed -or $mine -gt $installed)) {
            $wpid = Get-WidgetPid
            if ($wpid) { Stop-Process -Id $wpid -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500 }
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'CacheClock.ps1') -Destination $dest -Force
            Copy-Item -LiteralPath (Join-Path $root '.claude-plugin\plugin.json') -Destination $dest -Force
            Get-ChildItem -LiteralPath $dest -Filter *.ps1 | Unblock-File -ErrorAction SilentlyContinue
        }
    }
} catch { }

if (Get-WidgetPid) { exit 0 }
# Prefer the installed copy (stable path), else the one bundled in the plugin.
$widget = Join-Path $dest 'CacheClock.ps1'
if (-not (Test-Path -LiteralPath $widget)) { $widget = Join-Path $PSScriptRoot 'CacheClock.ps1' }
Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$widget`""
)
