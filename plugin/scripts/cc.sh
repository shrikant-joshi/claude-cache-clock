#!/bin/sh
# Cache Clock: Claude Code hook handler. POSIX sh + awk: macOS, Linux, WSL, Windows (Git Bash).
#   sh cc.sh start|prompt|stop|end     hooks (hook JSON on stdin)
#   sh cc.sh config [key value]        show or change a setting in config.json
#   sh cc.sh setup-info                what /cache-clock:setup needs to know
# Keeps one state file per session in <data dir>/sessions/<sid>.json, from the API "receipts"
# (usage fields) Claude Code writes into the session transcript. The status line and the
# Windows widget read the same files.

CC_HERE=$(cd "$(dirname "$0")" && pwd)
. "$CC_HERE/lib.sh"
CC_ROOT=$(dirname "$CC_HERE")

plugin_version() { cc_get "$(cat "$CC_ROOT/.claude-plugin/plugin.json" 2>/dev/null)" version; }

# Copy the status line into a folder that survives plugin updates, if it changed.
sync_statusline() {
    sd=$(cc_stable_dir)
    mkdir -p "$sd" 2>/dev/null || return 0
    for f in statusline.sh lib.sh json.awk; do
        cmp -s "$CC_HERE/$f" "$sd/$f" 2>/dev/null || cp -f "$CC_HERE/$f" "$sd/$f" 2>/dev/null
    done
}

# Windows add-on: start the widget (and bring an installed copy up to this version).
launch_widget() {
    [ "${CACHE_CLOCK_NO_AUTOSTART:-}" = 1 ] && return 0
    case $CC_PLATFORM in
        wsl) conv='wslpath -w' ;;
        gitbash) conv='cygpath -w' ;;
        *) return 0 ;;
    esac
    command -v powershell.exe >/dev/null 2>&1 || return 0
    ps1=$($conv "$CC_ROOT/addons/windows/launch.ps1" 2>/dev/null) || return 0
    dirw=$($conv "$CC_DIR" 2>/dev/null) || return 0
    # In the background: the widget takes a second or two to start, and the session shouldn't wait.
    (cd / && powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$ps1" -DataDir "$dirw" </dev/null >/dev/null 2>&1 &)
}

write_host_info() {
    case $CC_PLATFORM in wsl) env=wsl ;; gitbash) env=windows ;; *) return 0 ;; esac
    cc_set env "$(cc_jstr "$env")"
    cc_set distro "$(cc_jstr "${WSL_DISTRO_NAME:-}")"
    cc_set plugin_version "$(cc_jstr "$(plugin_version)")"
    cc_set updated_at "$(cc_now)"
    cc_write "$CC_DIR/host.json"
}

# Read the last receipt from the transcript into pending updates for the session file.
update_from_transcript() {  # transcript, turn_started_at, state ttl
    tp=$1; turn=${2:-0}; old_ttl=$3
    [ -n "$tp" ] && [ -f "$tp" ] || return 1
    # The transcript is written asynchronously. Give it a moment to catch up with the last response.
    i=0; u=''
    while [ $i -lt 4 ]; do
        u=$(tail -c 1048576 "$tp" 2>/dev/null | awk -f "$CC_AWK" -v mode=usage)
        if [ -n "$u" ]; then
            set -- $u
            [ "$1" -ge "$turn" ] && break
        fi
        sleep 0.4 2>/dev/null || sleep 1
        i=$((i + 1))
    done
    [ -n "$u" ] || return 1
    set -- $u
    ts=$1; inp=$2; rd=$3; wr=$4; ttl=$5
    [ "$ttl" -gt 0 ] || ttl=$old_ttl
    [ -n "$ttl" ] && [ "$ttl" != null ] || ttl=$(cc_default_ttl)
    # The cache timer restarts at the last request. If the transcript lags behind this turn, use now.
    last=$ts
    [ "$turn" -gt 0 ] && [ "$last" -lt "$turn" ] && last=$(cc_now)
    observed=false; [ $((rd + wr)) -gt 0 ] && observed=true
    rebuilt=false; [ "$wr" -gt "$rd" ] && rebuilt=true
    cc_set ttl_s "$ttl"
    cc_set last_response_at "$last"
    cc_set cache_read "$rd"
    cc_set cache_write "$wr"
    cc_set context_tokens $((inp + rd + wr))
    cc_set caching_observed "$observed"
    cc_set rebuilt "$rebuilt"
    if [ "$observed" = true ]; then cc_set expires_at $((last + ttl)); else cc_set expires_at null; fi
    cc_set basis '"transcript"'
}

