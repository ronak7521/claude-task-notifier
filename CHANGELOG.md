# Changelog

All notable changes to the Task Notifier plugin. Versions follow [Semantic Versioning](https://semver.org/);
the version is in [`plugin.json`](plugins/task-notifier/.claude-plugin/plugin.json) and each release is tagged `vX.Y.Z`.

## 1.5.0 - 2026-11-19

### Added
- `/task-notifier:test` sends a test notification and checks the Windows notification settings.
- `/task-notifier:doctor` explains why notifications do not appear (install, hooks, Windows and company settings,
  your own settings, debug log) and sends a test notification. Claude can also run it when you report missing notifications.
- Company PCs: when a security policy runs PowerShell in restricted (ConstrainedLanguage) mode, or PowerShell cannot
  run the script at all (including a crash or a kill by a security policy), the reason is recorded for the doctor
  instead of failing silently.
- Tests run automatically on GitHub (Windows PowerShell 5.1) for every pull request and every push to `main`.
- This changelog, and release tags for every version.

### Changed
- Claude no longer waits about 2 seconds at the end of every turn: the `Stop` and `StopFailure` hooks run in the
  background like the others. Scripted `claude -p` runs no longer notify. When a queued prompt starts the next
  turn at once, there is no "finished" toast, and the next turn's waiting toast keeps its details.
- The doctor also works outside a Claude Code session (for example from the VS Code extension): it then checks the
  settings saved in `~/.claude/settings.json`.
- One README: the repository README is the full guide; the plugin folder's README links to it.
- `.gitattributes` keeps `.cmd` files in CRLF line endings for everyone, so the launcher works whatever
  the user's git settings are.

### Security
- The launcher starts PowerShell by its full Windows path. Before, a `powershell.exe` in the project folder (for
  example in a cloned repository) would have run whenever Windows' current-folder lookup was on.

## 1.4.1 - 2026-11-19

### Fixed
- Quiet-while-watching in VS Code: the project name must be a whole part of the window title, so a
  project `api` no longer stays quiet while a `shop-api` window is in front. Handles the unsaved-changes dot,
  `[WSL: ...]`, `[SSH: ...]`, `(Workspace)`, profile names, `[Administrator]`, Cursor and em-dash titles.

### Changed
- Toast titles no longer repeat the project name ("Claude finished" instead of "Claude finished - shop-api");
  the project is in the toast header. The tray balloon fallback keeps it in the title.

## 1.4.0 - 2026-11-19

### Added
- Quiet while you watch: no toast while the window running Claude is in front and you used the keyboard or
  mouse in the last 2 minutes. `TASK_NOTIFIER_WHEN_FOCUSED=1` turns this off.
- Click a toast to open the project in VS Code, VS Code Insiders, Cursor or Windsurf.
- `TASK_NOTIFIER_EVENTS` turns notification types on or off individually.
- `TASK_NOTIFIER_DEBUG=1` logs every decision (titles and reasons only) to `%TEMP%\claude-task-notifier\debug.log`.
- Feature and security test suites (`tests\run-tests.cmd`).

### Fixed
- The paused toast never appeared with exactly one background task running.
- The focus-check helper DLL is cached in `%LOCALAPPDATA%` instead of `%TEMP%`, which may be shared with other users.
- Privacy mode no longer shows Claude's raw permission message.
- An invalid `VSCODE_PID` no longer drops the notification; click links escape every folder name.
- Newlines in a message can no longer forge debug log lines.
- A turned-off `permission` type no longer leaves a waiting marker.

## 1.3.0 - 2026-11-18

### Added
- Modern Windows toasts instead of tray balloons: kept in the notification center (Win+N), shown under their
  own **Task Notifier** name and icon, grouped per project, with a different sound per type. The app is
  registered in the user registry (HKCU), no admin rights needed.
- Toasts that stay on screen when Claude waits for you: a permission dialog, a question (AskUserQuestion) or
  an MCP input form left unanswered for about 6 seconds. They are removed once that tool call is answered.
- "Claude is asking" when a reply ends with a question.

### Fixed
- Long tasks never notified on large sessions: the transcript is no longer read (it blew the 10 s hook timeout).
- Hooks run without Git Bash installed (exec form).
- Correct install command in the README.
- Markdown cleanup no longer mangles `C#`, `#123` or `->`.
- Permission toasts show URLs, search patterns, MCP tool names and the Bash command description.

## 1.2.0 - 2026-11-18

First published version: Windows tray notifications when Claude finishes (with your prompt and the start of
the reply), pauses with background tasks running, needs permission, or stops with an error.
Settings `TASK_NOTIFIER_MIN_SECONDS` and `TASK_NOTIFIER_PRIVACY`.
