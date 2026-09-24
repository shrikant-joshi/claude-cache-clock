# Cache Clock

A Claude Code plugin that shows how long your prompt cache stays warm, warns you before it expires, and can keep it alive.

Claude Code caches your conversation for 1 hour (5 minutes on an API key). Once the cache expires, the next message rebuilds it: slower, and it uses more of your plan. Cache Clock reads the cache receipts Claude Code records after every response and turns them into an exact countdown.

## Requirements

- Windows 10 or 11. Claude Code can run in WSL or natively on Windows (native needs Git for Windows).
- Anywhere else, the plugin installs but does nothing.

## Install

```
/plugin marketplace add shrikant-joshi/claude-cache-clock
/plugin install cache-clock@cache-clock
```

Restart Claude Code. A small always-on-top widget starts with your first session and shows one row per session.

To get updates automatically: `/plugin`, then Marketplaces, `cache-clock`, Enable auto-update.

## What you get

- **Countdown widget:** green, then amber under 15 min, red under 5 min. Hover a row for the expiry time, tokens read and written, and context size.
- **Alerts:** Windows notifications at 15, 10 and 5 minutes left (2 and 1 for 5-minute caches).
- **Keep-alive:** right-click a row and choose "Keep alive now", or type `/cache-clock:keepalive`. Claude answers `ok`, and the timer starts over.
- **Auto keep-alive (off by default):** turn it on from the right-click menu. It pings each session 60 seconds before expiry. Each ping re-reads the whole conversation, so it runs on a budget: 1M cached tokens per idle stretch, refilled when you send a message.
- **Status line (optional):** `cache 23m left, warm until 16:42 (1h TTL), ctx 182k/1M (18%)`. Clone this repo and run `sh install.sh --statusline` from WSL or Git Bash, or `Install-CacheClock.ps1 -StatusLine` from PowerShell. This also adds the widget to the Start menu and Startup.

The right-click menu also has: check for updates, close automatically when Claude isn't running, hide a session, and the version.

## Settings

Stored in `%USERPROFILE%\.cache-clock\config.json`. Restart the widget after editing it.

| Key | Default | Meaning |
|---|---|---|
| `thresholds` | `[15,10,5]` | Alert times in minutes, 1-hour caches |
| `shortThresholds` | `[2,1]` | Alert times in minutes, 5-minute caches |
| `autoKeepAlive` | `false` | Ping automatically before expiry |
| `autoKeepAliveAt` | `60` | Seconds before expiry to ping |
| `autoKeepAliveBudget` | `1000000` | Cached tokens auto pings may re-read per idle stretch |
| `autoExit` | `true` | Close the widget when Claude isn't running |

Set `CACHE_CLOCK_NO_AUTOSTART=1` in your shell to stop the plugin from starting the widget.

## Uninstall

```
/plugin uninstall cache-clock@cache-clock
```

If you ran the installer, also run `sh install.sh --uninstall` (or `Install-CacheClock.ps1 -Uninstall`).

## License

BSD 3-Clause. See [LICENSE](LICENSE).
