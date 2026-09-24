# Cache Clock widget: an always-on-top prompt-cache countdown for Windows.
#
# Two kinds of timers ("lanes"):
#   Chat / Cowork (estimate): no cache data leaves the Claude app, so this lane resets when you
#     press Enter in the Claude app, double-click the row, or press Ctrl+Alt+K. It assumes a TTL.
#   Claude Code (exact): fed by the cache-clock plugin's hooks, which read the API's usage receipts.
#
# The Windows add-on of the cache-clock plugin: the plugin's hooks (plugin\scripts, any OS) write the
# session files; this widget only reads them and drops keep-alive flags.
# Alerts: Windows notifications at T-15, T-10 and T-5 (T-2 and T-1 for 5-minute caches).
# Auto keep-alive (opt-in): the plugin's listener pings Claude Code at T-60s, within a token budget.
# Closes itself when neither the Claude app nor a Claude Code session is running (opt-out).
# Run:    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File CacheClock.ps1
# Data:   %USERPROFILE%\.cache-clock\  (config.json, manual.json, sessions\, pings\)
# Needs Windows PowerShell 5.1 (built into Windows 10/11). Nothing to install.

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('CacheClockNative' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class CacheClockNative {
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    public static bool IsDown(int vKey) { return (GetAsyncKeyState(vKey) & 0x8000) != 0; }
    public static int ForegroundPid() {
        uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid); return (int)pid;
    }
}

public class CacheClockForm : Form {
    public CacheClockForm() {
        this.DoubleBuffered = true;
        this.SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x80; return cp; } // WS_EX_TOOLWINDOW: no Alt+Tab entry
    }
}
'@
}

# ---------- single instance ----------
$created = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\CacheClockWidget', [ref]$created)
if (-not $created) { return }

[void][CacheClockNative]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------- paths and helpers ----------
$script:Base = $env:CACHE_CLOCK_DIR
if (-not $script:Base) { $script:Base = Join-Path $HOME '.cache-clock' }
foreach ($sub in @('sessions', 'pings')) {
    $p = Join-Path $script:Base $sub
    if (-not (Test-Path -LiteralPath $p)) { [void](New-Item -ItemType Directory -Path $p -Force) }
}
$script:ConfigPath = Join-Path $script:Base 'config.json'
$script:ManualPath = Join-Path $script:Base 'manual.json'
$script:PidPath = Join-Path $script:Base 'widget.pid'
[IO.File]::WriteAllText($script:PidPath, [string]$PID)

function Get-Epoch { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# Version: plugin.json next to the installed copy, or the plugin's manifest when run from the plugin
# (addons\windows\ inside the plugin).
$script:Version = '?'
foreach ($mp in @((Join-Path $PSScriptRoot 'plugin.json'), (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '.claude-plugin\plugin.json'))) {
    try {
        if (Test-Path -LiteralPath $mp) { $script:Version = [string](Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json).version; break }
    } catch { }
}
function Write-Log([string]$msg) {
    try {
        $log = Join-Path $script:Base 'widget.log'
        if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 200KB) { Remove-Item -LiteralPath $log }
        Add-Content -LiteralPath $log -Value ("{0}  {1}" -f (Get-Date -Format 's'), $msg)
    } catch { }
}
function Get-SafeId([string]$id) { $id -replace '[^A-Za-z0-9_-]', '_' }

