# Cache Clock

A Claude Code plugin that shows how long your prompt cache stays warm, what it would cost to lose it, and can keep it alive. Works with the Claude Code CLI on macOS, Linux and Windows (native or WSL).

Claude Code caches your conversation for 1 hour (5 minutes on an API key). Once the cache expires, the next message rebuilds it: slower, and it uses more of your plan. Cache Clock reads the cache receipts Claude Code records after every response and turns them into an exact countdown.

## Install

```
/plugin marketplace add shrikant-joshi/claude-cache-clock
/plugin install cache-clock@cache-clock
/cache-clock:setup
```

`/cache-clock:setup` adds the status line to your Claude Code settings. Restart Claude Code afterwards.

To get updates automatically: `/plugin`, then Marketplaces, `cache-clock`, Enable auto-update.

Requirements: `sh` and `awk`, which every supported system already has. On native Windows, Claude Code runs hooks through Git for Windows. Costs use `curl` (or `wget`) once a day to fetch current prices; without either, the built-in price table is used.

## The status line

```
cache 23m left, until 16:42 (1h) | ctx 182k/1M 18% | auto on (7) | ping ~$0.04, rebuild ~$1.46
cache cold (1h) | rebuild ~182k tok, ~$1.46 | ctx 182k/1M 18% | auto off | 2 misses
```

| Segment | Meaning | Colours |
|---|---|---|
| `cache 23m left, until 16:42 (1h)` | Time until the cache expires, and the cache lifetime (TTL) | Green, yellow under 15 min, red under 5 min (2 and 1 min for 5-minute caches) |
| `cache cold (1h)` | The cache has expired; your next message rebuilds it | Grey |
| `ctx 182k/1M 18%` | Context size and share of the context window | Green, yellow from 25%, orange from 40%, red from 60% (250k, 400k, 600k on a 1M window) |
| `auto on (7)` / `auto off` | Auto keep-alive, and how many pings its budget still allows | Green; yellow at `(0)`; grey when off |
| `ping ~$0.04, rebuild ~$1.46` | What one keep-alive costs, and what rebuilding the cache would cost | |
| `rebuild ~182k tok, ~$1.46` | On a cold cache: tokens and cost your next message pays to rebuild it | |
| `2 misses` | Requests this session that re-processed content the cache already held | Yellow |

If you already have a status line, `/cache-clock:setup` shows how to add this as a segment instead of replacing yours.

### Costs

Costs are estimates at Anthropic API prices for the model you're using. A rebuild writes the whole conversation back into the cache (2x the input price for 1-hour caches, 1.25x for 5-minute ones). A keep-alive only reads it, at 0.1x the input price or less. So one rebuild costs as much as 20 to 80 keep-alives, depending on the model.

On a Pro or Max subscription you don't pay per token: read the dollar figure as a measure of how much of your plan's usage a rebuild takes.

Prices come from [LiteLLM's public price list](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json), fetched at most once a day when a session starts. The plugin ships a built-in table for when that fails. Models without a known price show tokens only. Set `showCost` to `false` to hide costs and stop the daily fetch.

## Keep-alive and alerts

- **Keep-alive:** type `/cache-clock:keepalive`. Claude answers `ok`, and the timer starts over.
- **Auto keep-alive (off by default):** `/cache-clock:auto-keepalive on`. It pings each session 60 seconds before expiry. Each ping re-reads the whole conversation, so it runs on a budget: 1M cached tokens per idle stretch, refilled when you send a message. The status line shows how many pings are left.
- **Alerts:** desktop notifications at 15, 10 and 5 minutes left (2 and 1 for 5-minute caches), and when the cache expires. macOS uses Notification Center; Linux uses `notify-send`; Windows uses the widget.

### Quiet keep-alive (Claude Code 2.1.287 and later)

The plugin includes a [mod](https://code.claude.com/docs/en/plugins/mods/overview). Where mods run (Claude Code in a terminal, and local sessions in the desktop app's Code tab), keep-alive pings from the widget and auto keep-alive become quiet: the mod re-reads the cached conversation in the background, so nothing is added to your conversation and Claude doesn't wake up. If the mod isn't running, or a quiet ping fails, the plugin falls back to waking Claude.

The mod also shows a band above the prompt in the last 15 minutes (2 on a 5-minute cache), with a live countdown and a **Keep warm** button. Set `band` to `false` to hide it.

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
| `ctxThresholds` | `[25,40,60]` | Context colour bands, in percent of the context window |
| `color` | `true` | Colours in the status line (also off when `NO_COLOR` is set) |
| `showCost` | `true` | Show costs in the status line, and fetch current prices daily |
| `autoExit` | `true` | Windows widget: close when Claude isn't running |
| `band` | `true` | Mod: show the countdown band above the prompt near expiry |

`/cache-clock:auto-keepalive` with no argument shows the current values. Set `CACHE_CLOCK_NO_AUTOSTART=1` to stop the plugin from starting the Windows widget.

## Uninstall

```
/plugin uninstall cache-clock@cache-clock
```

Also remove the `statusLine` entry from `~/.claude/settings.json`. If you added the Windows widget to Startup, first run `install.ps1 -Uninstall` from the plugin's `addons/windows` folder.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
