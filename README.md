# Cache Clock

A plugin for Claude Code and Codex that shows how long your prompt cache stays warm, what it would cost to lose it, and can keep it alive.

Both tools cache your conversation on the server for a while after each response: Claude Code for 1 hour (5 minutes on an API key), Codex for at least 30 minutes. Once the cache expires, the next message rebuilds it: slower, and it uses more of your plan. Cache Clock reads the cache receipts each tool records after every response and turns them into a countdown.

| | Claude Code | Codex |
|---|---|---|
| Where | CLI on macOS, Linux, Windows (native or WSL); desktop app Code tab | CLI on macOS, Linux, Windows (native or WSL); Codex in the ChatGPT desktop app |
| Cache lifetime | Exact, from Claude Code (1 hour or 5 minutes) | Assumed 30 minutes (OpenAI's minimum; 35 to 60 in tests) |
| Countdown | Status line, Windows widget, alerts | Windows widget, alerts (Codex has no custom status line) |
| Keep-alive | Quiet re-read of the cached conversation (needs Claude Code 2.1.287+), else a tiny turn | Quiet: a hidden fork of the session |
| Usage shown | Ping and rebuild cost at API prices | Codex plan usage |

## Install

**Claude Code:**

```
/plugin marketplace add shrikant-joshi/claude-cache-clock
/plugin install cache-clock@cache-clock
/cache-clock:setup
```

`/cache-clock:setup` adds the status line to your Claude Code settings. Restart Claude Code afterwards. For automatic updates: `/plugin`, then Marketplaces, `cache-clock`, Enable auto-update.

**Codex** (CLI and the ChatGPT desktop app; for the app, install with the Codex CLI on the same system, on Windows the Windows CLI, not one in WSL):

```
codex plugin marketplace add shrikant-joshi/claude-cache-clock
codex plugin add cache-clock@cache-clock
```

Codex runs plugin hooks only after you trust them: open `/hooks` in Codex and trust the five Cache Clock hooks (the desktop app asks when you open it). Codex asks again after updates that change them. To update: `codex plugin marketplace upgrade cache-clock`.

**Requirements:** `sh` and `awk`, which macOS and Linux already have. On native Windows, both tools run the hooks through Git for Windows (`sh` on the PATH). Cost figures use `curl` (or `wget`) once a day to fetch current prices; without either, the built-in price table is used.

## Countdown

### Windows widget

On Windows and WSL, the plugin starts a small always-on-top widget with one row per session, Claude Code and Codex alike: green, then amber under 15 min, red under 5 min. Hover a row for details. Click the row of a desktop app session (Claude app Code tab, or Codex in the ChatGPT app) to open that chat in its app. Right-click for keep-alive, auto keep-alive, check for updates, and more. It also has an estimated timer for the Claude desktop app's Chat and Cowork, which resets when you press Enter there.

In Claude Code, `/cache-clock:setup` can also add the widget to the Start menu and Startup.

### Alerts

Desktop notifications at 15, 10 and 5 minutes left (2 and 1 for 5-minute caches), and when the cache expires. macOS uses Notification Center; Linux uses `notify-send`; Windows uses the widget.

### Status line (Claude Code)

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

### Costs and usage

Claude Code costs are estimates at Anthropic API prices for the model you're using. A rebuild writes the whole conversation back into the cache (2x the input price for 1-hour caches, 1.25x for 5-minute ones). A keep-alive only reads it, at 0.1x the input price or less. So one rebuild costs as much as 20 to 80 keep-alives, depending on the model. On a Pro or Max subscription you don't pay per token: read the dollar figure as a measure of how much of your plan's usage a rebuild takes.

Prices come from [LiteLLM's public price list](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json), fetched at most once a day when a session starts. The plugin ships a built-in table for when that fails. Models without a known price show tokens only. Set `showCost` to `false` to hide costs and stop the daily fetch.

For Codex, the widget shows your plan usage and when it resets instead of dollar costs.

## Keep-alive

A keep-alive ping re-reads the cached conversation, which resets the cache timer for a fraction of what a rebuild costs.

- **Manual:** right-click a row in the widget and choose Keep alive. In Claude Code you can also type `/cache-clock:keepalive`.
- **Auto keep-alive (off by default):** pings each idle session shortly before expiry: 60 seconds before in Claude Code, 5 minutes before in Codex. Each ping re-reads the whole conversation, so it runs on a budget: 1M cached tokens per idle stretch, refilled when you send a message. Turn it on from the widget menu, with `/cache-clock:auto-keepalive on` in Claude Code, or by asking Codex to turn on Cache Clock auto keep-alive.

How a ping works:

- **Claude Code 2.1.287 and later:** the plugin's [mod](https://code.claude.com/docs/en/plugins/mods/overview) re-reads the cached conversation in the background, so nothing is added to your conversation and Claude doesn't wake up. This works in a terminal and in local sessions of the desktop app's Code tab. If the mod isn't running, or a quiet ping fails, the plugin falls back to a tiny turn: Claude answers `ok`. The mod also shows a band above the prompt in the last 15 minutes (2 on a 5-minute cache), with a live countdown and a **Keep warm** button. Set `band` to `false` to hide it.
- **Codex:** the plugin runs a hidden fork of the session (`codex exec --ephemeral fork`). It reads the cached conversation, adds nothing to it, and uses a little of your plan: the conversation plus about 20k tokens. If a fork fails, you get an alert and auto keep-alive tries again a minute later.

## Settings

Stored in `config.json` in the data folder, shared by Claude Code and Codex: `~/.cache-clock` on macOS and Linux, `%USERPROFILE%\.cache-clock` on Windows and WSL.

| Key | Default | Meaning |
|---|---|---|
| `autoKeepAlive` | `false` | Ping automatically before expiry |
| `autoKeepAliveAt` | `60` | Seconds before expiry to ping (Codex uses at least 300) |
| `autoKeepAliveBudget` | `1000000` | Cached tokens auto pings may re-read per idle stretch |
| `thresholds` | `[15,10,5]` | Alert times in minutes, 30-minute and longer caches |
| `shortThresholds` | `[2,1]` | Alert times in minutes, 5-minute caches |
| `ctxThresholds` | `[25,40,60]` | Context colour bands, in percent of the context window |
| `color` | `true` | Colours in the status line (also off when `NO_COLOR` is set) |
| `showCost` | `true` | Show costs in the status line, and fetch current prices daily |
| `autoExit` | `true` | Windows widget: close when no Claude Code or Codex session is running |
| `band` | `true` | Claude Code mod: show the countdown band above the prompt near expiry |

`/cache-clock:auto-keepalive` with no argument (or asking Codex for the Cache Clock settings) shows the current values. Set `CACHE_CLOCK_NO_AUTOSTART=1` to stop the plugin from starting the Windows widget.

## Uninstall

**Claude Code:** `/plugin uninstall cache-clock@cache-clock`, then remove the `statusLine` entry from `~/.claude/settings.json`.

**Codex:**

```
codex plugin remove cache-clock@cache-clock
codex plugin marketplace remove cache-clock
```

If you added the Windows widget to Startup, first run `install.ps1 -Uninstall` from the plugin's `addons/windows` folder.

## Not tested yet

macOS (Claude Code, Codex CLI and the Codex desktop app) and Claude Code on native Windows outside WSL have not been tested on real machines yet.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