function Read-Json([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
}
function Write-Json([string]$path, $obj) {
    try {
        $tmp = "$path.$PID.tmp"
        [IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } catch { }
}
function Format-Clock([long]$ts) { [DateTimeOffset]::FromUnixTimeSeconds($ts).ToLocalTime().ToString('HH:mm:ss') }
function Format-K($n) { if ($null -eq $n) { return '?' }; '{0:N0}k' -f ([double]$n / 1000) }
# Dollars as the status line prints them: cents under $100, whole dollars above.
function Format-Usd($n) {
    $v = [double]$n; $ic = [Globalization.CultureInfo]::InvariantCulture
    if ($v -lt 0.01) { return '<$0.01' }
    if ($v -lt 100) { return '$' + $v.ToString('0.00', $ic) }
    '$' + $v.ToString('0', $ic)
}

# ---------- config ----------
$script:Cfg = [ordered]@{
    x                = -1
    y                = -1
    manualTtlMin     = 60
    thresholds       = @(15, 10, 5)     # minutes, for 1-hour caches
    shortThresholds  = @(2, 1)          # minutes, for 5-minute caches
    autoResetOnEnter = $true
    hotkeyKey        = 'K'              # Ctrl+Alt+<key> resets the Chat / Cowork timer
    claudeProcesses  = @('claude')      # process names that count as "the Claude app"
    showManual       = $true
    opacity          = 0.93
    autoKeepAlive       = $false    # Claude Code: ping automatically before the cache expires
    autoKeepAliveAt     = 60        # seconds before expiry
    autoKeepAliveBudget = 1000000   # cached tokens auto pings may re-read per idle stretch
    autoExit         = $true        # close when no Claude app and no Claude Code session is running
}
$loaded = Read-Json $script:ConfigPath
if ($loaded) {
    foreach ($prop in $loaded.PSObject.Properties) {
        if ($script:Cfg.Contains($prop.Name)) { $script:Cfg[$prop.Name] = $prop.Value }
    }
}
function Save-Config {
    Write-Json $script:ConfigPath ([pscustomobject]$script:Cfg)
    try { $script:CfgStamp = (Get-Item -LiteralPath $script:ConfigPath).LastWriteTimeUtc } catch { }
}
Save-Config
# Pick up changes made elsewhere (for example /cache-clock:auto-keepalive in Claude Code).
function Update-ConfigFromDisk {
    try {
        $stamp = (Get-Item -LiteralPath $script:ConfigPath -ErrorAction Stop).LastWriteTimeUtc
        if ($stamp -eq $script:CfgStamp) { return }
        $script:CfgStamp = $stamp
        $disk = Read-Json $script:ConfigPath
        if ($disk) { foreach ($prop in $disk.PSObject.Properties) { if ($script:Cfg.Contains($prop.Name)) { $script:Cfg[$prop.Name] = $prop.Value } } }
    } catch { }
}

$script:Manual = Read-Json $script:ManualPath
if (-not $script:Manual) { $script:Manual = [pscustomobject]@{ last_reset_at = 0 } }

# ---------- runtime state ----------
$script:Lanes = @()
$script:Fired = @{}          # "<lane>|<expiry>" -> hashtable of alerts already shown
$script:Hidden = @{}         # session ids the user hid
$script:Pings = @{}          # session id -> epoch the ping was requested
$script:PrevEnter = $false
$script:PrevHotkey = $false
$script:LastEnterReset = 0
$script:FlashUntil = 0
$script:HoverRow = -1
$script:DragFrom = $null
$script:LastTopMost = 0
$script:StartedAt = Get-Epoch
$script:CodeActive = $false  # a Claude Code session file looks alive
$script:LastClaudeSeen = Get-Epoch
$script:LastProcCheck = 0
$script:Upd = $null          # running "check for updates" process

# ---------- colors and fonts ----------
$C = @{
    Bg     = [System.Drawing.Color]::FromArgb(30, 31, 34)
    Border = [System.Drawing.Color]::FromArgb(62, 64, 70)
    Hover  = [System.Drawing.Color]::FromArgb(42, 44, 48)
    Flash  = [System.Drawing.Color]::FromArgb(40, 70, 60)
    Text   = [System.Drawing.Color]::FromArgb(230, 230, 232)
    Muted  = [System.Drawing.Color]::FromArgb(140, 142, 150)
    Green  = [System.Drawing.Color]::FromArgb(88, 196, 130)
    Amber  = [System.Drawing.Color]::FromArgb(236, 178, 72)
    Red    = [System.Drawing.Color]::FromArgb(240, 96, 88)
    Blue   = [System.Drawing.Color]::FromArgb(110, 160, 245)
    Grey   = [System.Drawing.Color]::FromArgb(100, 102, 110)
}
$FontTitle = New-Object System.Drawing.Font('Segoe UI', 9)
$FontBadge = New-Object System.Drawing.Font('Segoe UI', 7.5)
$FontTime = New-Object System.Drawing.Font('Consolas', 10.5, [System.Drawing.FontStyle]::Bold)

# ---------- form ----------
$form = New-Object CacheClockForm
$form.Text = 'Cache Clock'
$form.FormBorderStyle = 'None'
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.StartPosition = 'Manual'
$form.BackColor = $C.Bg
$form.Opacity = [double]$script:Cfg.opacity

$g0 = $form.CreateGraphics(); $script:Scale = $g0.DpiX / 96.0; $g0.Dispose()
function Px([double]$v) { [int][math]::Round($v * $script:Scale) }
$script:RowH = Px 28
$script:Pad = Px 8
$script:W = Px 250
$form.Width = $script:W
$form.Height = $script:RowH + 2 * $script:Pad

function Set-DefaultPosition {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location = New-Object System.Drawing.Point(($wa.Right - $form.Width - (Px 16)), ($wa.Bottom - (Px 140)))
}
$pt = New-Object System.Drawing.Point([int]$script:Cfg.x, [int]$script:Cfg.y)
$onScreen = $false
foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) { if ($scr.WorkingArea.Contains($pt)) { $onScreen = $true } }
if ($onScreen) { $form.Location = $pt } else { Set-DefaultPosition }

$tip = New-Object System.Windows.Forms.ToolTip
$tip.InitialDelay = 400
$tip.AutoPopDelay = 20000

# ---------- tray icon (also used for notifications) ----------
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = [System.Drawing.SystemIcons]::Information
$notify.Text = "Cache Clock $($script:Version)"
$notify.Visible = $true

function Show-Alert([string]$title, [string]$text, [string]$kind = 'Warning') {
    $notify.ShowBalloonTip(10000, $title, $text, [System.Windows.Forms.ToolTipIcon]::$kind)
}

# ---------- actions ----------
function Reset-Manual {
    $script:Manual.last_reset_at = Get-Epoch
    Write-Json $script:ManualPath $script:Manual
    $script:FlashUntil = (Get-Epoch) + 1
    Update-Lanes; $form.Invalidate()
}
function Stop-Manual {
    $script:Manual.last_reset_at = 0
    Write-Json $script:ManualPath $script:Manual
    Update-Lanes; $form.Invalidate()
}
function Request-KeepAlive([string]$sid) {
    $flag = Join-Path (Join-Path $script:Base 'pings') ((Get-SafeId $sid) + '.flag')
    [IO.File]::WriteAllText($flag, [string](Get-Epoch))
    $script:Pings[$sid] = Get-Epoch
    Update-Lanes; $form.Invalidate()
}
function Test-ClaudeForeground {
    try {
        $fp = [CacheClockNative]::ForegroundPid()
        if (-not $fp) { return $false }
        $name = (Get-Process -Id $fp -ErrorAction Stop).ProcessName
        return (@($script:Cfg.claudeProcesses) -contains $name)
    } catch { return $false }
}

function Get-AutoPingsLeft($st) {
    # Same rule as the plugin's listener: each auto ping re-reads the whole context.
    $ctx = [long]$st.cache_read + [long]$st.cache_write
    if ($ctx -le 0) { $ctx = [long]$st.context_tokens }   # no receipt yet: the status line's context size
    if ($ctx -le 0) { return -1 }
    $left = [long]$script:Cfg.autoKeepAliveBudget - [long]$st.auto_spent
    if ($left -le 0) { return 0 }
    return [int][math]::Floor($left / $ctx)
}

# ---------- auto-exit ----------
function Test-AutoExit {
    # Close when neither the Claude app nor Claude Code has been around for a minute.
    # A grace period after start covers logging in before the Claude app is up.
    if (-not [bool]$script:Cfg.autoExit) { return }
    $now = Get-Epoch
    if (($now - $script:LastProcCheck) -lt 5) { return }
    $script:LastProcCheck = $now
    $app = @(Get-Process -Name @($script:Cfg.claudeProcesses) -ErrorAction SilentlyContinue).Count -gt 0
    if ($app -or $script:CodeActive) { $script:LastClaudeSeen = $now; return }
    if (($now - $script:StartedAt) -lt 180) { return }
    if (($now - $script:LastClaudeSeen) -ge 60) {
        Write-Log 'no Claude app or Claude Code session running: exiting'
        $form.Close()
    }
}

# ---------- check for updates ----------
function Start-UpdateCheck {
    # Runs the claude CLI where Claude Code lives (WSL or Windows, recorded by the plugin's
    # SessionStart hook): refresh the marketplace, then update the plugin.
    if ($script:Upd) { return }
    $h = Read-Json (Join-Path $script:Base 'host.json')
    $cmd = 'claude plugin marketplace update cache-clock && claude plugin update cache-clock@cache-clock --json'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($h -and $h.env -eq 'wsl' -and $h.distro) {
        $psi.FileName = 'wsl.exe'
        # -e runs sh directly: with --, the user's login shell would expand $PATH (and its "(x86)") first.
        $psi.Arguments = '-d ' + $h.distro + ' -e sh -lc "PATH=$HOME/.local/bin:$PATH; ' + $cmd + '"'
    } else {
        $psi.FileName = 'cmd.exe'
        $psi.Arguments = '/d /c "' + $cmd + '"'
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        # Drain both pipes in the background so a chatty CLI can't block on a full pipe.
        $script:Upd = @{ proc = $proc; out = $proc.StandardOutput.ReadToEndAsync(); err = $proc.StandardError.ReadToEndAsync(); started = Get-Epoch }
        Show-Alert 'Cache Clock' 'Checking for updates...' 'Info'
    } catch {
        Show-Alert 'Cache Clock' "Couldn't run the claude CLI: $_" 'Error'
    }
}

function Test-UpdateCheck {
    $u = $script:Upd
    if (-not $u) { return }
    if (-not $u.proc.HasExited) {
        if (((Get-Epoch) - $u.started) -gt 180) {
            try { $u.proc.Kill() } catch { }
            $script:Upd = $null
            Show-Alert 'Cache Clock' 'The update check timed out.' 'Error'
        }
        return
    }
    if (-not ($u.out.IsCompleted -and $u.err.IsCompleted)) { return }
    $script:Upd = $null
    $text = ($u.out.Result + "`n" + $u.err.Result) -replace '\x1b\[[0-9;]*[A-Za-z]', ''
    Write-Log "update check (exit $($u.proc.ExitCode)): $($text.Trim())"
    $res = $null
    foreach ($line in ($text -split "`n")) {
        if ($line.TrimStart().StartsWith('{')) { try { $res = $line | ConvertFrom-Json } catch { } }
    }
    if ($res -and $res.updateOutcome -eq 'up_to_date') {
        Show-Alert 'Cache Clock' "You're on the latest version ($($res.newVersion))." 'Info'
    } elseif ($res -and $res.outcome -eq 'ok') {
        Show-Alert 'Cache Clock' "Updated $($res.oldVersion) to $($res.newVersion). Restart Claude Code to apply it. The widget updates itself when the next session starts." 'Info'
    } else {
        $msg = $(if ($res -and $res.message) { [string]$res.message } else { (@($text -split "`n" | Where-Object { $_.Trim() }) | Select-Object -Last 2) -join ' ' })
        if (-not $msg) { $msg = "exit code $($u.proc.ExitCode)" }
        if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + '...' }
        Show-Alert 'Cache Clock: update check failed' $msg 'Error'
    }
}

