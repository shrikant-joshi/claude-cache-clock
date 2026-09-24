# Cache Clock

A Claude Code plugin that shows how long your prompt cache stays warm, warns you before it expires, and can keep it alive. Works with the Claude Code CLI on macOS, Linux and Windows (native or WSL).

Claude Code caches your conversation for 1 hour (5 minutes on an API key). Once the cache expires, the next message rebuilds it: slower, and it uses more of your plan. Cache Clock reads the cache receipts Claude Code records after every response and turns them into an exact countdown.

## Install

```
/plugin marketplace add shrikant-joshi/claude-cache-clock
/plugin install cache-clock@cache-clock
/cache-clock:setup
```

`/cache-clock:setup` adds the status line to your Claude Code settings. Restart Claude Code afterwards.

To get updates automatically: `/plugin`, then Marketplaces, `cache-clock`, Enable auto-update.

Requirements: `sh` and `awk`, which every supported system already has. On native Windows, Claude Code runs hooks through Git for Windows.

## What you get

- **Status line:** `cache 23m left, warm until 16:42 (1h TTL), ctx 182k/1M (18%)`. If you already have a status line, `/cache-clock:setup` shows how to add this as a segment instead of replacing yours.
- **Keep-alive:** type `/cache-clock:keepalive`. Claude answers `ok`, and the timer starts over.
- **Auto keep-alive (off by default):** `/cache-clock:auto-keepalive on`. It pings each session 60 seconds before expiry. Each ping re-reads the whole conversation, so it runs on a budget: 1M cached tokens per idle stretch, refilled when you send a message. The status line shows how many pings are left.
- **Alerts:** desktop notifications at 15, 10 and 5 minutes left (2 and 1 for 5-minute caches), and when the cache expires. macOS uses Notification Center; Linux uses `notify-send`; Windows uses the widget.

## Windows widget add-on

On Windows and WSL, the plugin also starts a small always-on-top widget with one row per session: green, then amber under 15 min, red under 5 min. Hover a row for details. Right-click for keep-alive, auto keep-alive, check for updates, and more. It also has an estimated timer for the Claude desktop app (Chat and Cowork), which resets when you press Enter there.

`/cache-clock:setup` can also add the widget to the Start menu and Startup.

## Settings

Stored in `config.json` in the data folder: `~/.cache-clock` on macOS and Linux, `%USERPROFILE%\.cache-clock` on Windows and WSL.

| Key | Default | Meaning |
|---|---|---|
| `autoKeepAlive` | `false` | Ping automatically before expiry |
| `autoKeepAliveAt` | `60` | Seconds before expiry to ping |
| `autoKeepAliveBudget` | `1000000` | Cached tokens auto pings may re-read per idle stretch |
| `thresholds` | `[15,10,5]` | Alert times in minutes, 1-hour caches |
| `shortThresholds` | `[2,1]` | Alert times in minutes, 5-minute caches |
| `autoExit` | `true` | Windows widget: close when Claude isn't running |

`/cache-clock:auto-keepalive` with no argument shows the current values. Set `CACHE_CLOCK_NO_AUTOSTART=1` to stop the plugin from starting the Windows widget.

## Uninstall

```
/plugin uninstall cache-clock@cache-clock
```

Also remove the `statusLine` entry from `~/.claude/settings.json`. If you added the Windows widget to Startup, first run `install.ps1 -Uninstall` from the plugin's `addons/windows` folder.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
