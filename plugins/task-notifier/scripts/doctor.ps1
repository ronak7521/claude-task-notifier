# Task Notifier doctor: explains why notifications do not appear, and sends a test notification.
# Started by doctor.cmd for /task-notifier:doctor (full report) and /task-notifier:test (-TestOnly).
# Prints a plain-text report for Claude to explain. It changes nothing, except that the test toast refreshes
# the app's name and icon registration, as every toast does.
#
# Each finding is one line: [OK], [INFO], [WARN] (may explain missing notifications) or [FAIL] (stops them),
# followed by "-> what to do" where there is something to do.
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.
param([switch]$TestOnly)

$ErrorActionPreference = 'Continue'
$script:Fails = 0
$script:Warns = 0

# Write-Host works in every language mode; [Console]::Out.WriteLine is a blocked method call in ConstrainedLanguage mode.
function Say([string]$level, [string]$msg, [string]$fix = '') {
    if ($level -eq 'FAIL') { $script:Fails++ } elseif ($level -eq 'WARN') { $script:Warns++ }
    Write-Host ('[{0}] {1}' -f $level, $msg)
    if ($fix) { Write-Host "       -> $fix" }
}

function Section([string]$name) { Write-Host ''; Write-Host "== $name ==" }

function Complete {
    Write-Host ''
    Write-Host ('Result: {0} problem(s), {1} warning(s).' -f $script:Fails, $script:Warns)
    exit 0
}

Write-Host 'Task Notifier doctor'

# --- PowerShell itself: everything else needs full language mode ---

$mode = [string]$ExecutionContext.SessionState.LanguageMode
if ($mode -ne 'FullLanguage') {
    Say 'FAIL' "PowerShell runs in $mode mode on this PC, set by a security policy (AppLocker or WDAC). Windows notifications cannot be shown from it." `
        'Ask IT to allow PowerShell scripts in the Claude Code plugin folder (%USERPROFILE%\.claude\plugins) to run in full language mode.'
    Complete
}

# Load notify.ps1's settings and functions (not its main block), so these checks use exactly the hook's own code.
$notifyPath = Join-Path $PSScriptRoot 'notify.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($notifyPath, [ref]$null, [ref]$null)
foreach ($st in $ast.EndBlock.Statements) {
    if ($st -is [Management.Automation.Language.FunctionDefinitionAst] -or $st -is [Management.Automation.Language.AssignmentStatementAst]) {
        . ([scriptblock]::Create($st.Extent.Text))
    }
}
# Code loaded this way has no $PSScriptRoot of its own; both scripts live in the same folder.
$PluginRoot = Split-Path -Parent $PSScriptRoot
# notify.ps1 silences errors (a hook must never print); the doctor should not hide them.
$ErrorActionPreference = 'Continue'

function Send-TestToast {
    if ($env:CTN_DRYRUN) { Say 'INFO' 'Dry run: the test notification was not shown.'; return }
    $group = 'ctn-doctor'
    try {
        $note = New-Note 'finished' 'Task Notifier test' @('If you can read this, Windows notifications work.') 'Notification.Default' 'doctor' 'Info' $false
        Show-Toast $note $group 'ctn-doctor' 'Task Notifier' ''
        Start-Sleep -Milliseconds 300
        $inCenter = @([Windows.UI.Notifications.ToastNotificationManager]::History.GetHistory($AppId) | Where-Object { $_.Group -eq $group }).Count -gt 0
        if ($inCenter) {
            Say 'OK' 'Test notification sent. Windows accepted it and it is in the notification center (Win+N).' `
                'If no banner appeared on screen, Do not disturb or Focus is on: banners are hidden, but notifications still collect in Win+N.'
        } else {
            Say 'WARN' 'Test notification sent, but Windows did not keep it in the notification center.' `
                'Settings > System > Notifications > Task Notifier: turn on "Show notifications in notification center".'
        }
    } catch {
        Say 'FAIL' "The test notification could not be shown: $($_.Exception.Message)" 'Run /task-notifier:doctor for the full report.'
    }
}

# --- Windows notification settings ---

function Test-WindowsSide {
    Section 'Windows notifications'
    $os = [Environment]::OSVersion.Version
    if ($os.Major -lt 10) { Say 'FAIL' "Windows $os is too old: toast notifications need Windows 10 or 11." }

    $push = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' -ErrorAction SilentlyContinue
    if ($push -and $push.ToastEnabled -eq 0) {
        Say 'FAIL' 'All notifications are turned off in Windows.' 'Settings > System > Notifications: turn Notifications on.'
    }

    $key = "HKCU:\Software\Classes\AppUserModelId\$AppId"
    if (Test-Path -LiteralPath $key) {
        $reg = Get-ItemProperty -LiteralPath $key
        if ($reg.IconUri -and -not (Test-Path -LiteralPath $reg.IconUri)) {
            Say 'INFO' 'The registered icon belongs to an older plugin version; the next notification updates it.'
        } else {
            Say 'OK' "Registered as the app ""$AppName"" (HKCU, no admin rights)."
        }
    } else {
        Say 'INFO' "Not registered as an app yet; the first notification registers ""$AppName""."
    }

    try {
        Initialize-Toasts
        $setting = [string][Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Setting
        switch ($setting) {
            'Enabled' { Say 'OK' 'Windows allows notifications from Task Notifier.' }
            'DisabledForApplication' { Say 'FAIL' 'Notifications from Task Notifier are turned off in Windows.' 'Settings > System > Notifications > Task Notifier: turn it on.' }
            'DisabledForUser' { Say 'FAIL' 'All notifications are turned off for your Windows account.' 'Settings > System > Notifications: turn Notifications on.' }
            'DisabledByGroupPolicy' { Say 'FAIL' 'A company policy turns notifications off on this PC.' 'Ask IT; the plugin cannot override this.' }
            default { Say 'WARN' "Windows reports the notification setting as ""$setting""." }
        }
    } catch {
        Say 'FAIL' "Windows notifications are not available here: $($_.Exception.Message)" 'The plugin falls back to tray balloons, which may also be hidden.'
    }

    $app = Get-ItemProperty -LiteralPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\$AppId" -ErrorAction SilentlyContinue
    if ($app -and $app.ShowInActionCenter -eq 0) {
        Say 'WARN' 'Task Notifier notifications are not kept in the notification center (Win+N).' `
            'Settings > System > Notifications > Task Notifier: turn on "Show notifications in notification center".'
    }
}