# ---------- lanes ----------
function Get-LaneColor($lane, [long]$now) {
    switch ($lane.status) {
        'working' { return $C.Blue }
        'idle' { return $C.Grey }
        'nocache' { return $C.Grey }
    }
    $r = $lane.expires - $now
    if ($r -le 0) { return $C.Grey }
    if ($lane.ttl -ge 900) { $amber = 900; $red = 300 } else { $amber = 120; $red = 60 }
    if ($r -gt $amber) { return $C.Green }
    if ($r -gt $red) { return $C.Amber }
    return $C.Red
}

function Get-LaneText($lane, [long]$now) {
    switch ($lane.status) {
        'working' { return 'working' }
        'idle' { return 'idle' }
        'nocache' { return 'no cache' }
        'pinging' { return 'ping...' }
    }
    $r = $lane.expires - $now
    if ($r -le 0) { return 'cold' }
    $m = [math]::Floor($r / 60); $s = $r % 60
    return ('{0:00}:{1:00}' -f $m, $s)
}

function Update-Lanes {
    $now = Get-Epoch
    $lanes = New-Object System.Collections.ArrayList

    if ($script:Cfg.showManual) {
        $ttl = [int]$script:Cfg.manualTtlMin * 60
        $last = [long]$script:Manual.last_reset_at
        $lane = [pscustomobject]@{
            key = 'manual'; kind = 'manual'; sid = $null
            title = 'Chat / Cowork'; badge = 'est.'
            ttl = $ttl; expires = $(if ($last) { $last + $ttl } else { 0 })
            status = $(if ($last) { 'timer' } else { 'idle' })
            tip = ''
        }
        $lane.tip = "Estimate only: Chat and Cowork don't share cache data.`n" +
            "Resets when you press Enter in the Claude app, double-click this row, or press Ctrl+Alt+$($script:Cfg.hotkeyKey).`n" +
            "Assumed TTL: $($script:Cfg.manualTtlMin) min. The timer starts when you send, so the real cache usually lasts a little longer." +
            $(if ($last) { "`nLast reset: $(Format-Clock $last)   Expires: $(Format-Clock ($last + $ttl))" } else { '' })
        [void]$lanes.Add($lane)
    }

    $dir = Join-Path $script:Base 'sessions'
    $codeActive = $false
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -ErrorAction SilentlyContinue)) {
        $st = Read-Json $f.FullName
        if (-not $st -or -not $st.session_id) { continue }
        $sid = [string]$st.session_id
        if ($script:Hidden.ContainsKey($sid)) { continue }
        $exp = [long]$st.expires_at
        $upd = [long]$st.updated_at
        # Housekeeping: drop sessions that ended without a SessionEnd hook.
        if (($exp -and ($now - $exp) -gt 6 * 3600) -or ($upd -and ($now - $upd) -gt 24 * 3600)) {
            Remove-Item -LiteralPath $f.FullName -ErrorAction SilentlyContinue; continue
        }
        # For auto-exit: a session that's working, recently updated, or not long cold counts as running.
        if ($st.status -eq 'working' -or ($upd -and ($now - $upd) -lt 120) -or ($exp -and ($now - $exp) -le 1800) -or (-not $exp -and ($now - $upd) -lt 3600)) { $codeActive = $true }
        if ($exp -and ($now - $exp) -gt 1800 -and $st.status -ne 'working') { continue }   # cold for 30+ min: hide

        $status = 'timer'
        if ($st.status -eq 'working') { $status = 'working' }
        elseif ($st.caching_observed -eq $false) { $status = 'nocache' }
        elseif (-not $exp) { $status = 'idle' }
        if ($script:Pings.ContainsKey($sid) -and $status -eq 'timer') { $status = 'pinging' }
        $autoAt = [long]$st.last_auto_ping_at
        if ($status -eq 'timer' -and $autoAt -and $autoAt -ge [long]$st.last_response_at -and ($now - $autoAt) -lt 90) { $status = 'pinging' }
        $autoLeft = -1
        if ([bool]$script:Cfg.autoKeepAlive) { $autoLeft = Get-AutoPingsLeft $st }

        $ttl = [int]$st.ttl_s; if (-not $ttl) { $ttl = 3600 }
        $ttlLabel = $(if ($ttl -le 300) { '5m' } else { '1h' })
        $proj = [string]$st.project; if (-not $proj) { $proj = $sid.Substring(0, [math]::Min(8, $sid.Length)) }
        $lane = [pscustomobject]@{
            key = "cc:$sid"; kind = 'cc'; sid = $sid
            title = "Code: $proj"; badge = $ttlLabel
            ttl = $ttl; expires = $exp; status = $status; tip = ''
            auto = ([bool]$script:Cfg.autoKeepAlive -and $autoLeft -ne 0)
        }
        if ($lane.auto) { $lane.badge = "$ttlLabel auto" }
        $lines = @("Claude Code: $($st.cwd)", "TTL $ttlLabel, from the server's usage receipts ($($st.basis)).")
        if ($st.last_response_at) {
            $rb = $(if ($st.rebuilt) { '  (this turn rebuilt the cache)' } else { '' })
            $lines += "Last response $(Format-Clock ([long]$st.last_response_at)): read $(Format-K $st.cache_read), wrote $(Format-K $st.cache_write)$rb"
        }
        if ($exp) { $lines += "Expires $(Format-Clock $exp)" }
        if ([long]$st.context_tokens -gt 0) {
            $cl = "Context: $(Format-K $st.context_tokens)"
            if ([long]$st.context_max -gt 0) { $cl += " of $(Format-K $st.context_max) ($([math]::Round(100.0 * [long]$st.context_tokens / [long]$st.context_max))%)" }
            $lines += $cl
        }
        # Costs come from the status line (API prices for this model); absent without it.
        $rbTok = [long]$st.rebuild_tokens
        if ($rbTok -gt 0) {
            $cold = ($st.warm -eq $false) -or ($exp -and $now -ge $exp)
            $hasCost = ($null -ne $st.rebuild_usd)
            if ($cold) {
                $cl = "Cold: next message rebuilds $(Format-K $rbTok) tokens"
                if ($hasCost) { $cl += ", ~$(Format-Usd $st.rebuild_usd)" }
                $lines += $cl
            } elseif ($hasCost) {
                $lines += "Keep-alive ~$(Format-Usd $st.ping_usd), rebuild ~$(Format-Usd $st.rebuild_usd) ($(Format-K $rbTok) tokens, API prices)"
            }
        }
        $ms = [long]$st.misses
        if ($ms -eq 1) { $lines += '1 cache miss this session' } elseif ($ms -gt 1) { $lines += "$ms cache misses this session" }
        if ([bool]$script:Cfg.autoKeepAlive) {
            $ctxK = Format-K ([long]$st.cache_read + [long]$st.cache_write)
            if ($autoLeft -lt 0) { $lines += "Auto keep-alive: on, pings at T-$($script:Cfg.autoKeepAliveAt)s." }
            elseif ($autoLeft -eq 0) { $lines += "Auto keep-alive: budget used for this idle stretch (context $ctxK). Send a message to refill it." }
            else { $lines += "Auto keep-alive: on, $autoLeft ping(s) left in the budget (context $ctxK)." }
        } else {
            $lines += 'Auto keep-alive: off (right-click to turn on).'
        }
        $lines += 'Right-click: keep alive (sends a tiny turn, uses a little of your plan).'
        $lane.tip = $lines -join "`n"
        [void]$lanes.Add($lane)
    }

    if ($lanes.Count -eq 0) {
        [void]$lanes.Add([pscustomobject]@{ key = 'none'; kind = 'none'; sid = $null; title = 'Cache Clock'; badge = ''; ttl = 3600; expires = 0; status = 'idle'; tip = "Cache Clock $($script:Version)`nNo timers. Turn on the Chat / Cowork timer from the right-click menu." })
    }
    $script:Lanes = $lanes.ToArray()
    $script:CodeActive = $codeActive
    $h = $script:Lanes.Count * $script:RowH + 2 * $script:Pad
    if ($form.Height -ne $h) {
        $bottom = $form.Bottom
        $form.Height = $h
        $form.Top = $bottom - $h   # grow upward so it doesn't slide under the taskbar
    }
}

