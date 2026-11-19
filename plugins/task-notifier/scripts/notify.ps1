# Task Notifier for Claude Code: Windows toast notifications.
#   Stop / StopFailure        finished, paused, asking a question in its reply, or stopped with an error
#   Notification              permission dialog or MCP input form left unanswered for ~6 s (sticky toast)
#   PreToolUse                AskUserQuestion dialog left unanswered for ~6 s (sticky toast)
#   UserPromptSubmit          records when the task started and the prompt text, for the Stop toast
#   PermissionRequest         records what the permission is for, for the permission toast
#   PostToolUse(Failure) / PermissionDenied   that tool call was answered: remove its sticky toast
#   SessionEnd                drop anything still pending for the session
# Prints nothing and always exits 0, so it never blocks or changes what Claude does.
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.
#
# Optional settings (environment variables, e.g. in the "env" block of ~/.claude/settings.json):
#   TASK_NOTIFIER_MIN_SECONDS     Only notify for finished tasks that took at least this long (default 30, 0 = always)
#   TASK_NOTIFIER_PRIVACY         1 = show only the project name, never prompt, reply, command or question text
#   TASK_NOTIFIER_EVENTS          Only these types, e.g. "permission,question,input,error" (default: all of
#                                 finished, asking, paused, error, permission, question, input)
#   TASK_NOTIFIER_WHEN_FOCUSED    1 = notify even while you are looking at Claude (default: stay quiet then)
#   TASK_NOTIFIER_DEBUG           1 = log every decision to %TEMP%\claude-task-notifier\debug.log
# Testing: set CTN_DRYRUN=1 to print the notification to stderr instead of showing it.
#
# Toasts are shown under their own app id. Windows only gives an unpackaged app a name and icon when the
# id is registered, so this writes HKCU\Software\Classes\AppUserModelId\ClaudeCode.TaskNotifier (no admin).
$ErrorActionPreference = 'SilentlyContinue'

$AppId = 'ClaudeCode.TaskNotifier'
$AppName = 'Task Notifier'
$StateDir = Join-Path $env:TEMP 'claude-task-notifier'
# Compiled code is cached in the user profile, never in TEMP: TEMP may point to a folder other users can write to.
$CacheDir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'claude-task-notifier' } else { '' }
$WaitSeconds = 6
$AwaySeconds = 120
$NativeVersion = 1
$script:LogTag = ''

# On/off settings accept 1, true, yes or on, ignoring case and surrounding spaces.
function Test-Flag([string]$value) { return $value.Trim() -match '^(1|true|yes|on)$' }

# --- Debug log (TASK_NOTIFIER_DEBUG=1): decisions and titles only, never prompt or reply text ---

function Write-Log([string]$msg) {
    if ($env:CTN_DRYRUN -and $msg) { [Console]::Error.WriteLine("  ($msg)") }
    if (-not (Test-Flag $env:TASK_NOTIFIER_DEBUG)) { return }
    try {
        $null = New-Item -ItemType Directory -Force -Path $StateDir
        $log = Join-Path $StateDir 'debug.log'
        if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 1MB) {
            Move-Item -LiteralPath $log (Join-Path $StateDir 'debug.old.log') -Force
        }
        # One entry per line: control characters (e.g. a newline in an error message) cannot fake log entries.
        $msg = $msg -replace '[\x00-\x1F\x7F]+', ' '
        $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $script:LogTag, $msg
        [IO.File]::AppendAllText($log, $line + "`r`n", (New-Object Text.UTF8Encoding $false))
    } catch { }
}

function Test-Enabled([string]$type) {
    $list = ([string]$env:TASK_NOTIFIER_EVENTS).Trim()
    if (-not $list) { return $true }
    return @($list.ToLowerInvariant() -split '[\s,;]+') -contains $type
}

