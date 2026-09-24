# Cache Clock: keep-alive listener (runs as an asyncRewake Stop hook).
# After each Claude Code turn, this waits in the background. If the widget drops a ping flag
# for this session, it exits with code 2, which wakes Claude for a tiny turn. That turn is a real
# API request, so it reads the cache and resets the TTL. With auto keep-alive on (widget menu),
# it also pings by itself shortly before expiry, within a token budget. Otherwise it only pings
# when asked.
# Compatible with Windows PowerShell 5.1 and PowerShell 7.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$hook = Read-HookInput
if (-not $hook -or -not $hook.session_id -or $hook.agent_id) { exit 0 }

$sid = [string]$hook.session_id
$waiterPath = Get-WaiterPath $sid
$pingPath = Get-PingPath $sid
$statePath = Get-SessionStatePath $sid

# Newest listener wins. An older one sees a different PID in the file and quits.
[IO.File]::WriteAllText($waiterPath, [string]$PID)
$started = Get-Epoch
$pollSeconds = 2
$maxLifetime = 2 * 3600

while ($true) {
    Start-Sleep -Seconds $pollSeconds
    $now = Get-Epoch

    $owner = ''
    try { $owner = (Get-Content -LiteralPath $waiterPath -Raw -ErrorAction Stop).Trim() } catch { exit 0 }
    if ($owner -ne [string]$PID) { exit 0 }
    if (($now - $started) -gt $maxLifetime) { exit 0 }

    $state = Read-JsonFile $statePath
    if (-not $state) { continue }   # the Stop hook may still be writing it

    # Once the cache has gone cold, a ping would pay for a full rebuild. Stop listening.
    if ($state.expires_at -and $now -gt ([long]$state.expires_at + 60)) { exit 0 }

    # Auto keep-alive: ping shortly before expiry, while the budget allows.
    $cfg = Get-Config
    if ([bool]$cfg.autoKeepAlive -and $state.status -ne 'working' -and $state.expires_at) {
        $left = [long]$state.expires_at - $now
        if ($left -gt 5 -and $left -le [int]$cfg.autoKeepAliveAt -and (Get-AutoPingsLeft $state $cfg) -gt 0) {
            $ctx = [long]$state.cache_read + [long]$state.cache_write
            Set-Prop $state 'auto_pings' ([int]$state.auto_pings + 1)
            Set-Prop $state 'auto_spent' ([long]$state.auto_spent + $ctx)
            Set-Prop $state 'last_auto_ping_at' $now
            Write-JsonFile $statePath $state
            Remove-Item -LiteralPath $waiterPath -ErrorAction SilentlyContinue
            [Console]::Error.WriteLine('[cache-clock] Automatic keep-alive ping to keep the prompt cache warm. Reply with exactly: ok. Do not call any tools and do not add anything else.')
            exit 2
        }
    }

    if (Test-Path -LiteralPath $pingPath) {
        Remove-Item -LiteralPath $pingPath -ErrorAction SilentlyContinue
        # Claude is mid-turn: the cache is being refreshed anyway, so skip the ping.
        if ($state.status -eq 'working') { continue }
        Remove-Item -LiteralPath $waiterPath -ErrorAction SilentlyContinue
        [Console]::Error.WriteLine('[cache-clock] The user asked for a keep-alive ping to keep the prompt cache warm. Reply with exactly: ok. Do not call any tools and do not add anything else.')
        exit 2
    }
}
