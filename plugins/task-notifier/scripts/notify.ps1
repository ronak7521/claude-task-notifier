# Task Notifier for Claude Code: Windows notifications for Stop, StopFailure and PermissionRequest.
# Prints nothing and always exits 0, so it never blocks or changes what Claude does.
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.
#
# Optional settings (environment variables, e.g. in the "env" block of ~/.claude/settings.json):
#   TASK_NOTIFIER_MIN_SECONDS  Only notify for finished tasks that took at least this long (default 30, 0 = always)
#   TASK_NOTIFIER_PRIVACY      1 = show only the project name, never prompt, reply or command text
$ErrorActionPreference = 'SilentlyContinue'

function Shorten([string]$s, [int]$max) {
    if (-not $s) { return '' }
    # Drop Markdown heading lines (e.g. "## Done") when there is other text.
    $lines = @($s -split "`r?`n" | Where-Object { $_.Trim() })
    $body = @($lines | Where-Object { $_ -notmatch '^\s*#' })
    if ($body.Count) { $lines = $body }
    $s = (($lines -join ' ') -replace '[`*#>]', '' -replace '\s+', ' ').Trim()
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

# Last real prompt you typed (text + time), read from the end of the session transcript (JSONL).
# Skips tool results, system/meta entries and slash-command output.
function Get-LastPrompt([string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
    $lines = @(Get-Content -LiteralPath $path -Tail 400 -Encoding UTF8)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        try { $e = $lines[$i] | ConvertFrom-Json } catch { continue }
        if (-not $e -or $e.type -ne 'user' -or $e.isMeta) { continue }
        $c = $e.message.content
        if ($c -is [string]) { $text = $c }
        else { $text = (@($c) | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ' ' }
        if ($text -and -not $text.TrimStart().StartsWith('<')) {
            return [pscustomobject]@{ Text = $text; Time = (ConvertTo-Utc $e.timestamp) }
        }
    }
    return $null
}

# Number of background tasks still running. The field's exact shape is not documented,
# so accept a number or a list; items with a finished status are not counted.
function Get-RunningBackgroundCount($bg) {
    if ($null -eq $bg) { return 0 }
    if ($bg -is [int] -or $bg -is [long]) { return [int]$bg }
    $running = @(@($bg) | Where-Object {
        $st = [string]$_.status
        -not $st -or $st -notmatch '^(completed|complete|done|failed|killed|cancelled|canceled|stopped)$'
    })
    return $running.Count
}

try {
    $privacy = $env:TASK_NOTIFIER_PRIVACY -match '^(1|true|yes|on)$'
    $minSeconds = 30
    if ($env:TASK_NOTIFIER_MIN_SECONDS -match '^\d+$') { $minSeconds = [int]$env:TASK_NOTIFIER_MIN_SECONDS }

    [Console]::InputEncoding = [Text.Encoding]::UTF8
    $data = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $project = if ($data.cwd) { Split-Path -Leaf $data.cwd } else { 'Claude Code' }
    $icon = 'Info'

    switch ([string]$data.hook_event_name) {
        'PermissionRequest' {
            $icon = 'Warning'
            $title = "Claude needs permission - $project"
            $tool = if ($data.tool_name) { [string]$data.tool_name } else { 'an action' }
            $detail = ''
            if (-not $privacy) {
                if ($data.tool_input.command) { $detail = [string]$data.tool_input.command }
                elseif ($data.tool_input.file_path) { $detail = Split-Path -Leaf ([string]$data.tool_input.file_path) }
            }
            $msg = if ($detail) { "Approve ${tool}: " + (Shorten $detail 200) } else { "Approve $tool to continue" }
        }
        'StopFailure' {
            $icon = 'Error'
            $title = "Claude stopped with an error - $project"
            $err = Shorten ([string]$data.error) 80
            $details = if ($privacy) { '' } else { Shorten ([string]$data.error_details) 160 }
            $parts = @()
            if ($err) { $parts += "Error: $err" }
            if ($details) { $parts += $details }
            $msg = if ($parts.Count) { $parts -join "`n" } else { 'The task did not finish.' }
        }
        default {
            $last = Get-LastPrompt ([string]$data.transcript_path)

            # Quiet for quick answers. If the start time is unknown, notify anyway.
            if ($minSeconds -gt 0 -and $last -and $last.Time) {
                $elapsed = ([datetime]::UtcNow - $last.Time).TotalSeconds
                if ($elapsed -ge 0 -and $elapsed -lt $minSeconds) { exit 0 }
            }

            $running = Get-RunningBackgroundCount $data.background_tasks
            if ($running -gt 0) {
                $title = "Claude paused - $project"
                $suffix = if ($running -eq 1) { '' } else { 's' }
                $status = "$running background task$suffix still running"
            } else {
                $title = "Claude finished - $project"
                $status = ''
            }

            $parts = @()
            if (-not $privacy) {
                $prompt = if ($last) { Shorten $last.Text 100 } else { '' }
                $reply = Shorten ([string]$data.last_assistant_message) 120
                if ($prompt) { $parts += "Task: $prompt" }
                if ($reply) { $parts += $reply }
            }
            if ($status) { $parts += $status }
            $msg = if ($parts.Count) { $parts -join "`n" } else { 'Task completed' }
        }
    }

    $title = $title.Substring(0, [Math]::Min(63, $title.Length))
    $msg = $msg.Substring(0, [Math]::Min(255, $msg.Length))

    if ($env:CTN_DRYRUN) { [Console]::Error.WriteLine("[$icon] $title`n$msg`n"); exit 0 }

    # Text goes to the child process via environment variables, never into the
    # script itself, so prompts or file names cannot inject commands.
    $env:CTN_TITLE = $title
    $env:CTN_MSG = $msg
    $env:CTN_ICON = $icon
    $toast = @'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$icons = @{ Info = [System.Drawing.SystemIcons]::Information; Warning = [System.Drawing.SystemIcons]::Warning; Error = [System.Drawing.SystemIcons]::Error }
$n = New-Object System.Windows.Forms.NotifyIcon
$n.Icon = $icons[$env:CTN_ICON]
$n.Visible = $true
$n.ShowBalloonTip(5000, $env:CTN_TITLE, $env:CTN_MSG, [System.Windows.Forms.ToolTipIcon]$env:CTN_ICON)
Start-Sleep -Seconds 6
$n.Dispose()
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($toast))
    # Detached, so Claude Code is not kept waiting while the notification shows.
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded)
} catch { }
exit 0
