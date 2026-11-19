---
name: test
description: Send a Task Notifier test notification to check that Windows shows Claude Code notifications.
disable-model-invocation: true
---

# Task Notifier test notification

1. Run this launcher with your shell tool. It checks the Windows notification settings and sends one test notification.
   - Bash: `"${CLAUDE_PLUGIN_ROOT}/scripts/doctor.cmd" test`
   - PowerShell: `& "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.cmd" test`
2. Report any `[FAIL]` or `[WARN]` line with the fix on the `->` line under it.
3. Ask whether "Task Notifier test" appeared on screen or in the notification center (Win+N).
   If it did not, suggest `/task-notifier:doctor` for the full check.

Do not change settings, files or the registry yourself.
