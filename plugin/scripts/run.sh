#!/bin/sh
# Cache Clock hook launcher.
# Runs a bundled PowerShell script with Windows PowerShell, from either:
#   - Claude Code in WSL (converts paths with wslpath), or
#   - Claude Code on native Windows via Git Bash (converts paths with cygpath).
# Anywhere else (macOS, plain Linux, cloud sandboxes) it does nothing and exits 0.
# Usage: sh run.sh <script.ps1> [args...]    (the hook JSON arrives on stdin)

name="$1"
[ -n "$name" ] || exit 0
shift

root="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$root" ]; then root="$(cd "$(dirname "$0")/.." && pwd)"; fi

skip() { cat >/dev/null 2>&1; exit 0; }

case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
        command -v cygpath >/dev/null 2>&1 || skip
        ps1="$(cygpath -w "$root/scripts/$name")"
        ;;
    Linux)
        if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then
            command -v wslpath >/dev/null 2>&1 || skip
            ps1="$(wslpath -w "$root/scripts/$name")"
            # Pass these through to the Windows side. /p converts a path value.
            export CACHE_CLOCK_WSL_DISTRO="${WSL_DISTRO_NAME:-}"
            export WSLENV="${WSLENV:+$WSLENV:}CACHE_CLOCK_WSL_DISTRO:CLAUDE_CODE_PROMPT_CACHE_TTL:FORCE_PROMPT_CACHING_5M:CACHE_CLOCK_NO_AUTOSTART:CACHE_CLOCK_DIR/p"
        else
            skip
        fi
        ;;
    *)
        skip
        ;;
esac

command -v powershell.exe >/dev/null 2>&1 || skip
exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps1" "$@"
