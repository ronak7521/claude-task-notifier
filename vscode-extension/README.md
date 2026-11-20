# Task Notifier for Claude Code

Windows notifications from [Claude Code](https://claude.com/claude-code), so you can work in another window
instead of watching the chat. **Windows only.**

- **Finished**: the project, your prompt and the start of Claude's reply. Quick answers (under 30 seconds) stay silent.
- **Asking**: Claude ended its reply with a question.
- **Paused**: the turn ended but background tasks are still running.
- **Error**: the turn stopped with an error, such as a rate limit.
- **Needs permission**, **has a question**, **needs your input**: these stay on screen until you answer, and
  disappear by themselves once you do.

No toast appears while you are looking at the Claude Code window. Clicking a toast opens the project's VS Code window.

## How it works

Notifications come from Claude Code's hooks, so the real work is done by the **Task Notifier plugin for Claude Code**.
This extension installs and manages that plugin for you:

1. When VS Code starts and the plugin is missing, the extension asks whether to install it. Nothing is installed
   without your OK.
2. It runs Claude Code's own commands (`claude plugin marketplace add ronak7521/claude-task-notifier` and
   `claude plugin install task-notifier@ronak-plugins`), the same ones you could type yourself.
3. Reload the window, and notifications start with your next Claude Code task.

It uses the `claude` program that comes with the Claude Code extension, or one installed from
[claude.com/claude-code](https://claude.com/claude-code).

## Commands

Open the Command Palette (**Ctrl+Shift+P**) and type **Task Notifier**:

| Command | What it does |
|---|---|
| Send Test Notification | Shows a test toast and checks the Windows notification settings. |
| Diagnose Missing Notifications | Checks the plugin, its hooks, Windows and company settings, and your own settings, then sends a test toast. |
| Install or Repair Claude Code Plugin | Installs the plugin, or turns it back on. |
| Update Claude Code Plugin | Gets the latest plugin version. |
| Remove Claude Code Plugin | Uninstalls the plugin from Claude Code. |

## Settings

Notification options (minimum task length, privacy mode, which types to show) are set in Claude Code's
`~/.claude/settings.json`. See the [full guide](https://github.com/ronak7521/claude-task-notifier#options-optional).

`taskNotifier.claudePath`: full path to `claude.exe`, if the extension cannot find it. It can only be set in your
user settings, not by a workspace.

## Troubleshooting

### The extension is installed, but no notifications appear and the plugin is not in Claude Code

The extension is only the installer. The notifications come from the **Task Notifier plugin** for Claude Code,
and it is installed only after you click **Install** in the "Install it now?" message. That message is easy to miss:

- VS Code hides messages after a few seconds and moves them to the **bell icon** at the bottom right.
- With **Do Not Disturb** turned on, messages are not shown at all.

Closing or ignoring the message installs nothing. It comes back the next time VS Code starts, unless you picked
**Don't Ask Again**.

To install the plugin now:

1. Press **Ctrl+Shift+P** and run **Task Notifier: Install or Repair Claude Code Plugin**.
2. Click **Reload Window** when asked, and restart any Claude Code session running in a terminal.
3. Run **Task Notifier: Send Test Notification**. A "Task Notifier" toast should appear.

To check it worked, run `claude plugin list` in a terminal, or `/plugin` in Claude Code. You should see
`task-notifier@ronak-plugins`.

### Seeing what the extension did

Open **View → Output** and pick **Task Notifier** in the drop-down. It shows every `claude` command the extension
ran and what it printed.

### "Task Notifier could not find Claude Code"

Install the Claude Code extension or CLI. If it is installed somewhere unusual, set `taskNotifier.claudePath` in your
user settings to the full path of `claude.exe`.

### Still no toasts after the plugin is installed

Run **Task Notifier: Diagnose Missing Notifications**. It checks Windows notification settings, Focus Assist,
company policies and your Claude Code settings, and says what to change.

## Privacy

Nothing is sent anywhere. The extension only runs Claude Code's plugin commands and the plugin's own check
script. The plugin shows notifications on your PC and keeps small state files in `%TEMP%`. Details and the
source code: [github.com/ronak7521/claude-task-notifier](https://github.com/ronak7521/claude-task-notifier).

## Requirements

- Windows 10 or 11
- Claude Code (the VS Code extension or the CLI)

Not affiliated with or endorsed by Anthropic. "Claude" is a trademark of Anthropic.
