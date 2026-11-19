# Security tests for the Task Notifier plugin (Windows PowerShell 5.1).
# Run: tests\run-tests.cmd  (exit code 0 = all passed)
#
# Hook input comes from Claude Code, but it carries text you and Claude wrote: prompts, replies, commands,
# file names. These tests feed hostile values through the real launcher (notify.cmd, dry-run mode) and
# through the script's own functions, and check that nothing is executed, escapes its folder or leaks.
# Keep this file ASCII-only.

. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$Secret = 'S3CR3T-7f2a'

# Every hook event, each carrying the secret in every free-text field Claude Code sends.
function Get-SecretFlow {
    return @(
        (New-Payload 'UserPromptSubmit' @{ prompt = "deploy with token $Secret" }),
        (New-Payload 'PermissionRequest' @{ tool_name = 'Bash'; tool_input = @{ command = "curl -H 'Authorization: $Secret' x"; description = "Upload $Secret" } }),
        (New-Payload 'Notification' @{ notification_type = 'permission_prompt'; message = "Claude needs your permission to use Bash $Secret" }),
        # Permission prompt with no earlier PermissionRequest record: the fallback text path.
        (New-Payload 'Notification' @{ session_id = 'sec-test-2'; notification_type = 'permission_prompt'; message = "Claude needs your permission to use $Secret" }),
        (New-Payload 'PreToolUse' @{ tool_name = 'AskUserQuestion'; tool_input = @{ questions = @(@{ question = "Use $Secret?"; header = 'Key'; options = @(@{ label = "Yes $Secret" }, @{ label = 'No' }) }) } }),
        (New-Payload 'Notification' @{ notification_type = 'elicitation_dialog'; message = "Enter $Secret" }),
        (New-Payload 'StopFailure' @{ error = 'unknown'; error_details = "failed at $Secret"; last_assistant_message = "Tried $Secret" }),
        (New-Payload 'Stop' @{ last_assistant_message = "Done, the key is $Secret" })
    )
}

# Load notify.ps1's functions without running its main block.
foreach ($fn in Get-NotifyFunctions) { . $fn }
$AppId = 'ClaudeCode.TaskNotifier'
$NativeVersion = 1
$script:LogTag = 'test'