# ---------- alerts ----------
function Test-Alerts {
    $now = Get-Epoch
    foreach ($lane in $script:Lanes) {
        if ($lane.kind -eq 'none' -or -not $lane.expires) { continue }
        if ($lane.status -eq 'working' -or $lane.status -eq 'nocache' -or $lane.status -eq 'idle') { continue }
        $key = "$($lane.key)|$($lane.expires)"
        if (-not $script:Fired.ContainsKey($key)) { $script:Fired[$key] = @{} }
        $fired = $script:Fired[$key]
        $r = $lane.expires - $now
        $title = $(if ($lane.kind -eq 'manual') { 'Cache Clock: Chat / Cowork (estimate)' } else { "Cache Clock: $($lane.title)" })

        if ($r -le 0) {
            if (-not $fired.ContainsKey('cold') -and ($now - $lane.expires) -lt 120) {
                $fired['cold'] = $true
                Show-Alert $title 'The cache has expired. Your next message rebuilds it: slower, and it uses more of your plan.' 'Info'
            }
            continue
        }

        $ths = $(if ($lane.ttl -ge 900) { @($script:Cfg.thresholds) } else { @($script:Cfg.shortThresholds) })
        if ($lane.auto) { continue }   # auto keep-alive will ping before it expires
        $crossed = @($ths | Where-Object { $r -le ([int]$_ * 60) -and -not $fired.ContainsKey([string]$_) })
        if ($crossed.Count -gt 0) {
            foreach ($t in $crossed) { $fired[[string]$t] = $true }
            $mins = [math]::Ceiling($r / 60)
            if ($lane.kind -eq 'manual') {
                $msg = "About $mins min left on the cache. Send any message in that chat to keep it warm."
            } else {
                $msg = "About $mins min left. Right-click the widget and choose Keep alive, or type /cache-clock:keepalive."
            }
            Show-Alert $title $msg 'Warning'
        }
    }
    # Forget alert records for expiries that are long gone.
    foreach ($k in @($script:Fired.Keys)) {
        $e = [long]($k.Split('|')[-1])
        if ($e -and ($now - $e) -gt 7200) { $script:Fired.Remove($k) }
    }
}

