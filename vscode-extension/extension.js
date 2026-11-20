'use strict';
const vscode = require('vscode');
const fs = require('fs');
const os = require('os');
const { execFile } = require('child_process');
const lib = require('./lib');

const DECLINED_KEY = 'taskNotifier.installDeclined';
let output;

function log(line) {
    output.appendLine(line);
}

function exists(p) {
    try { return fs.statSync(p).isFile(); } catch { return false; }
}

function findClaude() {
    const configured = vscode.workspace.getConfiguration('taskNotifier').get('claudePath') || '';
    const claudeExt = vscode.extensions.getExtension('anthropic.claude-code');
    return lib.findClaude({
        configured: configured.trim(),
        claudeExtensionPath: claudeExt ? claudeExt.extensionPath : '',
        env: process.env,
        exists,
    });
}

/**
 * Runs a program by full path from the home folder, never the workspace.
 * @returns {Promise<{code: number, stdout: string, stderr: string}>}
 */
function run(file, args, verbatim, timeoutMs) {
    // CLAUDECODE marks a Claude Code session; VS Code may have inherited it if it was started from one.
    const env = { ...process.env, NoDefaultCurrentDirectoryInExePath: '1' };
    for (const k of Object.keys(env)) if (k.toUpperCase() === 'CLAUDECODE') delete env[k];
    return new Promise((resolve) => {
        execFile(file, args, {
            cwd: os.homedir(),
            windowsHide: true,
            windowsVerbatimArguments: verbatim,
            timeout: timeoutMs,
            maxBuffer: 4 * 1024 * 1024,
            env,
        }, (err, stdout, stderr) => {
            const code = err ? (typeof err.code === 'number' ? err.code : 1) : 0;
            if (err && typeof err.code !== 'number') stderr = `${stderr}\n${err.message}`;
            resolve({ code, stdout: String(stdout), stderr: String(stderr) });
        });
    });
}

async function claude(claudePath, args, timeoutMs = 180000) {
    const c = lib.commandFor(claudePath, args, process.env.SystemRoot);
    log(`> claude ${args.join(' ')}`);
    const r = await run(c.file, c.args, c.verbatim, timeoutMs);
    const text = `${r.stdout}${r.stderr}`.trim();
    if (text && args !== lib.ARGS.list) log(text);
    return r;
}

async function requireClaude() {
    const p = findClaude();
    if (p) return p;
    const pick = await vscode.window.showErrorMessage(
        'Task Notifier could not find Claude Code. Install the Claude Code extension or CLI, or set "taskNotifier.claudePath".',
        'Get Claude Code', 'Open Settings');
    if (pick === 'Get Claude Code') vscode.env.openExternal(vscode.Uri.parse('https://claude.com/claude-code'));
    if (pick === 'Open Settings') vscode.commands.executeCommand('workbench.action.openSettings', 'taskNotifier.claudePath');
    return null;
}

async function status(claudePath) {
    const r = await claude(claudePath, lib.ARGS.list, 60000);
    if (r.code !== 0) throw new Error(`claude plugin list failed: ${r.stderr.trim() || r.code}`);
    return lib.parsePluginList(r.stdout);
}

async function offerReload(message) {
    const pick = await vscode.window.showInformationMessage(message, 'Reload Window');
    if (pick === 'Reload Window') vscode.commands.executeCommand('workbench.action.reloadWindow');
}

async function install() {
    const claudePath = await requireClaude();
    if (!claudePath) return;
    await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: 'Installing Task Notifier for Claude Code...' }, async () => {
        await claude(claudePath, lib.ARGS.addMarketplace);
        const r = await claude(claudePath, lib.ARGS.install);
        if (r.code !== 0) throw new Error('claude plugin install failed. See the "Task Notifier" output for details.');
        const s = await status(claudePath);
        if (s.installed && !s.enabled) await claude(claudePath, lib.ARGS.enable);
    });
    await offerReload('Task Notifier is installed. Reload the window (and restart any Claude Code terminal session) so Claude Code loads it.');
}

async function update() {
    const claudePath = await requireClaude();
    if (!claudePath) return;
    const s = await status(claudePath);
    if (!s.installed) return install();
    await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: 'Updating Task Notifier...' }, async () => {
        // Without a fresh catalog, "update" finds nothing new and we would wrongly say it is the latest.
        const refresh = await claude(claudePath, lib.ARGS.updateMarketplace);
        if (refresh.code !== 0) throw new Error('Could not check for a new version (is GitHub reachable?). See the "Task Notifier" output for details.');
        const r = await claude(claudePath, lib.ARGS.update);
        if (r.code !== 0) throw new Error('claude plugin update failed. See the "Task Notifier" output for details.');
    });
    const after = await status(claudePath);
    if (after.version === s.version) {
        vscode.window.showInformationMessage(`Task Notifier ${after.version} is the latest version.`);
    } else {
        await offerReload(`Task Notifier updated from ${s.version} to ${after.version}. Reload the window to use it.`);
    }
}

