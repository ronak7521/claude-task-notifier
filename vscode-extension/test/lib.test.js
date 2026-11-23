'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const lib = require('../lib');

const EXT = 'C:\\Users\\me\\.vscode\\extensions\\anthropic.claude-code-2.1.327-win32-x64';
const BUNDLED = `${EXT}\\resources\\native-binary\\claude.exe`;

test('finds the CLI bundled with the Claude Code extension first', () => {
    const p = lib.findClaude({ claudeExtensionPath: EXT, env: { USERPROFILE: 'C:\\Users\\me', PATH: 'C:\\tools' }, exists: () => true });
    assert.equal(p, BUNDLED);
});

test('a configured path wins over everything else', () => {
    const p = lib.findClaude({ configured: 'D:\\claude\\claude.exe', claudeExtensionPath: EXT, env: {}, exists: () => true });
    assert.equal(p, 'D:\\claude\\claude.exe');
});

test('falls back to the native installer folder, then PATH (.exe before .cmd)', () => {
    const env = { USERPROFILE: 'C:\\Users\\me', PATH: 'C:\\npm;C:\\other' };
    assert.equal(lib.findClaude({ env, exists: (p) => p === 'C:\\Users\\me\\.local\\bin\\claude.exe' || p.startsWith('C:\\npm') }),
        'C:\\Users\\me\\.local\\bin\\claude.exe');
    assert.equal(lib.findClaude({ env, exists: (p) => p.startsWith('C:\\npm') }), 'C:\\npm\\claude.exe');
    assert.equal(lib.findClaude({ env, exists: (p) => p === 'C:\\npm\\claude.cmd' }), 'C:\\npm\\claude.cmd');
});

test('returns null when Claude Code is not installed', () => {
    assert.equal(lib.findClaude({ claudeExtensionPath: EXT, env: { PATH: 'C:\\x' }, exists: () => false }), null);
});

test('security: never looks in relative, empty or network PATH entries (a workspace could plant claude.exe)', () => {
    const list = lib.claudeCandidates({ env: { PATH: '.;;bin;.\\tools;"C:\\quoted dir";\\\\server\\share;C:\\ok' } });
    assert.deepEqual(list, [
        'C:\\quoted dir\\claude.exe', 'C:\\quoted dir\\claude.cmd',
        'C:\\ok\\claude.exe', 'C:\\ok\\claude.cmd',
    ]);
});

test('security: a relative or non-executable configured path is ignored', () => {
    assert.deepEqual(lib.claudeCandidates({ configured: 'claude.exe', env: {} }), []);
    assert.deepEqual(lib.claudeCandidates({ configured: 'C:\\x\\claude.ps1', env: {} }), []);
});

test('an .exe is started directly with the fixed arguments', () => {
    const c = lib.commandFor(BUNDLED, lib.ARGS.list, 'C:\\Windows');
    assert.deepEqual(c, { file: BUNDLED, args: ['plugin', 'list', '--json'], verbatim: false });
});

test('a .cmd goes through cmd.exe by full path, quoted for /s', () => {
    const c = lib.commandFor('C:\\Program Files\\nodejs\\claude.cmd', lib.ARGS.install, 'C:\\Windows');
    assert.equal(c.file, 'C:\\Windows\\System32\\cmd.exe');
    assert.deepEqual(c.args, ['/d', '/s', '/c', '""C:\\Program Files\\nodejs\\claude.cmd" plugin install task-notifier@ronak-plugins"']);
    assert.equal(c.verbatim, true);
});

test('security: a .cmd path with cmd metacharacters is refused', () => {
    for (const bad of ['C:\\a&calc\\claude.cmd', 'C:\\a"b\\claude.cmd', 'C:\\%x%\\claude.cmd', 'C:\\a|b\\claude.cmd', 'C:\\a^b\\claude.cmd', 'C:\\a!b\\claude.cmd']) {
        assert.throws(() => lib.commandFor(bad, ['plugin'], 'C:\\Windows'), /Unsafe/, bad);
    }
});

test('the CLI arguments are fixed and name only this plugin', () => {
    assert.ok(Object.isFrozen(lib.ARGS));
    assert.deepEqual(lib.ARGS.addMarketplace, ['plugin', 'marketplace', 'add', 'ronak7521/claude-task-notifier']);
    for (const args of Object.values(lib.ARGS)) {
        for (const a of args) assert.match(a, /^[\w@./-]+$/);
    }
});

