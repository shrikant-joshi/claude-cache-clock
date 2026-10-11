---
name: auto-keepalive
description: Turn Cache Clock's automatic keep-alive on or off, or show its settings. Use only when the user asks for Cache Clock auto keep-alive by name.
---

The plugin's scripts are two folders up from this file: `<this SKILL.md's folder>/../../scripts/cc.sh`. Use that absolute path below.

- The user wants it on: run `sh <path to cc.sh> config autoKeepAlive true`
- The user wants it off: run `sh <path to cc.sh> config autoKeepAlive false`
- Otherwise: run `sh <path to cc.sh> config` and show the settings.

The command writes to Cache Clock's data folder, outside the workspace, so it may need the user's approval. Run nothing else.

Then reply in one or two lines. When on, auto keep-alive sends a hidden fork of each idle Codex session 5 minutes before its cache is estimated to expire (30 min after the last response), and retries once a minute if one fails. The fork adds nothing to the conversation and uses a little of the plan. It works within a budget of tokens per idle stretch (`autoKeepAliveBudget`, default 1,000,000), refilled by each real message. The same setting covers Claude Code.