function Test-Pings {
    $now = Get-Epoch
    foreach ($sid in @($script:Pings.Keys)) {
        $flag = Join-Path (Join-Path $script:Base 'pings') ((Get-SafeId $sid) + '.flag')
        if (-not (Test-Path -LiteralPath $flag)) {
            # The listener picked it up. The Stop hook will post the new expiry after Claude replies.
            if (($now - $script:Pings[$sid]) -gt 90) { $script:Pings.Remove($sid) }
            else {
                $st = Read-Json (Join-Path (Join-Path $script:Base 'sessions') ((Get-SafeId $sid) + '.json'))
                if ($st -and [long]$st.last_response_at -ge $script:Pings[$sid]) { $script:Pings.Remove($sid) }
            }
        } elseif (($now - $script:Pings[$sid]) -gt 20) {
            Remove-Item -LiteralPath $flag -ErrorAction SilentlyContinue
            $script:Pings.Remove($sid)
            Show-Alert 'Cache Clock' 'No keep-alive listener answered for that session. Type /cache-clock:keepalive in Claude Code instead.' 'Info'
        }
    }
}

# ---------- painting ----------
$form.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear($C.Bg)
    $now = Get-Epoch
    $pad = $script:Pad; $rh = $script:RowH; $w = $form.ClientSize.Width
    $timeW = Px 64
    for ($i = 0; $i -lt $script:Lanes.Count; $i++) {
        $lane = $script:Lanes[$i]
        $y = $pad + $i * $rh
        if ($lane.kind -eq 'manual' -and $now -le $script:FlashUntil) {
            $b = New-Object System.Drawing.SolidBrush($C.Flash); $g.FillRectangle($b, 1, $y, $w - 2, $rh); $b.Dispose()
        } elseif ($i -eq $script:HoverRow) {
            $b = New-Object System.Drawing.SolidBrush($C.Hover); $g.FillRectangle($b, 1, $y, $w - 2, $rh); $b.Dispose()
        }
        $col = Get-LaneColor $lane $now
        $d = Px 8
        $b = New-Object System.Drawing.SolidBrush($col); $g.FillEllipse($b, $pad, $y + [int](($rh - $d) / 2), $d, $d); $b.Dispose()

        $tx = $pad + $d + (Px 8)
        $titleSize = [System.Windows.Forms.TextRenderer]::MeasureText($lane.title, $FontTitle)
        $badgeW = 0; if ($lane.badge) { $badgeW = [System.Windows.Forms.TextRenderer]::MeasureText($lane.badge, $FontBadge).Width }
        $maxTitle = $w - $tx - $timeW - $pad - $badgeW - (Px 8)
        $tw = [math]::Min($titleSize.Width, $maxTitle)
        $flags = [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, NoPadding'
        [System.Windows.Forms.TextRenderer]::DrawText($g, $lane.title, $FontTitle, (New-Object System.Drawing.Rectangle($tx, $y, $tw, $rh)), $C.Text, $flags)
        if ($lane.badge) {
            $bw = [System.Windows.Forms.TextRenderer]::MeasureText($lane.badge, $FontBadge).Width
            [System.Windows.Forms.TextRenderer]::DrawText($g, $lane.badge, $FontBadge, (New-Object System.Drawing.Rectangle(($tx + $tw + (Px 4)), $y, $bw, $rh)), $(if ($lane.auto) { $C.Green } else { $C.Muted }), $flags)
        }
        $rflags = [System.Windows.Forms.TextFormatFlags]'Right, VerticalCenter, NoPadding'
        [System.Windows.Forms.TextRenderer]::DrawText($g, (Get-LaneText $lane $now), $FontTime, (New-Object System.Drawing.Rectangle(($w - $pad - $timeW), $y, $timeW, $rh)), $col, $rflags)
    }
    $pen = New-Object System.Drawing.Pen($C.Border); $g.DrawRectangle($pen, 0, 0, $w - 1, $form.ClientSize.Height - 1); $pen.Dispose()
})

