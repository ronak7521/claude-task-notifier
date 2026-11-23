'use strict';
const vscode = require('vscode');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFile } = require('child_process');
const lib = require('./lib');

const DECLINED_KEY = 'taskNotifier.installDeclined';
const GET_CLAUDE_URL = 'https://claude.com/claude-code';
let output;

function log(line) {
    output.appendLine(line);
}

function exists(p) {
    try { return fs.statSync(p).isFile(); } catch { return false; }
}

function claudeSearch() {
    const configured = vscode.workspace.getConfiguration('taskNotifier').get('claudePath') || '';
    const claudeExt = vscode.extensions.getExtension('anthropic.claude-code');
    return {
        configured: configured.trim(),
        claudeExtensionPath: claudeExt ? claudeExt.extensionPath : '',
        env: process.env,
        exists,
    };
}

function findClaude() {
    return lib.findClaude(claudeSearch());
}

/**
 * Runs a program by full path from the home folder, never the workspace.
 * @returns {Promise<{code: number, stdout: string, stderr: string, timedOut: boolean, notStarted: boolean, timeoutMs: number}>}
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
            resolve({
                code,
                stdout: String(stdout),
                stderr: String(stderr),
                timedOut: Boolean(err && err.killed),
                // A string code such as ENOENT means the program never ran.
                notStarted: Boolean(err && typeof err.code === 'string'),
                timeoutMs,
            });
        });
    });
}

async function claude(claudePath, args, timeoutMs = 180000) {
    const c = lib.commandFor(claudePath, args, process.env.SystemRoot);
    log(`> claude ${args.join(' ')}`);
    const r = await run(c.file, c.args, c.verbatim, timeoutMs);
    const text = `${r.stdout}${r.stderr}`.trim();
    if (text && (args !== lib.ARGS.list || r.code !== 0)) log(text);
    if (r.code !== 0) log(`(exit code ${r.code}${r.timedOut ? ', timed out' : ''})`);
    return r;
}

/** Runs a claude command and throws a message that says what to do if it fails. */
async function claudeStep(claudePath, args, step, timeoutMs) {
    const r = await claude(claudePath, args, timeoutMs);
    if (r.code !== 0) throw new Error(lib.explainFailure(step, r));
    return r;
}

/** Tells the user Claude Code is missing, where we looked and how to fix it. */
async function reportNoClaude(atStartup) {
    log('Claude Code was not found. Looked in:');
    for (const p of lib.claudeCandidates(claudeSearch())) log(`  ${p}`);
    const buttons = ['Get Claude Code', 'Set Path'];
    if (atStartup) buttons.push("Don't Ask Again");
    // Modal at start-up: a normal message hides in the bell after a few seconds, or entirely under Do Not Disturb.
    const pick = await vscode.window.showWarningMessage(
        'Task Notifier needs Claude Code, but it is not installed on this PC.',
        { modal: atStartup, detail: 'Install the Claude Code extension or CLI, then reload the window. If it is installed somewhere else, set "taskNotifier.claudePath".' },
        ...buttons);
    if (pick === 'Get Claude Code') vscode.env.openExternal(vscode.Uri.parse(GET_CLAUDE_URL));
    if (pick === 'Set Path') vscode.commands.executeCommand('workbench.action.openSettings', 'taskNotifier.claudePath');
    return pick;
}

async function requireClaude() {
    const p = findClaude();
    if (p) return p;
    await reportNoClaude();
    return null;
}

async function status(claudePath) {
    const r = await claudeStep(claudePath, lib.ARGS.list, 'Reading the Claude Code plugin list', 60000);
    try {
        return lib.parsePluginList(r.stdout);
    } catch {
        throw new Error('Claude Code returned a plugin list Task Notifier could not read. Update Claude Code to the latest version and try again.');
    }
}

function claudeSettingsPath() {
    const dir = process.env.CLAUDE_CONFIG_DIR;
    return path.join(dir && path.isAbsolute(dir) ? dir : path.join(os.homedir(), '.claude'), 'settings.json');
}

/**
 * Turns on Claude Code's auto-update for the plugin's marketplace (it applies from the next Claude Code session).
 * Never throws: a failure here must not fail an install.
 */
function ensureAutoUpdate() {
    try {
        if (vscode.workspace.getConfiguration('taskNotifier').get('autoUpdatePlugin') === false) return;
        let file = claudeSettingsPath();
        // Write to the real file, so a symlinked settings.json (e.g. from a dotfiles repo) stays a link.
        try { file = fs.realpathSync(file); } catch { /* does not exist yet */ }
        let text = null;
        try { text = fs.readFileSync(file, 'utf8'); } catch (e) { if (e.code !== 'ENOENT') throw e; }
        let known = null;
        try { known = fs.readFileSync(path.join(path.dirname(claudeSettingsPath()), 'plugins', 'known_marketplaces.json'), 'utf8'); } catch { /* not there yet */ }
        const r = lib.declareAutoUpdate(text, lib.registeredAutoUpdate(known));
        if (!r.changed) { log(`Plugin auto-update: ${r.reason}.`); return; }
        fs.mkdirSync(path.dirname(file), { recursive: true });
        const tmp = `${file}.task-notifier.tmp`;
        fs.writeFileSync(tmp, r.text);
        fs.renameSync(tmp, file);
        log(`Plugin auto-update turned on in ${file} (extraKnownMarketplaces.${lib.MARKETPLACE_NAME}.autoUpdate). Claude Code applies it from the next session.`);
    } catch (e) {
        log(`Could not turn on plugin auto-update: ${e.message || e}. Turn it on in Claude Code: /plugin > Marketplaces > ${lib.MARKETPLACE_NAME} > Enable auto-update.`);
    }
}