const LIST = JSON.stringify([
    { id: 'superpowers@claude-plugins-official', version: 'abc', scope: 'user', enabled: true, installPath: 'C:\\x' },
    { id: 'task-notifier@ronak-plugins', version: '1.4.0', scope: 'project', enabled: true, installPath: 'C:\\p' },
    { id: 'task-notifier@ronak-plugins', version: '1.5.0', scope: 'user', enabled: false, installPath: 'C:\\u' },
]);

test('reads the installed plugin, preferring the user-scope copy', () => {
    assert.deepEqual(lib.parsePluginList(LIST), { installed: true, enabled: false, version: '1.5.0', installPath: 'C:\\u', scope: 'user' });
});

test('reads the list even with text before the JSON', () => {
    assert.equal(lib.parsePluginList(`Checking...\n${LIST}`).version, '1.5.0');
});

test('not installed, or another marketplace with the same plugin name', () => {
    const other = JSON.stringify([{ id: 'task-notifier@someone-else', version: '9', scope: 'user', installPath: 'C:\\o' }]);
    assert.equal(lib.parsePluginList(other).installed, false);
    assert.equal(lib.parsePluginList('[]').installed, false);
});

test('reads the list between notices, even ones in brackets', () => {
    const pretty = JSON.stringify(JSON.parse(LIST), null, 2);
    assert.equal(lib.parsePluginList(`[warn] A new version is available\n${pretty}\n[info] done\n`).version, '1.5.0');
    assert.equal(lib.parsePluginList(`${LIST}\r\nUpdate available: run claude update\r\n`).version, '1.5.0');
    assert.equal(lib.parsePluginList('[notice] nothing\n[]\n').installed, false);
    assert.equal(lib.parsePluginList(`[1]\n${LIST}`).version, '1.5.0');
});

test('bad output from the CLI is an error, not "not installed"', () => {
    assert.throws(() => lib.parsePluginList('error: unknown command'), /JSON/);
    assert.throws(() => lib.parsePluginList('[not json'));
});

test('doctor script: found in the install folder, missing before 1.5.0', () => {
    assert.equal(lib.doctorScript('C:\\u', () => true), 'C:\\u\\scripts\\doctor.cmd');
    assert.equal(lib.doctorScript('C:\\u', () => false), null);
    assert.equal(lib.doctorScript('', () => true), null);
    assert.equal(lib.doctorScript('relative\\dir', () => true), null);
});