if ($TestOnly) {
    Test-WindowsSide
    Section 'Test notification'
    Send-TestToast
    Complete
}

# --- The plugin and its hooks ---

Section 'Plugin'
$version = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\.claude-plugin\plugin.json') -Raw | ConvertFrom-Json).version
Say 'INFO' "Task Notifier $version, running from $([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')))"

$claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$installedFile = Join-Path $claudeDir 'plugins\installed_plugins.json'
$settingsFile = Join-Path $claudeDir 'settings.json'
$installed = @()
if (Test-Path -LiteralPath $installedFile) {
    try {
        $list = (Get-Content -LiteralPath $installedFile -Raw | ConvertFrom-Json).plugins
        # Only copies that load here: user-wide ones, and project ones for this folder (not other projects).
        $here = (Get-Location).Path.TrimEnd('\')
        foreach ($p in $list.PSObject.Properties | Where-Object { $_.Name -like 'task-notifier@*' }) {
            foreach ($i in @($p.Value)) {
                if ($i.projectPath -and ([string]$i.projectPath).TrimEnd('\') -ne $here) { continue }
                $installed += "$($p.Name) $($i.version) ($($i.scope))"
            }
        }
    } catch { }
}
if ($installed.Count) { Say 'OK' ('Installed: ' + ($installed -join ', ')) }
else { Say 'INFO' 'Not installed from a marketplace (loaded with --plugin-dir, or the install record was not found).' }
if ($installed.Count -gt 1) {
    Say 'WARN' 'Installed more than once, so every event can notify twice.' 'Keep one: /plugin, then uninstall the extra copy.'
}

$settings = $null
if (Test-Path -LiteralPath $settingsFile) { try { $settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json } catch { } }
if ($settings -and $settings.enabledPlugins) {
    foreach ($p in $settings.enabledPlugins.PSObject.Properties | Where-Object { $_.Name -like 'task-notifier@*' -and $_.Value -eq $false }) {
        Say 'FAIL' "The plugin is turned off ($($p.Name) is false in settings.json)." "Turn it on with: claude plugin enable $($p.Name)"
    }
}

$recent = Get-ChildItem -LiteralPath $StateDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in '.json', '.pending', '.answered' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($recent -and $recent.LastWriteTime -gt (Get-Date).AddMinutes(-15)) {
    Say 'OK' ("The plugin's hooks are running (last at {0:HH:mm:ss})." -f $recent.LastWriteTime)
} elseif ($recent) {
    Say 'WARN' ("No hook has run in the last 15 minutes (last at {0:yyyy-MM-dd HH:mm})." -f $recent.LastWriteTime) `
        'If you installed or updated the plugin during this session, start a new one (in VS Code: Developer: Reload Window).'
} else {
    Say 'WARN' 'No hook has run yet on this PC.' 'Start a new Claude Code session after installing (in VS Code: Developer: Reload Window).'
}

$problemFile = Join-Path $StateDir 'last-problem.txt'
if (Test-Path -LiteralPath $problemFile) {
    Say 'FAIL' ('A hook could not notify: ' + (Get-Content -LiteralPath $problemFile -Raw).Trim()) `
        'If a company policy blocks PowerShell scripts, ask IT to allow scripts in %USERPROFILE%\.claude\plugins.'
}

foreach ($scope in 'MachinePolicy', 'UserPolicy') {
    $policy = [string](Get-ExecutionPolicy -Scope $scope)
    if ($policy -in 'AllSigned', 'Restricted') {
        Say 'FAIL' "A Group Policy sets the PowerShell execution policy to $policy ($scope), so the plugin's unsigned scripts cannot run." 'Ask IT to allow it; the plugin cannot override a Group Policy.'
    }
}

# --- Windows ---

Test-WindowsSide

# --- Settings that keep notifications quiet on purpose ---

Section 'Your settings'
$names = 'TASK_NOTIFIER_EVENTS', 'TASK_NOTIFIER_MIN_SECONDS', 'TASK_NOTIFIER_PRIVACY', 'TASK_NOTIFIER_WHEN_FOCUSED', 'TASK_NOTIFIER_DEBUG'
$saved = if ($settings -and $settings.env) { $settings.env } else { $null }
foreach ($n in $names) {
    $now = [string][Environment]::GetEnvironmentVariable($n)
    $inFile = if ($saved) { [string]$saved.$n } else { '' }
    # A saved value that is not active means the session started before it was saved. A value set elsewhere
    # (project settings, Windows environment variables) is fine; just say where it does not come from.
    if ($inFile -and $now -ne $inFile) {
        Say 'WARN' "$n is ""$inFile"" in settings.json but ""$now"" in this session." 'Start a new Claude Code session so the hooks use the saved value.'
    } elseif ($now -and -not $inFile) {
        Say 'INFO' "$n is ""$now"", set outside ~/.claude/settings.json (project settings or a Windows environment variable)."
    }
}

$all = 'finished', 'asking', 'paused', 'error', 'permission', 'question', 'input'
$off = @($all | Where-Object { -not (Test-Enabled $_) })
if ($off.Count -eq $all.Count) {
    Say 'FAIL' "TASK_NOTIFIER_EVENTS turns every notification off (""$env:TASK_NOTIFIER_EVENTS"")." "Use names from: $($all -join ', ')"
} elseif ($off.Count) {
    Say 'INFO' ('Turned off by TASK_NOTIFIER_EVENTS: ' + ($off -join ', ') + '.')
} else {
    Say 'OK' 'All notification types are on.'
}
$minSeconds = 30
if (([string]$env:TASK_NOTIFIER_MIN_SECONDS).Trim() -match '^\d+$') { $minSeconds = [int]$Matches[0] }
if ($minSeconds -ge 600) {
    Say 'WARN' "Finished notifications only for tasks over $minSeconds seconds (TASK_NOTIFIER_MIN_SECONDS)." 'Lower it, e.g. 30 (the default) or 0 for every answer.'
} else {
    Say 'INFO' "Finished notifications for tasks over $minSeconds seconds; quicker answers stay quiet."
}
if (Test-Flag $env:TASK_NOTIFIER_PRIVACY) { Say 'INFO' 'Privacy mode is on: notifications show only the project name.' }
if (Test-Flag $env:TASK_NOTIFIER_WHEN_FOCUSED) { Say 'INFO' 'TASK_NOTIFIER_WHEN_FOCUSED is on: notifications also appear while you watch Claude.' }
else { Say 'INFO' 'No notification while you are looking at Claude''s window (used it in the last 2 minutes); switch away to get them.' }

# --- Quiet while you watch ---

Section 'Focus check'
try {
    Initialize-Native
    Say 'OK' 'The focus check works (it can tell whether Claude''s window is in front).'
    if (Test-Watching (Split-Path -Leaf (Get-Location).Path)) {
        Say 'INFO' 'Right now you are looking at Claude, so finished notifications would stay quiet until you switch away.'
    }
} catch {
    Say 'WARN' "The focus check is unavailable ($($_.Exception.Message)). Notifications still work, but also appear while you watch." ''
}

# --- Debug log ---

Section 'Debug log'
$log = Join-Path $StateDir 'debug.log'
if (Test-Path -LiteralPath $log) {
    Say 'INFO' "Last entries of $log (why each notification was shown or stayed quiet):"
    Get-Content -LiteralPath $log -Tail 10 | ForEach-Object { Write-Host "       $_" }
} else {
    Say 'INFO' 'No debug log. To see why each notification is shown or stays quiet, set TASK_NOTIFIER_DEBUG to 1 in the env block of ~/.claude/settings.json and start a new session.'
}

Section 'Test notification'
Send-TestToast
Complete
