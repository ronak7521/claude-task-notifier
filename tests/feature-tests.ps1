# Feature tests for the Task Notifier plugin (Windows PowerShell 5.1).
# Run: tests\run-tests.cmd  (exit code 0 = all passed). "tests\run-tests.cmd live" also shows and removes
# one real toast to test the Windows notification plumbing.
#
# Covers every notification type, every setting and the full waiting-toast lifecycle through the real
# launcher (notify.cmd, dry-run mode), plus the helper functions and the "are you watching" check with a
# simulated screen. Keep this file ASCII-only.

. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
foreach ($fn in Get-NotifyFunctions) { . $fn }
$AppId = 'ClaudeCode.TaskNotifier'
$AppName = 'Task Notifier'
$AwaySeconds = 120
$NativeVersion = 1
$script:LogTag = 'test'
$ErrorText = @{ rate_limit = 'Rate limit reached'; server_error = 'API server error or overloaded' }

# Prompt state as if the task started $secondsAgo seconds ago.
function Set-PromptState($sandbox, [int]$secondsAgo, [string]$prompt = 'Fix the login bug', [string]$session = 'test-session-1') {
    $null = New-Item -ItemType Directory -Force -Path $sandbox.State
    $json = @{ time = [datetime]::UtcNow.AddSeconds(-$secondsAgo).ToString('o'); prompt = $prompt } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText((Join-Path $sandbox.State "$session.json"), $json)
}

# Runs one Stop hook for a task that took a minute and returns what would be shown.
function Get-StopNote($name, [hashtable]$stop, [hashtable]$envs = @{}) {
    $sb = New-Sandbox $name
    Set-PromptState $sb 60
    $r = Invoke-Hook $sb (New-Payload 'Stop' $stop) $envs
    return Get-Shown $r.Err
}

function Test-PendingFile($sandbox, [string]$session = 'test-session-1') { Test-Path (Join-Path $sandbox.State "$session.pending") }

# Temporarily set environment variables (null removes one) while running $body.
function Use-Env([hashtable]$vars, [scriptblock]$body) {
    $saved = @{}
    foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
    try { return & $body } finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
}