function Get-RowAt([int]$y) {
    $i = [math]::Floor(($y - $script:Pad) / $script:RowH)
    if ($i -ge 0 -and $i -lt $script:Lanes.Count) { return [int]$i }
    return -1
}

# ---------- mouse: drag, hover, double-click, right-click ----------
$form.Add_MouseDown({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:DragFrom = New-Object System.Drawing.Point($e.X, $e.Y)
    }
})
$form.Add_MouseMove({
    param($s, $e)
    if ($script:DragFrom -and $e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $form.Left += $e.X - $script:DragFrom.X
        $form.Top += $e.Y - $script:DragFrom.Y
        return
    }
    $row = Get-RowAt $e.Y
    if ($row -ne $script:HoverRow) {
        $script:HoverRow = $row
        $t = ''; if ($row -ge 0) { $t = $script:Lanes[$row].tip }
        $tip.SetToolTip($form, $t)
        $form.Invalidate()
    }
})
$form.Add_MouseLeave({ $script:HoverRow = -1; $form.Invalidate() })
$form.Add_MouseUp({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:DragFrom = $null
        if ($form.Left -ne [int]$script:Cfg.x -or $form.Top -ne [int]$script:Cfg.y) {
            $script:Cfg.x = $form.Left; $script:Cfg.y = $form.Top; Save-Config
        }
    } elseif ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        $menu = New-RowMenu (Get-RowAt $e.Y)
        $menu.Show($form, $e.Location)
    }
})
$form.Add_MouseDoubleClick({
    param($s, $e)
    $row = Get-RowAt $e.Y
    if ($row -ge 0 -and $script:Lanes[$row].kind -eq 'manual') { Reset-Manual }
})

