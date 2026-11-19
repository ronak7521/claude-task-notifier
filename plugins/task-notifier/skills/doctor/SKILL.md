---
name: doctor
description: Diagnose why Task Notifier's Windows notifications do not appear (not installed, hooks not loaded, Windows or company settings, quiet by design) and send a test notification. Use when the user says Claude Code notifications, toasts or Task Notifier alerts are missing or not working.
---

# Task Notifier doctor

Run the doctor and explain what it finds.

1. Run this launcher with your shell tool. It prints a report and sends one test notification. It changes no settings.
   - Bash: `"${CLAUDE_PLUGIN_ROOT}/scripts/doctor.cmd"`
   - PowerShell: `& "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.cmd"`
2. Each report line starts with `[OK]`, `[INFO]`, `[WARN]` or `[FAIL]`; a line starting with `->` under it says what to do.
   Tell the user, in this order:
   - every `[FAIL]` with its fix (these stop notifications),
   - every `[WARN]` with its fix (these can explain missing notifications),
   - the `[INFO]` lines that explain quiet-by-design behaviour, if the user is missing a notification that one of them explains
     (quick answers, quiet while they look at Claude, turned-off types).
   Skip the `[OK]` lines unless everything is OK, then say so in one sentence.
3. Ask whether the test notification appeared on screen or in the notification center (Win+N).
4. If the launcher could not start PowerShell at all, explain that a company policy probably blocks PowerShell scripts and
   that IT would need to allow scripts in `%USERPROFILE%\.claude\plugins`.

Do not change settings, files or the registry yourself. Suggest the change and let the user decide.
