# Task Notifier for Claude Code

This repository is a Claude Code plugin marketplace. The plugin lives in [`plugins/task-notifier`](plugins/task-notifier).

Windows notifications from Claude Code, so you can work in another window instead of watching the chat.
**Windows only, Claude Code only** (terminal and the VS Code extension; hooks do not run in claude.ai chat or Cowork).

- **Finished**: project name, your prompt and the start of Claude's reply.
  Quick answers (under 30 seconds) stay silent.
- **Asking**: Claude ended its reply with a question; the toast shows the question.
- **Paused**: Claude's turn ended but background tasks are still running; the toast names them.
- **Error**: the turn ended with an error, such as a rate limit, with the error details.

Claude waits as long as it takes when it needs you, so these stay **on screen until you click or dismiss them**:

- **Needs permission**: the command, file or URL to approve, plus Claude's description of a command.
- **Has a question**: the question and its answer options.
- **Needs your input**: an MCP server's input form or sign-in link.

They only appear when the request has waited about 6 seconds, so you are not interrupted while you are
watching, and they disappear by themselves once you answer in Claude Code.

Notifications are modern Windows toasts:

- They stay in the notification center (press **Win+N**) until you clear them. Windows removes unread ones after 3 days.
- They appear under their own app name, **Task Notifier**, with the plugin icon, grouped per project.
  Each project keeps only its latest toast of each kind, so old ones do not pile up.
- Each type has its own sound: the normal sound when finished, a reminder sound when Claude is waiting for you,
  and a different sound for errors.
- **Quiet while you watch**: no toast while the window running Claude is in front of you and you used the
  keyboard or mouse in the last 2 minutes. In VS Code the window title must show the project name, so another
  project's window does not count. In Windows Terminal any of its windows counts, since the active tab is unknown.
- **Click to open**: in VS Code (and Cursor or Windsurf), clicking a toast opens the project's window.
  In a plain terminal, clicking just dismisses it.

## Install
```
/plugin marketplace add ronak7521/claude-task-notifier
/plugin install task-notifier@ronak-plugins
```
Start a new Claude Code session afterwards.

## Options (optional)
Add to the `env` block of `~/.claude/settings.json`, then start a new session:
```json
{
  "env": {
    "TASK_NOTIFIER_MIN_SECONDS": "30",
    "TASK_NOTIFIER_PRIVACY": "1",
    "TASK_NOTIFIER_EVENTS": "permission,question,input,error"
  }
}
```
- `TASK_NOTIFIER_MIN_SECONDS`: only notify for tasks that took at least this long. Default `30`; `0` = always.
- `TASK_NOTIFIER_PRIVACY`: `1` shows only the project name, never prompt, reply, command or error details.
  Recommended when screen sharing or working with customer data.
- `TASK_NOTIFIER_EVENTS`: only these notification types, comma-separated. Default: all of `finished`, `asking`,
  `paused`, `error`, `permission`, `question`, `input`. For example `permission,question,input` gives only
  the "Claude is waiting for you" toasts.
- `TASK_NOTIFIER_WHEN_FOCUSED`: `1` notifies even while you are looking at Claude.
- `TASK_NOTIFIER_DEBUG`: `1` logs every decision (shown, or why it stayed quiet) to
  `%TEMP%\claude-task-notifier\debug.log`. It records titles and reasons, never your prompts or Claude's replies.

## How it works
The hooks print nothing and never block or change what Claude does. The plugin does not touch your `settings.json`.

| Hook | What it does |
|---|---|
| `Stop`, `StopFailure` | Finished, asking, paused and error toasts. Runs in the foreground (about 2 s at the end of a turn) so it also works in `claude -p` runs. |
| `PermissionRequest` | Remembers what the permission is for. |
| `Notification` | Shows the permission or input toast once a dialog has waited about 6 seconds. |
| `PreToolUse` (`AskUserQuestion`) | Shows the question toast once the question has waited about 6 seconds. |
| `PostToolUse`, `PostToolUseFailure`, `PermissionDenied` | Removes the waiting toast once that tool call was answered. Only starts PowerShell while such a toast exists. |
| `UserPromptSubmit` | Saves when your task started, so quick answers stay silent. |
| `SessionEnd` | Clears anything still waiting when you quit mid-dialog. Only starts PowerShell if needed. |

