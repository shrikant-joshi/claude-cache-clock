# Cache Clock: optional Claude Code status line.
# Claude Code (v2.1.251+) passes a prompt_cache object computed from the server's usage receipts,
# including the exact expires_at. This script prints it and hands it to the widget.
# Shows minutes left, the absolute expiry time and the context size ("23m left, warm until 16:42, ctx 182k/1M (18%)").
# Compatible with Windows PowerShell 5.1 and PowerShell 7.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$in = Read-HookInput
if (-not $in) { Write-Output 'cache: ?'; exit 0 }

function Format-Tokens([long]$n) {
    $ci = [Globalization.CultureInfo]::InvariantCulture
    if ($n -ge 1000000) { return ([double]$n / 1000000).ToString('0.#', $ci) + 'M' }
    return ([double]$n / 1000).ToString('0', $ci) + 'k'
}

# Context size from the last API response: input + cache reads + cache writes (what used_percentage counts).
$ctx = ''
$ctxTokens = 0; $ctxMax = 0
$cw = $in.context_window
if ($cw) {
    $ctxTokens = [long]$cw.total_input_tokens
    if (-not $ctxTokens -and $cw.current_usage) {
        $cu = $cw.current_usage
        $ctxTokens = [long]$cu.input_tokens + [long]$cu.cache_creation_input_tokens + [long]$cu.cache_read_input_tokens
    }
    $ctxMax = [long]$cw.context_window_size
    if ($ctxTokens -gt 0) {
        $ctx = 'ctx ' + (Format-Tokens $ctxTokens)
        if ($ctxMax -gt 0) {
            $pct = [math]::Round(100.0 * $ctxTokens / $ctxMax)
            $ctx += '/' + (Format-Tokens $ctxMax) + " ($pct%)"
        }
    }
}
$ctxSuffix = $(if ($ctx) { ", $ctx" } else { '' })

$pc = $in.prompt_cache
if (-not $pc) { Write-Output ('cache: no response yet' + $ctxSuffix); exit 0 }
if (-not $pc.caching_observed) { Write-Output ('cache: off' + $ctxSuffix); exit 0 }

$now = Get-Epoch
$ttlS = if ($pc.ttl -eq '5m') { 300 } else { 3600 }

$state = $null
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
        if ($ctxTokens -gt 0) {
            Set-Prop $state 'context_tokens' $ctxTokens
            Set-Prop $state 'context_max' $ctxMax
        }
        Set-Prop $state 'updated_at' $now
        Write-JsonFile $statePath $state
    } catch { }
}

# Auto keep-alive status, when it's on: how many pings the budget still allows for this context.
$auto = ''
try {
    $cfg = Get-Config
    if ([bool]$cfg.autoKeepAlive) {
        $n = -1
        if ($state) { $n = Get-AutoPingsLeft $state $cfg }
        if ($n -lt 0) { $auto = ', auto keep-alive on' }
        elseif ($n -eq 0) { $auto = ', auto keep-alive: budget used' }
        else { $auto = ", auto keep-alive: $n left" }
    }
} catch { }

# Pair this with "refreshInterval" in the statusLine settings so the countdown keeps moving.
$left = 0
if ($pc.expires_at) { $left = [long]$pc.expires_at - $now }
if ($pc.warm -and $left -gt 0) {
    $until = [DateTimeOffset]::FromUnixTimeSeconds([long]$pc.expires_at).ToLocalTime().ToString('HH:mm')
    $mins = [math]::Floor($left / 60)
    $leftText = if ($mins -ge 1) { "${mins}m left" } else { '<1m left' }
    Write-Output ("cache {0}, warm until {1} ({2} TTL){3}{4}" -f $leftText, $until, $pc.ttl, $ctxSuffix, $auto)
} else {
    Write-Output ("cache cold ({0} TTL){1}" -f $pc.ttl, $ctxSuffix)
}