function Add-MenuItem($menu, [string]$text, [scriptblock]$action, [bool]$checked = $false, [bool]$enabled = $true) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem($text)
    $item.Checked = $checked
    $item.Enabled = $enabled
    $item.Add_Click($action)
    [void]$menu.Items.Add($item)
    return $item
}

function New-RowMenu([int]$row) {
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $lane = $null; if ($row -ge 0) { $lane = $script:Lanes[$row] }
    [void](Add-MenuItem $menu "Cache Clock $($script:Version)" { } $false $false)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    if ($lane -and $lane.kind -eq 'manual') {
        [void](Add-MenuItem $menu 'I just sent a message (reset)' { Reset-Manual })
        [void](Add-MenuItem $menu 'Stop this timer' { Stop-Manual } $false ([long]$script:Manual.last_reset_at -gt 0))
        [void](Add-MenuItem $menu 'Assume 60-min cache' { $script:Cfg.manualTtlMin = 60; Save-Config; Update-Lanes; $form.Invalidate() } ([int]$script:Cfg.manualTtlMin -eq 60))
        [void](Add-MenuItem $menu 'Assume 5-min cache' { $script:Cfg.manualTtlMin = 5; Save-Config; Update-Lanes; $form.Invalidate() } ([int]$script:Cfg.manualTtlMin -eq 5))
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    } elseif ($lane -and $lane.kind -eq 'cc') {
        $sid = $lane.sid
        $canPing = ($lane.status -eq 'timer' -and $lane.expires -gt (Get-Epoch))
        $ping = Add-MenuItem $menu 'Keep alive now (sends a tiny turn)' { Request-KeepAlive $this.Tag } $false $canPing
        $ping.Tag = $sid
        $hide = Add-MenuItem $menu 'Hide this session' { $script:Hidden[$this.Tag] = $true; Update-Lanes; $form.Invalidate() }
        $hide.Tag = $sid
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    }

    [void](Add-MenuItem $menu 'Auto-reset when I press Enter in the Claude app' {
        $script:Cfg.autoResetOnEnter = -not [bool]$script:Cfg.autoResetOnEnter; Save-Config } ([bool]$script:Cfg.autoResetOnEnter))
    [void](Add-MenuItem $menu 'Show Chat / Cowork timer' {
        $script:Cfg.showManual = -not [bool]$script:Cfg.showManual; Save-Config; Update-Lanes; $form.Invalidate() } ([bool]$script:Cfg.showManual))
    [void](Add-MenuItem $menu "Auto keep-alive for Claude Code (at T-$($script:Cfg.autoKeepAliveAt)s)" {
        $script:Cfg.autoKeepAlive = -not [bool]$script:Cfg.autoKeepAlive; Save-Config; Update-Lanes; $form.Invalidate() } ([bool]$script:Cfg.autoKeepAlive))
    [void](Add-MenuItem $menu 'Close when Claude is not running' {
        $script:Cfg.autoExit = -not [bool]$script:Cfg.autoExit; Save-Config } ([bool]$script:Cfg.autoExit))
    [void](Add-MenuItem $menu 'Check for updates' { Start-UpdateCheck } $false ($null -eq $script:Upd))
    [void](Add-MenuItem $menu 'Open data folder' { Start-Process explorer.exe $script:Base })
    [void](Add-MenuItem $menu 'Exit Cache Clock' { $form.Close() })
    return $menu
}

