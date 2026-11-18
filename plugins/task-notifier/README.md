# Task Notifier for Claude Code

Windows notifications from Claude Code, so you can work in another window instead of watching the chat.
**Windows only, Claude Code only** (terminal and the VS Code extension; hooks do not run in claude.ai chat or Cowork).

- **Finished**: project name, your prompt and the start of Claude's reply.
  Quick answers (under 30 seconds) stay silent.
- **Paused**: Claude's turn ended but background tasks are still running.
- **Needs permission**: the command or file to approve.
- **Error**: the turn ended with an error, such as a rate limit or API error.

## Install
```
/plugin install task-notifier --marketplace ronak7521/claude-task-notifier
```
Start a new Claude Code session afterwards.

## Options (optional)
Add to the `env` block of `~/.claude/settings.json`, then start a new session:
```json
{
  "env": {
    "TASK_NOTIFIER_MIN_SECONDS": "30",
    "TASK_NOTIFIER_PRIVACY": "1"
  }
}
```
- `TASK_NOTIFIER_MIN_SECONDS`: only notify for tasks that took at least this long. Default `30`; `0` = always.
- `TASK_NOTIFIER_PRIVACY`: `1` shows only the project name, never prompt, reply, command or error details.
  Recommended when screen sharing or working with customer data.

## How it works
The plugin registers `Stop`, `StopFailure` and `PermissionRequest` hooks. The hook script shows the
notification and exits immediately. It prints nothing, so it never blocks or changes what Claude does,
and it does not touch your `settings.json`.

## Troubleshooting
- Nothing appears: check Do not disturb and Settings > System > Notifications (allow Windows PowerShell).
- "AuthorizationManager check failed": run `Get-ExecutionPolicy -List`; a Group Policy may block scripts.
- After unzipping a download, run `Get-ChildItem <folder> -Recurse | Unblock-File`.

## Disclaimer
Community plugin, not affiliated with or endorsed by Anthropic. "Claude" is a trademark of Anthropic.
