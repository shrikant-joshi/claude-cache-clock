# Cache Clock: Claude Code hook handler.
# Usage (from hooks.json): powershell.exe -NoProfile -ExecutionPolicy Bypass -File cc-hook.ps1 <start|prompt|stop|end>
# Reads the hook JSON on stdin and keeps one state file per session in ~/.cache-clock/sessions/.
# The widget reads those files. Everything here is derived from the API "receipts" (usage fields)
# that Claude Code writes into the session transcript.
# Compatible with Windows PowerShell 5.1 and PowerShell 7.

param([Parameter(Mandatory = $true)][string]$HookEvent)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$hook = Read-HookInput
if (-not $hook -or -not $hook.session_id) { exit 0 }
if ($hook.agent_id) { exit 0 }   # Subagents have their own 5-min cache. Track the main chat only.

$sid = [string]$hook.session_id
$transcript = Convert-HookPath ([string]$hook.transcript_path)
$statePath = Get-SessionStatePath $sid
$state = Read-JsonFile $statePath
if (-not $state) { $state = [pscustomobject]@{} }

$now = Get-Epoch
Set-Prop $state 'v' 1
Set-Prop $state 'source' 'claude-code'
Set-Prop $state 'session_id' $sid
if ($hook.cwd) {
    Set-Prop $state 'cwd' ([string]$hook.cwd)
    Set-Prop $state 'project' (Get-Leaf ([string]$hook.cwd))
}
Set-Prop $state 'updated_at' $now

function Update-FromTranscript {
    param($State, [string]$TranscriptPath, [long]$TurnStartedAt)
    if (-not $TranscriptPath -or -not (Test-Path -LiteralPath $TranscriptPath)) { return $false }

    # The transcript is written asynchronously. Give it a moment to catch up with the last response.
    $info = $null
    for ($i = 0; $i -lt 4; $i++) {
        $info = Get-LastUsage $TranscriptPath
        if ($info -and ($info.ts -ge $TurnStartedAt)) { break }
        Start-Sleep -Milliseconds 400
    }
    if (-not $info) { return $false }

    $ttl = $info.ttl_s
    if (-not $ttl) { $ttl = $State.ttl_s }
    if (-not $ttl) { $ttl = Get-DefaultTtl }

    # The cache timer restarts at the last request. Prefer the response's own timestamp.
    # If the transcript lags (entry older than this turn), fall back to "now".
    $last = $info.ts
    if ($TurnStartedAt -and $last -lt $TurnStartedAt) { $last = Get-Epoch }

    Set-Prop $State 'ttl_s' ([int]$ttl)
    Set-Prop $State 'last_response_at' ([long]$last)
    Set-Prop $State 'cache_read' ([long]$info.read)
    Set-Prop $State 'cache_write' ([long]$info.write)
    Set-Prop $State 'caching_observed' ([bool]($info.read -gt 0 -or $info.write -gt 0))
    # A "rebuild" is a turn where the server wrote more than it read: model switch, compaction, expiry, etc.
    Set-Prop $State 'rebuilt' ([bool]($info.write -gt $info.read))
    if ($State.caching_observed) {
        Set-Prop $State 'expires_at' ([long]($last + $ttl))
    } else {
        Set-Prop $State 'expires_at' $null
    }
    Set-Prop $State 'basis' 'transcript'
    return $true
}

switch ($HookEvent) {
    'start' {
        Set-Prop $state 'status' 'idle'
        [void](Update-FromTranscript $state $transcript 0)
        Write-JsonFile $statePath $state
        Start-WidgetIfNeeded
    }
    'prompt' {
        Set-Prop $state 'status' 'working'
        Set-Prop $state 'turn_started_at' $now
        Write-JsonFile $statePath $state
    }
    'stop' {
        $turnStart = 0
        if ($state.turn_started_at) { $turnStart = [long]$state.turn_started_at }
        Set-Prop $state 'status' 'idle'
        [void](Update-FromTranscript $state $transcript $turnStart)
        Write-JsonFile $statePath $state
    }
    'end' {
        Remove-Item -LiteralPath $statePath -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Get-WaiterPath $sid) -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Get-PingPath $sid) -ErrorAction SilentlyContinue
    }
}
exit 0