try {
    $null = New-Item -ItemType Directory -Force -Path $Root

    Section 'Hostile hook input'

    $sb = New-Sandbox 'malformed'
    foreach ($bad in @('', '{not json', '[]', 'null', '{"hook_event_name":"Stop","session_id":{"a":1}}', ('{"x":"' + ('A' * 300000) + '"}'))) {
        $r = Invoke-Hook $sb $bad
        Check "malformed input (length $($bad.Length)) exits 0 and prints nothing to stdout" ($r.Exit -eq 0 -and -not $r.Out) "exit=$($r.Exit) out=$($r.Out)"
    }
    $r = Invoke-Hook $sb (New-Payload 'Stop' @{ last_assistant_message = ('x' * 2MB) }) @{ TASK_NOTIFIER_MIN_SECONDS = '0' }
    $longest = ($r.Err -split "`n" | Measure-Object -Maximum -Property Length).Maximum
    Check 'a 2 MB reply is handled in time and shortened' ($r.Exit -eq 0 -and -not $r.TimedOut -and $longest -le 200) "exit=$($r.Exit) longest line=$longest"

    $sb = New-Sandbox 'unwritable'
    $r = Invoke-Hook $sb (New-Payload 'UserPromptSubmit' @{ prompt = 'x' }) @{ TEMP = 'Q:\does\not\exist'; TMP = 'Q:\does\not\exist'; TASK_NOTIFIER_DEBUG = '1' }
    Check 'unusable TEMP folder still exits 0 (never blocks Claude)' ($r.Exit -eq 0) "exit=$($r.Exit)"

    Section 'Path traversal in session_id'

    $StateDir = Join-Path $Root 'unit\state'
    foreach ($id in @('..\..\..\Windows\win', '../../etc/x', 'C:\Windows\System32\evil', 'abc:stream', 'a b\..\c', '%TEMP%', '', '....')) {
        $path = Get-StatePath $id 'json'
        $ok = ((Split-Path -Parent $path) -eq $StateDir) -and ((Split-Path -Leaf $path) -match '^[A-Za-z0-9_-]+\.json$')
        Check "session_id '$id' stays inside the state folder" $ok "got $path"
    }
    $sb = New-Sandbox 'traversal'
    foreach ($id in @('..\..\escaped', '..\..\..\escaped', 'C:\escaped')) {
        foreach ($ev in @('UserPromptSubmit', 'PermissionRequest')) {
            $payload = New-Payload $ev @{ session_id = $id; prompt = 'x'; tool_name = 'Bash'; tool_input = @{ command = 'ls' } }
            $null = Invoke-Hook $sb $payload
        }
    }
    $outside = @(Get-ChildItem -LiteralPath $sb.Dir -Recurse -File | Where-Object { -not $_.FullName.StartsWith($sb.State + '\') -and $_.Name -notlike '__PSScriptPolicyTest_*' })
    $escaped = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*escaped*' | Where-Object { $_.DirectoryName -ne $sb.State }) +
               @(Get-ChildItem -LiteralPath 'C:\' -File -Filter 'escaped*')
    Check 'hook runs with traversal session_ids write only inside the state folder' ($outside.Count -eq 0 -and $escaped.Count -eq 0) (($outside + $escaped | ForEach-Object FullName) -join ', ')

    Section 'Toast XML injection'

    $evilLines = @(
        '</text><action activationType="protocol" arguments="file:///C:/Windows/System32/calc.exe" content="x"/><text>',
        '<!DOCTYPE t [<!ENTITY e "boom">]> &e; <![CDATA[ ]]> &amp; ''"<>'
    )
    $note = New-Note 'finished' 'Claude finished - x"/><toast launch="evil:">' $evilLines 'Notification.Default' 'turn' 'Info' $true
    $project = 'p"><header id="z'
    $cwdKey = 'k"/><action activationType="protocol" arguments="evil:"/>'
    $launch = 'vscode://file/C:/a" activationType="foreground'
    $xmlText = Get-ToastXml $note $cwdKey $project $launch
    $xml = New-Object Xml.XmlDocument
    $xml.XmlResolver = $null
    try { $xml.LoadXml($xmlText); $parsed = $true } catch { $parsed = $false }
    Check 'toast XML with hostile text is still well-formed' $parsed $xmlText
    if ($parsed) {
        $texts = @($xml.SelectNodes('//text') | ForEach-Object InnerText)
        Check 'hostile title and lines stay literal text' (($texts.Count -eq 3) -and ($texts[0] -eq $note.Title) -and ($texts[1] -eq $evilLines[0]) -and ($texts[2] -eq $evilLines[1])) ($texts -join ' | ')
        $actions = @($xml.SelectNodes('//action'))
        Check 'no injected action buttons (only the dismiss button)' (($actions.Count -eq 1) -and ($actions[0].activationType -eq 'system')) $xmlText
        Check 'no DOCTYPE or entity reaches the toast' ($null -eq $xml.DocumentType -and $xmlText -notmatch '<!DOCTYPE') $xmlText
        Check 'launch attribute holds exactly the given link' (($xml.DocumentElement.launch -eq $launch) -and ($xml.DocumentElement.activationType -eq 'protocol')) $xml.DocumentElement.OuterXml.Substring(0, 120)
        Check 'header title and id hold exactly the given values' (($xml.toast.header.title -eq $project) -and ($xml.toast.header.id -eq $cwdKey) -and (@($xml.SelectNodes('//header')).Count -eq 1)) ''
    }
    try {
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $winDoc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $winDoc.LoadXml($xmlText)
        Check 'Windows toast parser accepts the escaped XML' ($winDoc.GetElementsByTagName('text').Length -eq 3) ''
    } catch { Check 'Windows toast parser accepts the escaped XML' $false $_.Exception.Message }

    Section 'Click link (launch URI)'

    $savedPid = $env:VSCODE_PID; $savedTerm = $env:TERM_PROGRAM
    try {
        foreach ($v in @('abc', '123; calc', '$(calc)', '-5', '99999999999', '1e3', '0x10', '')) {
            $env:VSCODE_PID = $v
            $got = try { Get-EditorPid } catch { 'error: ' + $_.Exception.Message }
            Check "VSCODE_PID '$v' is rejected" ($got -eq -1) "got $got"
        }
        $env:VSCODE_PID = ' 42 '
        Check 'VSCODE_PID with spaces around a number is accepted' ((Get-EditorPid) -eq 42) ''

        $env:VSCODE_PID = 'abc & calc'; $env:TERM_PROGRAM = $null
        $uri = $null; $threw = $false
        try { $uri = Get-LaunchUri 'C:\work\shop-api' } catch { $threw = $true }
        Check 'bad VSCODE_PID gives no link and does not throw' ((-not $threw) -and ($uri -eq '')) "uri=$uri"

        $env:VSCODE_PID = [string]$PID
        Check 'a non-editor VSCODE_PID process still only gets a fixed scheme' ((Get-LaunchUri 'C:\w') -like 'vscode://file/*') (Get-LaunchUri 'C:\w')

        $env:VSCODE_PID = $null; $env:TERM_PROGRAM = 'vscode'
        $cwd = 'C:\work\a #1?x=%41&b\it''s "q" <x>'
        $uri = Get-LaunchUri $cwd
        $u = [Uri]$uri
        $roundTrip = [Uri]::UnescapeDataString($uri.Substring('vscode://file/'.Length))
        Check 'special characters in the folder are escaped' (($uri -notmatch '[#?" <>]') -and ($u.Query -eq '') -and ($u.Fragment -eq '')) $uri
        Check 'escaped link still points to the same folder' ($roundTrip -eq ($cwd -replace '\\', '/')) $roundTrip
        Check 'drive letter stays readable' ($uri -like 'vscode://file/C:/work/*') $uri

        $env:TERM_PROGRAM = $null
        Check 'plain terminal gets no link' ((Get-LaunchUri 'C:\w') -eq '') ''
    } finally { $env:VSCODE_PID = $savedPid; $env:TERM_PROGRAM = $savedTerm }

    $sb = New-Sandbox 'badpid'
    $r = Invoke-Hook $sb (New-Payload 'Stop' @{ last_assistant_message = 'ok' }) @{ TASK_NOTIFIER_MIN_SECONDS = '0'; VSCODE_PID = '1; calc' }
    Check 'end to end: bad VSCODE_PID still shows the notification' ($r.Err -match 'Claude finished') $r.Err

    Section 'Command and variable injection'

    $sb = New-Sandbox 'inject'
    $evil = '$(New-Item -Path X_PWNED_A) `$env:USERNAME %USERNAME% & echo X_PWNED_B > x.txt | calc ;"'''
    $null = Invoke-Hook $sb (New-Payload 'UserPromptSubmit' @{ prompt = $evil })
    $r = Invoke-Hook $sb (New-Payload 'Stop' @{ last_assistant_message = $evil }) @{ TASK_NOTIFIER_MIN_SECONDS = '0' }
    Check 'prompt and reply text is shown literally, never evaluated' (($r.Err -match [regex]::Escape('$(New-Item -Path X_PWNED_A)')) -and ($r.Err -match '%USERNAME%') -and ($r.Err -notmatch "\b$([regex]::Escape($env:USERNAME))\b")) $r.Err
    $pwned = @(Get-ChildItem -LiteralPath $Scripts, $sb.Dir, (Get-Location).Path -Recurse -File | Where-Object { $_.Name -match 'X_PWNED|^x\.txt$' })
    Check 'no file was created by injected commands' ($pwned.Count -eq 0) (($pwned | ForEach-Object FullName) -join ', ')
    Check 'hooks print nothing to stdout' (-not $r.Out) $r.Out

    $sb = New-Sandbox 'ifpending'
    $r = Invoke-Hook $sb (New-Payload 'PostToolUse' @{ tool_name = 'Bash' }) @{ TASK_NOTIFIER_DEBUG = '1' } 'ifpending'
    Check 'tool calls without a waiting toast never start PowerShell' (($r.Exit -eq 0) -and -not (Test-Path (Join-Path $sb.State 'debug.log'))) ''

    Section 'Privacy mode'

    $sb = New-Sandbox 'privacy'
    $all = ''
    foreach ($p in Get-SecretFlow) {
        $r = Invoke-Hook $sb $p @{ TASK_NOTIFIER_PRIVACY = '1'; TASK_NOTIFIER_MIN_SECONDS = '0' }
        $all += $r.Err + $r.Out
        if ($p.hook_event_name -eq 'PreToolUse') { Remove-Item (Join-Path $sb.State '*.pending') -ErrorAction SilentlyContinue }
    }
    Check 'privacy mode: no notification contains prompt, command, question, reply or error text' ($all -notmatch $Secret) (($all -split "`n" | Where-Object { $_ -match $Secret }) -join ' | ')
    Check 'privacy mode: notifications were still produced' (([regex]::Matches($all, '\] Claude ')).Count -ge 5) $all
    $files = (Get-ChildItem -LiteralPath $sb.State -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join ''
    Check 'privacy mode: state files contain no secret text' ($files -notmatch $Secret) $files

    Section 'Debug log'

    $sb = New-Sandbox 'debuglog'
    foreach ($p in Get-SecretFlow) {
        $null = Invoke-Hook $sb $p @{ TASK_NOTIFIER_DEBUG = '1'; TASK_NOTIFIER_MIN_SECONDS = '0' }
        if ($p.hook_event_name -eq 'PreToolUse') { Remove-Item (Join-Path $sb.State '*.pending') -ErrorAction SilentlyContinue }
    }
    $log = Join-Path $sb.State 'debug.log'
    $logText = if (Test-Path $log) { [IO.File]::ReadAllText($log) } else { '' }
    Check 'debug log is written, including notification titles' (([regex]::Matches($logText, 'dry run, not shown')).Count -ge 5) $logText
    Check 'debug log contains no prompt, command, question, reply or error text' ($logText -notmatch $Secret) (($logText -split "`n" | Where-Object { $_ -match $Secret }) -join ' | ')

    $StateDir = Join-Path $Root 'unit\logstate'
    $env:TASK_NOTIFIER_DEBUG = '1'
    Write-Log "real`r`n2026-01-01 00:00:00 [Fake] forged entry`0$([char]27)[31m"
    $env:TASK_NOTIFIER_DEBUG = $null
    $lines = @([IO.File]::ReadAllLines((Join-Path $StateDir 'debug.log')))
    Check 'newlines in a log message cannot forge extra log entries' ($lines.Count -eq 1) ($lines -join ' | ')

    Section 'Cached helper DLL'

    # A DLL planted in TEMP (which may be shared with other users) must never be loaded.
    $sb = New-Sandbox 'planted'
    $null = New-Item -ItemType Directory -Force -Path $sb.State
    $marker = Join-Path $sb.Dir 'PLANTED_DLL_RAN.txt'
    $planted = @"
using System;
namespace CTN {
  public static class Native {
    static Native() { System.IO.File.WriteAllText(@"$marker", "loaded"); }
    public static IntPtr GetForegroundWindow() { return IntPtr.Zero; }
    public static uint GetWindowThreadProcessId(IntPtr h, out uint pid) { pid = 0; return 0; }
    public static IntPtr GetConsoleWindow() { return IntPtr.Zero; }
    public static string Title(IntPtr h) { return ""; }
    public static IntPtr RootOwner(IntPtr h) { return IntPtr.Zero; }
    public static uint IdleMilliseconds() { return 0; }
  }
}
"@
    $plantedDll = Join-Path $sb.State "ctn-native-$NativeVersion.dll"
    $job = Start-Job -ScriptBlock { param($src, $out) Add-Type -TypeDefinition $src -OutputAssembly $out -OutputType Library } -ArgumentList $planted, $plantedDll
    $null = Wait-Job $job -Timeout 60; Remove-Job $job -Force
    Check 'test setup: planted DLL was built in TEMP' (Test-Path $plantedDll) ''
    $r = Invoke-Hook $sb (New-Payload 'Stop' @{ last_assistant_message = 'ok' }) @{ TASK_NOTIFIER_MIN_SECONDS = '0'; TASK_NOTIFIER_WHEN_FOCUSED = $null }
    Check 'a DLL planted in TEMP is never loaded' (-not (Test-Path $marker)) 'the planted DLL ran'
    Check 'the helper DLL is cached in LOCALAPPDATA instead' (Test-Path (Join-Path $sb.Local "claude-task-notifier\ctn-native-$NativeVersion.dll")) $r.Err
    Check 'notification still works next to a planted DLL' ($r.Err -match 'Claude finished') $r.Err

    $sb = New-Sandbox 'nolocal'
    $r = Invoke-Hook $sb (New-Payload 'Stop' @{ last_assistant_message = 'ok' }) @{ TASK_NOTIFIER_MIN_SECONDS = '0'; TASK_NOTIFIER_WHEN_FOCUSED = $null; LOCALAPPDATA = $null }
    $anyDll = @(Get-ChildItem -LiteralPath $sb.Dir -Recurse -Filter '*.dll')
    Check 'without LOCALAPPDATA nothing is cached on disk' (($anyDll.Count -eq 0) -and ($r.Err -match 'Claude finished')) (($anyDll | ForEach-Object FullName) -join ', ')

    Section 'Programs planted in the project folder'

    # Hooks run in the project folder, where cmd.exe would look for programs first. A cloned repo with its own
    # powershell.exe must not get it run. Claude Code sets NoDefaultCurrentDirectoryInExePath; the launchers must
    # not rely on that, so the test removes it.
    $sb = New-Sandbox 'plantedexe'
    $proj = Join-Path $sb.Dir 'cloned-repo'
    $null = New-Item -ItemType Directory -Force -Path $proj
    $marker = Join-Path $sb.Dir 'PLANTED_EXE_RAN.txt'
    $exeSrc = "public static class P { public static void Main() { System.IO.File.AppendAllText(@""$marker"", ""ran\r\n""); } }"
    $job = Start-Job -ScriptBlock { param($src, $out) Add-Type -TypeDefinition $src -OutputAssembly $out -OutputType ConsoleApplication } -ArgumentList $exeSrc, (Join-Path $proj 'powershell.exe')
    $null = Wait-Job $job -Timeout 60; Remove-Job $job -Force
    Check 'test setup: planted powershell.exe was built in the project folder' (Test-Path (Join-Path $proj 'powershell.exe')) ''
    $noGuard = @{ NoDefaultCurrentDirectoryInExePath = $null; TASK_NOTIFIER_MIN_SECONDS = '0' }
    $r = Invoke-Hook $sb (New-Payload 'Stop' @{ last_assistant_message = 'ok'; cwd = $proj }) $noGuard '' $NotifyCmd $proj
    Check 'notify.cmd never runs a powershell.exe from the project folder' (-not (Test-Path $marker)) 'the planted powershell.exe ran'
    Check 'and still notifies with the real PowerShell' ($r.Err -match 'Claude finished') $r.Err
    $r = Invoke-Hook $sb '' $noGuard 'test' (Join-Path $Scripts 'doctor.cmd') $proj
    Check 'doctor.cmd never runs a powershell.exe from the project folder' (-not (Test-Path $marker) -and $r.Out -match 'Task Notifier doctor') 'the planted powershell.exe ran'

    Section 'Static checks'

    $src = [IO.File]::ReadAllText($NotifyPs1)
    $cmd = [IO.File]::ReadAllText($NotifyCmd)
    $hooks = [IO.File]::ReadAllText((Join-Path $Repo 'plugins\task-notifier\hooks\hooks.json'))
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($src, [ref]$tokens, [ref]$errors)
    Check 'notify.ps1 parses without errors' ($errors.Count -eq 0) (($errors | ForEach-Object Message) -join '; ')
    Check 'notify.ps1 is ASCII only' (-not ([Text.Encoding]::UTF8.GetBytes($src) | Where-Object { $_ -gt 127 })) ''
    $dynamic = @($tokens | Where-Object { $_.Kind -eq 'Identifier' -or $_.Kind -eq 'Generic' } | Where-Object { $_.Text -match '^(Invoke-Expression|iex|Invoke-Command|icm)$' })
    Check 'no Invoke-Expression or Invoke-Command' ($dynamic.Count -eq 0) (($dynamic | ForEach-Object Text) -join ', ')
    $starts = [regex]::Matches($src, 'Start-Process[^\r\n]*(\r?\n[^\r\n]*-ArgumentList[^\r\n]*)?')
    Check 'the only Start-Process is the fixed balloon script (-EncodedCommand of a constant)' (($starts.Count -eq 1) -and ($starts[0].Value -match "-EncodedCommand', \`$encoded")) (($starts | ForEach-Object Value) -join ' || ')
    Check 'registry writes only go to HKCU' (($src -notmatch 'HKLM:|HKEY_LOCAL_MACHINE|Registry::') -and ($src -match 'HKCU:\\Software\\Classes\\AppUserModelId\\')) ''
    Check 'every toast text goes through Format-Xml' (-not ([regex]::Matches($src, '<text>\$\((?!Format-Xml)').Count)) ''
    Check 'notify.cmd never passes hook input on the command line' (($cmd -notmatch '%\*') -and ($cmd -match '-File "%~dp0notify\.ps1"\s*\r?\n')) ''
    $doctorCmd = [IO.File]::ReadAllText((Join-Path $Scripts 'doctor.cmd'))
    $fullPs = '"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"'
    foreach ($launcher in @(@('notify.cmd', $cmd), @('doctor.cmd', $doctorCmd))) {
        $body = $launcher[1]
        Check "$($launcher[0]) starts PowerShell only by its full Windows path" (($body.Contains($fullPs) -or $body.Contains('set "CTN_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"')) -and
            ($body -match 'set "NoDefaultCurrentDirectoryInExePath=1"')) ''
    }
    Check 'doctor.cmd only reacts to the fixed word "test" and forwards no arguments' (($doctorCmd -notmatch '%\*') -and
        ([regex]::Matches($doctorCmd, '%~?1').Count -eq 1) -and ($doctorCmd -match 'if /i "%~1"=="test"')) ''
    $doctorSrc = [IO.File]::ReadAllText((Join-Path $Scripts 'doctor.ps1'))
    $errors = $null; $dtokens = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($doctorSrc, [ref]$dtokens, [ref]$errors)
    Check 'doctor.ps1 parses without errors and is ASCII only' (($errors.Count -eq 0) -and -not ([Text.Encoding]::UTF8.GetBytes($doctorSrc) | Where-Object { $_ -gt 127 })) (($errors | ForEach-Object Message) -join '; ')
    $ddyn = @($dtokens | Where-Object { $_.Kind -eq 'Identifier' -or $_.Kind -eq 'Generic' } | Where-Object { $_.Text -match '^(Invoke-Expression|iex|Invoke-Command|icm|Start-Process|Set-ItemProperty|New-ItemProperty|Remove-Item|Set-Content)$' })
    Check 'doctor.ps1 runs nothing and changes nothing itself (no iex, Start-Process or writes)' ($ddyn.Count -eq 0) (($ddyn | ForEach-Object Text) -join ', ')
    $hookJson = $hooks | ConvertFrom-Json
    $cmds = @($hookJson.hooks.PSObject.Properties | ForEach-Object { $_.Value } | ForEach-Object { $_.hooks } | ForEach-Object { $_ })
    Check 'all hooks use exec form (cmd.exe with fixed args, no shell string)' ((@($cmds | Where-Object { $_.command -ne 'cmd.exe' -or -not $_.args }).Count -eq 0) -and $cmds.Count -ge 10) ''
}
catch {
    $script:Failed++
    Write-Host "FAIL  test run aborted: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
}
Complete-Tests