$ErrorText = @{
    rate_limit            = 'Rate limit reached'
    authentication_failed = 'Authentication failed'
    oauth_org_not_allowed = 'Your organization does not allow this sign-in'
    account_on_hold       = 'Account on hold'
    billing_error         = 'Billing problem'
    invalid_request       = 'Invalid request'
    model_not_found       = 'Model not found'
    server_error          = 'API server error or overloaded'
    max_output_tokens     = 'Reply hit the output token limit'
    cloud_credential_error = 'Cloud provider credentials problem'
}

function Shorten([string]$s, [int]$max) {
    if (-not $s) { return '' }
    # Drop Markdown heading lines (e.g. "## Done") when there is other text.
    $lines = @($s -split "`r?`n" | Where-Object { $_.Trim() })
    $body = @($lines | Where-Object { $_ -notmatch '^\s*#' })
    if ($body.Count) { $lines = $body }
    # Strip Markdown only where it is markup, so "C#", "#123" and "->" survive.
    $lines = @($lines | ForEach-Object { $_ -replace '^\s*(#+|>+)\s*', '' })
    $s = (($lines -join ' ') -replace '`|\*\*', '' -replace '\s+', ' ').Trim()
    if ($s.Length -gt $max) { return $s.Substring(0, $max - 3) + '...' }
    return $s
}

function ConvertTo-Utc($value) {
    if (-not $value) { return $null }
    if ($value -is [datetime]) { return $value.ToUniversalTime() }
    try {
        return [datetime]::Parse([string]$value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
    } catch { return $null }
}

function Get-AgeSeconds($time) {
    $t = ConvertTo-Utc $time
    if (-not $t) { return [double]::MaxValue }
    return ([datetime]::UtcNow - $t).TotalSeconds
}

# --- State files in %TEMP%\claude-task-notifier, named after the session ---
#   <session>.json       prompt time and text (UserPromptSubmit)
#   <session>.pending    Claude is waiting for you: which tool call, and what to show. notify.cmd checks
#                        for *.pending before starting PowerShell after a tool call, so tool calls stay cheap
#   <session>.answered   when a pending tool call was last answered, to tell "answered" from "never recorded"

function Get-StatePath($sessionId, [string]$suffix) {
    $id = ([string]$sessionId) -replace '[^A-Za-z0-9_-]', ''
    if (-not $id) { $id = 'default' }
    return Join-Path $StateDir "$id.$suffix"
}

function Write-State([string]$path, $object) {
    $null = New-Item -ItemType Directory -Force -Path $StateDir
    $json = $object | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding $false))
}

