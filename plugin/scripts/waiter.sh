#!/bin/sh
# Cache Clock: keep-alive listener (runs as an asyncRewake Stop hook). POSIX sh + awk.
# After each turn it waits in the background, and exits with code 2 to wake Claude for a tiny
# turn when:
#   - the widget (or anything else) drops pings/<sid>.flag: a manual keep-alive, or
#   - auto keep-alive is on and the cache is about to expire, within the token budget.
# That turn is a real API request, so it reads the cache and resets the TTL.
# When the Cache Clock mod (hooks/mod.tsx, Claude Code 2.1.287+) runs in the session, it asks the
# mod first: the mod answers with a fork ping, which reads the cache without a turn. Protocol:
# write pings/<sid>.fork ("<epoch> <kind>"), the mod copies it to pings/<sid>.ack at once and runs
# `cc.sh mod forked` when done, which removes both. No ack in 6s, or a recent failed fork: wake.
# On macOS and Linux it also shows the expiry alerts (on Windows the widget does).
# `waiter.sh codex` (hooks/codex-hooks.json, an async Stop hook): Codex has no asyncRewake. It runs
# such a hook in the foreground, and exit 2 there blocks the Stop and continues the turn, in an
# endless loop. So on Codex the listener never exits 2 and never wakes. It pings by running a fork
# itself: `codex exec --ephemeral fork <sid>` sends the session's history plus a tiny prompt as a
# separate thread, which reads the session's cache entry and adds nothing to the conversation.

CC_HERE=$(cd "$(dirname "$0")" && pwd)
. "$CC_HERE/lib.sh"

host=${1:-claude-code}
input=$(cat)
eval "$(cc_fields "$input" h 'session_id agent_id transcript_path cwd')"
[ -n "$h_session_id" ] || exit 0
[ -n "$h_agent_id" ] && exit 0
[ "${CACHE_CLOCK_IN_FORK:-}" = 1 ] && exit 0   # our own Codex fork ping
[ "$h_transcript_path" = null ] && h_transcript_path=''
[ "$host" = codex ] && [ -z "$h_transcript_path" ] && exit 0   # codex exec --ephemeral: nothing to keep warm

safe=$(cc_safe_id "$h_session_id")
state="$CC_DIR/sessions/$safe.json"
ping="$CC_DIR/pings/$safe.flag"
fork_req="$CC_DIR/pings/$safe.fork"
fork_ack="$CC_DIR/pings/$safe.ack"
fork_out="$CC_DIR/pings/$safe.out"
waiter="$CC_DIR/waiters/$safe.pid"

# Newest listener wins. An older one sees a different PID in the file and quits.
echo $$ > "$waiter"
# Claude Code kills this listener (TERM) when the session ends, and then skips the SessionEnd
# hook while an asyncRewake hook was still running (seen in 2.1.281). So the listener does the
# session-end cleanup itself: if it's still the current listener, the session is over. A newer
# listener means the session is alive, so leave its files alone. Sleep in the background and
# wait for it: a trapped signal interrupts `wait` at once, a foreground sleep would delay it.
sp=''
on_signal() {
    [ -n "$sp" ] && kill "$sp" 2>/dev/null
    if [ "$(cat "$waiter" 2>/dev/null)" = "$$" ]; then rm -f "$state" "$ping" "$waiter" "$fork_req" "$fork_ack" "$fork_out"; fi
    exit 0
}
trap on_signal HUP INT TERM
started=$(cc_now)
fired=' '
fired_for=''
fork_since=''

nap() {
    sleep "$1" </dev/null >/dev/null 2>&1 &
    sp=$!
    wait "$sp"
    sp=''
}

# Ask the mod for a fork ping. Returns 0 when the mod took the request.
try_fork() {
    [ -n "$s_mod_version" ] || return 1
    case "$s_fork_failed_at" in ''|null|*[!0-9]*) ;; *) [ $((now - s_fork_failed_at)) -lt 600 ] && return 1 ;; esac
    req="$now $1"
    printf '%s\n' "$req" > "$fork_req"
    i=0
    while [ $i -lt 6 ]; do
        nap 1
        # Acked, or already done (`cc.sh mod forked` removed the request).
        if [ ! -f "$fork_req" ] || [ "$(cat "$fork_ack" 2>/dev/null)" = "$req" ]; then
            fork_since=$now
            started=$now
            return 0
        fi
        i=$((i + 1))
    done
    rm -f "$fork_req"
    return 1
}

