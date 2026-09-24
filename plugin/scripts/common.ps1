# Cache Clock: shared helpers for the hook, waiter, and status line scripts.
# Compatible with Windows PowerShell 5.1 and PowerShell 7.

function Get-Epoch { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Read-HookInput {
    # Hook JSON arrives on stdin as UTF-8 (also when piped in from WSL).
    try { [Console]::InputEncoding = New-Object Text.UTF8Encoding($false) } catch { }
    try {
        $raw = [Console]::In.ReadToEnd()
        if (-not $raw) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

function Convert-HookPath([string]$p) {
    # Claude Code in WSL reports Linux paths. Map them to paths Windows can open:
    #   /mnt/c/Users/x  -> C:\Users\x
    #   /home/x/...     -> \\wsl$\<distro>\home\x\...
    if (-not $p -or -not $p.StartsWith('/')) { return $p }
    if ($p -match '^/mnt/([a-zA-Z])(/.*)?$') {
        $rest = [string]$Matches[2]; if (-not $rest) { $rest = '/' }
        return ('{0}:{1}' -f $Matches[1].ToUpper(), ($rest -replace '/', '\'))
    }
    if ($env:CACHE_CLOCK_WSL_DISTRO) {
        return ('\\wsl$\{0}{1}' -f $env:CACHE_CLOCK_WSL_DISTRO, ($p -replace '/', '\'))
    }
    return $p
}

function Get-Leaf([string]$p) {
    # Works for both C:\a\b and /home/a/b.
    $parts = @($p -split '[\\/]' | Where-Object { $_ })
    if ($parts.Count -eq 0) { return $p }
    return $parts[-1]
}

function ConvertTo-Epoch($value) {
    if ($null -eq $value) { return 0 }
    if ($value -is [datetime]) {
        return ([DateTimeOffset]$value.ToUniversalTime()).ToUnixTimeSeconds()
    }
    try {
        return [DateTimeOffset]::Parse([string]$value, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeSeconds()
    } catch { return 0 }
}

function Get-BaseDir {
    $dir = $env:CACHE_CLOCK_DIR
    if (-not $dir) { $dir = Join-Path $HOME '.cache-clock' }
    foreach ($sub in @('', 'sessions', 'pings', 'waiters')) {
        $p = if ($sub) { Join-Path $dir $sub } else { $dir }
        if (-not (Test-Path -LiteralPath $p)) { [void](New-Item -ItemType Directory -Path $p -Force) }
    }
    return $dir
}

function Get-SafeId([string]$id) { return ($id -replace '[^A-Za-z0-9_-]', '_') }
function Get-SessionStatePath([string]$sid) { Join-Path (Join-Path (Get-BaseDir) 'sessions') ((Get-SafeId $sid) + '.json') }
function Get-PingPath([string]$sid) { Join-Path (Join-Path (Get-BaseDir) 'pings') ((Get-SafeId $sid) + '.flag') }
function Get-WaiterPath([string]$sid) { Join-Path (Join-Path (Get-BaseDir) 'waiters') ((Get-SafeId $sid) + '.pid') }

function Read-JsonFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { return $null }
}

function Write-JsonFile([string]$path, $obj) {
    # Write to a temp file, then swap it in, so the widget never reads a half-written file.
    $tmp = "$path.$PID.tmp"
    $json = $obj | ConvertTo-Json -Depth 6 -Compress
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Set-Prop($obj, [string]$name, $value) {
    if ($obj.PSObject.Properties[$name]) { $obj.$name = $value }
    else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}

function Get-DefaultTtl {
    # Claude Code's own override, if set. Otherwise assume the subscription default (1 hour).
    switch ($env:CLAUDE_CODE_PROMPT_CACHE_TTL) {
        '5m' { return 300 }
        '1h' { return 3600 }
    }
    if ($env:FORCE_PROMPT_CACHING_5M -eq '1') { return 300 }
    return 3600
}

function Read-FileTail([string]$path, [int]$maxBytes = 1048576) {
    # Read only the end of the transcript. Transcripts can grow to many MB.
    $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $len = $fs.Length
        $n = [int][math]::Min($len, $maxBytes)
        [void]$fs.Seek($len - $n, [IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] $n
        $read = 0
        while ($read -lt $n) { $r = $fs.Read($buf, $read, $n - $read); if ($r -le 0) { break }; $read += $r }
        $text = [Text.Encoding]::UTF8.GetString($buf, 0, $read)
    } finally { $fs.Dispose() }
    $lines = $text -split "`n"
    if ($len -gt $maxBytes -and $lines.Count -gt 1) { $lines = $lines[1..($lines.Count - 1)] }   # first line is partial
    return $lines
}

function Get-JsonNumber([string]$line, [string]$field) {
    $m = [regex]::Match($line, '"' + $field + '":(\d+)')
    if ($m.Success) { return [long]$m.Groups[1].Value }
    return 0
}

function Get-LastUsage([string]$transcriptPath) {
    # Returns the usage "receipt" of the last main-chat API response in the transcript:
    #   ts (epoch), read, write, ttl_s (3600, 300, or $null if no recent cache write says which).
    # Uses regex on raw JSONL lines instead of full JSON parsing: much faster on big transcripts.
    # Unescaped keys like "usage" and "timestamp" only occur at the entry's own level, not inside
    # message text, where JSON escapes the quotes.
    $lines = Read-FileTail $transcriptPath
    $result = $null
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if (-not $line -or $line.IndexOf('"type":"assistant"') -lt 0) { continue }
        if ($line.IndexOf('"isSidechain":true') -ge 0) { continue }
        if ($line.IndexOf('"cache_read_input_tokens":') -lt 0) { continue }

        if (-not $result) {
            $tsm = [regex]::Match($line, '"timestamp":"([^"]+)"')
            $result = [pscustomobject]@{
                ts    = $(if ($tsm.Success) { ConvertTo-Epoch $tsm.Groups[1].Value } else { 0 })
                read  = Get-JsonNumber $line 'cache_read_input_tokens'
                write = Get-JsonNumber $line 'cache_creation_input_tokens'
                ttl_s = $null
            }
        }
        # The TTL shows up in the split of cache writes. Walk back to the latest write that says which.
        if ((Get-JsonNumber $line 'ephemeral_1h_input_tokens') -gt 0) { $result.ttl_s = 3600; break }
        if ((Get-JsonNumber $line 'ephemeral_5m_input_tokens') -gt 0) { $result.ttl_s = 300; break }
    }
    return $result
}

function Start-WidgetIfNeeded {
    if ($env:OS -ne 'Windows_NT') { return }
    if ($env:CACHE_CLOCK_NO_AUTOSTART -eq '1') { return }
    $pidFile = Join-Path (Get-BaseDir) 'widget.pid'
    if (Test-Path -LiteralPath $pidFile) {
        $wpid = 0
        [void][int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(), [ref]$wpid)
        if ($wpid -and (Get-Process -Id $wpid -ErrorAction SilentlyContinue)) { return }
    }
    # Prefer the installed copy (stable path), else the one bundled in the plugin.
    $widget = Join-Path $env:LOCALAPPDATA 'CacheClock\CacheClock.ps1'
    if (-not (Test-Path -LiteralPath $widget)) {
        $widget = Join-Path (Split-Path -Parent $PSScriptRoot) 'widget\CacheClock.ps1'
    }
    if (-not (Test-Path -LiteralPath $widget)) { return }
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$widget`""
    )
}