function Read-State([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return [IO.File]::ReadAllText($path) | ConvertFrom-Json
}

function Save-PromptState($data, [bool]$privacy) {
    $text = if ($privacy) { '' } else { [string]$data.prompt }
    Write-State (Get-StatePath $data.session_id 'json') @{ time = [datetime]::UtcNow.ToString('o'); prompt = $text }
    # Forget sessions untouched for a week. Markers left by a session that ended mid-dialog would make every
    # tool call start PowerShell, so drop them after 2 hours (the toast itself is still removed at Stop).
    $now = Get-Date
    Get-ChildItem -LiteralPath $StateDir -File | Where-Object {
        $_.LastWriteTime -lt $now.AddDays(-7) -or
        ($_.Extension -in '.pending', '.answered' -and $_.LastWriteTime -lt $now.AddHours(-2))
    } | Remove-Item -Force
}

# Short stable hash, e.g. to recognise the same tool call again without storing its text.
function Get-ShortHash([string]$s) {
    $sha = [Security.Cryptography.SHA1]::Create()
    $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))
    return (($hash[0..7] | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Write-Pending([string]$path, [string]$tool, [string]$match, [string]$label, [string]$detail, [string]$why) {
    Write-State $path @{ time = [datetime]::UtcNow.ToString('o'); tool = $tool; match = $match; label = $label; detail = $detail; why = $why }
}

# Is this tool call the one we are waiting on? Parallel tool calls finish while another waits for
# permission, so only the same tool with the same input counts. '*' means any tool call (MCP input forms).
function Test-PendingMatch($pending, $data) {
    if (-not $pending) { return $false }
    if ($pending.tool -eq '*') { return $true }
    if ([string]$pending.tool -ne [string]$data.tool_name) { return $false }
    return (-not $pending.match) -or ($pending.match -eq (Get-ShortHash (Get-PermissionDetail $data.tool_input)))
}

# --- Toast plumbing ---

function Initialize-Toasts {
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
}

# Toast group: a short hash of the project folder (Windows limits tag and group to 64 characters).
function Get-GroupKey([string]$cwd) { return 'p' + (Get-ShortHash $cwd.ToLowerInvariant()) }

function Remove-Toast([string]$tag, [string]$group) {
    if ($env:CTN_DRYRUN) { return }
    try { Initialize-Toasts; [Windows.UI.Notifications.ToastNotificationManager]::History.Remove($tag, $group, $AppId) } catch { }
}

# You answered (or the turn ended): drop the sticky toast and what it was about.
function Clear-Waiting($data, [string]$group) {
    Remove-Item -LiteralPath (Get-StatePath $data.session_id 'pending') -Force
    Remove-Toast 'waiting' $group
}

# Registers the app name and icon. Only writes when a value changed, e.g. a new plugin version moved the icon.
function Register-App {
    $key = "HKCU:\Software\Classes\AppUserModelId\$AppId"
    if (-not (Test-Path -LiteralPath $key)) { $null = New-Item -Path $key -Force }
    $cur = Get-ItemProperty -LiteralPath $key
    if ($cur.DisplayName -ne $AppName) {
        $null = New-ItemProperty -LiteralPath $key -Name DisplayName -Value $AppName -PropertyType String -Force
    }
    $icon = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\.claude-plugin\icon.png'))
    if ((Test-Path -LiteralPath $icon) -and $cur.IconUri -ne $icon) {
        $null = New-ItemProperty -LiteralPath $key -Name IconUri -Value $icon -PropertyType String -Force
    }
    if ($cur.ShowInSettings -ne 1) {
        $null = New-ItemProperty -LiteralPath $key -Name ShowInSettings -Value 1 -PropertyType DWord -Force
    }
}

# --- Are you looking at Claude right now? ---

# Small Win32 helper. Compiling it takes ~0.7 s, so it is compiled once into a cached DLL.
function Initialize-Native {
    if ('CTN.Native' -as [type]) { return }
    $source = @'
using System; using System.Runtime.InteropServices; using System.Text;
namespace CTN {
  public static class Native {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
    public static string Title(IntPtr hwnd) { var sb = new StringBuilder(512); GetWindowText(hwnd, sb, 512); return sb.ToString(); }
    public static IntPtr RootOwner(IntPtr hwnd) { return GetAncestor(hwnd, 3); }
    public static uint IdleMilliseconds() {
      var info = new LASTINPUTINFO(); info.cbSize = (uint)Marshal.SizeOf(info);
      if (!GetLastInputInfo(ref info)) return 0;
      return unchecked((uint)Environment.TickCount - info.dwTime);
    }
  }
}
'@
    # No user profile folder: compile in memory every time rather than cache somewhere less safe.
    if (-not $CacheDir) { Add-Type -TypeDefinition $source -ErrorAction Stop; return }
    $dll = Join-Path $CacheDir "ctn-native-$NativeVersion.dll"
    $tmp = Join-Path $CacheDir "ctn-native-$NativeVersion.$PID.tmp.dll"
    try { Add-Type -Path $dll -ErrorAction Stop; return } catch { }
    try {
        # Build next to the final name and move into place, so parallel hooks never load a half-written file.
        $null = New-Item -ItemType Directory -Force -Path $CacheDir
        Add-Type -TypeDefinition $source -OutputAssembly $tmp -OutputType Library -ErrorAction Stop
        Move-Item -LiteralPath $tmp $dll -ErrorAction Stop
        Add-Type -Path $dll -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $tmp -Force
        if (-not ('CTN.Native' -as [type])) { Add-Type -TypeDefinition $source -ErrorAction Stop }
    }
}

# True when the window running this Claude session is in front and you used the keyboard or mouse in
# the last 2 minutes. Then you can see Claude yourself, so the toast would only interrupt you.
function Test-Watching([string]$project) {
    if (Test-Flag $env:TASK_NOTIFIER_WHEN_FOCUSED) { return $false }
    try {
        Initialize-Native
        $idle = [CTN.Native]::IdleMilliseconds() / 1000
        if ($idle -ge $AwaySeconds) { Write-Log ("away: no input for {0:N0} s" -f $idle); return $false }
        $fg = [CTN.Native]::GetForegroundWindow()
        if ($fg -eq [IntPtr]::Zero) { return $false }

        # Terminal: our console window, or the terminal window that owns it (Windows Terminal).
        $console = [CTN.Native]::GetConsoleWindow()
        if ($console -ne [IntPtr]::Zero -and ($console -eq $fg -or [CTN.Native]::RootOwner($console) -eq $fg)) { return $true }

        $fgPid = [uint32]0
        $null = [CTN.Native]::GetWindowThreadProcessId($fg, [ref]$fgPid)
        $name = (Get-Process -Id $fgPid -ErrorAction Stop).ProcessName
        # Windows Terminal does not tell which tab is active, so any of its windows counts.
        if ($env:WT_SESSION -and $name -eq 'WindowsTerminal') { return $true }

        # VS Code (extension or integrated terminal): one process owns every window, so the window must
        # also show this project's name in its title.
        $editor = ((Get-EditorPid) -eq [int]$fgPid) -or
                  ($env:TERM_PROGRAM -eq 'vscode' -and $name -match '^(Code|Code - Insiders|Cursor|Windsurf)$')
        if ($editor) { return ([CTN.Native]::Title($fg) -match [regex]::Escape($project)) }
        return $false
    } catch {
        Write-Log "focus check failed: $($_.Exception.Message)"
        return $false
    }
}

# --- Click a toast to open the project (VS Code and its forks only; a terminal has no link to open) ---

# VSCODE_PID as a number, or -1 when it is missing or not a plain number.
function Get-EditorPid {
    $value = ([string]$env:VSCODE_PID).Trim()
    if ($value -match '^\d{1,9}$') { return [int]$value }
    return -1
}

# Only these fixed schemes are ever used; the process name just picks one of them.
function Get-EditorScheme([string]$name) {
    switch -regex ($name) {
        '^Code - Insiders$' { return 'vscode-insiders' }
        '^Cursor$'          { return 'cursor' }
        '^Windsurf$'        { return 'windsurf' }
    }
    return 'vscode'
}

function Get-LaunchUri([string]$cwd) {
    try {
        if (-not $cwd) { return '' }
        $editorPid = Get-EditorPid
        if ($editorPid -gt 0) { $name = (Get-Process -Id $editorPid -ErrorAction Stop).ProcessName }
        elseif ($env:TERM_PROGRAM -eq 'vscode') { $name = 'Code' }
        else { return '' }
        $scheme = Get-EditorScheme $name
        # Escape each folder name, so '#', '?' or '%' in a name cannot change what the link points to.
        $parts = @(($cwd -replace '\\', '/').Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) })
        if ($parts[0] -match '^[A-Za-z]%3A$') { $parts[0] = $parts[0].Substring(0, 1) + ':' }
        return "${scheme}://file/" + ($parts -join '/')
    } catch {
        Write-Log "no click link: $($_.Exception.Message)"
        return ''
    }
}

