#!/bin/sh
# Cache Clock: keep-alive listener (runs as an asyncRewake Stop hook). POSIX sh + awk.
# After each turn it waits in the background, and exits with code 2 to wake Claude for a tiny
# turn when:
#   - the widget (or anything else) drops pings/<sid>.flag: a manual keep-alive, or
#   - auto keep-alive is on and the cache is about to expire, within the token budget.
# That turn is a real API request, so it reads the cache and resets the TTL.
# On macOS and Linux it also shows the expiry alerts (on Windows the widget does).

CC_HERE=$(cd "$(dirname "$0")" && pwd)
. "$CC_HERE/lib.sh"

input=$(cat)
eval "$(cc_fields "$input" h 'session_id agent_id')"
[ -n "$h_session_id" ] || exit 0
[ -n "$h_agent_id" ] && exit 0

safe=$(cc_safe_id "$h_session_id")
state="$CC_DIR/sessions/$safe.json"
ping="$CC_DIR/pings/$safe.flag"
waiter="$CC_DIR/waiters/$safe.pid"

# Newest listener wins. An older one sees a different PID in the file and quits.
echo $$ > "$waiter"
started=$(cc_now)
fired=' '

wake() {
    rm -f "$waiter"
    echo "[cache-clock] $1 Reply with exactly: ok. Do not call any tools and do not add anything else." >&2
    exit 2
}

while :; do
    sleep 2
    now=$(cc_now)
    owner=$(cat "$waiter" 2>/dev/null) || exit 0
    [ "$owner" = "$$" ] || exit 0
    [ $((now - started)) -gt 7200 ] && exit 0
    [ -f "$state" ] || continue   # the Stop hook may still be writing it
    eval "$(cc_fields "$(cat "$state")" s 'status expires_at ttl_s cache_read cache_write auto_spent auto_pings project')"
    case "$s_expires_at" in ''|null|*[!0-9]*) s_expires_at='' ;; esac
    cc_load_config

    if [ -n "$s_expires_at" ]; then
        left=$((s_expires_at - now))
        # Once the cache has gone cold, a ping would pay for a full rebuild. Stop listening.
        [ $left -lt -60 ] && exit 0
        auto_left=0
        [ "$cfg_autoKeepAlive" = true ] && auto_left=$(cc_auto_left "${s_cache_read:-0}" "${s_cache_write:-0}" "${s_auto_spent:-0}" "$cfg_autoKeepAliveBudget")

        # Auto keep-alive: ping shortly before expiry, while the budget allows.
        if [ "$s_status" != working ] && [ $left -gt 5 ] && [ $left -le "$cfg_autoKeepAliveAt" ] && [ "$auto_left" -gt 0 ]; then
            cc_set auto_pings $(( ${s_auto_pings:-0} + 1 ))
            cc_set auto_spent $(( ${s_auto_spent:-0} + ${s_cache_read:-0} + ${s_cache_write:-0} ))
            cc_set last_auto_ping_at "$now"
            cc_write "$state"
            wake 'Automatic keep-alive ping to keep the prompt cache warm.'
        fi

        # Alerts (macOS and Linux). Skipped while auto keep-alive has this session covered.
        if [ "$s_status" != working ] && { [ "$CC_PLATFORM" = mac ] || [ "$CC_PLATFORM" = linux ]; }; then
            title="Cache Clock: ${s_project:-Claude Code}"
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
                [ -n "$crossed" ] && cc_notify "$title" "About $(( (left + 59) / 60 )) min left. Type /cache-clock:keepalive to keep it warm."
            fi
        fi
    fi

    if [ -f "$ping" ]; then
        rm -f "$ping"
        # Claude is mid-turn: the cache is being refreshed anyway, so skip the ping.
        [ "$s_status" = working ] && continue
        wake 'The user asked for a keep-alive ping to keep the prompt cache warm.'
    fi
done
