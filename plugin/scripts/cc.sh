#!/bin/sh
# Cache Clock: Claude Code hook handler. POSIX sh + awk: macOS, Linux, WSL, Windows (Git Bash).
#   sh cc.sh start|prompt|stop|end [codex]   hooks (hook JSON on stdin); codex: from hooks/codex-hooks.json
#   sh cc.sh config [key value]        show or change a setting in config.json
#   sh cc.sh setup-info                what /cache-clock:setup needs to know
#   sh cc.sh datadir                   print the data folder
#   sh cc.sh mod hello <sid> <version>                     called by hooks/mod.tsx (the mod)
#   sh cc.sh mod forked <sid> ok|fail <read> <write>       a fork ping's result (also from waiter.sh codex)
# Keeps one state file per session in <data dir>/sessions/<sid>.json, from the API "receipts"
# (usage fields) Claude Code writes into the session transcript, or Codex into its rollout file.
# The status line (Claude Code only) and the Windows widget read the same files.

CC_HERE=$(cd "$(dirname "$0")" && pwd)
. "$CC_HERE/lib.sh"
CC_ROOT=$(dirname "$CC_HERE")

plugin_version() { cc_get "$(cat "$CC_ROOT/.claude-plugin/plugin.json" 2>/dev/null)" version; }