function Format-Xml([string]$s) { return [Security.SecurityElement]::Escape($s) }

# Modern toast, kept in the notification center (Win+N) under a header per project.
# Same tag + group replaces the older toast, so each project keeps only its latest toast of each kind.
# Sticky toasts use the reminder scenario: they stay on screen until clicked or dismissed.
# All text is XML-escaped, so prompts or file names cannot change the toast markup.
function Get-ToastXml($note, [string]$cwdKey, [string]$project, [string]$launch) {
    # A toast shows the title plus at most two text lines.
    $lines = @($note.Lines)
    if ($lines.Count -gt 2) { $lines = @($lines[0], (($lines[1..($lines.Count - 1)]) -join "`n")) }
    $texts = (@($note.Title) + $lines | ForEach-Object { "<text>$(Format-Xml $_)</text>" }) -join ''
    $scenario = if ($note.Sticky) { ' scenario="reminder"' } else { '' }
    # Windows 11 only keeps a reminder on screen when it has a button.
    $actions = if ($note.Sticky) { '<actions><action activationType="system" arguments="dismiss" content=""/></actions>' } else { '' }
    $hid = Format-Xml $cwdKey
    # Clicking the toast opens the project in the editor that runs Claude.
    $open = if ($launch) { " launch=`"$(Format-Xml $launch)`" activationType=`"protocol`"" } else { '' }
    return "<toast$scenario$open>" +
        "<visual><binding template=`"ToastGeneric`">$texts</binding></visual>" +
        "<audio src=`"ms-winsoundevent:$($note.Sound)`"/>" + $actions +
        "<header id=`"$hid`" title=`"$(Format-Xml $project)`" arguments=`"$hid`"/>" +
        '</toast>'
}

function Show-Toast($note, [string]$group, [string]$cwdKey, [string]$project, [string]$launch) {
    $ErrorActionPreference = 'Stop'
    Register-App
    Initialize-Toasts
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml((Get-ToastXml $note $cwdKey $project $launch))
    $toast = [Windows.UI.Notifications.ToastNotification]::new($doc)
    $toast.Tag = $note.Tag
    $toast.Group = $group
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show($toast)
}

# Fallback for systems without WinRT toasts: the old tray balloon, in a detached process because it
# must stay alive while the balloon shows. Text goes via environment variables, never into the script.
function Show-Balloon([string]$title, [string]$msg, [string]$kind) {
    $env:CTN_TITLE = $title.Substring(0, [Math]::Min(63, $title.Length))
    $env:CTN_MSG = $msg.Substring(0, [Math]::Min(255, $msg.Length))
    $env:CTN_ICON = $kind
    $balloon = @'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$icons = @{ Info = [System.Drawing.SystemIcons]::Information; Warning = [System.Drawing.SystemIcons]::Warning; Error = [System.Drawing.SystemIcons]::Error }
$n = New-Object System.Windows.Forms.NotifyIcon
$n.Icon = $icons[$env:CTN_ICON]
$n.Visible = $true
$n.ShowBalloonTip(5000, $env:CTN_TITLE, $env:CTN_MSG, [System.Windows.Forms.ToolTipIcon]$env:CTN_ICON)
Start-Sleep -Seconds 6
$n.Dispose()
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($balloon))
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded)
}

