#!/bin/sh
# Cache Clock installer for POSIX shells on Windows: WSL or Git Bash.
#   Install:                 sh install.sh
#   Also add status line:    sh install.sh --statusline
#   Uninstall:               sh install.sh --uninstall
# Installs the Windows widget (via Install-CacheClock.ps1), then prints the Claude Code steps.

set -e
here="$(cd "$(dirname "$0")" && pwd)"
statusline=0
uninstall=0
for a in "$@"; do
    case "$a" in
        --statusline) statusline=1 ;;
        --uninstall) uninstall=1 ;;
        *) echo "Unknown option: $a"; exit 1 ;;
    esac
done

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) env=gitbash; winpath() { cygpath -w "$1"; } ;;
    Linux)
        if ! command -v wslpath >/dev/null 2>&1; then echo "Cache Clock needs Windows (WSL or Git Bash)."; exit 1; fi
        env=wsl; winpath() { wslpath -w "$1"; } ;;
    *) echo "Cache Clock needs Windows (WSL or Git Bash)."; exit 1 ;;
esac
command -v powershell.exe >/dev/null 2>&1 || { echo "powershell.exe not found. In WSL, check that Windows interop is on."; exit 1; }

ps() { powershell.exe -NoProfile -ExecutionPolicy Bypass "$@"; }
installer="$(winpath "$here/Install-CacheClock.ps1")"

if [ "$uninstall" = 1 ]; then
    ps -File "$installer" -Uninstall
    echo "If you added the status line, remove the \"statusLine\" entry from ~/.claude/settings.json."
    exit 0
fi

# In Git Bash, ~/.claude is the Windows one, so the PowerShell installer can add the status line itself.
if [ "$env" = gitbash ] && [ "$statusline" = 1 ]; then
    ps -File "$installer" -StatusLine -NoPluginHint
else
    ps -File "$installer" -NoPluginHint
fi

# In WSL, Claude Code reads ~/.claude/settings.json inside Linux. Add the status line there.
if [ "$env" = wsl ] && [ "$statusline" = 1 ]; then
    lad="$(ps -Command '[Environment]::GetFolderPath("LocalApplicationData")' | tr -d '\r')"
    sl="$(printf '%s' "$lad/CacheClock/statusline.ps1" | tr '\\' '/')"
    cmd="powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"$sl\""
    settings="$HOME/.claude/settings.json"
    if command -v python3 >/dev/null 2>&1; then
        CC_SETTINGS="$settings" CC_CMD="$cmd" python3 - <<'PY'
import json, os, shutil
p, cmd = os.environ["CC_SETTINGS"], os.environ["CC_CMD"]
os.makedirs(os.path.dirname(p), exist_ok=True)
data = {}
if os.path.exists(p):
    with open(p) as f:
        data = json.load(f)
if "statusLine" in data:
    print("You already have a status line, so I left it alone. To use this one, set:")
    print(json.dumps({"statusLine": {"type": "command", "command": cmd}}, indent=2))
else:
    if os.path.exists(p):
        shutil.copy(p, p + ".bak")
    data["statusLine"] = {"type": "command", "command": cmd}
    with open(p, "w") as f:
        json.dump(data, f, indent=2)
    print("Status line added to " + p + " (backup: settings.json.bak if it existed).")
PY
    else
        echo "python3 not found. Add this to $settings yourself:"
        echo "  \"statusLine\": { \"type\": \"command\", \"command\": \"$(printf '%s' "$cmd" | sed 's/"/\\"/g')\" }"
    fi
fi

echo ""
echo "Next, in Claude Code:"
echo "  /plugin marketplace add $here"
echo "  /plugin install cache-clock@cache-clock"