# Copy the status line into a folder that survives plugin updates, if it changed.
sync_statusline() {
    sd=$(cc_stable_dir)
    mkdir -p "$sd" 2>/dev/null || return 0
    for f in statusline.sh lib.sh json.awk prices.txt; do
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

# One machine can run Claude Code in WSL and on Windows (the desktop app's Local sessions), so
# each environment keeps its own fields and the widget's update check covers both.
# env/distro/plugin_version are the last writer's, for widgets older than 0.7.2.
write_host_info() {
    case $CC_PLATFORM in wsl) env=wsl ;; gitbash) env=windows ;; *) return 0 ;; esac
    v=$(plugin_version); t=$(cc_now)
    cc_set env "$(cc_jstr "$env")"
    cc_set plugin_version "$(cc_jstr "$v")"
    cc_set updated_at "$t"
    cc_set "${env}_version" "$(cc_jstr "$v")"
    cc_set "${env}_at" "$t"
    if [ "$env" = wsl ]; then
        cc_set distro "$(cc_jstr "${WSL_DISTRO_NAME:-}")"
        cc_set wsl_distro "$(cc_jstr "${WSL_DISTRO_NAME:-}")"
    else
        # The desktop app's own claude.exe: Windows often has no claude on PATH.
        cli=${CLAUDE_CODE_EXECPATH:-}
        case "$cli" in /*) command -v cygpath >/dev/null 2>&1 && cli=$(cygpath -w "$cli" 2>/dev/null) ;; esac
        cc_set windows_cli "$(cc_jstr "$cli")"
    fi
    cc_write "$CC_DIR/host.json"
}

# A listener lives at most 2 hours and doesn't always remove its PID file (cold exit, killed,
# reboot), and a killed writer can leave a temp file. Clear both once they are 3 hours old.
sweep_stale() {
    find "$CC_DIR/waiters" "$CC_DIR/sessions" -type f \( -name '*.pid' -o -name '*.tmp' \) -mmin +180 -exec rm -f {} + 2>/dev/null
}

# Read the last receipt from the transcript into pending updates for the session file.
update_from_transcript() {  # transcript, turn_started_at, state ttl
    tp=$1; turn=${2:-0}; old_ttl=$3
    [ -n "$tp" ] || return 1
    # The transcript is written asynchronously (on a session's first turn it may not exist yet).
    # Give it a moment to catch up with the last response.
    i=0; u=''; tries=8
    [ "$turn" -gt 0 ] || tries=1   # SessionStart: take what's there, don't wait
    while [ $i -lt $tries ]; do
        [ -f "$tp" ] && u=$(tail -c 1048576 "$tp" 2>/dev/null | awk -f "$CC_AWK" -v mode=usage)
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

# Codex: its rollout's last token_count. input_tokens includes the cached part, and Codex
# reports no cache writes (cache_write_input_tokens reads 0), so writes = input - cached.
# OpenAI caches every prompt over 1024 tokens with no opt-in, so any response starts a TTL.
CODEX_TTL=1800   # docs: at least 30 min; spike: warm at 35m41s, cold at 60m20s
update_from_rollout() {  # rollout, turn_started_at
    tp=$1; turn=${2:-0}
    [ -n "$tp" ] || return 1
    i=0; u=''; tries=8
    [ "$turn" -gt 0 ] || tries=1
    while [ $i -lt $tries ]; do
        [ -f "$tp" ] && u=$(tail -c 1048576 "$tp" 2>/dev/null | awk -f "$CC_AWK" -v mode=codex)
        if [ -n "$u" ]; then
            set -- $u
            [ "$1" -ge "$turn" ] && break
        fi
        sleep 0.4 2>/dev/null || sleep 1
        i=$((i + 1))
    done
    [ -n "$u" ] || return 1
    set -- $u
    ts=$1; inp=$2; rd=$3
    wr=$((inp - rd)); [ "$wr" -ge 0 ] || wr=0
    last=$ts
    [ "$turn" -gt 0 ] && [ "$last" -lt "$turn" ] && last=$(cc_now)
    rebuilt=false; [ "$wr" -gt "$rd" ] && rebuilt=true
    cc_set ttl_s "$CODEX_TTL"
    cc_set last_response_at "$last"
    cc_set cache_read "$rd"
    cc_set cache_write "$wr"
    cc_set context_tokens "$inp"
    [ "$4" != - ] && cc_set context_max "$4"
    cc_set quota_pct "$(cc_jnum "${5%.*}")"
    cc_set quota_resets_at "$(cc_jnum "$6")"
    cc_set quota_window_min "$(cc_jnum "$7")"
    if [ "$inp" -gt 0 ]; then
        cc_set caching_observed true
        cc_set expires_at $((last + CODEX_TTL))
    else
        cc_set caching_observed false
        cc_set expires_at null
    fi
    cc_set rebuilt "$rebuilt"
    cc_set basis '"transcript"'
}

# Codex fires no SessionEnd when the TUI exits, so its session files would stay forever.
# Remove Codex sessions that have been cold for an hour, or never got a receipt in 2 hours.
# Not this one: a resumed session starts with an old receipt.
sweep_codex() {
    for f in "$CC_DIR"/sessions/*.json; do
        [ -f "$f" ] && [ "$f" != "$state" ] || continue
        j=$(cat "$f" 2>/dev/null)
        case "$j" in *'"source":"codex"'*) ;; *) continue ;; esac
        eval "$(cc_fields "$j" w 'expires_at updated_at')"
        case "$w_expires_at" in ''|null|*[!0-9]*) w_expires_at='' ;; esac
        case "$w_updated_at" in ''|null|*[!0-9]*) w_updated_at=0 ;; esac
        if { [ -n "$w_expires_at" ] && [ $((now - w_expires_at)) -gt 3600 ]; } ||
           { [ -z "$w_expires_at" ] && [ $((now - w_updated_at)) -gt 7200 ]; }; then
            b=$(basename "$f" .json)
            rm -f "$f" "$CC_DIR/waiters/$b.pid" "$CC_DIR/pings/$b.flag" "$CC_DIR/pings/$b.out"
        fi
    done
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
        printf '%s\n' "config: $f"
        printf '%s\n' "autoKeepAlive=$cfg_autoKeepAlive autoKeepAliveAt=$cfg_autoKeepAliveAt autoKeepAliveBudget=$cfg_autoKeepAliveBudget"
        printf '%s\n' "thresholds=$cfg_thresholds shortThresholds=$cfg_shortThresholds"
        printf '%s\n' "ctxThresholds=$cfg_ctxThresholds color=$cfg_color showCost=$cfg_showCost band=$cfg_band"
        exit 0 ;;
    setup-info)
        sync_statusline
        sd=$(cc_stable_dir)
        printf '%s\n' "platform: $CC_PLATFORM"
        printf '%s\n' "data_dir: $CC_DIR"
        printf '%s\n' "settings_file: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
        printf '%s\n' "statusline_command: sh \"$sd/statusline.sh\""
        case $CC_PLATFORM in
            wsl) printf '%s\n' "widget_install: powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$(wslpath -w "$CC_ROOT/addons/windows/install.ps1")'" ;;
            gitbash) printf '%s\n' "widget_install: powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$(cygpath -w "$CC_ROOT/addons/windows/install.ps1")'" ;;
            *) printf '%s\n' "widget_install: none (the widget is Windows-only)" ;;
        esac
        exit 0 ;;
    datadir)
        printf '%s\n' "$CC_DIR"
        exit 0 ;;
    mod)
        sub=${2:-}; sid=${3:-}
        [ -n "$sid" ] || exit 1
        safe=$(cc_safe_id "$sid")
        state="$CC_DIR/sessions/$safe.json"
        now=$(cc_now)
        cc_set session_id "$(cc_jstr "$sid")"
        case "$sub" in
            hello)
                cc_set mod_version "$(cc_jstr "${4:-}")" ;;
            forked)
                rm -f "$CC_DIR/pings/$safe.fork" "$CC_DIR/pings/$safe.ack"
                eval "$(cc_fields "$(cat "$state" 2>/dev/null)" s 'ttl_s expires_at fork_pings')"
                if [ "${4:-}" = ok ]; then
                    # The fork read the main transcript's cache entry, which resets its TTL.
                    # Confirmed for the 5m and 1h TTLs (dev/cc-fork-spike, 2026-10-11).
                    ttl=$s_ttl_s; case "$ttl" in ''|null|*[!0-9]*) ttl=$(cc_default_ttl) ;; esac
                    until=$((now + ttl))
                    case "$s_expires_at" in ''|null|*[!0-9]*) s_expires_at=0 ;; esac
                    cc_set last_fork_at "$now"
                    cc_set fork_expires_at "$until"
                    cc_set fork_pings $(( ${s_fork_pings:-0} + 1 ))
                    [ "$until" -gt "$s_expires_at" ] && cc_set expires_at "$until"
                else
                    cc_set fork_failed_at "$now"
                fi
                cc_set last_fork_read "$(cc_jnum "${5:-}")"
                cc_set last_fork_write "$(cc_jnum "${6:-}")" ;;
            *) exit 1 ;;
        esac
        cc_set updated_at "$now"
        mkdir -p "$CC_DIR/sessions" 2>/dev/null
        cc_write "$state"
        exit 0 ;;
esac

ev=${1:-}
host=${2:-claude-code}
[ "${CACHE_CLOCK_IN_FORK:-}" = 1 ] && { cat >/dev/null; exit 0; }   # hooks of our own Codex fork ping (waiter.sh): not a session
input=$(cat)
eval "$(cc_fields "$input" h 'session_id agent_id transcript_path cwd model')"
[ -n "$h_session_id" ] || exit 0
[ -n "$h_agent_id" ] && exit 0   # Subagents have their own 5-min cache. Track the main chat only.
[ "$h_transcript_path" = null ] && h_transcript_path=''
# Codex: `codex exec --ephemeral` has no rollout (and nothing to track): our own fork pings, for one.
[ "$host" = codex ] && [ -z "$h_transcript_path" ] && [ "$ev" != end ] && exit 0

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
cc_set source "$(cc_jstr "$host")"
cc_set session_id "$(cc_jstr "$sid")"
# app = the Claude desktop app or the Codex (ChatGPT) desktop app: the widget can open the chat there.
client=terminal
case "$host:${CLAUDE_CODE_ENTRYPOINT:-}:${CODEX_INTERNAL_ORIGINATOR_OVERRIDE:-}" in
    claude-code:claude-desktop:*|codex:*:*Desktop*) client=app ;;
esac
cc_set client "\"$client\""
# The Claude app opens its sessions by its own id (claude://code/continue?session=local_...), not the CLI's.
if [ "$client:$host" = app:claude-code ]; then
    case "${CLAUDE_CODE_HOST_SESSION_ID:-}" in local_*[!A-Za-z0-9_-]*|'') ;; local_*) cc_set app_session "\"$CLAUDE_CODE_HOST_SESSION_ID\"" ;; esac
fi
if [ -n "$h_cwd" ]; then
    cc_set cwd "$(cc_jstr "$h_cwd")"
    cc_set project "$(cc_jstr "$(cc_basename "$h_cwd")")"
fi
cc_set updated_at "$now"
# Claude Code's model comes from the status line. Codex has none, but puts the model in the hook input.
[ "$host" = codex ] && [ -n "$h_model" ] && cc_set model "$(cc_jstr "$h_model")"

# One reader per host: Claude Code transcript or Codex rollout.
update_receipt() {  # turn_started_at
    if [ "$host" = codex ]; then update_from_rollout "$transcript" "$1"; else update_from_transcript "$transcript" "$1" "$s_ttl_s"; fi
}

case "$ev" in
    start)
        cc_set status '"idle"'
        update_receipt 0
        cc_write "$state"
        write_host_info
        sweep_codex
        sweep_stale
        if [ "$host" != codex ]; then   # status line and $ prices are Claude Code only
            sync_statusline
            cc_load_config
            [ "$cfg_showCost" = false ] || (cc_refresh_prices </dev/null >/dev/null 2>&1 &)
        fi
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
        update_receipt "${s_turn_started_at:-0}"
        cc_write "$state"
        ;;
    end)
        rm -f "$state" "$CC_DIR/waiters/$safe.pid" "$CC_DIR/pings/$safe.flag" "$CC_DIR/pings/$safe.fork" "$CC_DIR/pings/$safe.ack" "$CC_DIR/pings/$safe.out"
        ;;
esac
exit 0