# --- Building the notification for each event ---

# $type is one of the TASK_NOTIFIER_EVENTS names: finished, asking, paused, error, permission, question, input.
function New-Note($type, $title, $lines, $sound, $tag, $kind, [bool]$sticky) {
    return [pscustomobject]@{
        Type = $type; Title = $title; Lines = @($lines | Where-Object { $_ }); Sound = $sound; Tag = $tag; Kind = $kind; Sticky = $sticky
    }
}

# "mcp__github__create_issue" -> "create_issue (github)"
function Get-ToolLabel([string]$tool) {
    if ($tool -match '^mcp__(.+?)__(.+)$') { return "$($Matches[2]) ($($Matches[1]))" }
    if ($tool) { return $tool }
    return 'an action'
}

# The most useful part of a tool call to show when asking for permission.
function Get-PermissionDetail($in) {
    if (-not $in) { return '' }
    if ($in.command) { return [string]$in.command }
    if ($in.url) { return [string]$in.url }
    if ($in.file_path) { return Split-Path -Leaf ([string]$in.file_path) }
    if ($in.notebook_path) { return Split-Path -Leaf ([string]$in.notebook_path) }
    if ($in.pattern) { return [string]$in.pattern }
    if ($in.query) { return [string]$in.query }
    if ($in.path) { return Split-Path -Leaf ([string]$in.path) }
    if ($in.description) { return [string]$in.description }
    return ''
}

