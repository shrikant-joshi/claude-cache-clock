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
# endless loop. So on Codex the listener never exits 2 and never wakes: alerts only, for now.

CC_HERE=$(cd "$(dirname "$0")" && pwd)
. "$CC_HERE/lib.sh"

host=${1:-claude-code}
input=$(cat)
eval "$(cc_fields "$input" h 'session_id agent_id')"
[ -n "$h_session_id" ] || exit 0
[ -n "$h_agent_id" ] && exit 0

safe=$(cc_safe_id "$h_session_id")
state="$CC_DIR/sessions/$safe.json"
ping="$CC_DIR/pings/$safe.flag"
fork_req="$CC_DIR/pings/$safe.fork"
fork_ack="$CC_DIR/pings/$safe.ack"
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
    if [ "$(cat "$waiter" 2>/dev/null)" = "$$" ]; then rm -f "$state" "$ping" "$waiter" "$fork_req" "$fork_ack"; fi
    exit 0
}
trap on_signal HUP INT TERM
started=$(cc_now)
fired=' '
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
    cc_load_config

    if [ -n "$s_expires_at" ]; then
        left=$((s_expires_at - now))
        # Once the cache has gone cold, a ping would pay for a full rebuild. Stop listening.
        [ $left -lt -60 ] && exit 0
        auto_left=0
        ctx=$(( ${s_cache_read:-0} + ${s_cache_write:-0} ))
        [ "$ctx" -gt 0 ] || ctx=${s_context_tokens:-0}   # no receipt yet: the status line's context size
        [ "$cfg_autoKeepAlive" = true ] && [ "$host" != codex ] && auto_left=$(cc_auto_left "$ctx" 0 "${s_auto_spent:-0}" "$cfg_autoKeepAliveBudget")

        # Auto keep-alive: ping shortly before expiry, while the budget allows.
        if [ "$s_status" != working ] && [ $left -gt 5 ] && [ $left -le "$cfg_autoKeepAliveAt" ] && [ "$auto_left" -gt 0 ]; then
            cc_set auto_pings $(( ${s_auto_pings:-0} + 1 ))
            cc_set auto_spent $(( ${s_auto_spent:-0} + ctx ))
            cc_set last_auto_ping_at "$now"
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
        [ "$host" = codex ] && continue   # no keep-alive on Codex yet
        # Claude is mid-turn: the cache is being refreshed anyway, so skip the ping.
        [ "$s_status" = working ] && continue
        try_fork manual && continue
        wake 'The user asked for a keep-alive ping to keep the prompt cache warm.'
    fi
done
