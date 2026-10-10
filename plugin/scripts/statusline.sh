#!/bin/sh
# Cache Clock: Claude Code status line. POSIX sh + awk.
# Claude Code passes a prompt_cache object computed from the server's usage receipts, including the
# exact expires_at, plus the context window and the model. This prints, with colours,
#   cache 23m left, until 16:42 (1h) | ctx 182k/1M 18% | auto on (7) | ping ~$0.05, rebuild ~$1.46
#   cache cold (1h) | rebuild ~182k tok, ~$1.46 | ctx 182k/1M 18% | auto off
# and hands the exact expiry to the session file for the widget and the keep-alive listener.
# Use it as your statusLine command (/cache-clock:setup), or call it from your own status line
# script with the same JSON on stdin to add it as a segment.

CC_HERE=$(cd "$(dirname "$0")" && pwd)
. "$CC_HERE/lib.sh"

input=$(cat)
[ -n "$input" ] || { echo 'cache: ?'; exit 0; }
now=$(cc_now)

fmt_tokens() { awk -v n="$1" 'BEGIN { if (n >= 1000000) { s = sprintf("%.1f", n / 1000000); sub(/\.0$/, "", s); print s "M" } else printf "%.0fk\n", n / 1000 }'; }

# $ amounts: cents under $100, whole dollars above.
fmt_usd() { awk -v n="$1" 'BEGIN { if (n < 0.01) print "<$0.01"; else if (n < 100) printf "$%.2f\n", n; else printf "$%.0f\n", n }'; }

cc_load_config
if [ "$cfg_color" = false ] || [ -n "${NO_COLOR:-}" ]; then
    GREEN=''; YELLOW=''; ORANGE=''; RED=''; GREY=''; RST=''
else
    e=$(printf '\033')
    GREEN="$e[32m"; YELLOW="$e[33m"; ORANGE="$e[38;5;208m"; RED="$e[31m"; GREY="$e[90m"; RST="$e[0m"
fi
paint() { printf '%s%s%s' "$1" "$2" "$RST"; }   # colour text

eval "$(cc_fields "$input" i 'session_id current_dir')"
pc=$(cc_raw "$input" prompt_cache)
cw=$(cc_raw "$input" context_window)
eval "$(cc_fields "$pc" pc 'caching_observed warm ttl expires_at misses recache_tokens_if_cold')"
eval "$(cc_fields "$(cc_raw "$input" model)" mdl 'id')"
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
# Context colour by share of the window: 25/40/60% (250k/400k/600k on a 1M window) by default.
ctx=''
if [ "$ctx_tokens" -gt 0 ]; then
    win=$ctx_max; [ "$win" -gt 0 ] || win=1000000
    pct=$(( (ctx_tokens * 100 + win / 2) / win ))
    set -- $cfg_ctxThresholds
    col=$GREEN
    [ $((ctx_tokens * 100)) -ge $(( ${1:-25} * win )) ] && col=$YELLOW
    [ $((ctx_tokens * 100)) -ge $(( ${2:-40} * win )) ] && col=$ORANGE
    [ $((ctx_tokens * 100)) -ge $(( ${3:-60} * win )) ] && col=$RED
    t="ctx $(fmt_tokens "$ctx_tokens")"
    [ "$ctx_max" -gt 0 ] && t="$t/$(fmt_tokens "$ctx_max") $pct%"
    ctx=" | $(paint "$col" "$t")"
fi

[ -n "$pc" ] && [ "$pc" != null ] || { echo "cache: no response yet$ctx"; exit 0; }
[ "$pc_caching_observed" = true ] || { echo "cache: off$ctx"; exit 0; }

ttl_s=3600; [ "$pc_ttl" = 5m ] && ttl_s=300
case "$pc_expires_at" in ''|null|*[!0-9]*) pc_expires_at='' ;; esac

state=''
[ -n "$i_session_id" ] && state="$CC_DIR/sessions/$(cc_safe_id "$i_session_id").json"
# A fork ping from the mod (hooks/mod.tsx) reads the cache outside Claude Code's own requests, so
# prompt_cache may not count it. Take the later expiry.
if [ -n "$state" ] && [ -f "$state" ]; then
    eval "$(cc_fields "$(cat "$state")" st 'fork_expires_at')"
    case "$st_fork_expires_at" in ''|null|*[!0-9]*) ;; *)
        if [ "$st_fork_expires_at" -gt "${pc_expires_at:-0}" ] && [ "$st_fork_expires_at" -gt "$now" ]; then
            pc_expires_at=$st_fork_expires_at; pc_warm=true
        fi ;;
    esac
