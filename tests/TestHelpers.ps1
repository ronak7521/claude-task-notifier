# Shared helpers for the Task Notifier tests (dot-sourced by each *-tests.ps1). Keep this file ASCII-only.
#
# Tests run the real launcher (notify.cmd) in dry-run mode, which prints the notification to stderr instead
# of showing it, inside a throwaway TEMP / LOCALAPPDATA. Your real state, toasts and registry are untouched.

$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Plugin = Join-Path $Repo 'plugins\task-notifier'
$Scripts = Join-Path $Plugin 'scripts'
$NotifyCmd = Join-Path $Scripts 'notify.cmd'
$NotifyPs1 = Join-Path $Scripts 'notify.ps1'
# CTN_TEST_ROOT picks the folder for the throwaway sandboxes (CI sets it); default is TEMP.
$base = if ($env:CTN_TEST_ROOT) { $env:CTN_TEST_ROOT } else { [IO.Path]::GetTempPath() }
$Root = Join-Path $base ('ctn-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:Failed = 0
$script:Passed = 0
$script:Skipped = 0

function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:Passed++; Write-Host "PASS  $name" }
    else { $script:Failed++; Write-Host "FAIL  $name" -ForegroundColor Red; if ($detail) { Write-Host "      $detail" } }
}

function Skip([string]$name, [string]$why) { $script:Skipped++; Write-Host "SKIP  $name ($why)" -ForegroundColor Yellow }

function Section([string]$name) { Write-Host "`n--- $name ---" }

# Fresh, empty TEMP and LOCALAPPDATA for one test.
function New-Sandbox([string]$name) {
    $dir = Join-Path $Root $name
    $sb = [pscustomobject]@{ Dir = $dir; Temp = (Join-Path $dir 'temp'); Local = (Join-Path $dir 'local') }
    $null = New-Item -ItemType Directory -Force -Path $sb.Temp, $sb.Local
    $sb | Add-Member State (Join-Path $sb.Temp 'claude-task-notifier')
    return $sb
}

# Runs notify.cmd like Claude Code does: payload on stdin, hook settings in the environment.
# Inherited editor/terminal and TASK_NOTIFIER_* variables are removed so results do not depend on this machine.
# The focus check is off by default (TASK_NOTIFIER_WHEN_FOCUSED=1); pass it as $null to turn it on.
# -launcher runs another .cmd (e.g. doctor.cmd); -cwd sets the working folder (hooks run in the project folder).
function Invoke-Hook($sandbox, $payload, [hashtable]$envs = @{}, [string]$arg = '', [string]$launcher = $NotifyCmd, [string]$cwd = '') {
    $psi = New-Object Diagnostics.ProcessStartInfo 'cmd.exe'
    $psi.Arguments = '/d /s /c ""' + $launcher + '"' + $(if ($arg) { " $arg" }) + '"'
    if ($cwd) { $psi.WorkingDirectory = $cwd }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($k in @($psi.EnvironmentVariables.Keys)) {
        if ($k -match '^(TASK_NOTIFIER_|CTN_|VSCODE_PID$|TERM_PROGRAM$|WT_SESSION$)') { $psi.EnvironmentVariables.Remove($k) }
    }
    $psi.EnvironmentVariables['TEMP'] = $sandbox.Temp
    $psi.EnvironmentVariables['TMP'] = $sandbox.Temp
    $psi.EnvironmentVariables['LOCALAPPDATA'] = $sandbox.Local
    $psi.EnvironmentVariables['CTN_DRYRUN'] = '1'
    $psi.EnvironmentVariables['TASK_NOTIFIER_WHEN_FOCUSED'] = '1'
    foreach ($k in $envs.Keys) {
        if ($null -eq $envs[$k]) { $psi.EnvironmentVariables.Remove($k) } else { $psi.EnvironmentVariables[$k] = [string]$envs[$k] }
    }
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
    $text = if ($payload -is [string]) { $payload } else { $payload | ConvertTo-Json -Depth 8 -Compress }
    $bytes = (New-Object Text.UTF8Encoding $false).GetBytes($text)
    $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $p.StandardInput.Close()
    $done = $p.WaitForExit(60000)
    if (-not $done) { $p.Kill() }
    return [pscustomobject]@{ Exit = $(if ($done) { $p.ExitCode } else { -1 }); Out = $out.Result; Err = $err.Result; TimedOut = -not $done }
}

function New-Payload([string]$hookEvent, [hashtable]$extra = @{}) {
    $p = @{ hook_event_name = $hookEvent; session_id = 'test-session-1'; cwd = 'C:\work\shop-api' }
    foreach ($k in $extra.Keys) { $p[$k] = $extra[$k] }
    return $p
}

# notify.ps1's functions as script blocks; dot-source each at script level to load them without running main.
function Get-NotifyFunctions {
    $ast = [Management.Automation.Language.Parser]::ParseFile($NotifyPs1, [ref]$null, [ref]$null)
    foreach ($fn in $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] }) {
        [scriptblock]::Create($fn.Extent.Text)
    }
}

# Dry-run output of one notification: "[type: Kind/Sound/Tag sticky] Title", then its lines.
function Get-Shown([string]$stderr) {
    $m = [regex]::Match($stderr, '\[(\w+): (\w+)/([\w.]+)/(\w+)( sticky)?\] ([^\r\n]+)((?:\r?\n[^\r\n]+)*)')
    if (-not $m.Success) { return $null }
    $lines = @($m.Groups[7].Value -split "\r?\n" | Where-Object { $_ })
    return [pscustomobject]@{
        Type = $m.Groups[1].Value; Kind = $m.Groups[2].Value; Sound = $m.Groups[3].Value; Tag = $m.Groups[4].Value
        Sticky = $m.Groups[5].Success; Title = $m.Groups[6].Value
        Lines = @($lines | Where-Object { $_ -notlike 'click opens: *' -and $_ -notlike 'header: *' })
        Launch = (@($lines | Where-Object { $_ -like 'click opens: *' }) | ForEach-Object { $_.Substring(13) }) -join ''
        Header = (@($lines | Where-Object { $_ -like 'header: *' }) | ForEach-Object { $_.Substring(8) }) -join ''
    }
}

function Complete-Tests {
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    $skips = if ($script:Skipped) { ", $script:Skipped skipped" } else { '' }
    Write-Host "`n$script:Passed passed, $script:Failed failed$skips"
    if ($script:Failed) { exit 1 } else { exit 0 }
}
