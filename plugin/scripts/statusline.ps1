# Cache Clock: optional Claude Code status line.
# Claude Code (v2.1.251+) passes a prompt_cache object computed from the server's usage receipts,
# including the exact expires_at. This script prints it and hands it to the widget.
# Shows an absolute time ("warm until 16:42") so it stays correct between refreshes.
# Compatible with Windows PowerShell 5.1 and PowerShell 7.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$in = Read-HookInput
if (-not $in) { Write-Output 'cache: ?'; exit 0 }

$pc = $in.prompt_cache
if (-not $pc) { Write-Output 'cache: no response yet'; exit 0 }
if (-not $pc.caching_observed) { Write-Output 'cache: off'; exit 0 }

$now = Get-Epoch
$ttlS = if ($pc.ttl -eq '5m') { 300 } else { 3600 }

if ($in.session_id) {
    try {
        $statePath = Get-SessionStatePath ([string]$in.session_id)
        $state = Read-JsonFile $statePath
        if (-not $state) { $state = [pscustomobject]@{ v = 1; source = 'claude-code'; session_id = [string]$in.session_id; status = 'idle' } }
        if ($in.workspace -and $in.workspace.current_dir) {
            Set-Prop $state 'cwd' ([string]$in.workspace.current_dir)
            Set-Prop $state 'project' (Get-Leaf ([string]$in.workspace.current_dir))
        }
        Set-Prop $state 'ttl_s' $ttlS
        Set-Prop $state 'expires_at' $(if ($pc.expires_at) { [long]$pc.expires_at } else { $null })
        Set-Prop $state 'warm' ([bool]$pc.warm)
        Set-Prop $state 'caching_observed' $true
        Set-Prop $state 'misses' $pc.misses
        Set-Prop $state 'basis' 'statusline'
        Set-Prop $state 'updated_at' $now
        Write-JsonFile $statePath $state
    } catch { }
}

if ($pc.warm -and $pc.expires_at) {
    $until = [DateTimeOffset]::FromUnixTimeSeconds([long]$pc.expires_at).ToLocalTime().ToString('HH:mm')
    Write-Output ("cache warm until {0} ({1} TTL)" -f $until, $pc.ttl)
} else {
    Write-Output ("cache cold ({0})" -f $pc.ttl)
}