case "${1:-}" in
    config)
        shift
        f="$CC_DIR/config.json"
        if [ $# -ge 2 ]; then
            case "$2" in true|false|null|-*[0-9]|[0-9]*) v=$2 ;; *) v=$(cc_jstr "$2") ;; esac
            cc_set "$1" "$v"
            cc_write "$f"
        fi
        cc_load_config
        echo "config: $f"
        echo "autoKeepAlive=$cfg_autoKeepAlive autoKeepAliveAt=$cfg_autoKeepAliveAt autoKeepAliveBudget=$cfg_autoKeepAliveBudget"
        echo "thresholds=$cfg_thresholds shortThresholds=$cfg_shortThresholds"
        exit 0 ;;
    setup-info)
        sync_statusline
        sd=$(cc_stable_dir)
        echo "platform: $CC_PLATFORM"
        echo "data_dir: $CC_DIR"
        echo "settings_file: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
        echo "statusline_command: sh \"$sd/statusline.sh\""
        case $CC_PLATFORM in
            wsl) echo "widget_install: powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"$(wslpath -w "$CC_ROOT/addons/windows/install.ps1")\"" ;;
            gitbash) echo "widget_install: powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"$(cygpath -w "$CC_ROOT/addons/windows/install.ps1")\"" ;;
            *) echo "widget_install: none (the widget is Windows-only)" ;;
        esac
        exit 0 ;;
esac

ev=${1:-}
input=$(cat)
eval "$(cc_fields "$input" h 'session_id agent_id transcript_path cwd')"
[ -n "$h_session_id" ] || exit 0
[ -n "$h_agent_id" ] && exit 0   # Subagents have their own 5-min cache. Track the main chat only.

sid=$h_session_id
safe=$(cc_safe_id "$sid")
state="$CC_DIR/sessions/$safe.json"
now=$(cc_now)
transcript=''
[ -n "$h_transcript_path" ] && transcript=$(cc_native_path "$h_transcript_path")

old=''
[ -f "$state" ] && old=$(cat "$state")
eval "$(cc_fields "$old" s 'ttl_s turn_started_at last_auto_ping_at')"

cc_set v 1
cc_set source '"claude-code"'
cc_set session_id "$(cc_jstr "$sid")"
if [ -n "$h_cwd" ]; then
    cc_set cwd "$(cc_jstr "$h_cwd")"
    cc_set project "$(cc_jstr "$(cc_basename "$h_cwd")")"
fi
cc_set updated_at "$now"

case "$ev" in
    start)
        cc_set status '"idle"'
        update_from_transcript "$transcript" 0 "$s_ttl_s"
        cc_write "$state"
        write_host_info
        sync_statusline
        launch_widget
        ;;
    prompt)
        cc_set status '"working"'
        cc_set turn_started_at "$now"
        # A real message from the user starts a new idle stretch: refill the auto keep-alive budget.
        # Keep-alive wake-ups carry the [cache-clock] tag, and may or may not fire this hook.
        is_ping=false
        case "$input" in *'[cache-clock]'*) is_ping=true ;; esac
        [ -n "$s_last_auto_ping_at" ] && [ $((now - s_last_auto_ping_at)) -lt 30 ] && is_ping=true
        if [ "$is_ping" = false ]; then
            cc_set auto_pings 0
            cc_set auto_spent 0
        fi
        cc_write "$state"
        ;;
    stop)
        cc_set status '"idle"'
        update_from_transcript "$transcript" "${s_turn_started_at:-0}" "$s_ttl_s"
        cc_write "$state"
        ;;
    end)
        rm -f "$state" "$CC_DIR/waiters/$safe.pid" "$CC_DIR/pings/$safe.flag"
        ;;
esac
exit 0