test('failure messages name the step, quote the error line and say what to do', () => {
    const net = lib.explainFailure('Installing the plugin', { code: 1, stdout: 'Cloning...\n', stderr: "fatal: unable to access 'https://github.com/x/': Could not resolve host: github.com\n" });
    assert.match(net, /^Installing the plugin failed \(fatal: unable to access/);
    assert.match(net, /could not reach GitHub/);
    assert.match(lib.explainFailure('x', { code: 1, stderr: 'Error: spawn git ENOENT' }), /Install Git for Windows/);
    assert.match(lib.explainFailure('x', { code: 1, stderr: 'HTTP 403: API rate limit exceeded' }), /rate limit or no access/);
    assert.match(lib.explainFailure('x', { code: 1, stderr: 'EPERM: operation not permitted, rename' }), /Windows refused access/);
    assert.match(lib.explainFailure('x', { code: 1, stderr: 'Plugin task-notifier not found in marketplace ronak-plugins' }), /catalog/);
    assert.match(lib.explainFailure('x', { code: 1, stderr: 'Blocked by managed settings policy' }), /IT admin/);
    assert.match(lib.explainFailure('x', { code: 1, stderr: 'weird' }), /\(weird\)\. See the "Task Notifier" output/);
});

test('a GitHub 403 from git is a rate limit or access problem, not "check your internet"', () => {
    const r = lib.explainFailure('x', { code: 1, stderr: "fatal: unable to access 'https://github.com/ronak7521/claude-task-notifier.git/': The requested URL returned error: 403" });
    assert.match(r, /rate limit or no access/);
    assert.doesNotMatch(r, /internet connection/);
});

test('failure messages for a timeout or a claude that cannot start', () => {
    assert.match(lib.explainFailure('x', { code: 1, timedOut: true, timeoutMs: 180000 }), /^x failed\. It did not finish within 180 seconds/);
    assert.match(lib.explainFailure('x', { code: 1, notStarted: true, stderr: 'spawn C:\\c\\claude.exe ENOENT' }), /claudePath/);
});

test('the error line skips colours and progress lines and is kept short', () => {
    assert.equal(lib.errorLine('\x1b[32mFetching\x1b[0m\n\x1b[31m✘ Failed to install\x1b[0m\ndone'), '✘ Failed to install');
    assert.equal(lib.errorLine('one\ntwo\n'), 'two');
    assert.equal(lib.errorLine('error ' + 'x'.repeat(300)).length, 200);
    assert.equal(lib.errorLine(''), '');
});

const AUTO = { source: { source: 'github', repo: 'ronak7521/claude-task-notifier' }, autoUpdate: true };

test('auto-update: added to settings.json, keeping everything else and its formatting', () => {
    const text = '{\r\n    "model": "opus",\r\n    "extraKnownMarketplaces": {\r\n        "other": { "source": { "source": "github", "repo": "a/b" } }\r\n    }\r\n}\r\n';
    const r = lib.declareAutoUpdate(text);
    assert.equal(r.changed, true);
    const s = JSON.parse(r.text);
    assert.equal(s.model, 'opus');
    assert.deepEqual(s.extraKnownMarketplaces.other, { source: { source: 'github', repo: 'a/b' } });
    assert.deepEqual(s.extraKnownMarketplaces['ronak-plugins'], AUTO);
    assert.match(r.text, /^\{\r\n {4}"model"/);
    assert.ok(r.text.endsWith('}\r\n'));
});

test('auto-update: a missing, empty or BOM-prefixed settings file', () => {
    for (const t of [null, '', '﻿{}']) {
        const r = lib.declareAutoUpdate(t);
        assert.deepEqual(JSON.parse(r.text), { extraKnownMarketplaces: { 'ronak-plugins': AUTO } }, String(t));
    }
});

test('auto-update: a choice the user made is kept', () => {
    const off = JSON.stringify({ extraKnownMarketplaces: { 'ronak-plugins': { source: { source: 'github', repo: 'x/y' }, autoUpdate: false } } });
    assert.deepEqual(lib.declareAutoUpdate(off), { changed: false, reason: 'turned off in your settings, so it was left off' });
    assert.equal(lib.declareAutoUpdate(JSON.stringify({ extraKnownMarketplaces: { 'ronak-plugins': AUTO } })).changed, false);
    const ownSource = lib.declareAutoUpdate(JSON.stringify({ extraKnownMarketplaces: { 'ronak-plugins': { source: { source: 'git', url: 'https://x' } } } }));
    assert.deepEqual(JSON.parse(ownSource.text).extraKnownMarketplaces['ronak-plugins'], { source: { source: 'git', url: 'https://x' }, autoUpdate: true });
});

test('auto-update: turned off in /plugin before the extension wrote anything is kept off', () => {
    const known = JSON.stringify({ 'ronak-plugins': { source: { source: 'github', repo: 'x/y' }, autoUpdate: false } });
    assert.equal(lib.registeredAutoUpdate(known), false);
    assert.deepEqual(lib.declareAutoUpdate('{}', lib.registeredAutoUpdate(known)),
        { changed: false, reason: 'turned off in Claude Code (/plugin), so it was left off' });
    // Never chosen (no field), or the file is missing or unreadable: turn it on.
    for (const k of [JSON.stringify({ 'ronak-plugins': { source: {} } }), null, 'not json', '{}']) {
        assert.equal(lib.registeredAutoUpdate(k), undefined, String(k));
        assert.equal(lib.declareAutoUpdate('{}', lib.registeredAutoUpdate(k)).changed, true, String(k));
    }
    // An explicit true in settings.json still wins over an older false in the registry.
    assert.equal(lib.declareAutoUpdate(JSON.stringify({ extraKnownMarketplaces: { 'ronak-plugins': AUTO } }), false).reason, 'already on');
});

test('auto-update: settings that are not plain JSON are never rewritten', () => {
    for (const t of ['{ // comment\n "a": 1 }', '[1]', '"x"', JSON.stringify({ extraKnownMarketplaces: [] })]) {
        assert.equal(lib.declareAutoUpdate(t).changed, false, t);
    }
});

test('start-up lock: one window at a time, released after, taken over when stale', () => {
    const os = require('os');
    const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'tn-lock-')), 'startup.lock');
    const release = lib.tryLock(file, 60000, fs);
    assert.equal(typeof release, 'function');
    assert.equal(lib.tryLock(file, 60000, fs), null, 'a second window is turned away');
    release();
    assert.equal(fs.existsSync(file), false);
    const again = lib.tryLock(file, 60000, fs);
    assert.equal(typeof again, 'function', 'free again after release');
    const old = new Date(Date.now() - 120000);
    fs.utimesSync(file, old, old);
    const takeover = lib.tryLock(file, 60000, fs);
    assert.equal(typeof takeover, 'function', 'a lock left by a crashed window is taken over');
    takeover();
    assert.equal(typeof lib.tryLock(path.join(file, 'no', 'such', 'dir'), 60000, fs), 'function', 'no usable lock file: go ahead');
    fs.rmSync(path.dirname(file), { recursive: true, force: true });
});