fi

# What a keep-alive ping (cache read) and a rebuild (cache write at this TTL) cost at API prices.
# Claude Code reports the exact rebuild size; fall back to the context size.
rb=${pc_recache_tokens_if_cold:-}
case "$rb" in ''|*[!0-9]*) rb=0 ;; esac
[ "$rb" -gt 0 ] || rb=$ctx_tokens
ping_usd=''; rebuild_usd=''; ping_n=null; rebuild_n=null
if [ "$cfg_showCost" != false ] && [ "$rb" -gt 0 ] && [ -n "$mdl_id" ]; then
    pr=$(cc_price "$mdl_id")
    if [ -n "$pr" ]; then
        set -- $(awk -v t="$rb" -v ttl="$pc_ttl" -v p="$pr" 'BEGIN {
            split(p, a, " "); in_ = a[1]; w = (ttl == "5m") ? a[2] : a[3]; r = a[4]
            if (w == "-" || w == "") w = in_ * (ttl == "5m" ? 1.25 : 2)
            if (r == "-" || r == "") r = in_ * 0.1
            printf "%.6f %.6f\n", t * r / 1000000, t * w / 1000000 }')
        ping_n=$1; rebuild_n=$2
        ping_usd=$(fmt_usd "$1"); rebuild_usd=$(fmt_usd "$2")
    fi
fi

if [ -n "$state" ]; then
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
    cc_set model "$(cc_jstr "$mdl_id")"
    cc_set rebuild_tokens "$rb"
    cc_set ping_usd "$ping_n"
    cc_set rebuild_usd "$rebuild_n"
    cc_set updated_at "$now"
    if [ "$ctx_tokens" -gt 0 ]; then
        cc_set context_tokens "$ctx_tokens"
        [ "$ctx_max" -gt 0 ] && cc_set context_max "$ctx_max"
    fi
    cc_write "$state" 2>/dev/null
fi

# Auto keep-alive: on (pings the budget still allows for this context) or off.
if [ "$cfg_autoKeepAlive" = true ]; then
    n=-1
    if [ -n "$state" ] && [ -f "$state" ]; then
        eval "$(cc_fields "$(cat "$state")" s 'cache_read cache_write auto_spent')"
        c=$(( ${s_cache_read:-0} + ${s_cache_write:-0} )); [ "$c" -gt 0 ] || c=$ctx_tokens
        n=$(cc_auto_left "$c" 0 "${s_auto_spent:-0}" "$cfg_autoKeepAliveBudget")
    fi
    if [ "$n" -lt 0 ]; then auto=" | $(paint "$GREEN" 'auto on')"
    elif [ "$n" -eq 0 ]; then auto=" | $(paint "$YELLOW" 'auto on (0)')"
    else auto=" | $(paint "$GREEN" "auto on ($n)")"; fi
else
    auto=" | $(paint "$GREY" 'auto off')"
fi

# Requests that re-processed what the cache already held (not counting compaction or clearing).
misses=''
case "$pc_misses" in ''|*[!0-9]*|0) ;; 1) misses=" | $(paint "$YELLOW" '1 miss')" ;; *) misses=" | $(paint "$YELLOW" "$pc_misses misses")" ;; esac

# Pair this with "refreshInterval" in the statusLine settings so the countdown keeps moving.
# Countdown colour, like the widget: yellow under 15 min (2 on a 5m cache), red under 5 (1).
left=0
[ -n "$pc_expires_at" ] && left=$((pc_expires_at - now))
if [ "$pc_warm" = true ] && [ $left -gt 0 ]; then
    mins=$((left / 60))
    if [ $mins -ge 1 ]; then lt="${mins}m left"; else lt='<1m left'; fi
    if [ "$ttl_s" -le 300 ]; then warn=120; crit=60; else warn=900; crit=300; fi
    col=$GREEN; [ $left -lt $warn ] && col=$YELLOW; [ $left -lt $crit ] && col=$RED
    cost=''; [ -n "$rebuild_usd" ] && cost=" | ping ~$ping_usd, rebuild ~$rebuild_usd"
    echo "$(paint "$col" "cache $lt"), until $(cc_hm "$pc_expires_at") ($pc_ttl)$ctx$auto$cost$misses"
else
    cost=''
    if [ "$rb" -gt 0 ]; then
        cost=" | rebuild ~$(fmt_tokens "$rb") tok"
        [ -n "$rebuild_usd" ] && cost="$cost, ~$rebuild_usd"
    fi
    echo "$(paint "$GREY" "cache cold") ($pc_ttl)$cost$ctx$auto$misses"
fi