# PermissionRequest fires as soon as the dialog opens; the toast waits for Notification (~6 s unanswered).
# Marked pending right away, so approving at any point after this removes the toast.
function Save-PermissionState($data, [string]$pendingPath, [bool]$privacy) {
    $raw = Get-PermissionDetail $data.tool_input
    $detail = ''; $why = ''
    if (-not $privacy) {
        $detail = Shorten $raw 200
        # Bash calls carry a plain-language description of the command; show it as a second line.
        if ($data.tool_input.command -and $data.tool_input.description) { $why = Shorten ([string]$data.tool_input.description) 120 }
    }
    Write-Pending $pendingPath ([string]$data.tool_name) (Get-ShortHash $raw) (Get-ToolLabel ([string]$data.tool_name)) $detail $why
}

function Get-PermissionNote($data, $pending, [string]$project, [bool]$privacy) {
    $lines = @()
    # Only trust a recent record, so an old permission is never shown for a different prompt.
    if ($pending -and $pending.tool -ne '*' -and (Get-AgeSeconds $pending.time) -lt 120) {
        $lines += if ($pending.detail) { "Approve $($pending.label): $($pending.detail)" } else { "Approve $($pending.label) to continue" }
        $lines += $pending.why
    } elseif (-not $privacy -and $data.message) {
        $lines += Shorten ([string]$data.message) 200
    } else {
        $lines += 'Approve the request in Claude Code to continue'
    }
    return New-Note 'permission' "Claude needs permission - $project" $lines 'Notification.Reminder' 'waiting' 'Warning' $true
}

function Get-InputNote($data, [string]$project, [bool]$privacy) {
    $lines = @()
    if (-not $privacy -and $data.message) { $lines += Shorten ([string]$data.message) 200 }
    if (-not $lines.Count) { $lines += 'An MCP server is waiting for your input' }
    return New-Note 'input' "Claude needs your input - $project" $lines 'Notification.Reminder' 'waiting' 'Warning' $true
}

function Get-QuestionNote($data, [string]$project, [bool]$privacy) {
    $qs = @($data.tool_input.questions | Where-Object { $_ })
    $lines = @()
    if (-not $privacy -and $qs.Count) {
        $q = $qs[0]
        $text = Shorten ([string]$q.question) 150
        if ($qs.Count -gt 1) { $text += " (+$($qs.Count - 1) more)" }
        $lines += $text
        $options = @($q.options | ForEach-Object { [string]$_.label } | Where-Object { $_ })
        if ($options.Count) { $lines += Shorten ('Options: ' + ($options -join ' / ')) 150 }
    }
    if (-not $lines.Count) { $lines += 'Answer the question in Claude Code to continue' }
    return New-Note 'question' "Claude has a question - $project" $lines 'Notification.Reminder' 'waiting' 'Warning' $true
}

function Get-ErrorNote($data, [string]$project, [bool]$privacy) {
    $code = [string]$data.error
    $err = if ($ErrorText.ContainsKey($code)) { $ErrorText[$code] } else { Shorten $code 80 }
    $details = ''
    if (-not $privacy) {
        $details = Shorten ([string]$data.error_details) 160
        # StopFailure's last_assistant_message is the API error text shown in the chat.
        if (-not $details) { $details = Shorten ([string]$data.last_assistant_message) 160 }
        # Skip details that only repeat the error, e.g. "API Error: Rate limit reached".
        if ($err -and $details -match [regex]::Escape($err)) { $details = '' }
    }
    $lines = @()
    if ($err) { $lines += "Error: $err" } else { $lines += 'The task did not finish.' }
    $lines += $details
    return New-Note 'error' "Claude stopped with an error - $project" $lines 'Notification.SMS' 'error' 'Error' $false
}

# Background tasks still in flight; Stop sends only in-flight ones, finished statuses are skipped anyway.
function Get-RunningBackgroundTasks($bg) {
    return @(@($bg) | Where-Object {
        $_ -and ([string]$_.status) -notmatch '^(completed|complete|done|failed|killed|cancelled|canceled|stopped)$'
    })
}