async function uninstall() {
    const claudePath = await requireClaude();
    if (!claudePath) return;
    const sure = await vscode.window.showWarningMessage('Remove the Task Notifier plugin from Claude Code? You will get no more notifications.', { modal: true }, 'Remove');
    if (sure !== 'Remove') return;
    const r = await claude(claudePath, lib.ARGS.uninstall);
    if (r.code !== 0) throw new Error('claude plugin uninstall failed. See the "Task Notifier" output for details.');
    await offerReload('Task Notifier was removed from Claude Code. Reload the window to stop its hooks.');
}

/** Runs the plugin's doctor (test = only the test notification) and shows what it printed. */
async function doctor(testOnly) {
    const claudePath = await requireClaude();
    if (!claudePath) return;
    let s = await status(claudePath);
    if (!s.installed) {
        const pick = await vscode.window.showWarningMessage('The Task Notifier plugin is not installed in Claude Code.', 'Install');
        if (pick === 'Install') await install();
        return;
    }
    let script = lib.doctorScript(s.installPath, exists);
    if (!script) {
        const pick = await vscode.window.showWarningMessage(`Task Notifier ${s.version} is too old for this command. Update it first.`, 'Update');
        if (pick !== 'Update') return;
        await update();
        s = await status(claudePath);
        script = lib.doctorScript(s.installPath, exists);
        if (!script) return;
    }
    const c = lib.commandFor(script, testOnly ? ['test'] : [], process.env.SystemRoot);
    output.show(true);
    log(testOnly ? '> Task Notifier test' : '> Task Notifier doctor');
    const r = await vscode.window.withProgress({ location: vscode.ProgressLocation.Window, title: 'Task Notifier: checking...' },
        () => run(c.file, c.args, c.verbatim, 120000));
    log(`${r.stdout}${r.stderr}`.trim());
    const fails = (r.stdout.match(/^\s*\[FAIL\]/gm) || []).length;
    if (fails) vscode.window.showWarningMessage(`Task Notifier found ${fails} problem(s). See the "Task Notifier" output.`);
    else if (testOnly) vscode.window.showInformationMessage('Test notification sent. Did a "Task Notifier" toast appear?');
}

/** On start-up: offer to install the plugin once, unless the user said no. */
async function checkOnStartup(context) {
    if (context.globalState.get(DECLINED_KEY)) return;
    const claudePath = findClaude();
    if (!claudePath) return;
    let s;
    try { s = await status(claudePath); } catch (e) { log(String(e.message || e)); return; }
    if (s.installed && s.enabled) return;
    const text = s.installed
        ? 'The Task Notifier plugin is turned off in Claude Code. Turn it on?'
        : 'Task Notifier needs its Claude Code plugin to send Windows notifications. Install it now?';
    const pick = await vscode.window.showInformationMessage(text, s.installed ? 'Turn On' : 'Install', 'Not Now', "Don't Ask Again");
    if (pick === 'Install') await install();
    else if (pick === 'Turn On') {
        await claude(claudePath, lib.ARGS.enable);
        await offerReload('Task Notifier is turned on. Reload the window so Claude Code loads it.');
    } else if (pick === "Don't Ask Again") await context.globalState.update(DECLINED_KEY, true);
}

function guarded(fn) {
    return async (...a) => {
        try { await fn(...a); } catch (e) {
            log(String(e && e.stack || e));
            vscode.window.showErrorMessage(String(e && e.message || e));
        }
    };
}

function activate(context) {
    output = vscode.window.createOutputChannel('Task Notifier');
    context.subscriptions.push(output);
    if (process.platform !== 'win32') {
        log('Task Notifier works on Windows only.');
        return;
    }
    const commands = {
        'taskNotifier.install': install,
        'taskNotifier.update': update,
        'taskNotifier.test': () => doctor(true),
        'taskNotifier.doctor': () => doctor(false),
        'taskNotifier.uninstall': uninstall,
    };
    for (const [id, fn] of Object.entries(commands)) context.subscriptions.push(vscode.commands.registerCommand(id, guarded(fn)));
    guarded(() => checkOnStartup(context))();
}

function deactivate() {}

module.exports = { activate, deactivate };