async function offerReload(message) {
    const pick = await vscode.window.showInformationMessage(message, 'Reload Window');
    if (pick === 'Reload Window') vscode.commands.executeCommand('workbench.action.reloadWindow');
}

async function install() {
    const claudePath = await requireClaude();
    if (!claudePath) return;
    await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: 'Installing Task Notifier for Claude Code...' }, async () => {
        // Exits 0 when the catalog is already there.
        await claudeStep(claudePath, lib.ARGS.addMarketplace, 'Adding the Task Notifier catalog to Claude Code');
        await claudeStep(claudePath, lib.ARGS.install, 'Installing the Task Notifier plugin');
        const s = await status(claudePath);
        if (!s.installed) throw new Error('Claude Code reported success, but the plugin is not in its list. Try "Task Notifier: Install or Repair Claude Code Plugin" again.');
        if (!s.enabled) await claudeStep(claudePath, lib.ARGS.enable, 'Turning on the Task Notifier plugin');
    });
    ensureAutoUpdate();
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
        if (refresh.code !== 0) throw new Error(lib.explainFailure('Checking for a new version', refresh));
        await claudeStep(claudePath, lib.ARGS.update, 'Updating the Task Notifier plugin');
    });
    ensureAutoUpdate();
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
    await claudeStep(claudePath, lib.ARGS.uninstall, 'Removing the Task Notifier plugin');
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
    if (fails) vscode.window.showWarningMessage(`Task Notifier found ${fails} problem(s). Each [FAIL] line in the "Task Notifier" output says how to fix it.`, 'Show Output').then((p) => { if (p) output.show(); });
    else if (r.code !== 0) throw new Error(lib.explainFailure(testOnly ? 'The test notification' : 'The check', r));
    else if (testOnly) vscode.window.showInformationMessage('Test notification sent. Did a "Task Notifier" toast appear?');
}

// Covers a dialog left open for a while; an older lock is from a crashed window.
const STARTUP_LOCK_STALE_MS = 10 * 60 * 1000;

/** On start-up: say if Claude Code is missing, else offer to install the plugin, unless the user said no. */
async function checkOnStartup(context) {
    if (context.globalState.get(DECLINED_KEY)) return;
    // Every open window runs this; only one may show the dialog and install, or installs collide.
    const release = lib.tryLock(path.join(os.tmpdir(), 'task-notifier-vscode-startup.lock'), STARTUP_LOCK_STALE_MS, fs);
    if (!release) { log('Start-up check skipped: another VS Code window is running it.'); return; }
    try {
        await startupCheck(context);
    } finally {
        release();
    }
}

async function startupCheck(context) {
    const claudePath = findClaude();
    if (!claudePath) {
        if (await reportNoClaude(true) === "Don't Ask Again") await context.globalState.update(DECLINED_KEY, true);
        return;
    }
    const s = await status(claudePath);
    // Also for plugins installed before this version or by hand.
    if (s.installed) ensureAutoUpdate();
    if (s.installed && s.enabled) return;
    const text = s.installed
        ? 'The Task Notifier plugin is turned off in Claude Code. Turn it on?'
        : 'Task Notifier needs its Claude Code plugin to send Windows notifications. Install it now?';
    const detail = 'Without it you get no notifications. Claude Code will keep it up to date automatically. '
        + 'You can do this later with "Task Notifier: Install or Repair Claude Code Plugin" (Ctrl+Shift+P).';
    // Modal, so it cannot be missed; Cancel ("not now") asks again at the next start.
    const pick = await vscode.window.showInformationMessage(text, { modal: true, detail }, s.installed ? 'Turn On' : 'Install', "Don't Ask Again");
    if (pick === 'Install') await install();
    else if (pick === 'Turn On') {
        await claudeStep(claudePath, lib.ARGS.enable, 'Turning on the Task Notifier plugin');
        await offerReload('Task Notifier is turned on. Reload the window so Claude Code loads it.');
    } else if (pick === "Don't Ask Again") await context.globalState.update(DECLINED_KEY, true);
}

function guarded(fn) {
    return async (...a) => {
        try { await fn(...a); } catch (e) {
            log(String(e && e.stack || e));
            const pick = await vscode.window.showErrorMessage(`Task Notifier: ${String(e && e.message || e)}`, 'Show Output');
            if (pick === 'Show Output') output.show();
        }
    };
}

function activate(context) {
    output = vscode.window.createOutputChannel('Task Notifier');
    context.subscriptions.push(output);
    if (process.platform !== 'win32') {
        log('Task Notifier works on Windows only.');
        vscode.window.showWarningMessage('Task Notifier works on Windows only, so it does nothing on this computer.');
        return;
    }
    const commands = {
        // Installing by hand undoes an earlier "Don't Ask Again", so a later removal is noticed again.
        'taskNotifier.install': async () => { await context.globalState.update(DECLINED_KEY, undefined); await install(); },
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