try {
    $null = New-Item -ItemType Directory -Force -Path $Root

    # ------------------------------------------------------------------------------------------------
    Section 'Finished, asking and paused (Stop)'

    $n = Get-StopNote 'finished' @{ last_assistant_message = "## Summary`nAll 42 tests pass now." }
    Check 'finished: type, title and toast style' ($n -and $n.Type -eq 'finished' -and $n.Title -eq 'Claude finished' -and $n.Header -eq 'shop-api' -and
        $n.Kind -eq 'Info' -and $n.Sound -eq 'Notification.Default' -and $n.Tag -eq 'turn' -and -not $n.Sticky) "$($n | Out-String)"
    Check 'finished: shows your prompt and the start of the reply' ($n.Lines[0] -eq 'Task: Fix the login bug' -and $n.Lines[1] -eq 'All 42 tests pass now.') ($n.Lines -join ' | ')
    Check 'finished: Markdown heading lines are dropped' (-not ($n.Lines -match 'Summary')) ($n.Lines -join ' | ')

    $n = Get-StopNote 'longreply' @{ last_assistant_message = ('word ' * 100) }
    Check 'finished: a long reply is cut to 120 characters' ($n.Lines[1].Length -eq 120 -and $n.Lines[1].EndsWith('...')) "length $($n.Lines[1].Length)"

    $n = Get-StopNote 'emptyreply' @{ last_assistant_message = '' }
    Check 'finished: empty reply still shows the task' ($n.Lines.Count -eq 1 -and $n.Lines[0] -eq 'Task: Fix the login bug') ($n.Lines -join ' | ')

    $sb = New-Sandbox 'nothing'
    $n = Get-Shown (Invoke-Hook $sb (New-Payload 'Stop' @{ last_assistant_message = '' })).Err
    Check 'finished: no prompt and no reply shows "Task completed"' (($n.Lines -join '|') -eq 'Task completed') ($n.Lines -join ' | ')

    foreach ($ask in @('Should I also update the docs?', '**Ready to deploy?**', 'Run `npm test` now?', 'Shall I continue? ', '(want me to commit?)')) {
        $n = Get-StopNote 'asking' @{ last_assistant_message = "I fixed the bug.`n`n$ask" }
        Check "asking: '$ask' is recognised as a question" ($n.Type -eq 'asking' -and $n.Title -eq 'Claude is asking' -and $n.Header -eq 'shop-api' -and $n.Sound -eq 'Notification.Reminder' -and -not $n.Sticky) "$($n.Type)"
    }
    $n = Get-StopNote 'askingline' @{ last_assistant_message = "Done with step 1.`nShould I also update the docs?" }
    Check 'asking: shows the question itself' ($n.Lines[-1] -eq 'Should I also update the docs?') ($n.Lines -join ' | ')
    foreach ($notAsk in @("Is it fixed? Yes.`nAll tests pass.", 'See https://example.com/?q=1 for details.', 'Done.')) {
        $n = Get-StopNote 'notasking' @{ last_assistant_message = $notAsk }
        Check "finished: '$($notAsk -replace "`n", ' / ')' is not a question" ($n.Type -eq 'finished') $n.Type
    }

    $one = @(@{ id = '1'; type = 'local_bash'; status = 'running'; description = 'npm run watch' }, @{ id = '2'; status = 'completed'; description = 'old build' })
    $n = Get-StopNote 'paused1' @{ last_assistant_message = 'Watcher started.'; background_tasks = $one }
    Check 'paused: type, title and sound' ($n.Type -eq 'paused' -and $n.Title -eq 'Claude paused' -and $n.Header -eq 'shop-api' -and $n.Sound -eq 'Notification.Default') "$($n.Type)"
    Check 'paused: names the running task, skips finished ones' ($n.Lines[-1] -eq '1 background task still running: npm run watch') ($n.Lines -join ' | ')
    $two = @(@{ status = 'running'; description = 'dev server' }, @{ status = 'pending'; command = 'pytest -x' }, @{ status = 'running'; type = 'agent' })
    $n = Get-StopNote 'paused3' @{ last_assistant_message = 'ok'; background_tasks = $two }
    Check 'paused: plural, falls back to command, then type' ($n.Lines[-1] -eq '3 background tasks still running: dev server, pytest -x, agent') ($n.Lines -join ' | ')
    $done = @(@{ status = 'completed' }, @{ status = 'failed' }, @{ status = 'killed' }, @{ status = 'CANCELLED' })
    $n = Get-StopNote 'pausednone' @{ last_assistant_message = 'All done.'; background_tasks = $done }
    Check 'finished: only finished background tasks means finished, not paused' ($n.Type -eq 'finished') $n.Type

    $sb = New-Sandbox 'nocwd'
    $p = New-Payload 'Stop' @{ last_assistant_message = 'ok' }; $p.Remove('cwd')
    $n = Get-Shown (Invoke-Hook $sb $p).Err
    Check 'no project folder: header says "Claude Code"' ($n.Title -eq 'Claude finished' -and $n.Header -eq 'Claude Code') "$($n.Title) | $($n.Header)"

    # ------------------------------------------------------------------------------------------------
    Section 'Quick answers (TASK_NOTIFIER_MIN_SECONDS)'

    $sb = New-Sandbox 'quick'
    $null = Invoke-Hook $sb (New-Payload 'UserPromptSubmit' @{ prompt = 'hi' }) @{ TASK_NOTIFIER_DEBUG = '1' }
    $r = Invoke-Hook $sb (New-Payload 'Stop' @{ last_assistant_message = 'Hello!' }) @{ TASK_NOTIFIER_DEBUG = '1' }
    Check 'default 30 s: a quick answer stays quiet' (-not (Get-Shown $r.Err)) $r.Err
    Check 'quiet quick answer is explained in the debug log' ([IO.File]::ReadAllText((Join-Path $sb.State 'debug.log')) -match 'quiet: quick answer') ''
    Check 'prompt state is saved with time and prompt' ((Get-Content (Join-Path $sb.State 'test-session-1.json') -Raw | ConvertFrom-Json).prompt -eq 'hi') ''
    Check 'a 60 s task notifies' ($null -ne (Get-StopNote 'slow' @{ last_assistant_message = 'ok' })) ''
    $sb = New-Sandbox 'unknownstart'
    Check 'unknown start time notifies anyway' ($null -ne (Get-Shown (Invoke-Hook $sb (New-Payload 'Stop' @{ last_assistant_message = 'ok' })).Err)) ''
    $sb = New-Sandbox 'min0'
    Set-PromptState $sb 1
    Check 'MIN_SECONDS=0 notifies even for a 1 s answer' ($null -ne (Get-Shown (Invoke-Hook $sb (New-Payload 'Stop' @{ last_assistant_message = 'ok' }) @{ TASK_NOTIFIER_MIN_SECONDS = ' 0 ' }).Err)) ''
    Check 'MIN_SECONDS=abc falls back to 30 (quiet for 1 s)' (-not (Get-Shown (Invoke-Hook $sb (New-Payload 'Stop' @{ last_assistant_message = 'ok' }) @{ TASK_NOTIFIER_MIN_SECONDS = 'abc' }).Err)) ''
    Check 'MIN_SECONDS=120 keeps a 60 s task quiet' ($null -eq (Get-StopNote 'min120' @{ last_assistant_message = 'ok' } @{ TASK_NOTIFIER_MIN_SECONDS = '120' })) ''
    $sb = New-Sandbox 'errquick'
    Set-PromptState $sb 1
    Check 'errors notify even for quick answers' ((Get-Shown (Invoke-Hook $sb (New-Payload 'StopFailure' @{ error = 'rate_limit' })).Err).Type -eq 'error') ''

    # ------------------------------------------------------------------------------------------------
    Section 'Errors (StopFailure)'

    function Get-ErrorShown([hashtable]$fields, [hashtable]$envs = @{}) {
        $sb = New-Sandbox 'error'
        return Get-Shown (Invoke-Hook $sb (New-Payload 'StopFailure' $fields) $envs).Err
    }
    $n = Get-ErrorShown @{ error = 'rate_limit'; last_assistant_message = 'API Error: Rate limit reached' }
    Check 'error: type, title and its own sound' ($n.Type -eq 'error' -and $n.Title -eq 'Claude stopped with an error' -and $n.Header -eq 'shop-api' -and
        $n.Kind -eq 'Error' -and $n.Sound -eq 'Notification.SMS' -and $n.Tag -eq 'error' -and -not $n.Sticky) "$($n | Out-String)"
    Check 'error: known code is readable, repeated details skipped' (($n.Lines -join '|') -eq 'Error: Rate limit reached') ($n.Lines -join ' | ')
    $n = Get-ErrorShown @{ error = 'server_error'; error_details = 'upstream connect timeout'; last_assistant_message = 'ignored' }
    Check 'error: error_details shown as second line' (($n.Lines -join '|') -eq 'Error: API server error or overloaded|upstream connect timeout') ($n.Lines -join ' | ')
    $n = Get-ErrorShown @{ error = 'brand_new_code'; last_assistant_message = 'Something odd happened' }
    Check 'error: unknown code shown as is, reply text as details' (($n.Lines -join '|') -eq 'Error: brand_new_code|Something odd happened') ($n.Lines -join ' | ')
    $n = Get-ErrorShown @{}
    Check 'error: no error code says the task did not finish' (($n.Lines -join '|') -eq 'The task did not finish.') ($n.Lines -join ' | ')

    # ------------------------------------------------------------------------------------------------
    Section 'Permission requests (sticky)'

    $bash = @{ tool_name = 'Bash'; tool_input = @{ command = 'npm publish --access public'; description = 'Publish the package' } }
    $sb = New-Sandbox 'perm'
    $r = Invoke-Hook $sb (New-Payload 'PermissionRequest' $bash)
    Check 'PermissionRequest shows nothing yet but records what it is for' ((-not (Get-Shown $r.Err)) -and (Test-PendingFile $sb)) $r.Err
    $n = Get-Shown (Invoke-Hook $sb (New-Payload 'Notification' @{ notification_type = 'permission_prompt'; message = 'Claude needs your permission to use Bash' })).Err
    Check 'permission: sticky reminder toast' ($n.Type -eq 'permission' -and $n.Title -eq 'Claude needs permission' -and $n.Header -eq 'shop-api' -and $n.Sticky -and
        $n.Sound -eq 'Notification.Reminder' -and $n.Tag -eq 'waiting' -and $n.Kind -eq 'Warning') "$($n | Out-String)"
    Check 'permission: shows the command and its description' (($n.Lines -join '|') -eq 'Approve Bash: npm publish --access public|Publish the package') ($n.Lines -join ' | ')
    $null = Invoke-Hook $sb (New-Payload 'PostToolUse' @{ tool_name = 'Read'; tool_input = @{ file_path = 'C:\x\a.txt' } }) @{} 'ifpending'
    Check 'a parallel tool call finishing does not clear the waiting toast' (Test-PendingFile $sb) ''
    $null = Invoke-Hook $sb (New-Payload 'PostToolUse' @{ tool_name = 'Bash'; tool_input = @{ command = 'ls' } }) @{} 'ifpending'
    Check 'the same tool with different input does not clear it' (Test-PendingFile $sb) ''
    $null = Invoke-Hook $sb (New-Payload 'PostToolUse' $bash) @{} 'ifpending'
    Check 'approving (PostToolUse of that call) clears the waiting toast' (-not (Test-PendingFile $sb)) ''
    Check 'and records when it was answered' (Test-Path (Join-Path $sb.State 'test-session-1.answered')) ''
    $r = Invoke-Hook $sb (New-Payload 'Notification' @{ notification_type = 'permission_prompt'; message = 'x' }) @{ TASK_NOTIFIER_DEBUG = '1' }
    Check 'a late permission Notification right after answering stays quiet' ((-not (Get-Shown $r.Err)) -and ($r.Err -match 'answered while starting up')) $r.Err

    foreach ($ev in @('PostToolUseFailure', 'PermissionDenied')) {
        $sb = New-Sandbox "perm-$ev"
        $null = Invoke-Hook $sb (New-Payload 'PermissionRequest' $bash)
        $null = Invoke-Hook $sb (New-Payload $ev $bash) @{} 'ifpending'
        Check "$ev of that call clears the waiting toast" (-not (Test-PendingFile $sb)) ''
    }

    $cases = @(
        @{ name = 'mcp tool'; req = @{ tool_name = 'mcp__github__create_issue'; tool_input = @{ title = 'x' } }; want = 'Approve create_issue (github) to continue' },
        @{ name = 'web fetch'; req = @{ tool_name = 'WebFetch'; tool_input = @{ url = 'https://example.com/a' } }; want = 'Approve WebFetch: https://example.com/a' },
        @{ name = 'file edit'; req = @{ tool_name = 'Edit'; tool_input = @{ file_path = 'C:\work\shop-api\src\app.ts' } }; want = 'Approve Edit: app.ts' }
    )
    foreach ($c in $cases) {
        $sb = New-Sandbox 'permcase'
        $null = Invoke-Hook $sb (New-Payload 'PermissionRequest' $c.req)
        $n = Get-Shown (Invoke-Hook $sb (New-Payload 'Notification' @{ notification_type = 'permission_prompt' })).Err
        Check "permission detail for a $($c.name)" ($n.Lines[0] -eq $c.want) ($n.Lines -join ' | ')
    }

    $sb = New-Sandbox 'permnorecord'
    $n = Get-Shown (Invoke-Hook $sb (New-Payload 'Notification' @{ notification_type = 'permission_prompt'; message = 'Claude needs your permission to use the network' })).Err
    Check 'permission without a PermissionRequest record shows Claude''s message' ($n.Type -eq 'permission' -and $n.Lines[0] -eq 'Claude needs your permission to use the network') ($n.Lines -join ' | ')
    Check 'and waits on any tool call ("*")' ((Get-Content (Join-Path $sb.State 'test-session-1.pending') -Raw | ConvertFrom-Json).tool -eq '*') ''
    $null = Invoke-Hook $sb (New-Payload 'PostToolUse' @{ tool_name = 'Anything' }) @{} 'ifpending'
    Check 'any tool call then clears it' (-not (Test-PendingFile $sb)) ''

    $sb = New-Sandbox 'permold'
    $null = New-Item -ItemType Directory -Force -Path $sb.State
    $old = @{ time = [datetime]::UtcNow.AddMinutes(-5).ToString('o'); tool = 'Bash'; match = 'x'; label = 'Bash'; detail = 'rm -rf old'; why = '' } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText((Join-Path $sb.State 'test-session-1.pending'), $old)
    $n = Get-Shown (Invoke-Hook $sb (New-Payload 'Notification' @{ notification_type = 'permission_prompt'; message = 'Claude needs your permission to use Bash' })).Err
    Check 'a permission record older than 2 minutes is not trusted' ($n.Lines[0] -eq 'Claude needs your permission to use Bash') ($n.Lines -join ' | ')

    # ------------------------------------------------------------------------------------------------
    Section 'Questions (AskUserQuestion, sticky)'

    $qs = @{ tool_name = 'AskUserQuestion'; tool_input = @{ questions = @(
        @{ question = 'Which database should I use?'; header = 'DB'; options = @(@{ label = 'PostgreSQL' }, @{ label = 'SQLite' }) },
        @{ question = 'Add tests?'; header = 'Tests'; options = @(@{ label = 'Yes' }) }) } }
    $sb = New-Sandbox 'question'
    $n = Get-Shown (Invoke-Hook $sb (New-Payload 'PreToolUse' $qs)).Err
    Check 'question: sticky reminder toast' ($n.Type -eq 'question' -and $n.Title -eq 'Claude has a question' -and $n.Header -eq 'shop-api' -and $n.Sticky -and $n.Tag -eq 'waiting' -and $n.Sound -eq 'Notification.Reminder') "$($n | Out-String)"
    Check 'question: first question, count of the rest, and options' (($n.Lines -join '|') -eq 'Which database should I use? (+1 more)|Options: PostgreSQL / SQLite') ($n.Lines -join ' | ')
    $null = Invoke-Hook $sb (New-Payload 'PostToolUse' $qs) @{} 'ifpending'
    Check 'answering the question clears the waiting toast' (-not (Test-PendingFile $sb)) ''
    $sb = New-Sandbox 'questionempty'
    $n = Get-Shown (Invoke-Hook $sb (New-Payload 'PreToolUse' @{ tool_name = 'AskUserQuestion'; tool_input = @{} })).Err
    Check 'question without text shows a generic line' (($n.Lines -join '|') -eq 'Answer the question in Claude Code to continue') ($n.Lines -join ' | ')
    $sb = New-Sandbox 'pretool'
    $r = Invoke-Hook $sb (New-Payload 'PreToolUse' @{ tool_name = 'Bash'; tool_input = @{ command = 'ls' } })
    Check 'other PreToolUse tools are ignored' ((-not (Get-Shown $r.Err)) -and -not (Test-PendingFile $sb)) $r.Err

    # ------------------------------------------------------------------------------------------------
    Section 'MCP input requests (sticky)'

    foreach ($t in @('elicitation_dialog', 'elicitation_url_dialog')) {
        $sb = New-Sandbox "input-$t"
        $n = Get-Shown (Invoke-Hook $sb (New-Payload 'Notification' @{ notification_type = $t; message = 'Sign in to Jira to continue' })).Err
        Check "$t`: sticky input toast with the server's message" ($n.Type -eq 'input' -and $n.Title -eq 'Claude needs your input' -and $n.Header -eq 'shop-api' -and $n.Sticky -and $n.Lines[0] -eq 'Sign in to Jira to continue') "$($n | Out-String)"
        $null = Invoke-Hook $sb (New-Payload 'PostToolUse' @{ tool_name = 'mcp__jira__search' }) @{} 'ifpending'
        Check "$t`: cleared by the next tool call" (-not (Test-PendingFile $sb)) ''
    }
    $sb = New-Sandbox 'inputempty'
    $n = Get-Shown (Invoke-Hook $sb (New-Payload 'Notification' @{ notification_type = 'elicitation_dialog' })).Err
    Check 'input without a message shows a generic line' ($n.Lines[0] -eq 'An MCP server is waiting for your input') ($n.Lines -join ' | ')
    $sb = New-Sandbox 'idle'
    $r = Invoke-Hook $sb (New-Payload 'Notification' @{ notification_type = 'idle_prompt'; message = 'Claude is waiting' })
    Check 'other notification types are ignored' ((-not (Get-Shown $r.Err)) -and -not (Test-PendingFile $sb)) $r.Err

    # ------------------------------------------------------------------------------------------------
    Section 'Waiting toast is cleared when the turn moves on'

    foreach ($ev in @('UserPromptSubmit', 'Stop', 'StopFailure', 'SessionEnd')) {
        $sb = New-Sandbox "clear-$ev"
        $null = Invoke-Hook $sb (New-Payload 'PermissionRequest' $bash)
        $arg = if ($ev -eq 'SessionEnd') { 'ifpending' } else { '' }
        $null = Invoke-Hook $sb (New-Payload $ev @{ prompt = 'next'; last_assistant_message = 'ok' }) @{} $arg
        Check "$ev clears a waiting toast" (-not (Test-PendingFile $sb)) ''
    }
    $sb = New-Sandbox 'othersession'
    $null = Invoke-Hook $sb (New-Payload 'PermissionRequest' $bash)
    $null = Invoke-Hook $sb (New-Payload 'Stop' @{ session_id = 'test-session-2'; last_assistant_message = 'ok' })
    Check 'another session ending does not clear this session''s toast' (Test-PendingFile $sb) ''

    $sb = New-Sandbox 'fastpath'
    $null = Invoke-Hook $sb (New-Payload 'PermissionRequest' $bash)
    $null = Invoke-Hook $sb (New-Payload 'PostToolUse' @{ tool_name = 'Read' }) @{ TASK_NOTIFIER_DEBUG = '1' } 'ifpending'
    Check 'with a waiting toast, tool calls do start PowerShell (to check it)' (Test-Path (Join-Path $sb.State 'debug.log')) ''

    # ------------------------------------------------------------------------------------------------
    Section 'Choosing types (TASK_NOTIFIER_EVENTS)'

    $flows = [ordered]@{
        finished   = { param($sb, $e) Set-PromptState $sb 60; Invoke-Hook $sb (New-Payload 'Stop' @{ last_assistant_message = 'ok' }) $e }
        asking     = { param($sb, $e) Set-PromptState $sb 60; Invoke-Hook $sb (New-Payload 'Stop' @{ last_assistant_message = 'Go on?' }) $e }
        paused     = { param($sb, $e) Set-PromptState $sb 60; Invoke-Hook $sb (New-Payload 'Stop' @{ last_assistant_message = 'ok'; background_tasks = @(@{ status = 'running' }) }) $e }
        error      = { param($sb, $e) Invoke-Hook $sb (New-Payload 'StopFailure' @{ error = 'rate_limit' }) $e }
        permission = { param($sb, $e) $null = Invoke-Hook $sb (New-Payload 'PermissionRequest' $bash) $e; Invoke-Hook $sb (New-Payload 'Notification' @{ notification_type = 'permission_prompt' }) $e }
        question   = { param($sb, $e) Invoke-Hook $sb (New-Payload 'PreToolUse' $qs) $e }
        input      = { param($sb, $e) Invoke-Hook $sb (New-Payload 'Notification' @{ notification_type = 'elicitation_dialog' }) $e }
    }
    foreach ($type in $flows.Keys) {
        $sb = New-Sandbox "on-$type"
        $n = Get-Shown (& $flows[$type] $sb @{ TASK_NOTIFIER_EVENTS = " $($type.ToUpper()) ; error" }).Err
        Check "EVENTS lists $type (any case, spaces, ';'): shown" ($n.Type -eq $type) "$($n.Type)"
        $other = if ($type -eq 'error') { 'finished' } else { 'error' }
        $sb = New-Sandbox "off-$type"
        $r = & $flows[$type] $sb @{ TASK_NOTIFIER_EVENTS = $other; TASK_NOTIFIER_DEBUG = '1' }
        $log = if (Test-Path (Join-Path $sb.State 'debug.log')) { [IO.File]::ReadAllText((Join-Path $sb.State 'debug.log')) } else { '' }
        Check "EVENTS without $type`: quiet" (-not (Get-Shown $r.Err)) $r.Err
        if ($type -in 'permission', 'question', 'input') {
            Check "EVENTS without $type`: records no waiting marker (tool calls stay cheap)" (-not (Test-PendingFile $sb)) ''
        } else {
            Check "EVENTS without $type`: debug log says why" ($log -match "'$type' is not in TASK_NOTIFIER_EVENTS") $log
        }
    }
    $sb = New-Sandbox 'eventsall'
    Check 'EVENTS empty or spaces: everything on' ((Get-Shown (& $flows['finished'] $sb @{ TASK_NOTIFIER_EVENTS = '   ' }).Err).Type -eq 'finished') ''

    # ------------------------------------------------------------------------------------------------
    Section 'Privacy mode (TASK_NOTIFIER_PRIVACY)'

    $priv = @{ TASK_NOTIFIER_PRIVACY = ' Yes ' }
    $expect = [ordered]@{
        finished   = 'Task completed'
        asking     = 'Claude is waiting for your answer'
        paused     = '1 background task still running'
        error      = 'Error: Rate limit reached'
        permission = 'Approve Bash to continue'
        question   = 'Answer the question in Claude Code to continue'
        input      = 'An MCP server is waiting for your input'
    }
    foreach ($type in $expect.Keys) {
        $sb = New-Sandbox "priv-$type"
        $n = Get-Shown (& $flows[$type] $sb $priv).Err
        Check "privacy $type`: only a generic line" ($n.Type -eq $type -and ($n.Lines -join '|') -eq $expect[$type]) ($n.Lines -join ' | ')
    }
    $sb = New-Sandbox 'privstate'
    $null = Invoke-Hook $sb (New-Payload 'UserPromptSubmit' @{ prompt = 'secret plan' }) $priv
    Check 'privacy: the prompt text is not saved' ((Get-Content (Join-Path $sb.State 'test-session-1.json') -Raw | ConvertFrom-Json).prompt -eq '') ''

    # ------------------------------------------------------------------------------------------------
    Section 'Click to open (launch link)'

    $sb = New-Sandbox 'launch'
    Set-PromptState $sb 60
    $n = Get-Shown (Invoke-Hook $sb (New-Payload 'Stop' @{ last_assistant_message = 'ok'; cwd = 'C:\work\my shop' }) @{ TERM_PROGRAM = 'vscode' }).Err
    Check 'VS Code: clicking opens the project folder' ($n.Launch -eq 'vscode://file/C:/work/my%20shop') $n.Launch
    $n = Get-Shown (Invoke-Hook $sb (New-Payload 'Stop' @{ last_assistant_message = 'ok' })).Err
    Check 'plain terminal: no link' ($n.Launch -eq '') $n.Launch
    foreach ($pair in @(@('Code', 'vscode'), @('Code - Insiders', 'vscode-insiders'), @('Cursor', 'cursor'), @('Windsurf', 'windsurf'), @('powershell', 'vscode'), @('', 'vscode'))) {
        Check "editor '$($pair[0])' uses $($pair[1])://" ((Get-EditorScheme $pair[0]) -eq $pair[1]) (Get-EditorScheme $pair[0])
    }
    $code = Get-Process -Name 'Code' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($code) {
        $u = Use-Env @{ VSCODE_PID = [string]$code.Id; TERM_PROGRAM = $null } { Get-LaunchUri 'C:\work\shop-api' }
        Check 'VSCODE_PID of a running VS Code gives a vscode link' ($u -eq 'vscode://file/C:/work/shop-api') $u
    } else { Skip 'VSCODE_PID of a running VS Code' 'VS Code is not running' }
    $u = Use-Env @{ VSCODE_PID = '999999999'; TERM_PROGRAM = $null } { Get-LaunchUri 'C:\work\shop-api' }
    Check 'VSCODE_PID of a process that is gone gives no link' ($u -eq '') $u
    Check 'no folder gives no link' ((Use-Env @{ TERM_PROGRAM = 'vscode' } { Get-LaunchUri '' }) -eq '') ''
    $u = Use-Env @{ TERM_PROGRAM = 'vscode'; VSCODE_PID = $null } { Get-LaunchUri '\\server\share\proj' }
    Check 'network folder gives a link without error' ($u -like 'vscode://file/*server/share/proj') $u

    # ------------------------------------------------------------------------------------------------
    Section 'Quiet while you watch (simulated screen)'

    Add-Type -TypeDefinition @'
using System;
namespace CTN {
  public static class Native {
    public static IntPtr Fg, ConsoleWnd, Owner; public static uint FgPid, Idle; public static string TitleText = "";
    public static IntPtr GetForegroundWindow() { return Fg; }
    public static uint GetWindowThreadProcessId(IntPtr h, out uint pid) { pid = FgPid; return 1; }
    public static IntPtr GetConsoleWindow() { return ConsoleWnd; }
    public static string Title(IntPtr h) { return TitleText; }
    public static IntPtr RootOwner(IntPtr h) { return Owner; }
    public static uint IdleMilliseconds() { return Idle; }
  }
}
'@
    function Set-Screen([int]$fg = 100, [int]$console = 0, [int]$owner = 0, [uint32]$procId = $PID, [string]$title = '', [uint32]$idleMs = 1000) {
        [CTN.Native]::Fg = [IntPtr]$fg; [CTN.Native]::ConsoleWnd = [IntPtr]$console; [CTN.Native]::Owner = [IntPtr]$owner
        [CTN.Native]::FgPid = $procId; [CTN.Native]::TitleText = $title; [CTN.Native]::Idle = $idleMs
    }
    $clean = @{ TASK_NOTIFIER_WHEN_FOCUSED = $null; VSCODE_PID = $null; TERM_PROGRAM = $null; WT_SESSION = $null; CTN_DRYRUN = $null; TASK_NOTIFIER_DEBUG = $null }
    function Watching([hashtable]$envs = @{}, [string]$project = 'shop-api') {
        $all = @{}; foreach ($k in $clean.Keys) { $all[$k] = $clean[$k] }; foreach ($k in $envs.Keys) { $all[$k] = $envs[$k] }
        return Use-Env $all { Test-Watching $project }
    }

    Set-Screen -fg 100 -console 100
    Check 'terminal: Claude''s console window in front -> quiet' (Watching) ''
    Check 'TASK_NOTIFIER_WHEN_FOCUSED=1 -> always notify' (-not (Watching @{ TASK_NOTIFIER_WHEN_FOCUSED = 'on' })) ''
    Set-Screen -fg 100 -console 100 -idleMs 119000
    Check 'idle 119 s -> still counts as watching' (Watching) ''
    Set-Screen -fg 100 -console 100 -idleMs 121000
    Check 'idle 2 minutes or more -> you are away, notify' (-not (Watching)) ''
    Set-Screen -fg 0 -console 100
    Check 'no window in front (lock screen) -> notify' (-not (Watching)) ''
    Set-Screen -fg 100 -console 55 -owner 100
    Check 'terminal window that owns Claude''s console in front -> quiet' (Watching) ''
    Set-Screen -fg 100 -console 55 -owner 77
    Check 'another app in front -> notify' (-not (Watching)) ''
    Set-Screen -fg 100 -procId $PID -title 'app.ts - shop-api - Visual Studio Code'
    Check 'VS Code window of this project in front -> quiet' (Watching @{ VSCODE_PID = [string]$PID }) ''
    Set-Screen -fg 100 -procId $PID -title 'index.ts - other-project - Visual Studio Code'
    Check 'VS Code window of another project in front -> notify' (-not (Watching @{ VSCODE_PID = [string]$PID })) ''
    Set-Screen -fg 100 -procId $PID -title 'shop-api - Visual Studio Code'
    Check 'a different VS Code (other VSCODE_PID) in front -> notify' (-not (Watching @{ VSCODE_PID = '4' })) ''
    Set-Screen -fg 100 -procId $PID -title 'shopXapi - Visual Studio Code'
    Check 'project name is matched literally, not as a pattern' (-not (Watching @{ VSCODE_PID = [string]$PID } 'shop.api')) ''
    Set-Screen -fg 100 -procId $PID -title 'app.ts - shop-api - Visual Studio Code'
    Check 'project "api" is not fooled by a "shop-api" window -> notify' (-not (Watching @{ VSCODE_PID = [string]$PID } 'api')) ''

    # Editor window titles: is the project a whole part of the title?
    $dash = [string][char]0x2014; $dot = [string][char]0x25CF
    $titles = @(
        @('shop-api', 'app.ts - shop-api - Visual Studio Code', $true),
        @('shop-api', 'shop-api - Visual Studio Code', $true),
        @('shop-api', "$dot app.ts - shop-api - Visual Studio Code", $true),
        @('shop-api', "$dot shop-api - Visual Studio Code", $true),
        @('shop-api', 'app.ts - shop-api [WSL: Ubuntu] - Visual Studio Code', $true),
        @('shop-api', 'app.ts - shop-api [SSH: build-box] - Visual Studio Code', $true),
        @('shop-api', 'app.ts - shop-api (Workspace) - Visual Studio Code', $true),
        @('shop-api', 'app.ts - shop-api - Work Profile - Visual Studio Code', $true),
        @('shop-api', 'app.ts - shop-api - Visual Studio Code [Administrator]', $true),
        @('shop-api', 'app.ts - shop-api - Cursor', $true),
        @('shop-api', "app.ts $dash shop-api $dash Visual Studio Code", $true),
        @('Shop-API', 'app.ts - shop-api - Visual Studio Code', $true),
        @('my - project', 'app.ts - my - project - Visual Studio Code', $true),
        @('api', 'app.ts - shop-api - Visual Studio Code', $false),
        @('api', 'app.ts - api-gateway - Visual Studio Code', $false),
        @('shop', 'app.ts - shop-api - Visual Studio Code', $false),
        @('shop-api', 'app.ts - shop-api-v2 - Visual Studio Code', $false),
        @('shop-api', 'app.ts - old shop-api - Visual Studio Code', $false),
        @('shop-api', 'Welcome - Visual Studio Code', $false),
        @('shop-api', '', $false),
        @('', 'app.ts - shop-api - Visual Studio Code', $false)
    )
    foreach ($t in $titles) {
        $got = Test-TitleShowsProject $t[1] $t[0]
        $verb = if ($t[2]) { 'matches' } else { 'does not match' }
        Check "project '$($t[0])' $verb title '$($t[1])'" ($got -eq $t[2]) "got $got"
    }
    Set-Screen -fg 100 -procId 999999999
    Check 'window of a process that is gone -> notify, no error' (-not (Watching @{ VSCODE_PID = [string]$PID })) ''
    $editor = Get-Process -Name 'Code', 'Cursor', 'Windsurf' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($editor) {
        Set-Screen -fg 100 -procId ([uint32]$editor.Id) -title 'shop-api - Visual Studio Code'
        Check 'VS Code integrated terminal (TERM_PROGRAM) with this project in front -> quiet' (Watching @{ TERM_PROGRAM = 'vscode' }) ''
        Check 'a terminal outside VS Code ignores VS Code windows -> notify' (-not (Watching)) ''
    } else { Skip 'VS Code integrated terminal' 'no VS Code, Cursor or Windsurf running' }
    $wt = Get-Process -Name 'WindowsTerminal' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($wt) {
        Set-Screen -fg 100 -console 55 -procId ([uint32]$wt.Id)
        Check 'Windows Terminal in front (WT_SESSION) -> quiet' (Watching @{ WT_SESSION = 'x' }) ''
        Check 'Windows Terminal in front, Claude not in it -> notify' (-not (Watching)) ''
    } else { Skip 'Windows Terminal' 'Windows Terminal is not running' }

    $sb = New-Sandbox 'watching-e2e'
    $r = Invoke-Hook $sb (New-Payload 'Stop' @{ last_assistant_message = 'ok' }) @{ TASK_NOTIFIER_WHEN_FOCUSED = $null; TASK_NOTIFIER_MIN_SECONDS = '0' }
    Check 'end to end: the real focus check runs without error' (($r.Exit -eq 0) -and ($r.Err -notmatch 'focus check failed')) $r.Err

    # ------------------------------------------------------------------------------------------------
    Section 'Debug log and housekeeping'

    $sb = New-Sandbox 'debug'
    Set-PromptState $sb 60
    $null = Invoke-Hook $sb (New-Payload 'Stop' @{ last_assistant_message = 'ok' }) @{ TASK_NOTIFIER_DEBUG = 'true' }
    $log = [IO.File]::ReadAllText((Join-Path $sb.State 'debug.log'))
    Check 'debug log: time, event, session and decision on each line' ($log -match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \[Stop test-ses\] received' -and $log -match 'finished: Claude finished \(shop-api\)') $log
    $sb = New-Sandbox 'nodebug'
    Set-PromptState $sb 60
    $null = Invoke-Hook $sb (New-Payload 'Stop' @{ last_assistant_message = 'ok' }) @{ TASK_NOTIFIER_DEBUG = '0' }
    Check 'TASK_NOTIFIER_DEBUG=0 writes no log' (-not (Test-Path (Join-Path $sb.State 'debug.log'))) ''

    $sb = New-Sandbox 'rotate'
    $null = New-Item -ItemType Directory -Force -Path $sb.State
    [IO.File]::WriteAllText((Join-Path $sb.State 'debug.log'), ('x' * 1100KB))
    $null = Invoke-Hook $sb (New-Payload 'UserPromptSubmit' @{ prompt = 'x' }) @{ TASK_NOTIFIER_DEBUG = '1' }
    Check 'debug log over 1 MB moves to debug.old.log' (((Get-Item (Join-Path $sb.State 'debug.old.log')).Length -ge 1MB) -and ((Get-Item (Join-Path $sb.State 'debug.log')).Length -lt 1KB)) ''

    $sb = New-Sandbox 'cleanup'
    $null = New-Item -ItemType Directory -Force -Path $sb.State
    $ages = @{ 'old.json' = (Get-Date).AddDays(-8); 'week.json' = (Get-Date).AddDays(-6); 'old.pending' = (Get-Date).AddHours(-3)
               'new.pending' = (Get-Date).AddHours(-1); 'old.answered' = (Get-Date).AddHours(-3) }
    foreach ($f in $ages.Keys) { $p = Join-Path $sb.State $f; Set-Content $p '{}'; (Get-Item $p).LastWriteTime = $ages[$f] }
    $null = Invoke-Hook $sb (New-Payload 'UserPromptSubmit' @{ prompt = 'x' })
    $left = @(Get-ChildItem $sb.State | ForEach-Object Name | Sort-Object) -join ','
    Check 'old state is cleaned up (7 days; waiting markers after 2 hours)' ($left -eq 'new.pending,test-session-1.json,week.json') $left

    $sb = New-Sandbox 'unicode'
    $cafe = 'caf' + [char]0x00E9
    $null = Invoke-Hook $sb (New-Payload 'UserPromptSubmit' @{ prompt = "Fix the $cafe menu"; cwd = "C:\work\$cafe" }) @{ TASK_NOTIFIER_MIN_SECONDS = '0'; TASK_NOTIFIER_DEBUG = '1' }
    $null = Invoke-Hook $sb (New-Payload 'Stop' @{ last_assistant_message = 'ok'; cwd = "C:\work\$cafe" }) @{ TASK_NOTIFIER_MIN_SECONDS = '0'; TASK_NOTIFIER_DEBUG = '1' }
    $state = [IO.File]::ReadAllText((Join-Path $sb.State 'test-session-1.json'), [Text.Encoding]::UTF8)
    Check 'non-English text survives (prompt state)' ($state.Contains("Fix the $cafe menu")) $state
    Check 'non-English project names survive (toast header)' ([IO.File]::ReadAllText((Join-Path $sb.State 'debug.log'), [Text.Encoding]::UTF8).Contains("Claude finished ($cafe)")) ''

    $sb = New-Sandbox 'unknown'
    $r = Invoke-Hook $sb (New-Payload 'SomeFutureEvent' @{})
    Check 'unknown hook events are ignored' ($r.Exit -eq 0 -and -not (Get-Shown $r.Err) -and -not $r.Out) $r.Err

    # ------------------------------------------------------------------------------------------------
    Section 'Helper functions'

    Check 'Test-Flag accepts 1, true, YES, " on "' (@('1', 'true', 'YES', ' on ' | Where-Object { Test-Flag $_ }).Count -eq 4) ''
    Check 'Test-Flag rejects 0, false, no, 2, empty' (@('0', 'false', 'no', '2', '' | Where-Object { Test-Flag $_ }).Count -eq 0) ''
    Check 'Shorten keeps C#, #123 and ->, strips ** and backticks' ((Shorten "**Fixed** issue #123 in C# code -> see ``app.cs``" 200) -eq 'Fixed issue #123 in C# code -> see app.cs') (Shorten "**Fixed** issue #123 in C# code -> see ``app.cs``" 200)
    Check 'Shorten strips quote markers and joins lines' ((Shorten "> quoted`n  second line" 200) -eq 'quoted second line') ''
    Check 'Shorten keeps headings when there is nothing else' ((Shorten '## Done' 50) -eq 'Done') ''
    Check 'Shorten of empty text is empty' ((Shorten '' 10) -eq '') ''
    Check 'Get-ToolLabel names MCP tools by server' ((Get-ToolLabel 'mcp__github__create_issue') -eq 'create_issue (github)' -and (Get-ToolLabel 'Bash') -eq 'Bash' -and (Get-ToolLabel '') -eq 'an action') ''
    $details = @(
        @(@{ command = 'ls'; description = 'd' }, 'ls'), @(@{ url = 'https://a' }, 'https://a'), @(@{ file_path = 'C:\a\b.txt' }, 'b.txt'),
        @(@{ notebook_path = 'C:\n\x.ipynb' }, 'x.ipynb'), @(@{ pattern = '*.ts' }, '*.ts'), @(@{ query = 'q' }, 'q'),
        @(@{ path = 'C:\a\dir' }, 'dir'), @(@{ description = 'only' }, 'only'), @(@{ other = 1 }, ''), @($null, '')
    )
    $bad = @($details | Where-Object { (Get-PermissionDetail ([pscustomobject]$_[0])) -ne $_[1] })
    Check 'Get-PermissionDetail picks the most useful field' ($bad.Count -eq 0) (($bad | ForEach-Object { $_[1] }) -join ', ')
    $h = Get-ShortHash 'abc'
    Check 'Get-ShortHash is 16 hex characters and stable' ($h -match '^[0-9a-f]{16}$' -and $h -eq (Get-ShortHash 'abc') -and $h -ne (Get-ShortHash 'abd')) $h
    Check 'Get-GroupKey ignores folder case' ((Get-GroupKey 'c:\work\a') -eq (Get-GroupKey 'C:\Work\A'.ToLowerInvariant()) -and (Get-GroupKey 'x').Length -eq 17) ''
    Check 'Get-AgeSeconds of a bad time is "very old"' ((Get-AgeSeconds 'not a date') -eq [double]::MaxValue -and (Get-AgeSeconds $null) -eq [double]::MaxValue) ''
    Check 'Get-AgeSeconds of an ISO time' ([Math]::Abs((Get-AgeSeconds ([datetime]::UtcNow.AddSeconds(-30).ToString('o'))) - 30) -lt 2) ''
    $pend = [pscustomobject]@{ tool = 'Bash'; match = (Get-ShortHash 'ls') }
    Check 'Test-PendingMatch: same tool and input' (Test-PendingMatch $pend ([pscustomobject]@{ tool_name = 'Bash'; tool_input = @{ command = 'ls' } })) ''
    Check 'Test-PendingMatch: other input or tool, or nothing waiting' (-not (Test-PendingMatch $pend ([pscustomobject]@{ tool_name = 'Bash'; tool_input = @{ command = 'pwd' } })) -and
        -not (Test-PendingMatch $pend ([pscustomobject]@{ tool_name = 'Read' })) -and -not (Test-PendingMatch $null ([pscustomobject]@{ tool_name = 'Bash' }))) ''
    Check 'Test-PendingMatch: "*" and no hash match any call of that kind' ((Test-PendingMatch ([pscustomobject]@{ tool = '*' }) ([pscustomobject]@{ tool_name = 'X' })) -and
        (Test-PendingMatch ([pscustomobject]@{ tool = 'AskUserQuestion'; match = '' }) ([pscustomobject]@{ tool_name = 'AskUserQuestion' }))) ''

    $plain = New-Note 'finished' 'T' @('a', 'b', 'c', 'd') 'Notification.Default' 'turn' 'Info' $false
    $x = [xml](Get-ToastXml $plain 'key' 'proj' '')
    Check 'toast: title plus at most 2 text lines (the rest joined)' ($x.SelectNodes('//text').Count -eq 3 -and $x.SelectNodes('//text')[2].InnerText -eq "b`nc`nd") ''
    Check 'toast: normal toast has no reminder, button or link' ((-not $x.toast.scenario) -and (-not $x.SelectNodes('//action').Count) -and (-not $x.toast.launch)) ''
    Check 'toast: sound and project header' ($x.toast.audio.src -eq 'ms-winsoundevent:Notification.Default' -and $x.toast.header.title -eq 'proj' -and $x.toast.header.id -eq 'key') ''
    $sticky = New-Note 'permission' 'T' @('a') 'Notification.Reminder' 'waiting' 'Warning' $true
    $x = [xml](Get-ToastXml $sticky 'key' 'proj' 'vscode://file/C:/p')
    Check 'toast: sticky toast is a reminder with a dismiss button' ($x.toast.scenario -eq 'reminder' -and $x.SelectNodes('//action').Count -eq 1) ''
    Check 'toast: click link opens via protocol' ($x.toast.launch -eq 'vscode://file/C:/p' -and $x.toast.activationType -eq 'protocol') ''

    # ------------------------------------------------------------------------------------------------
    Section 'Locked-down PCs and launcher problems'

    # ConstrainedLanguage mode (AppLocker / WDAC): simulated by switching the session before loading notify.ps1.
    $sb = New-Sandbox 'clm'
    $null = New-Item -ItemType Directory -Force -Path $sb.Dir
    Set-Content (Join-Path $sb.Dir 'clm.ps1') ("`$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'`r`n. '$NotifyPs1'") -Encoding ascii
    Set-Content (Join-Path $sb.Dir 'clm.cmd') ("@echo off`r`nset ""PSModulePath=""`r`n""%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""$(Join-Path $sb.Dir 'clm.ps1')""`r`n") -Encoding ascii
    Set-PromptState $sb 60
    $r = Invoke-Hook $sb (New-Payload 'Stop' @{ last_assistant_message = 'ok' }) @{} '' (Join-Path $sb.Dir 'clm.cmd')
    $problem = Join-Path $sb.State 'last-problem.txt'
    $text = if (Test-Path $problem) { Get-Content $problem -Raw } else { '' }
    Check 'restricted PowerShell (ConstrainedLanguage): exits cleanly' ($r.Exit -eq 0 -and -not (Get-Shown $r.Err) -and $r.Err -notmatch 'Exception|error') $r.Err
    Check 'restricted PowerShell: records why for the doctor' ($text -match 'ConstrainedLanguage mode' -and $text -match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d ') $text
    $r = Invoke-Hook $sb (New-Payload 'Stop' @{ last_assistant_message = 'ok' })
    Check 'the problem note is removed once a hook runs normally again' ((Get-Shown $r.Err) -and -not (Test-Path $problem)) ''

    $sb = New-Sandbox 'nopowershell'
    $r = Invoke-Hook $sb (New-Payload 'Stop' @{ last_assistant_message = 'ok' }) @{ SystemRoot = (Join-Path $sb.Dir 'no-windows') }
    $problem = Join-Path $sb.State 'last-problem.txt'
    $text = if (Test-Path $problem) { Get-Content $problem -Raw } else { '' }
    Check 'PowerShell cannot start: the launcher still exits 0 (never blocks Claude)' ($r.Exit -eq 0) "exit $($r.Exit)"
    Check 'PowerShell cannot start: the launcher records it for the doctor' ($text -match 'PowerShell could not run notify\.ps1 \(exit code \d+\)') $text

    # ------------------------------------------------------------------------------------------------
    Section 'Doctor and test commands (dry run)'

    $DoctorCmd = Join-Path $Scripts 'doctor.cmd'
    # Runs the doctor against a fake Claude config folder; returns its report.
    function Invoke-Doctor($sandbox, [hashtable]$envs = @{}, [string]$arg = '', $settings = $null, $installed = $null) {
        $config = Join-Path $sandbox.Dir 'claude-config'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $config 'plugins')
        if ($settings) { $settings | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $config 'settings.json') -Encoding ascii }
        if ($installed) { $installed | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $config 'plugins\installed_plugins.json') -Encoding ascii }
        $all = @{ CLAUDE_CONFIG_DIR = $config; TASK_NOTIFIER_WHEN_FOCUSED = $null }; foreach ($k in $envs.Keys) { $all[$k] = $envs[$k] }
        return Invoke-Hook $sandbox '' $all $arg $DoctorCmd
    }
    function Get-Install([int]$copies) {
        $list = @(1..$copies | ForEach-Object { @{ scope = 'user'; version = '1.5.0'; installPath = "C:\x\$_" } })
        return @{ version = 2; plugins = @{ 'task-notifier@ronak-plugins' = $list } }
    }

    $sb = New-Sandbox 'doctor-ok'
    Set-PromptState $sb 10
    $r = Invoke-Doctor $sb @{} '' @{ enabledPlugins = @{ 'task-notifier@ronak-plugins' = $true } } (Get-Install 1)
    Check 'doctor: runs, prints every section and a result line' ($r.Exit -eq 0 -and $r.Out -match '^Task Notifier doctor' -and
        $r.Out -match '== Plugin ==' -and $r.Out -match '== Windows notifications ==' -and $r.Out -match '== Your settings ==' -and
        $r.Out -match '== Focus check ==' -and $r.Out -match '== Test notification ==' -and $r.Out -match 'Result: \d+ problem\(s\), \d+ warning\(s\)\.') $r.Out
    Check 'doctor: reports the installed copy and running hooks' ($r.Out -match '\[OK\] Installed: task-notifier@ronak-plugins 1\.5\.0 \(user\)' -and $r.Out -match '\[OK\] The plugin''s hooks are running') $r.Out
    Check 'doctor: all types on, default 30 s, dry run shows no toast' ($r.Out -match '\[OK\] All notification types are on' -and $r.Out -match 'over 30 seconds' -and $r.Out -match 'Dry run: the test notification was not shown') $r.Out
    Check 'doctor: every finding uses the [OK]/[INFO]/[WARN]/[FAIL] format' (@($r.Out -split "\r?\n" | Where-Object { $_ -and $_ -notmatch '^(Task Notifier doctor|== .+ ==|\[(OK|INFO|WARN|FAIL)\] .+|       .*|Result: .+)$' }).Count -eq 0) $r.Out

    $sb = New-Sandbox 'doctor-nohooks'
    $r = Invoke-Doctor $sb
    Check 'doctor: no hook has run yet -> tells you to start a new session' ($r.Out -match '\[WARN\] No hook has run yet' -and $r.Out -match 'Reload Window') $r.Out
    Check 'doctor: not installed from a marketplace is explained' ($r.Out -match '\[INFO\] Not installed from a marketplace') $r.Out

    $sb = New-Sandbox 'doctor-old'
    $null = New-Item -ItemType Directory -Force -Path $sb.State
    $old = Join-Path $sb.State 'old-session.json'; Set-Content $old '{}'; (Get-Item $old).LastWriteTime = (Get-Date).AddHours(-3)
    Check 'doctor: hooks silent for a while -> suggests a new session' ((Invoke-Doctor $sb).Out -match '\[WARN\] No hook has run in the last 15 minutes') ''

    $sb = New-Sandbox 'doctor-disabled'
    $r = Invoke-Doctor $sb @{} '' @{ enabledPlugins = @{ 'task-notifier@ronak-plugins' = $false } } (Get-Install 2)
    Check 'doctor: plugin turned off -> FAIL with the enable command' ($r.Out -match '\[FAIL\] The plugin is turned off' -and $r.Out -match 'claude plugin enable task-notifier@ronak-plugins') $r.Out
    Check 'doctor: installed twice -> WARN about double notifications' ($r.Out -match '\[WARN\] Installed more than once') $r.Out

    $sb = New-Sandbox 'doctor-events'
    $r = Invoke-Doctor $sb @{ TASK_NOTIFIER_EVENTS = 'nonsense' }
    Check 'doctor: EVENTS turns everything off -> FAIL listing valid names' ($r.Out -match '\[FAIL\] TASK_NOTIFIER_EVENTS turns every notification off' -and $r.Out -match 'finished, asking, paused') $r.Out
    $r = Invoke-Doctor $sb @{ TASK_NOTIFIER_EVENTS = 'permission,question' }
    Check 'doctor: EVENTS with some types -> lists what is off' ($r.Out -match '\[INFO\] Turned off by TASK_NOTIFIER_EVENTS: finished, asking, paused, error, input\.') $r.Out

    $sb = New-Sandbox 'doctor-settings'
    $r = Invoke-Doctor $sb @{ TASK_NOTIFIER_MIN_SECONDS = '900'; TASK_NOTIFIER_PRIVACY = '1' } '' @{ env = @{ TASK_NOTIFIER_MIN_SECONDS = '60'; TASK_NOTIFIER_PRIVACY = '1' } }
    Check 'doctor: very high MIN_SECONDS -> WARN' ($r.Out -match '\[WARN\] Finished notifications only for tasks over 900 seconds') $r.Out
    Check 'doctor: settings.json changed but session not restarted -> WARN' ($r.Out -match '\[WARN\] TASK_NOTIFIER_MIN_SECONDS is "60" in settings.json but "900" in this session') $r.Out
    Check 'doctor: matching settings are not reported as changed' ($r.Out -notmatch 'TASK_NOTIFIER_PRIVACY is "') $r.Out
    Check 'doctor: privacy mode is mentioned' ($r.Out -match '\[INFO\] Privacy mode is on') $r.Out
    $r = Invoke-Doctor $sb @{ TASK_NOTIFIER_DEBUG = '1' }
    Check 'doctor: a setting from outside settings.json is INFO, not "start a new session"' ($r.Out -match '\[INFO\] TASK_NOTIFIER_DEBUG is "1", set outside' -and $r.Out -notmatch '\[WARN\] TASK_NOTIFIER_DEBUG') $r.Out

    $sb = New-Sandbox 'doctor-projects'
    $inst = @{ version = 2; plugins = @{ 'task-notifier@ronak-plugins' = @(
        @{ scope = 'user'; version = '1.5.0' }, @{ scope = 'project'; version = '1.4.0'; projectPath = 'C:\some\other\project' }) } }
    $r = Invoke-Doctor $sb @{} '' $null $inst
    Check 'doctor: a project install for another folder does not count as a second copy' (($r.Out -notmatch 'Installed more than once') -and
        ($r.Out -match '(?m)^\[OK\] Installed: task-notifier@ronak-plugins 1\.5\.0 \(user\)\r?$')) $r.Out

    $doctorSrc = Get-Content (Join-Path $Scripts 'doctor.ps1') -Raw
    Check 'doctor: does not inherit notify.ps1''s silenced errors' ($doctorSrc -match '(?s)AssignmentStatementAst.*?\$ErrorActionPreference = ''Continue''') ''

    $sb = New-Sandbox 'doctor-problem'
    $null = New-Item -ItemType Directory -Force -Path $sb.State
    Set-Content (Join-Path $sb.State 'last-problem.txt') '2026-01-01 10:00:00 PowerShell could not run notify.ps1 (exit code 1).'
    Check 'doctor: a recorded hook problem -> FAIL with the reason' ((Invoke-Doctor $sb).Out -match '\[FAIL\] A hook could not notify: 2026-01-01 10:00:00 PowerShell could not run') ''

    $sb = New-Sandbox 'doctor-debuglog'
    $null = New-Item -ItemType Directory -Force -Path $sb.State
    Set-Content (Join-Path $sb.State 'debug.log') '2026-01-01 10:00:00 [Stop abc] quiet: quick answer (3 s)'
    Check 'doctor: shows the last debug log lines' ((Invoke-Doctor $sb).Out -match '       2026-01-01 10:00:00 \[Stop abc\] quiet: quick answer') ''

    $sb = New-Sandbox 'doctor-test'
    $r = Invoke-Doctor $sb @{} 'test'
    Check '/task-notifier:test: only Windows checks and the test notification' ($r.Out -match '== Windows notifications ==' -and $r.Out -match '== Test notification ==' -and
        $r.Out -notmatch '== Plugin ==' -and $r.Out -notmatch '== Your settings ==' -and $r.Exit -eq 0) $r.Out
    $r = Invoke-Doctor $sb @{} '"test & echo INJECTED"'
    Check 'doctor launcher passes on nothing but the word "test"' ($r.Out -notmatch 'INJECTED' -and $r.Out -match '== Plugin ==') $r.Out

    $sb = New-Sandbox 'doctor-clm'
    Set-Content (Join-Path $sb.Dir 'dclm.ps1') ("`$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'`r`n. '$(Join-Path $Scripts 'doctor.ps1')'") -Encoding ascii
    Set-Content (Join-Path $sb.Dir 'dclm.cmd') ("@echo off`r`nset ""PSModulePath=""`r`n""%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""$(Join-Path $sb.Dir 'dclm.ps1')""`r`n") -Encoding ascii
    $r = Invoke-Hook $sb '' @{} '' (Join-Path $sb.Dir 'dclm.cmd')
    Check 'doctor on restricted PowerShell: explains it instead of crashing' ($r.Exit -eq 0 -and $r.Out -match '\[FAIL\] PowerShell runs in ConstrainedLanguage mode' -and $r.Out -match 'Result: 1 problem') "$($r.Out) $($r.Err)"

    # ------------------------------------------------------------------------------------------------
    Section 'Plugin files'

    $hooks = (Get-Content (Join-Path $Plugin 'hooks\hooks.json') -Raw | ConvertFrom-Json).hooks
    $want = [ordered]@{
        UserPromptSubmit = @('', $true, ''); PermissionRequest = @('', $true, ''); PreToolUse = @('AskUserQuestion', $true, '')
        Notification = @('permission_prompt|elicitation_dialog|elicitation_url_dialog', $true, '')
        PostToolUse = @('', $true, 'ifpending'); PostToolUseFailure = @('', $true, 'ifpending'); PermissionDenied = @('', $true, 'ifpending')
        SessionEnd = @('', $false, 'ifpending'); Stop = @('', $true, ''); StopFailure = @('', $true, '')
    }
    # Only SessionEnd may make Claude wait (and only while a waiting toast exists); everything else runs in the background.
    foreach ($ev in $want.Keys) {
        $g = @($hooks.$ev); $h = if ($g.Count) { @($g[0].hooks)[0] } else { $null }
        $ok = $h -and $g.Count -eq 1 -and ([string]$g[0].matcher -eq $want[$ev][0]) -and ([bool]$h.async -eq $want[$ev][1]) -and
              ($h.command -eq 'cmd.exe') -and ($h.args[2] -eq '${CLAUDE_PLUGIN_ROOT}\scripts\notify.cmd') -and ([string]$h.args[3] -eq $want[$ev][2]) -and
              ($want[$ev][1] -or $h.timeout -eq 10)
        Check "hooks.json: $ev (matcher, async/timeout, launcher)" $ok ($g | ConvertTo-Json -Depth 5 -Compress)
    }
    Check 'hooks.json: no unexpected hooks' (@($hooks.PSObject.Properties.Name).Count -eq $want.Count) (@($hooks.PSObject.Properties.Name) -join ', ')
    $manifest = Get-Content (Join-Path $Plugin '.claude-plugin\plugin.json') -Raw | ConvertFrom-Json
    $market = Get-Content (Join-Path $Repo '.claude-plugin\marketplace.json') -Raw | ConvertFrom-Json
    Check 'plugin.json: name and version' ($manifest.name -eq 'task-notifier' -and $manifest.version -match '^\d+\.\d+\.\d+$') $manifest.version
    Check 'marketplace.json lists the plugin folder' (@($market.plugins | Where-Object { $_.name -eq 'task-notifier' -and $_.source -match 'plugins/task-notifier' }).Count -eq 1) ''
    Check 'plugin icon exists' (Test-Path (Join-Path $Plugin '.claude-plugin\icon.png')) ''
    $readme = Get-Content (Join-Path $Repo 'README.md') -Raw
    $settings = @([regex]::Matches((Get-Content $NotifyPs1 -Raw), '\$env:(TASK_NOTIFIER_\w+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $undocumented = @($settings | Where-Object { $readme -notmatch "``$_``" })
    Check "README documents every setting the script reads ($($settings.Count))" ($settings.Count -ge 5 -and $undocumented.Count -eq 0) ($undocumented -join ', ')
    $pluginReadme = Get-Content (Join-Path $Plugin 'README.md') -Raw
    Check 'plugin folder README links to the full README and the changelog' ($pluginReadme -match 'github\.com/ronak7521/claude-task-notifier#readme' -and $pluginReadme -match 'CHANGELOG\.md') ''
    # Strip CR: a checkout with core.autocrlf=true (the default on Windows and on GitHub's runner) has CRLF, and (?m)$ does not match before \r.
    $changelog = (Get-Content (Join-Path $Repo 'CHANGELOG.md') -Raw) -replace '\r', ''
    Check "CHANGELOG has an entry for the current version $($manifest.version)" ($changelog -match "(?m)^## $([regex]::Escape($manifest.version)) - \d{4}-\d\d-\d\d$") ''
    $attrs = Get-Content (Join-Path $Repo '.gitattributes') -Raw
    Check '.gitattributes keeps .cmd files in CRLF' ($attrs -match '(?m)^\*\.cmd\s+text\s+eol=crlf') ''
    $badLf = @(Get-ChildItem -Path $Repo -Recurse -Filter '*.cmd' | Where-Object { $_.FullName -notmatch '\\\.git\\' } |
        Where-Object { [IO.File]::ReadAllText($_.FullName) -match '(?<!\r)\n' } | ForEach-Object Name)
    Check 'every .cmd file in the working copy has CRLF line endings' ($badLf.Count -eq 0) ($badLf -join ', ')
    $workflow = Get-Content (Join-Path $Repo '.github\workflows\tests.yml') -Raw
    Check 'GitHub workflow runs the tests on Windows' ($workflow -match 'runs-on:\s*windows-' -and $workflow -match 'run:\s*tests\\run-tests\.cmd' -and $workflow -match 'pull_request') ''
    foreach ($skill in @(@('doctor', $false, ''), @('test', $true, ' test'))) {
        $md = (Get-Content (Join-Path $Plugin "skills\$($skill[0])\SKILL.md") -Raw) -replace '\r', ''
        $front = [regex]::Match($md, '(?s)^---\n(.*?)\n---').Groups[1].Value
        $ok = ($front -match "(?m)^name: $($skill[0])$") -and ($front -match '(?m)^description: \S') -and
              (($front -match '(?m)^disable-model-invocation: true$') -eq $skill[1]) -and
              $md.Contains('"${CLAUDE_PLUGIN_ROOT}/scripts/doctor.cmd"' + $skill[2])
        Check "skill /task-notifier:$($skill[0]): front matter and launcher" $ok $front
    }
    Check 'README documents the slash commands' ($readme -match '/task-notifier:doctor' -and $readme -match '/task-notifier:test') ''

    # ------------------------------------------------------------------------------------------------
    if ($env:CTN_TEST_LIVE -eq '1') {
        Section 'Live Windows toast (shows one toast briefly)'
        Initialize-Toasts
        $history = [Windows.UI.Notifications.ToastNotificationManager]::History
        $group = 'ctn-selftest'
        function Register-App { }   # never touch the registry from a test
        function Count-Live { @($history.GetHistory($AppId) | Where-Object { $_.Group -eq $group }).Count }
        $live = New-Note 'finished' 'Task Notifier self-test' @('This toast removes itself.') 'Notification.Default' 'turn' 'Info' $false
        Show-Toast $live $group 'ctn-selftest' 'Task Notifier tests' ''
        Check 'live: toast reaches the notification center' ((Count-Live) -eq 1) ''
        Show-Toast $live $group 'ctn-selftest' 'Task Notifier tests' ''
        Check 'live: same tag and group replaces it (no pile-up)' ((Count-Live) -eq 1) ''
        Remove-Toast 'turn' $group
        Check 'live: Remove-Toast takes it back' ((Count-Live) -eq 0) ''
        $key = "HKCU:\Software\Classes\AppUserModelId\$AppId"
        if (Test-Path $key) {
            $reg = Get-ItemProperty $key
            Check 'live: registered app name and settings entry' ($reg.DisplayName -eq $AppName -and $reg.ShowInSettings -eq 1) ''
        } else { Skip 'live: registry entry' 'not registered yet (no toast shown by the plugin so far)' }
    } else { Skip 'live Windows toast' 'run "tests\run-tests.cmd live" to include it' }
}
catch {
    $script:Failed++
    Write-Host "FAIL  test run aborted: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
}
Complete-Tests
