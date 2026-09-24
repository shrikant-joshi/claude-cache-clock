# Cache Clock: shared helpers for cc.sh, waiter.sh and statusline.sh. POSIX sh + awk.
# Sourced, not run. Expects $CC_HERE (the scripts folder) to be set by the caller.
# Runs on macOS, Linux, WSL, and native Windows (Git Bash, which Claude Code uses for hooks).

CC_AWK="$CC_HERE/json.awk"

cc_now() { date +%s; }

cc_platform() {
    case "$(uname -s 2>/dev/null)" in
        Darwin) echo mac ;;
        MINGW*|MSYS*|CYGWIN*) echo gitbash ;;
        Linux)
            if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then echo wsl; else echo linux; fi ;;
        *) echo other ;;
    esac
}
CC_PLATFORM=${CACHE_CLOCK_PLATFORM:-$(cc_platform)}   # override for testing

# WSL: the Windows user profile as a Linux path (/mnt/c/Users/x). Cached: cmd.exe is slow to start.
cc_windows_home() {
    cache="${XDG_CACHE_HOME:-$HOME/.cache}/cache-clock/windows-home"
    if [ -s "$cache" ]; then cat "$cache"; return 0; fi
    command -v cmd.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1 || return 1
    w=$(cd /mnt/c 2>/dev/null; cmd.exe /d /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')
    case "$w" in ''|*%*) return 1 ;; esac
    p=$(wslpath -u "$w" 2>/dev/null) || return 1
    mkdir -p "$(dirname "$cache")" && printf '%s\n' "$p" > "$cache"
    printf '%s\n' "$p"
}

# Data folder shared with the Windows widget. On Windows (WSL or Git Bash) it's %USERPROFILE%\.cache-clock,
# so the widget finds it. Elsewhere ~/.cache-clock. Override: CACHE_CLOCK_DIR.
cc_data_dir() {
    if [ -n "${CACHE_CLOCK_DIR:-}" ]; then
        d=$CACHE_CLOCK_DIR
    else
        d="$HOME/.cache-clock"
        case $CC_PLATFORM in
            wsl) h=$(cc_windows_home) && d="$h/.cache-clock" ;;
            gitbash) [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1 && d="$(cygpath -u "$USERPROFILE")/.cache-clock" ;;
        esac
    fi
    mkdir -p "$d/sessions" "$d/pings" "$d/waiters" 2>/dev/null
    printf '%s\n' "$d"
}

# Stable home for the status line script: plugin updates change the plugin path, not this one.
# Only trust CLAUDE_PLUGIN_DATA if it's ours: a shell can inherit another plugin's value.
cc_stable_dir() {
    case "${CLAUDE_PLUGIN_DATA:-}" in
        */cache-clock-*) printf '%s\n' "$CLAUDE_PLUGIN_DATA" ;;
        *) printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/data/cache-clock-cache-clock" ;;
    esac
}

# ---- JSON ----
cc_get() { printf '%s' "$1" | awk -f "$CC_AWK" -v mode=get -v key="$2"; }        # json, key
cc_raw() { printf '%s' "$1" | awk -f "$CC_AWK" -v mode=raw -v key="$2"; }        # json, key
cc_fields() { printf '%s' "$1" | awk -f "$CC_AWK" -v mode=fields -v prefix="$2" -v keys="$3"; }  # json, prefix, keys
cc_jstr() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }
cc_jnum() { case "$1" in ''|*[!0-9-]*) printf 'null' ;; *) printf '%s' "$1" ;; esac; }
cc_jbool() { case "$1" in true|1) printf 'true' ;; *) printf 'false' ;; esac; }

# Pending updates for cc_write: "key<TAB>json" lines.
CC_UPD=''
cc_set() { CC_UPD="$CC_UPD$1	$2
"; }

# Merge CC_UPD into a flat JSON file, atomically (temp file + rename), then clear CC_UPD.
# A mkdir lock keeps two writers (hook, status line, listener) from losing each other's fields.
cc_write() {
    f=$1; lk="$f.lock"; n=0
    until mkdir "$lk" 2>/dev/null; do
        n=$((n + 1)); [ $n -ge 40 ] && { rmdir "$lk" 2>/dev/null; n=0; }   # stale lock from a killed writer
        sleep 0.05 2>/dev/null || sleep 1
    done
    { [ -f "$f" ] && cat "$f"; } | CC_UPD="$CC_UPD" awk -f "$CC_AWK" -v mode=merge > "$f.$$.tmp" && mv -f "$f.$$.tmp" "$f"
    rmdir "$lk" 2>/dev/null
    CC_UPD=''
}

cc_safe_id() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'; }

# Paths in hook input: Git Bash gets Windows paths (C:\...). Everything else is already native.
cc_native_path() {
    if [ "$CC_PLATFORM" = gitbash ] && command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s\n' "$1"; fi
}

cc_basename() { printf '%s' "$1" | sed 's#\\#/#g; s#/*$##; s#.*/##'; }

# Settings shared with the widget (config.json). Missing keys get defaults.
cc_load_config() {
    cfg=''
    [ -f "$CC_DIR/config.json" ] && cfg=$(cat "$CC_DIR/config.json")
    eval "$(cc_fields "$cfg" cfg 'autoKeepAlive autoKeepAliveAt autoKeepAliveBudget thresholds shortThresholds')"
    [ -n "$cfg_autoKeepAlive" ] || cfg_autoKeepAlive=false
    [ -n "$cfg_autoKeepAliveAt" ] || cfg_autoKeepAliveAt=60
    [ -n "$cfg_autoKeepAliveBudget" ] || cfg_autoKeepAliveBudget=1000000
    cfg_thresholds=$(printf '%s' "${cfg_thresholds:-15,10,5}" | tr -cd '0-9,' | tr ',' ' ')
    cfg_shortThresholds=$(printf '%s' "${cfg_shortThresholds:-2,1}" | tr -cd '0-9,' | tr ',' ' ')
}

# Auto pings left in the budget: each one re-reads the whole context. -1 if the size is unknown.
cc_auto_left() {  # cache_read cache_write auto_spent budget
    ctx=$(( ${1:-0} + ${2:-0} ))
    [ "$ctx" -gt 0 ] || { echo -1; return; }
    left=$(( ${4:-0} - ${3:-0} ))
    [ "$left" -gt 0 ] || { echo 0; return; }
    echo $(( left / ctx ))
}

cc_default_ttl() {
    case "${CLAUDE_CODE_PROMPT_CACHE_TTL:-}" in 5m) echo 300; return ;; 1h) echo 3600; return ;; esac
    [ "${FORCE_PROMPT_CACHING_5M:-}" = 1 ] && { echo 300; return; }
    echo 3600
}

# Epoch -> local HH:MM (GNU date, then BSD date).
cc_hm() { date -d "@$1" +%H:%M 2>/dev/null || date -r "$1" +%H:%M 2>/dev/null; }

# Desktop notification on macOS and Linux. On Windows the widget shows them.
cc_notify() {  # title message
    t=$(printf '%s' "$1" | tr -d '"\\'); m=$(printf '%s' "$2" | tr -d '"\\')
    case $CC_PLATFORM in
        mac) osascript -e "display notification \"$m\" with title \"$t\"" >/dev/null 2>&1 ;;
        linux) command -v notify-send >/dev/null 2>&1 && notify-send "$t" "$m" >/dev/null 2>&1 ;;
    esac
    return 0
}

CC_DIR=$(cc_data_dir)
