---
name: auto-keepalive
description: Turn Cache Clock's automatic keep-alive on or off, or show its settings. Only run when the user types /cache-clock:auto-keepalive.
disable-model-invocation: true
argument-hint: on|off
---

The user's argument: `$ARGUMENTS`

- `on`: run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/cc.sh" config autoKeepAlive true`
- `off`: run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/cc.sh" config autoKeepAlive false`
- anything else or empty: run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/cc.sh" config` and show the settings.

Then reply in one or two lines. When on, auto keep-alive pings each session 60 seconds before its cache expires, within a budget of cached tokens re-read per idle stretch (`autoKeepAliveBudget`, default 1,000,000), refilled by each real message. Do not call any other tools.
