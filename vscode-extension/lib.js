'use strict';
// Logic without the vscode module, so it can be tested with plain Node.
const path = require('path').win32;

const PLUGIN_NAME = 'task-notifier';
const MARKETPLACE_NAME = 'ronak-plugins';
const MARKETPLACE_SOURCE = 'ronak7521/claude-task-notifier';
const PLUGIN_ID = `${PLUGIN_NAME}@${MARKETPLACE_NAME}`;

// Fixed argument lists for the claude CLI. Nothing from the user or a workspace ever goes into them.
const ARGS = Object.freeze({
    list: ['plugin', 'list', '--json'],
    addMarketplace: ['plugin', 'marketplace', 'add', MARKETPLACE_SOURCE],
    updateMarketplace: ['plugin', 'marketplace', 'update', MARKETPLACE_NAME],
    install: ['plugin', 'install', PLUGIN_ID],
    update: ['plugin', 'update', PLUGIN_ID],
    enable: ['plugin', 'enable', PLUGIN_ID],
    uninstall: ['plugin', 'uninstall', PLUGIN_ID],
});

/**
 * Places to look for the claude CLI, best first. Only absolute paths: a relative PATH entry would
 * resolve against the workspace, and a workspace can contain a planted claude.exe.
 * @param {{configured?: string, claudeExtensionPath?: string, env: Record<string,string|undefined>}} o
 * @returns {string[]}
 */
function claudeCandidates(o) {
    const env = o.env || {};
    const list = [];
    if (o.configured) list.push(o.configured);
    if (o.claudeExtensionPath) list.push(path.join(o.claudeExtensionPath, 'resources', 'native-binary', 'claude.exe'));
    if (env.USERPROFILE) list.push(path.join(env.USERPROFILE, '.local', 'bin', 'claude.exe'));
    for (const dir of String(env.PATH || env.Path || '').split(';')) {
        const d = dir.trim().replace(/^"(.*)"$/, '$1');
        if (!d || !path.isAbsolute(d) || d.startsWith('\\\\')) continue;
        list.push(path.join(d, 'claude.exe'), path.join(d, 'claude.cmd'));
    }
    return list.filter((p) => path.isAbsolute(p) && /\.(exe|cmd)$/i.test(p));
}

/**
 * @param {Parameters<typeof claudeCandidates>[0] & {exists: (p: string) => boolean}} o
 * @returns {string|null}
 */
function findClaude(o) {
    return claudeCandidates(o).find((p) => o.exists(p)) || null;
}

/**
 * How to start the CLI. A .cmd (npm install) needs cmd.exe; its path must then hold no character cmd treats specially.
 * @param {string} claudePath
 * @param {string[]} args
 * @param {string} systemRoot
 * @returns {{file: string, args: string[], verbatim: boolean}}
 */
function commandFor(claudePath, args, systemRoot) {
    if (!/\.cmd$/i.test(claudePath)) return { file: claudePath, args: [...args], verbatim: false };
    if (/["%&|<>^!\r\n]/.test(claudePath)) throw new Error(`Unsafe characters in the claude path: ${claudePath}`);
    const cmd = path.join(systemRoot || 'C:\\Windows', 'System32', 'cmd.exe');
    return { file: cmd, args: ['/d', '/s', '/c', `""${claudePath}" ${args.join(' ')}"`], verbatim: true };
}

/**
 * Reads `claude plugin list --json`.
 * @param {string} stdout
 * @returns {{installed: boolean, enabled: boolean, version: string, installPath: string, scope: string}}
 */
function parsePluginList(stdout) {
    const start = stdout.indexOf('[');
    if (start < 0) throw new Error('claude plugin list did not return JSON');
    const all = JSON.parse(stdout.slice(start));
    if (!Array.isArray(all)) throw new Error('claude plugin list did not return a list');
    const mine = all.filter((p) => p && p.id === PLUGIN_ID);
    const user = mine.find((p) => p.scope === 'user') || mine[0];
    if (!user) return { installed: false, enabled: false, version: '', installPath: '', scope: '' };
    return {
        installed: true,
        enabled: user.enabled !== false,
        version: String(user.version || ''),
        installPath: String(user.installPath || ''),
        scope: String(user.scope || ''),
    };
}

/**
 * The plugin's doctor launcher, or null if this plugin version has none (before 1.5.0).
 * @param {string} installPath
 * @param {(p: string) => boolean} exists
 */
function doctorScript(installPath, exists) {
    if (!installPath || !path.isAbsolute(installPath)) return null;
    const p = path.join(installPath, 'scripts', 'doctor.cmd');
    return exists(p) ? p : null;
}

module.exports = {
    PLUGIN_NAME, MARKETPLACE_NAME, MARKETPLACE_SOURCE, PLUGIN_ID, ARGS,
    claudeCandidates, findClaude, commandFor, parsePluginList, doctorScript,
};