# Codex: run the fork ping and record the result (`cc.sh mod forked`, as for the Claude Code mod).
# Model, sandbox, approval policy and effort come from the session's last turn_context: they must
# match, or the request's prefix differs and misses the cache. At most 2 min. Returns 1 on failure.
# An auto fork is charged to the budget afterwards, with the tokens it really sent (none if it never
# reached the server). A failure alerts once per expiry.
CODEX_FORK_EXTRA=20000   # uncached tokens a fork adds on top of the history (exec's own context), live ~15-22k
CODEX_FORK_LEAD=300      # auto forks start at least this long before expiry: a slow or failed fork leaves time to retry
CODEX_FORK_RETRY=60      # after a failed fork, wait this long before the next auto attempt
CODEX_PING='[cache-clock] Automatic keep-alive, not from the user. Take no action and call no tools. Reply with only: ok'
codex_fork() {  # auto|manual
    kind=$1
    tp=$(cc_native_path "$h_transcript_path")
    set -- $(tail -c 1048576 "$tp" 2>/dev/null | awk -f "$CC_AWK" -v mode=codexctx)
    if [ $# -eq 5 ] && [ "$1" != - ] && [ "$2" != - ] && [ "$3" != - ]; then
        net=''; [ "$4" = true ] && net='-c sandbox_workspace_write.network_access=true'
        eff=''; [ "$5" != - ] && eff="-c model_reasoning_effort=\"$5\""
        dir=''; [ -n "$h_cwd" ] && [ -d "$h_cwd" ] && dir=$h_cwd
        (
            [ -n "$dir" ] && cd "$dir"
            CACHE_CLOCK_IN_FORK=1 exec "${CACHE_CLOCK_CODEX:-${CODEX_CLI_PATH:-codex}}" exec --ephemeral --skip-git-repo-check --json \
                -m "$1" -s "$3" -c "approval_policy=\"$2\"" $net $eff fork "$h_session_id" "$CODEX_PING"
        ) </dev/null >"$fork_out" 2>&1 &
        fp=$!; i=0
        while kill -0 "$fp" 2>/dev/null; do
            [ $i -ge 120 ] && { kill "$fp" 2>/dev/null; break; }
            nap 1; i=$((i + 1))
        done
        wait "$fp"; rc=$?
    else
        echo "no turn_context in $tp" > "$fork_out"; rc=1
    fi
    u=$(grep -o '"usage":{[^}]*}' "$fork_out" 2>/dev/null | tail -1)
    fin=$(cc_get "{$u}" input_tokens); frd=$(cc_get "{$u}" cached_input_tokens)
    if [ "$kind" = auto ] && [ -n "$fin" ]; then
        cc_set auto_pings $(( ${s_auto_pings:-0} + 1 ))
        cc_set auto_spent $(( ${s_auto_spent:-0} + fin ))
        cc_write "$state"
    fi
    if [ "$rc" -eq 0 ] && [ -n "$fin" ] && [ -n "$frd" ]; then
        sh "$CC_HERE/cc.sh" mod forked "$h_session_id" ok "$frd" $((fin - frd))
        rm -f "$fork_out"   # kept on failure, for a look
        started=$(cc_now)
        return 0
    fi
    sh "$CC_HERE/cc.sh" mod forked "$h_session_id" fail "$frd" ''
    case "$fired" in *' forkfail '*) ;; *)
        fired="$fired forkfail "
        { [ "$CC_PLATFORM" = mac ] || [ "$CC_PLATFORM" = linux ]; } &&
            cc_notify "Cache Clock: ${s_project:-Codex}" 'The keep-alive ping failed. Send a message in Codex to keep the cache warm.' ;;
    esac
    return 1
}

wake() {
    [ "$host" = codex ] && return 0
    rm -f "$waiter"
    echo "[cache-clock] $1 Reply with exactly: ok. Do not call any tools and do not add anything else." >&2
    exit 2
}

