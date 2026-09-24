---
name: setup
description: Set up Cache Clock's status line in Claude Code settings, and on Windows optionally install the widget add-on. Only run when the user types /cache-clock:setup.
disable-model-invocation: true
---

Set up Cache Clock for the user. Keep it short.

1. Run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/cc.sh" setup-info`. It prints `platform`, `settings_file`, `statusline_command` and `widget_install`.
2. Status line: read `settings_file` (it may not exist yet).
   - If it has no `statusLine`, or the existing `statusLine.command` mentions `CacheClock` or `cache-clock` (an older Cache Clock line), set `statusLine` to `{"type": "command", "command": "<statusline_command>", "refreshInterval": 30}`. Keep every other setting unchanged.
   - Otherwise the user has their own status line. Don't replace it. Show them `statusline_command` and explain they can call it from their script with the same JSON on stdin to append the cache segment, or ask if they want it replaced.
3. If `widget_install` is a command (Windows or WSL), ask whether to add the widget to the Start menu and Startup. The plugin starts the widget with each session either way; installing only adds the shortcuts and a stable copy. If yes, run the command.
4. Reply in two or three lines: what changed, and that the status line appears on its next refresh.