All except `Stop`, `StopFailure` and `SessionEnd` run in the background (`async`). Hooks start `cmd.exe` directly
(exec form), so they work with or without Git Bash installed.

- Small state files live in `%TEMP%\claude-task-notifier`: your prompt time and text (time only in privacy
  mode) and what a pending permission is for. Files older than 7 days are deleted automatically.
- `%LOCALAPPDATA%\claude-task-notifier` caches `ctn-native-1.dll`, a tiny helper compiled on your machine on
  first use that asks Windows which window is in front (it makes the focus check take 20 ms instead of 700 ms).
  It is kept in your user profile, not in TEMP, because TEMP can point to a folder other users can write to.
- To show the **Task Notifier** name and icon, the script registers the app in your user registry under
  `HKCU\Software\Classes\AppUserModelId\ClaudeCode.TaskNotifier`. This needs no admin rights.
- If toasts are not available, it falls back to a classic tray balloon.

## Uninstall
```
/plugin uninstall task-notifier@ronak-plugins
```
Then remove the registry entry, saved prompt times and the cached helper in PowerShell:
```powershell
Remove-Item 'HKCU:\Software\Classes\AppUserModelId\ClaudeCode.TaskNotifier' -Recurse
Remove-Item "$env:TEMP\claude-task-notifier", "$env:LOCALAPPDATA\claude-task-notifier" -Recurse
```

## Security
- Prompts, replies, commands and file names are only ever shown as text: they are XML-escaped in the toast,
  never run, and never passed on a command line. Hook input is read from stdin only.
- State files are named from the session id with everything except letters, digits, `-` and `_` removed,
  so they cannot be written outside the state folder.
- The click link only uses fixed schemes (`vscode`, `vscode-insiders`, `cursor`, `windsurf`) and escapes
  every folder name.
- Privacy mode and the debug log never contain prompt, reply, command, question or error text.
- The registry entry is under HKCU only; no admin rights, nothing machine-wide.

## Tests
The repository (not the installed plugin) has two test suites. Run them before a release:
```
tests\run-tests.cmd          all tests, no toasts shown
tests\run-tests.cmd live     also shows and removes one real toast
```
- **Feature tests**: every notification type and its text, sound and stickiness; the waiting-toast lifecycle
  (recorded, shown, cleared by answering, by the next prompt, at the end of the turn or session); every setting;
  quiet-while-watching with a simulated screen; click links; debug log; clean-up of old state; the hook wiring.
- **Security tests**: hostile hook input, path traversal, toast XML injection, link escaping, command injection,
  privacy and debug-log leaks, and a planted helper DLL.

They run the real launcher in dry-run mode inside a throwaway TEMP folder, so they leave your settings,
state and registry untouched. Exit code 0 means everything passed.

## Troubleshooting
- Nothing appears: check Do not disturb and Settings > System > Notifications (allow **Task Notifier**).
  Then set `TASK_NOTIFIER_DEBUG=1`, start a new session and read `debug.log`: it says why each toast stayed quiet.
- "AuthorizationManager check failed": run `Get-ExecutionPolicy -List`; a Group Policy may block scripts.
- After unzipping a download, run `Get-ChildItem <folder> -Recurse | Unblock-File`.
- To test without showing anything, pipe a hook payload into `scripts\notify.cmd` with `CTN_DRYRUN=1` set;
  the notification text is printed to stderr.

## Disclaimer
Community plugin, not affiliated with or endorsed by Anthropic. "Claude" is a trademark of Anthropic.