test('start-up lock: two windows that both see a crashed window\'s lock cannot both take it over', () => {
    const os = require('os');
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tn-race-'));
    const file = path.join(dir, 'startup.lock');
    const old = new Date(Date.now() - 120000);
    fs.writeFileSync(file, 'crashed');
    fs.utimesSync(file, old, old);

    // Window B looks first and sees the old lock; window A then completes a takeover before B goes on.
    let releaseA;
    let firstLook = true;
    const fsB = {
        ...fs,
        statSync: (p, ...r) => {
            const st = fs.statSync(p, ...r);
            if (p === file && firstLook) { firstLook = false; releaseA = lib.tryLock(file, 60000, fs); }
            return st;
        },
    };
    const b = lib.tryLock(file, 60000, fsB);
    assert.equal(typeof releaseA, 'function', 'A took over the old lock');
    assert.equal(b, null, 'B sees the lock is now in use and stays out');
    assert.equal(fs.readFileSync(file, 'utf8'), String(process.pid), 'A\'s lock was not removed by B');
    assert.equal(fs.existsSync(`${file}.takeover`), false, 'the takeover guard is cleaned up');

    // While a takeover is under way, others stay out; a guard left by a crash is cleared for the next start.
    releaseA();
    fs.writeFileSync(file, 'crashed'); fs.utimesSync(file, old, old);
    fs.writeFileSync(`${file}.takeover`, 'busy');
    assert.equal(lib.tryLock(file, 60000, fs), null, 'a takeover in progress');
    fs.utimesSync(`${file}.takeover`, old, old);
    assert.equal(lib.tryLock(file, 60000, fs), null, 'an old guard is cleared, not used');
    assert.equal(fs.existsSync(`${file}.takeover`), false);
    const next = lib.tryLock(file, 60000, fs);
    assert.equal(typeof next, 'function', 'the next start takes over');
    next();
    fs.rmSync(dir, { recursive: true, force: true });
});

test('extension.js: start-up check is locked across windows, settings are written through symlinks', () => {
    const src = fs.readFileSync(path.join(__dirname, '..', 'extension.js'), 'utf8');
    assert.match(src, /lib\.tryLock\(/);
    assert.match(src, /finally \{\s*release\(\);/);
    assert.match(src, /file = fs\.realpathSync\(file\)/);
});

test('package.json: commands, Windows-only targets and a machine-scoped claude path', () => {
    const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'package.json'), 'utf8'));
    const src = fs.readFileSync(path.join(__dirname, '..', 'extension.js'), 'utf8');
    for (const c of pkg.contributes.commands) assert.ok(src.includes(`'${c.command}'`), `${c.command} is registered`);
    assert.equal(pkg.publisher, 'RonakChotaliya');
    // A workspace must not be able to point the extension at a claude.exe of its choosing.
    assert.equal(pkg.contributes.configuration.properties['taskNotifier.claudePath'].scope, 'machine');
    assert.equal(pkg.contributes.configuration.properties['taskNotifier.autoUpdatePlugin'].scope, 'machine');
    assert.equal(pkg.contributes.configuration.properties['taskNotifier.autoUpdatePlugin'].default, true);
    assert.match(pkg.scripts.package, /--target win32-x64/);
    assert.deepEqual(pkg.extensionKind, ['ui']);
});

test('extension.js: the doctor runs as "outside a session", and a failed catalog refresh is an error', () => {
    const src = fs.readFileSync(path.join(__dirname, '..', 'extension.js'), 'utf8');
    // The doctor reads CLAUDECODE to decide whether it runs inside Claude Code.
    assert.match(src, /toUpperCase\(\) === 'CLAUDECODE'\) delete env\[k\]/);
    assert.match(src, /refresh\.code !== 0\) throw/);
    assert.match(src, /cwd: os\.homedir\(\)/);
});

test('extension.js: the start-up prompts are modal, so they cannot hide in the notification bell', () => {
    const src = fs.readFileSync(path.join(__dirname, '..', 'extension.js'), 'utf8');
    assert.match(src, /showInformationMessage\(text, \{ modal: true/);
    assert.match(src, /reportNoClaude\(true\)/);
    assert.match(src, /modal: atStartup/);
});
