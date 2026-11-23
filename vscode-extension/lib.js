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
 * The JSON array in CLI output that may have notices before or after it, even ones such as "[warn] ...":
 * tries each line that starts with "[" up to each line that ends with "]", longest first.
 * @param {string} text
 * @returns {any[]|null}
 */
function findJsonArray(text) {
    const starts = [...text.matchAll(/^[ \t]*\[/gm)].map((m) => m.index + m[0].length - 1);
    const ends = [...text.matchAll(/\][ \t]*\r?$/gm)].map((m) => m.index).reverse();
    for (const s of starts) {
        for (const e of ends) {
            if (e < s) continue;
            try {
                const v = JSON.parse(text.slice(s, e + 1));
                // A list of plugin records: objects only, so a notice such as "[1]" is not taken for it.
                if (Array.isArray(v) && v.every((x) => x && typeof x === 'object' && !Array.isArray(x))) return v;
            } catch { /* not this pair */ }
        }
    }
    return null;
}

/**
 * Reads `claude plugin list --json`.
 * @param {string} stdout
 * @returns {{installed: boolean, enabled: boolean, version: string, installPath: string, scope: string}}
 */
function parsePluginList(stdout) {
    const all = findJsonArray(String(stdout));
    if (!all) throw new Error('claude plugin list did not return a JSON list');
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

// Known causes of a failed claude command, matched against its output, with what the user can do about each.
const HINTS = [
    [/spawn git|git[^\n]*(not found|not recognized|ENOENT)/i,
        'Git is needed to download the plugin. Install Git for Windows (https://git-scm.com), restart VS Code and try again.'],
    [/ENOTFOUND|EAI_AGAIN|getaddrinfo|Could not resolve host|ECONNREFUSED|ECONNRESET|ETIMEDOUT|unable to access|network|proxy|certificate|SSL/i,
        'Claude Code could not reach GitHub. Check your internet connection, VPN or proxy, then try again.'],
    [/rate limit|\b403\b/i,
        'GitHub refused the request (rate limit or no access). Wait a few minutes and try again.'],
    [/EACCES|EPERM|EBUSY|access is denied|permission denied/i,
        'Windows refused access to a file under %USERPROFILE%\\.claude. Close other Claude Code sessions and try again; if it repeats, antivirus or a company policy may be blocking it.'],
    [/policy|managed settings|not allowed|blocked/i,
        'Your organization\'s Claude Code settings may block plugins from this source. Ask your IT admin.'],
    [/not found|unknown (plugin|marketplace)/i,
        'Claude Code could not find the plugin in its catalog. Try "Task Notifier: Install or Repair Claude Code Plugin" again in a few minutes.'],
];

/**
 * The most telling line of CLI output: the first one that looks like an error, else the last one.
 * @param {string} text
 */
function errorLine(text) {
    const lines = String(text).replace(/\x1b\[[0-9;]*m/g, '').split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
    const line = lines.find((l) => /error|failed|denied|cannot|could not|not found|✘/i.test(l)) || lines[lines.length - 1] || '';
    return line.length > 200 ? `${line.slice(0, 197)}...` : line;
}

/**
 * A message for a failed step that says what went wrong and what to do.
 * @param {string} step e.g. "Installing the plugin"
 * @param {{code: number, stdout?: string, stderr?: string, timedOut?: boolean, notStarted?: boolean, timeoutMs?: number}} r
 */
function explainFailure(step, r) {
    const text = `${r.stdout || ''}\n${r.stderr || ''}`;
    let hint;
    if (r.timedOut) {
        hint = `It did not finish within ${Math.round((r.timeoutMs || 0) / 1000)} seconds. Check your connection and try again.`;
    } else if (r.notStarted) {
        hint = 'The claude program could not be started. Reinstall Claude Code, or set "taskNotifier.claudePath" to the full path of claude.exe.';
    } else {
        const found = HINTS.find(([re]) => re.test(text));
        hint = found ? found[1] : 'See the "Task Notifier" output for the full message.';
    }
    const detail = r.timedOut ? '' : errorLine(text);
    return `${step} failed${detail ? ` (${detail})` : ''}. ${hint}`;
}

module.exports = {
    PLUGIN_NAME, MARKETPLACE_NAME, MARKETPLACE_SOURCE, PLUGIN_ID, ARGS,
    claudeCandidates, findClaude, commandFor, findJsonArray, parsePluginList, doctorScript,
    errorLine, explainFailure,
};
