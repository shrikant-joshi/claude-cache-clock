#!/bin/sh
# Cache Clock: Claude Code status line. POSIX sh + awk.
# Claude Code passes a prompt_cache object computed from the server's usage receipts, including the
# exact expires_at, plus the context window. This prints
#   cache 23m left, warm until 16:42 (1h TTL), ctx 182k/1M (18%)
# and hands the exact expiry to the session file for the widget and the keep-alive listener.
# Use it as your statusLine command (/cache-clock:setup), or call it from your own status line
# script with the same JSON on stdin to add it as a segment.

CC_HERE=$(cd "$(dirname "$0")" && pwd)
. "$CC_HERE/lib.sh"

input=$(cat)
[ -n "$input" ] || { echo 'cache: ?'; exit 0; }
now=$(cc_now)

fmt_tokens() { awk -v n="$1" 'BEGIN { if (n >= 1000000) { s = sprintf("%.1f", n / 1000000); sub(/\.0$/, "", s); print s "M" } else printf "%.0fk\n", n / 1000 }'; }

eval "$(cc_fields "$input" i 'session_id current_dir')"
pc=$(cc_raw "$input" prompt_cache)
cw=$(cc_raw "$input" context_window)
eval "$(cc_fields "$pc" pc 'caching_observed warm ttl expires_at misses')"
eval "$(cc_fields "$cw" cw 'total_input_tokens context_window_size')"

# Context size from the last API response: input + cache reads + cache writes (what used_percentage counts).
ctx_tokens=${cw_total_input_tokens:-0}
case "$ctx_tokens" in *[!0-9]*|'') ctx_tokens=0 ;; esac
if [ "$ctx_tokens" -eq 0 ] && [ -n "$cw" ]; then
    cu=$(cc_raw "$cw" current_usage)
    eval "$(cc_fields "$cu" cu 'input_tokens cache_creation_input_tokens cache_read_input_tokens')"
    ctx_tokens=$(( ${cu_input_tokens:-0} + ${cu_cache_creation_input_tokens:-0} + ${cu_cache_read_input_tokens:-0} ))
fi
ctx_max=${cw_context_window_size:-0}
case "$ctx_max" in *[!0-9]*|'') ctx_max=0 ;; esac
ctx=''
if [ "$ctx_tokens" -gt 0 ]; then
    ctx=", ctx $(fmt_tokens "$ctx_tokens")"
    [ "$ctx_max" -gt 0 ] && ctx="$ctx/$(fmt_tokens "$ctx_max") ($(( (ctx_tokens * 100 + ctx_max / 2) / ctx_max ))%)"
fi

[ -n "$pc" ] && [ "$pc" != null ] || { echo "cache: no response yet$ctx"; exit 0; }
[ "$pc_caching_observed" = true ] || { echo "cache: off$ctx"; exit 0; }

ttl_s=3600; [ "$pc_ttl" = 5m ] && ttl_s=300
case "$pc_expires_at" in ''|null|*[!0-9]*) pc_expires_at='' ;; esac

state=''
if [ -n "$i_session_id" ]; then
    state="$CC_DIR/sessions/$(cc_safe_id "$i_session_id").json"
    if [ ! -f "$state" ]; then
        cc_set v 1; cc_set source '"claude-code"'; cc_set session_id "$(cc_jstr "$i_session_id")"; cc_set status '"idle"'
    fi
    if [ -n "$i_current_dir" ]; then
        cc_set cwd "$(cc_jstr "$i_current_dir")"
        cc_set project "$(cc_jstr "$(cc_basename "$i_current_dir")")"
    fi
    cc_set ttl_s "$ttl_s"
    cc_set expires_at "$(cc_jnum "$pc_expires_at")"
    cc_set warm "$(cc_jbool "$pc_warm")"
    cc_set caching_observed true
    cc_set misses "$(cc_jnum "$pc_misses")"
    cc_set basis '"statusline"'
    cc_set updated_at "$now"
    if [ "$ctx_tokens" -gt 0 ]; then
        cc_set context_tokens "$ctx_tokens"
        [ "$ctx_max" -gt 0 ] && cc_set context_max "$ctx_max"
    fi
    cc_write "$state" 2>/dev/null
fi

# Auto keep-alive status, when it's on: how many pings the budget still allows for this context.
auto=''
cc_load_config
if [ "$cfg_autoKeepAlive" = true ]; then
    n=-1
    if [ -n "$state" ] && [ -f "$state" ]; then
        eval "$(cc_fields "$(cat "$state")" s 'cache_read cache_write auto_spent')"
        c=$(( ${s_cache_read:-0} + ${s_cache_write:-0} )); [ "$c" -gt 0 ] || c=$ctx_tokens
        n=$(cc_auto_left "$c" 0 "${s_auto_spent:-0}" "$cfg_autoKeepAliveBudget")
    fi
    if [ "$n" -lt 0 ]; then auto=', auto keep-alive on'
    elif [ "$n" -eq 0 ]; then auto=', auto keep-alive: budget used'
    else auto=", auto keep-alive: $n left"; fi
fi

# Pair this with "refreshInterval" in the statusLine settings so the countdown keeps moving.
left=0
[ -n "$pc_expires_at" ] && left=$((pc_expires_at - now))
if [ "$pc_warm" = true ] && [ $left -gt 0 ]; then
    mins=$((left / 60))
    if [ $mins -ge 1 ]; then lt="${mins}m left"; else lt='<1m left'; fi
    echo "cache $lt, warm until $(cc_hm "$pc_expires_at") ($pc_ttl TTL)$ctx$auto"
else
    echo "cache cold ($pc_ttl TTL)$ctx"
fi