# ---------- tray menu ----------
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
[void](Add-MenuItem $trayMenu 'Reset Chat / Cowork timer' { Reset-Manual })
[void](Add-MenuItem $trayMenu 'Show / hide widget' { $form.Visible = -not $form.Visible })
[void](Add-MenuItem $trayMenu 'Check for updates' { Start-UpdateCheck })
[void](Add-MenuItem $trayMenu 'Move widget to default spot' { Set-DefaultPosition; $script:Cfg.x = $form.Left; $script:Cfg.y = $form.Top; Save-Config })
[void](Add-MenuItem $trayMenu 'Exit Cache Clock' { $form.Close() })
$notify.ContextMenuStrip = $trayMenu
$notify.Add_DoubleClick({ $form.Visible = -not $form.Visible })

# ---------- timers ----------
$uiTimer = New-Object System.Windows.Forms.Timer
$uiTimer.Interval = 1000
$uiTimer.Add_Tick({
    try {
        Update-ConfigFromDisk
        Update-Lanes
        Test-Alerts
        Test-Pings
        Test-UpdateCheck
        Test-AutoExit
        $now = Get-Epoch
        if (($now - $script:LastTopMost) -ge 10) { $form.TopMost = $false; $form.TopMost = $true; $script:LastTopMost = $now }
        $form.Invalidate()
    } catch { Write-Log "ui tick: $_" }
})

$keyTimer = New-Object System.Windows.Forms.Timer
$keyTimer.Interval = 30
$keyTimer.Add_Tick({
    try {
        $now = Get-Epoch
        # Enter in the Claude app = a message was probably sent (Shift+Enter is a new line).
        $enter = [CacheClockNative]::IsDown(0x0D)
        if ($enter -and -not $script:PrevEnter -and [bool]$script:Cfg.autoResetOnEnter -and $script:Cfg.showManual) {
            if (-not [CacheClockNative]::IsDown(0x10) -and ($now - $script:LastEnterReset) -ge 1 -and (Test-ClaudeForeground)) {
                $script:LastEnterReset = $now
                Reset-Manual
            }
        }
        $script:PrevEnter = $enter

        # Ctrl+Alt+<key> resets the manual timer from anywhere.
        $vk = [int][char]([string]$script:Cfg.hotkeyKey).ToUpper()[0]
        $hot = [CacheClockNative]::IsDown(0x11) -and [CacheClockNative]::IsDown(0x12) -and [CacheClockNative]::IsDown($vk)
        if ($hot -and -not $script:PrevHotkey) { Reset-Manual }
        $script:PrevHotkey = $hot
    } catch { Write-Log "key tick: $_" }
})

$form.Add_FormClosed({
    $uiTimer.Stop(); $keyTimer.Stop()
    $notify.Visible = $false; $notify.Dispose()
    Remove-Item -LiteralPath $script:PidPath -ErrorAction SilentlyContinue
    try { $script:Mutex.ReleaseMutex() } catch { }
})

Update-Lanes
$uiTimer.Start()
$keyTimer.Start()
[System.Windows.Forms.Application]::Run($form)