function Get-TurnNote($data, [string]$project, [bool]$privacy, [int]$minSeconds) {
    $last = $null
    $state = Read-State (Get-StatePath $data.session_id 'json')
    if ($state) { $last = [pscustomobject]@{ Text = [string]$state.prompt; Time = (ConvertTo-Utc $state.time) } }

    # Quiet for quick answers. If the start time is unknown, notify anyway.
    if ($minSeconds -gt 0 -and $last -and $last.Time) {
        $elapsed = ([datetime]::UtcNow - $last.Time).TotalSeconds
        if ($elapsed -ge 0 -and $elapsed -lt $minSeconds) { Write-Log ("quiet: quick answer ({0:N0} s)" -f $elapsed); return $null }
    }

    $reply = [string]$data.last_assistant_message
    $lastLine = @($reply -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1
    $asking = [bool]($lastLine -and (($lastLine -replace '[\s\*_`)"]+$', '') -match '\?$'))
    $running = @(Get-RunningBackgroundTasks $data.background_tasks)

    $lines = @()
    if (-not $privacy -and $last) { $lines += if ($last.Text) { 'Task: ' + (Shorten $last.Text 100) } }

    if ($running.Count) {
        $type = 'paused'; $title = "Claude paused - $project"; $sound = 'Notification.Default'
        if (-not $privacy) { $lines += Shorten $reply 120 }
        $suffix = if ($running.Count -eq 1) { '' } else { 's' }
        $status = "$($running.Count) background task$suffix still running"
        if (-not $privacy) {
            $names = @($running | ForEach-Object {
                if ($_.description) { [string]$_.description } elseif ($_.command) { [string]$_.command } else { [string]$_.type }
            } | Where-Object { $_ })
            if ($names.Count) { $status += ': ' + ($names -join ', ') }
        }
        $lines += Shorten $status 120
    } elseif ($asking) {
        # Claude ended its turn with a question: show the question itself.
        $type = 'asking'; $title = "Claude is asking - $project"; $sound = 'Notification.Reminder'
        if (-not $privacy) { $lines += Shorten $lastLine 160 }
    } else {
        $type = 'finished'; $title = "Claude finished - $project"; $sound = 'Notification.Default'
        if (-not $privacy) { $lines += Shorten $reply 120 }
    }
    if (-not @($lines | Where-Object { $_ }).Count) { $lines += if ($asking) { 'Claude is waiting for your answer' } else { 'Task completed' } }
    return New-Note $type $title $lines $sound 'turn' 'Info' $false
}

# --- Main ---

try {
    $privacy = Test-Flag $env:TASK_NOTIFIER_PRIVACY
    $minSeconds = 30
    if (([string]$env:TASK_NOTIFIER_MIN_SECONDS).Trim() -match '^\d+$') { $minSeconds = [int]$Matches[0] }

    [Console]::InputEncoding = [Text.Encoding]::UTF8
    $data = [Console]::In.ReadToEnd() | ConvertFrom-Json
    if (-not $data) { Write-Log 'ignored: no hook input'; exit 0 }

    $hookEvent = [string]$data.hook_event_name
    $sid = ([string]$data.session_id) -replace '[^A-Za-z0-9_-]', ''
    $script:LogTag = "$hookEvent " + $sid.Substring(0, [Math]::Min(8, $sid.Length))
    Write-Log ((@('received', $data.notification_type, $data.tool_name) | Where-Object { $_ }) -join ' ')

    $cwd = [string]$data.cwd
    $project = if ($cwd) { Split-Path -Leaf $cwd } else { 'Claude Code' }
    $cwdKey = if ($cwd) { $cwd.ToLowerInvariant() } else { 'claude-code' }
    $group = Get-GroupKey $cwdKey
    $pendingPath = Get-StatePath $data.session_id 'pending'
    $note = $null

    switch ($hookEvent) {
        'UserPromptSubmit' {
            Save-PromptState $data $privacy
            Clear-Waiting $data $group
        }
        'PermissionRequest' {
            # Turned-off types record nothing, so tool calls never start PowerShell for them.
            if (Test-Enabled 'permission') { Save-PermissionState $data $pendingPath $privacy }
        }
        { $_ -in 'PostToolUse', 'PostToolUseFailure', 'PermissionDenied' } {
            if (Test-PendingMatch (Read-State $pendingPath) $data) {
                Clear-Waiting $data $group
                Write-State (Get-StatePath $data.session_id 'answered') @{ time = [datetime]::UtcNow.ToString('o') }
            }
        }
        'SessionEnd' { Clear-Waiting $data $group }
        'Notification' {
            switch ([string]$data.notification_type) {
                'permission_prompt' {
                    if (-not (Test-Enabled 'permission')) { break }
                    $pending = Read-State $pendingPath
                    if ($pending) { $note = Get-PermissionNote $data $pending $project $privacy }
                    elseif ((Get-AgeSeconds (Read-State (Get-StatePath $data.session_id 'answered')).time) -gt 15) {
                        # Nothing recorded and nothing just answered: a prompt without PermissionRequest,
                        # such as a sandboxed command's network request. Any tool call ends it.
                        Write-Pending $pendingPath '*' '' '' '' ''
                        $note = Get-PermissionNote $data $null $project $privacy
                    }
                    else { Write-Log 'quiet: answered while starting up' }
                }
                { $_ -in 'elicitation_dialog', 'elicitation_url_dialog' } {
                    if (Test-Enabled 'input') {
                        Write-Pending $pendingPath '*' '' '' '' ''
                        $note = Get-InputNote $data $project $privacy
                    }
                }
            }
        }
        'PreToolUse' {
            if ([string]$data.tool_name -eq 'AskUserQuestion' -and (Test-Enabled 'question')) {
                # Same ~6 s grace as permission prompts: answering sooner (PostToolUse removes the
                # marker) means you are at the screen, so no toast.
                Write-Pending $pendingPath 'AskUserQuestion' '' '' '' ''
                if (-not $env:CTN_DRYRUN) {
                    Start-Sleep -Milliseconds ([Math]::Max(0, $WaitSeconds * 1000 - 1500))
                }
                if (Test-Path -LiteralPath $pendingPath) { $note = Get-QuestionNote $data $project $privacy }
                else { Write-Log 'quiet: question answered within the grace period' }
            }
        }
        { $_ -in 'Stop', 'StopFailure' } {
            # The turn is over, so any permission or question it waited on is resolved.
            Clear-Waiting $data $group
            $note = if ($_ -eq 'StopFailure') { Get-ErrorNote $data $project $privacy }
                    else { Get-TurnNote $data $project $privacy $minSeconds }
        }
    }

    if (-not $note) { exit 0 }
    if (-not (Test-Enabled $note.Type)) { Write-Log "quiet: '$($note.Type)' is not in TASK_NOTIFIER_EVENTS"; exit 0 }
    if (Test-Watching $project) { Write-Log "quiet: you are looking at Claude ($($note.Type))"; exit 0 }
    $launch = Get-LaunchUri $cwd

    if ($env:CTN_DRYRUN) {
        $flags = if ($note.Sticky) { ' sticky' } else { '' }
        $opens = if ($launch) { "`nclick opens: $launch" } else { '' }
        [Console]::Error.WriteLine("[$($note.Type): $($note.Kind)/$($note.Sound)/$($note.Tag)$flags] $($note.Title)`n$($note.Lines -join "`n")$opens`n")
        Write-Log "dry run, not shown: $($note.Type): $($note.Title)"
        exit 0
    }

    try { Show-Toast $note $group $cwdKey $project $launch; Write-Log "shown $($note.Type): $($note.Title)" }
    catch {
        Write-Log "toast failed, showing a balloon instead: $($_.Exception.Message)"
        Show-Balloon $note.Title ($note.Lines -join "`n") $note.Kind
    }
    # Answered while the toast was being shown: take it back.
    if ($note.Sticky -and -not (Test-Path -LiteralPath $pendingPath)) { Remove-Toast 'waiting' $group; Write-Log 'removed: answered while showing' }
} catch { Write-Log "error: $($_.Exception.Message)" }
exit 0
