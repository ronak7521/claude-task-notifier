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
#   TASK_NOTIFIER_MIN_SECONDS  Only notify for finished tasks that took at least this long (default 30, 0 = always)
#   TASK_NOTIFIER_PRIVACY      1 = show only the project name, never prompt, reply, command or question text
# Testing: set CTN_DRYRUN=1 to print the notification to stderr instead of showing it.
#
# Toasts are shown under their own app id. Windows only gives an unpackaged app a name and icon when the
# id is registered, so this writes HKCU\Software\Classes\AppUserModelId\ClaudeCode.TaskNotifier (no admin).
$ErrorActionPreference = 'SilentlyContinue'

$AppId = 'ClaudeCode.TaskNotifier'
$AppName = 'Task Notifier'
$StateDir = Join-Path $env:TEMP 'claude-task-notifier'
$WaitSeconds = 6

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

function Format-Xml([string]$s) { return [Security.SecurityElement]::Escape($s) }

# Modern toast, kept in the notification center (Win+N) under a header per project.
# Same tag + group replaces the older toast, so each project keeps only its latest toast of each kind.
# Sticky toasts use the reminder scenario: they stay on screen until clicked or dismissed.
# All text is XML-escaped, so prompts or file names cannot change the toast markup.
function Show-Toast($note, [string]$group, [string]$cwdKey, [string]$project) {
    $ErrorActionPreference = 'Stop'
    Register-App
    Initialize-Toasts

    # A toast shows the title plus at most two text lines.
    $lines = @($note.Lines)
    if ($lines.Count -gt 2) { $lines = @($lines[0], (($lines[1..($lines.Count - 1)]) -join "`n")) }
    $texts = (@($note.Title) + $lines | ForEach-Object { "<text>$(Format-Xml $_)</text>" }) -join ''
    $scenario = if ($note.Sticky) { ' scenario="reminder"' } else { '' }
    # Windows 11 only keeps a reminder on screen when it has a button.
    $actions = if ($note.Sticky) { '<actions><action activationType="system" arguments="dismiss" content=""/></actions>' } else { '' }
    $hid = Format-Xml $cwdKey
    $xml = "<toast$scenario>" +
        "<visual><binding template=`"ToastGeneric`">$texts</binding></visual>" +
        "<audio src=`"ms-winsoundevent:$($note.Sound)`"/>" + $actions +
        "<header id=`"$hid`" title=`"$(Format-Xml $project)`" arguments=`"$hid`"/>" +
        '</toast>'

    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($xml)
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

function New-Note($title, $lines, $sound, $tag, $kind, [bool]$sticky) {
    return [pscustomobject]@{ Title = $title; Lines = @($lines | Where-Object { $_ }); Sound = $sound; Tag = $tag; Kind = $kind; Sticky = $sticky }
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

function Get-PermissionNote($data, $pending, [string]$project) {
    $lines = @()
    # Only trust a recent record, so an old permission is never shown for a different prompt.
    if ($pending -and $pending.tool -ne '*' -and (Get-AgeSeconds $pending.time) -lt 120) {
        $lines += if ($pending.detail) { "Approve $($pending.label): $($pending.detail)" } else { "Approve $($pending.label) to continue" }
        $lines += $pending.why
    } elseif ($data.message) {
        $lines += Shorten ([string]$data.message) 200
    } else {
        $lines += 'Approve the request in Claude Code to continue'
    }
    return New-Note "Claude needs permission - $project" $lines 'Notification.Reminder' 'waiting' 'Warning' $true
}

function Get-InputNote($data, [string]$project, [bool]$privacy) {
    $lines = @()
    if (-not $privacy -and $data.message) { $lines += Shorten ([string]$data.message) 200 }
    if (-not $lines.Count) { $lines += 'An MCP server is waiting for your input' }
    return New-Note "Claude needs your input - $project" $lines 'Notification.Reminder' 'waiting' 'Warning' $true
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
    return New-Note "Claude has a question - $project" $lines 'Notification.Reminder' 'waiting' 'Warning' $true
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
    return New-Note "Claude stopped with an error - $project" $lines 'Notification.SMS' 'error' 'Error' $false
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
        if ($elapsed -ge 0 -and $elapsed -lt $minSeconds) { return $null }
    }

    $reply = [string]$data.last_assistant_message
    $lastLine = @($reply -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1
    $asking = [bool]($lastLine -and (($lastLine -replace '[\s\*_`)"]+$', '') -match '\?$'))
    $running = Get-RunningBackgroundTasks $data.background_tasks

    $lines = @()
    if (-not $privacy -and $last) { $lines += if ($last.Text) { 'Task: ' + (Shorten $last.Text 100) } }

    if ($running.Count) {
        $title = "Claude paused - $project"; $sound = 'Notification.Default'
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
        $title = "Claude is asking - $project"; $sound = 'Notification.Reminder'
        if (-not $privacy) { $lines += Shorten $lastLine 160 }
    } else {
        $title = "Claude finished - $project"; $sound = 'Notification.Default'
        if (-not $privacy) { $lines += Shorten $reply 120 }
    }
    if (-not @($lines | Where-Object { $_ }).Count) { $lines += if ($asking) { 'Claude is waiting for your answer' } else { 'Task completed' } }
    return New-Note $title $lines $sound 'turn' 'Info' $false
}

# --- Main ---

try {
    $privacy = $env:TASK_NOTIFIER_PRIVACY -match '^(1|true|yes|on)$'
    $minSeconds = 30
    if ($env:TASK_NOTIFIER_MIN_SECONDS -match '^\d+$') { $minSeconds = [int]$env:TASK_NOTIFIER_MIN_SECONDS }

    [Console]::InputEncoding = [Text.Encoding]::UTF8
    $data = [Console]::In.ReadToEnd() | ConvertFrom-Json
    if (-not $data) { exit 0 }

    $cwd = [string]$data.cwd
    $project = if ($cwd) { Split-Path -Leaf $cwd } else { 'Claude Code' }
    $cwdKey = if ($cwd) { $cwd.ToLowerInvariant() } else { 'claude-code' }
    $group = Get-GroupKey $cwdKey
    $pendingPath = Get-StatePath $data.session_id 'pending'
    $note = $null

    switch ([string]$data.hook_event_name) {
        'UserPromptSubmit' {
            Save-PromptState $data $privacy
            Clear-Waiting $data $group
        }
        'PermissionRequest' { Save-PermissionState $data $pendingPath $privacy }
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
                    $pending = Read-State $pendingPath
                    if ($pending) { $note = Get-PermissionNote $data $pending $project }
                    elseif ((Get-AgeSeconds (Read-State (Get-StatePath $data.session_id 'answered')).time) -gt 15) {
                        # Nothing recorded and nothing just answered: a prompt without PermissionRequest,
                        # such as a sandboxed command's network request. Any tool call ends it.
                        Write-Pending $pendingPath '*' '' '' '' ''
                        $note = Get-PermissionNote $data $null $project
                    }
                    # Otherwise it was answered while this process started: no toast.
                }
                { $_ -in 'elicitation_dialog', 'elicitation_url_dialog' } {
                    Write-Pending $pendingPath '*' '' '' '' ''
                    $note = Get-InputNote $data $project $privacy
                }
            }
        }
        'PreToolUse' {
            if ([string]$data.tool_name -eq 'AskUserQuestion') {
                # Same ~6 s grace as permission prompts: answering sooner (PostToolUse removes the
                # marker) means you are at the screen, so no toast.
                Write-Pending $pendingPath 'AskUserQuestion' '' '' '' ''
                if (-not $env:CTN_DRYRUN) {
                    Start-Sleep -Milliseconds ([Math]::Max(0, $WaitSeconds * 1000 - 1500))
                }
                if (Test-Path -LiteralPath $pendingPath) { $note = Get-QuestionNote $data $project $privacy }
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

    if ($env:CTN_DRYRUN) {
        $flags = if ($note.Sticky) { ' sticky' } else { '' }
        [Console]::Error.WriteLine("[$($note.Kind)/$($note.Sound)/$($note.Tag)$flags] $($note.Title)`n$($note.Lines -join "`n")`n")
        exit 0
    }

    try { Show-Toast $note $group $cwdKey $project }
    catch { Show-Balloon $note.Title ($note.Lines -join "`n") $note.Kind }
    # Answered while the toast was being shown: take it back.
    if ($note.Sticky -and -not (Test-Path -LiteralPath $pendingPath)) { Remove-Toast 'waiting' $group }
} catch { }
exit 0