while :; do
    nap 2
    now=$(cc_now)
    owner=$(cat "$waiter" 2>/dev/null) || exit 0
    [ "$owner" = "$$" ] || exit 0
    [ $((now - started)) -gt 7200 ] && exit 0
    [ -f "$state" ] || continue   # the Stop hook may still be writing it
    # A fork the mod is still running: wait for its result (at most 2 min).
    if [ -n "$fork_since" ]; then
        if [ -f "$fork_req" ] && [ $((now - fork_since)) -lt 120 ]; then continue; fi
        rm -f "$fork_req" "$fork_ack"
        fork_since=''
    fi
    eval "$(cc_fields "$(cat "$state")" s 'status expires_at ttl_s cache_read cache_write context_tokens auto_spent auto_pings project mod_version fork_failed_at fork_expires_at')"
    case "$s_expires_at" in ''|null|*[!0-9]*) s_expires_at='' ;; esac
    # The status line writes Claude Code's own expiry, which may not count fork pings.
    case "$s_fork_expires_at" in ''|null|*[!0-9]*) ;; *)
        [ "$s_fork_expires_at" -gt "${s_expires_at:-0}" ] && s_expires_at=$s_fork_expires_at ;;
    esac
    # A new expiry (a fork ping) starts a new round of alerts.
    [ "$s_expires_at" = "$fired_for" ] || { fired=' '; fired_for=$s_expires_at; }
    # Codex: a short pause after a failed fork before the next auto attempt.
    cool=''
    case "$s_fork_failed_at" in ''|null|*[!0-9]*) ;; *) [ "$host" = codex ] && [ $((now - s_fork_failed_at)) -lt $CODEX_FORK_RETRY ] && cool=1 ;; esac
    cc_load_config
    auto_at=$cfg_autoKeepAliveAt
    [ "$host" = codex ] && [ "$auto_at" -lt $CODEX_FORK_LEAD ] && auto_at=$CODEX_FORK_LEAD

    if [ -n "$s_expires_at" ]; then
        left=$((s_expires_at - now))
        # Once the cache has gone cold, a ping would pay for a full rebuild. Stop listening.
        [ $left -lt -60 ] && exit 0
        auto_left=0
        ctx=$(( ${s_cache_read:-0} + ${s_cache_write:-0} ))
        [ "$ctx" -gt 0 ] || ctx=${s_context_tokens:-0}   # no receipt yet: the status line's context size
        [ "$host" = codex ] && [ "$ctx" -gt 0 ] && ctx=$((ctx + CODEX_FORK_EXTRA))
        [ "$cfg_autoKeepAlive" = true ] && [ -z "$cool" ] && auto_left=$(cc_auto_left "$ctx" 0 "${s_auto_spent:-0}" "$cfg_autoKeepAliveBudget")

        # Auto keep-alive: ping shortly before expiry, while the budget allows.
        if [ "$s_status" != working ] && [ $left -gt 5 ] && [ $left -le "$auto_at" ] && [ "$auto_left" -gt 0 ]; then
            cc_set last_auto_ping_at "$now"
            if [ "$host" = codex ]; then
                cc_write "$state"
                codex_fork auto
                continue
            fi
            cc_set auto_pings $(( ${s_auto_pings:-0} + 1 ))
            cc_set auto_spent $(( ${s_auto_spent:-0} + ctx ))
            cc_write "$state"
            try_fork auto && continue
            wake 'Automatic keep-alive ping to keep the prompt cache warm.'
        fi

        # Alerts (macOS and Linux). Skipped while auto keep-alive has this session covered.
        if [ "$s_status" != working ] && { [ "$CC_PLATFORM" = mac ] || [ "$CC_PLATFORM" = linux ]; }; then
            app='Claude Code'; hint=' Type /cache-clock:keepalive to keep it warm.'
            [ "$host" = codex ] && { app=Codex; hint=''; }
            title="Cache Clock: ${s_project:-$app}"
            if [ $left -le 0 ]; then
                case "$fired" in *' cold '*) ;; *)
                    fired="$fired cold "
                    cc_notify "$title" 'The cache has expired. Your next message rebuilds it: slower, and it uses more of your plan.' ;;
                esac
            elif [ "$auto_left" -le 0 ]; then
                ths=$cfg_thresholds; [ "${s_ttl_s:-3600}" -lt 900 ] && ths=$cfg_shortThresholds
                crossed=''
                for t in $ths; do
                    if [ $left -le $((t * 60)) ]; then
                        case "$fired" in *" $t "*) ;; *) fired="$fired $t "; crossed=1 ;; esac
                    fi
                done
                [ -n "$crossed" ] && cc_notify "$title" "About $(( (left + 59) / 60 )) min left.$hint"
            fi
        fi
    fi

    if [ -f "$ping" ]; then
        rm -f "$ping"
        # Claude is mid-turn: the cache is being refreshed anyway, so skip the ping.
        [ "$s_status" = working ] && continue
        [ "$host" = codex ] && { codex_fork manual; continue; }
        try_fork manual && continue
        wake 'The user asked for a keep-alive ping to keep the prompt cache warm.'
    fi
done
