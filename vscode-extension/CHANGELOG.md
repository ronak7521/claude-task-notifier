# Changelog

## 1.0.2 - 2026-11-23

### Changed
- The "Install it now?" prompt at start-up is a dialog in the middle of the window instead of a message that hid in
  the notification bell after a few seconds. Cancel asks again at the next start; running
  "Install or Repair Claude Code Plugin" undoes an earlier "Don't Ask Again".
- When Claude Code is not installed, the extension says so at start-up, lists where it looked in the
  "Task Notifier" output, and offers to open the Claude Code download page or the `taskNotifier.claudePath` setting.
- Failed steps now show what went wrong and how to fix it: no internet or proxy, Git missing, a GitHub rate limit,
  a locked file, a company policy, a timeout. Every error has a **Show Output** button.
- A failure to add the plugin catalog is reported instead of being skipped, and problems at start-up show a message
  instead of only being logged.

## 1.0.1 - 2026-11-20

### Fixed
- "Diagnose Missing Notifications" checks the settings saved in `~/.claude/settings.json` instead of warning
  that every saved setting needs a new session.
- "Update" reports a failed version check instead of saying the plugin is up to date.
- Reading the plugin list no longer breaks when Claude Code prints a notice before or after it.

## 1.0.0 - 2026-11-20

First version: installs, updates, tests, diagnoses and removes the Task Notifier plugin for Claude Code.
