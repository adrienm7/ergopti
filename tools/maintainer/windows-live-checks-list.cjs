// tools/maintainer/windows-live-checks-list.cjs

/**
 * ==============================================================================
 * MODULE: Windows Live Checks, the list
 * DESCRIPTION:
 * One entry per check of the maintainer's Windows PC lists that can run against
 * a real, isolated driver (windows-live-checks.cjs). A check boots what it
 * needs, drives it through the live harness, judges the answers, and returns
 * { state: 'PASS' | 'FAIL' | 'NOT EXECUTED', detail }.
 *
 * FEATURES & RATIONALE:
 * 1. Every driver boots in English, so a row is named by its caption.
 * 2. A check that cannot judge (a precondition is missing) says NOT EXECUTED
 *    with the reason; it never passes by default.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { KEY } = require('../lib/_generated/config_keys.cjs');
const live = require('./windows-live-checks.cjs');

const pass = (detail) => ({ state: 'PASS', detail });
const fail = (detail) => ({ state: 'FAIL', detail });
const notExecuted = (detail) => ({ state: 'NOT EXECUTED', detail });
const ENGLISH = "[script]\nlocale = 'en'\n";
const RELOAD_ROW = 're:Reload$';
const SUSPEND_ROW = 're:Suspend$';

/**
 * Boots an English driver, optionally over a seeded configuration.
 * @param {object} context The check context.
 * @param {string} name Session label.
 * @param {string} [extraToml] TOML appended to the English locale line.
 * @returns {Promise<{session: object, pid: number}>}
 */
async function bootEnglish(context, name, extraToml = '') {
	const session = context.newSession(name);
	session.seed('autohotkey/config.toml', ENGLISH + extraToml);
	const pid = await session.start();
	return { session, pid };
}

/**
 * Boots an English driver with the Metrics category on, switched on through its own
 * menu row (the stored key has been renamed before), then boots it again over the
 * same profile so a click can happen while that second driver starts.
 * @param {object} context The check context.
 * @param {string} name Session label.
 * @param {object} [restartOptions] Options of the second boot (startupClicks, expectReload).
 * @returns {Promise<{session: object, pid: number}>}
 */
async function bootWithMetrics(context, name, restartOptions = {}) {
	const { session, pid } = await bootEnglish(context, name);
	// Enabling the metrics may first show a security warning to confirm.
	await session.run(
		'click_confirming',
		['Security Warning', 're:Metrics$', 're:Enable metrics'],
		180000,
		{
			followReload: true
		}
	);
	await session.quiesce(pid);
	const second = await session.restart(restartOptions);
	return { session, pid: second };
}

/**
 * Runs tools/control/request_driver_reload.ps1 against a session's control folder.
 * @param {object} session The session whose driver is asked.
 * @param {number} [timeoutMs] The script's own wait for completion.
 * @returns {{code: number, outcome: object|null, text: string}}
 */
function requestReload(session, timeoutMs = 90000) {
	const script = path.join(live.ROOT, 'tools', 'control', 'request_driver_reload.ps1');
	const out = spawnSync(
		'powershell.exe',
		['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, '-TimeoutMs', String(timeoutMs)],
		{
			env: { ...process.env, LOCALAPPDATA: session.root },
			encoding: 'utf8',
			timeout: timeoutMs + 60000,
			windowsHide: true
		}
	);
	const text = (out.stdout || '').trim();
	let outcome = null;
	try {
		outcome = JSON.parse(text.split(/\r?\n/).pop());
	} catch {
		outcome = null;
	}
	return { code: out.status, outcome, text: text || (out.stderr || '').trim() };
}

// The shipped French magic-key pack, without the layout emulation: c★ gives c’est.
const MAGIC_KEY_CONFIG = [
	'[category_enabled]',
	'hotstrings = true',
	'french_magickey = true',
	'[hotstrings.french_magickey.text_expansion]',
	'enabled = true',
	'[hotstrings.french_magickey.text_expansion_auto]',
	'enabled = true',
	'[hotstrings.french_magickey.text_expansion_emojis]',
	'enabled = true',
	''
].join('\n');

/**
 * Waits for a log line (the driver flushes its logs in batches).
 * @param {object} session The session.
 * @param {string} fragment Text the line must contain.
 * @param {Set<string>} before The log lines that existed before the action.
 * @param {number} timeoutMs Limit.
 * @returns {Promise<string|null>} The first such new line, or null.
 */
async function waitForLog(session, fragment, before, timeoutMs) {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		const line = session.logLines(fragment).find((candidate) => !before.has(candidate));
		if (line) return line;
		await live.sleep(250);
	}
	return null;
}

/**
 * Closes Windows Search if it holds the foreground: a Win+S the driver missed
 * opens it, and left there it takes the keys and the focus of the checks after.
 * @returns {boolean} Whether it was open.
 */
function closeWindowsSearch() {
	const script = `Add-Type -Namespace LiveChecks -Name Foreground -MemberDefinition '[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int p);'; $owner = 0; [void][LiveChecks.Foreground]::GetWindowThreadProcessId([LiveChecks.Foreground]::GetForegroundWindow(), [ref]$owner); if ((Get-Process -Id $owner).ProcessName -eq 'SearchHost') { (New-Object -ComObject WScript.Shell).SendKeys('{ESC}'); Start-Sleep -Milliseconds 600; 'closed' }`;
	const out = spawnSync('powershell.exe', ['-NoProfile', '-Command', script], {
		encoding: 'utf8',
		windowsHide: true,
		timeout: 30000
	});
	return (out.stdout || '').includes('closed');
}

/**
 * Closes the Explorer windows showing a folder, so a check leaves none behind.
 * @param {string} folder The folder a check opened.
 */
function closeExplorerWindows(folder) {
	const script = `$wanted = '${folder.replace(/'/g, "''")}'; (New-Object -ComObject Shell.Application).Windows() | Where-Object { $_.Document -and $_.Document.Folder -and $_.Document.Folder.Self.Path -eq $wanted } | ForEach-Object { $_.Quit() }`;
	spawnSync('powershell.exe', ['-NoProfile', '-Command', script], {
		windowsHide: true,
		timeout: 30000
	});
}

/** The count of driver processes of a session, successors included. */
const driverCount = (session) => session.processes().length;

/**
 * The shipped English locale, which names every row of an English driver.
 * @returns {Object<string, string>}
 */
function englishLocale() {
	return JSON.parse(
		fs.readFileSync(
			path.join(live.ROOT, 'static', 'ergopti_plus', '_shared', 'data', 'locales', 'en.json'),
			'utf8'
		)
	);
}

/** A literal text as a regular expression that matches only it. */
const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** Collapses every run of white space, so a dialog's line breaks compare as spaces. */
const squash = (text) => text.replace(/\s+/g, ' ').trim();

/**
 * Finds a rule in a shipped hotstring file, so a check typing it says when the
 * data it relies on moved instead of failing on the driver.
 * @param {string} relative Path under _shared/modules/hotstrings.
 * @param {string} trigger The rule's trigger.
 * @returns {{section: string, line: string}|null}
 */
function shippedRule(relative, trigger) {
	const file = path.join(live.ROOT, 'static', 'ergopti_plus', '_shared', 'modules', 'hotstrings');
	let section = '';
	for (const line of fs.readFileSync(path.join(file, relative), 'utf8').split(/\r?\n/)) {
		const header = /^\[\[([a-z0-9_]+)\]\]/.exec(line);
		if (header) section = header[1];
		else if (line.startsWith(`${JSON.stringify(trigger)} = {`)) return { section, line };
	}
	return null;
}

/**
 * Types a script into a fresh typing target and reads back what it holds.
 * No hse_reset: it makes the word start unknown, and word-start rules refuse.
 * @param {object} session The session.
 * @param {string[][]} steps Typist lines after the common head.
 * @param {number} [gap] Milliseconds after each key.
 * @returns {Promise<string>} The target's text, line breaks as backslash-n.
 */
async function typeInto(session, steps, gap = 120) {
	await session.run('edit_open');
	session.type([
		['mode', 'event'],
		['level', '100'],
		['gap', String(gap)],
		...steps,
		['wait', '900']
	]);
	const value = (await session.run('edit_value')).replace(/^value=/, '');
	await session.run('edit_close');
	return value;
}

/**
 * Reads the `rows` command's answer as rows.
 * @param {string} answer "A > B > C  [checked]  [disabled] | ..." as LiveCmdRows writes it.
 * @returns {{path: string[], checked: boolean, disabled: boolean}[]}
 */
function parseRows(answer) {
	return answer
		.split(' | ')
		.filter(Boolean)
		.map((line) => ({
			path: line.replace(/ {2}\[(checked|disabled)\]/g, '').split(' > '),
			checked: line.includes('  [checked]'),
			disabled: line.includes('  [disabled]')
		}));
}

/** Parses "key=value" pairs out of a command's detail line. */
function fields(detail) {
	const found = {};
	for (const match of (detail || '').matchAll(/(\w+)=(.*?)(?= \w+=|$)/g))
		found[match[1]] = match[2];
	return found;
}

/**
 * A file of the driver's configuration folder, as exact bytes.
 * @param {object} session The session.
 * @param {string} relative Path under the configuration folder.
 * @returns {Buffer|null} The bytes, or null when absent.
 */
function configBytes(session, relative) {
	const file = path.join(session.config, relative);
	return fs.existsSync(file) ? fs.readFileSync(file) : null;
}

/**
 * The names of the driver's backup files for one base name.
 * @param {object} session The session.
 * @param {RegExp} pattern What a backup's name looks like.
 * @returns {string[]}
 */
function backupNames(session, pattern) {
	const folder = path.join(session.config, 'autohotkey');
	return fs.existsSync(folder) ? fs.readdirSync(folder).filter((name) => pattern.test(name)) : [];
}

/**
 * The current version of a migration registry, read from its file.
 * @param {string} relative Path under _shared.
 * @returns {number}
 */
function registryVersion(relative) {
	const text = fs.readFileSync(
		path.join(live.ROOT, 'static', 'ergopti_plus', '_shared', relative),
		'utf8'
	);
	return Number(/^current_version = (\d+)/m.exec(text)[1]);
}

/**
 * The oldest config.toml version the shipped registry still migrates.
 * @returns {number}
 */
function oldestVersion() {
	const text = fs.readFileSync(
		path.join(
			live.ROOT,
			'static',
			'ergopti_plus',
			'_shared',
			'core',
			'config_schema',
			'migrations.toml'
		),
		'utf8'
	);
	return Number(/^oldest_version = (\d+)/m.exec(text)[1]);
}

/**
 * The machine's HKCU touchpad values, read only: an isolated driver must never
 * change them (on 2026-11-11 a Gestures Clear all reset them to the factory values).
 * @returns {string}
 */
function touchpadRegistry() {
	const out = spawnSync(
		'reg.exe',
		['query', 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\PrecisionTouchPad', '/s'],
		{ encoding: 'utf8', windowsHide: true }
	);
	return out.stdout || '';
}

/**
 * The private touchpad key an isolated driver writes instead of the machine's
 * (TouchpadRegistryPrivatePath in modules/gestures/touchpad_registry.ahk).
 * @param {object} session The session.
 * @returns {Map<string, number>|null} name => DWORD, or null when the driver wrote none.
 */
function privateTouchpadKey(session) {
	const file = path.join(session.root, 'touchpad_registry_private.txt');
	if (!fs.existsSync(file)) return null;
	const lines = fs.readFileSync(file, 'utf8').replace(/^﻿/, '').split('\n').filter(Boolean);
	if (lines[0] !== 'ergopti-touchpad-private-key 1')
		throw new Error(`${file} does not start with the private key header`);
	return new Map(
		lines.slice(2).map((line) => {
			const [name, , value] = line.split(' ');
			return [name, Number(value)];
		})
	);
}

/**
 * The Windows factory touchpad values, which a Clear all writes without a backup.
 * @returns {Map<string, number>}
 */
function touchpadFactoryDefaults() {
	const { buildContract, SOURCE } = require('../codegen/codegen-touchpad-registry.cjs');
	const contract = buildContract(require('smol-toml').parse(fs.readFileSync(SOURCE, 'utf8')));
	return new Map(contract.factoryDefaults.map((entry) => [entry.name, entry.value]));
}

/**
 * Says how a private touchpad key differs from the factory values, or '' when it holds them.
 * @param {Map<string, number>|null} key privateTouchpadKey().
 * @param {string} after What the driver had just done.
 * @returns {string}
 */
function touchpadFactoryProblem(key, after) {
	if (!key) return `${after} wrote no private touchpad key`;
	const factory = touchpadFactoryDefaults();
	const wrong = [...new Set([...factory.keys(), ...key.keys()])].filter(
		(name) => key.get(name) !== factory.get(name)
	);
	return wrong.length > 0
		? `${after} left the private touchpad key off its factory values: ${wrong.join(', ')}`
		: '';
}

// What Clear all and Restore recommended must leave alone in every category.
const SENTINELS_TOML = [
	'# a comment the user wrote',
	'[zz_live_unknown]',
	"keep = 'unknown key'",
	'[llm]',
	"trigger_shortcut = '^!a'",
	''
].join('\n');

/**
 * Ticks a category's enable row when it reads off. Since 77f417280e an off category
 * greys every other row of its menu (menu.category_off_reason), its Restore and
 * Clear included, and a fresh profile starts with the categories off.
 * @param {object} session The session.
 * @param {number} pid The serving driver.
 * @param {string} menu The category submenu's click specifier ('re:Shortcuts$').
 * @param {string} enable The enable row's English caption, unique in the tray.
 * @param {string} [dialog] A confirmation the switch shows ('.' for none).
 * @returns {Promise<number>} The driver serving afterwards.
 */
async function ensureCategoryOn(session, pid, menu, enable, dialog = '.') {
	const rows = (await session.run('rows', [`^${enable}`])).split(' | ').filter(Boolean);
	if (rows.length !== 1) throw new Error(`${rows.length} "${enable}" rows in the tray`);
	if (rows[0].includes('[checked]')) return pid;
	await session.run('click_confirming', [dialog, menu, `re:^${enable}`], 180000, {
		followReload: true
	});
	return (await session.quiesce(pid)).pid;
}

/**
 * Clicks one Clear or Restore row and judges what any scoped change must respect.
 * @param {object} session The session.
 * @param {number} pid The serving pid.
 * @param {string[]} row The row's path.
 * @param {string} label The name in a failure.
 * @param {RegExp} scope The configuration keys the row may change.
 * @param {string[]} problems Collects failures.
 * @returns {Promise<{pid: number, config: object, changed: number}>}
 */
async function clickScoped(session, pid, row, label, scope, problems) {
	const before = configBytes(session, 'autohotkey/config.toml');
	const beforeTap = configBytes(session, 'autohotkey/tap_hold.toml');
	const snapshot = live.configSnapshot(session);
	const backups = new Set(backupNames(session, /\.backup-/));
	try {
		await session.run('click_confirming', ['.', ...row], 180000, { followReload: true });
	} catch (error) {
		throw new Error(`${label}: ${error.message}`);
	}
	const settled = await session.quiesce(pid);
	const config = live.configSnapshot(session);
	const changes = live.diffSnapshots(snapshot, config);
	const stray = changes.filter((change) => !scope.test(change.key));
	if (stray.length > 0)
		problems.push(`${label}: outside its scope: ${stray.map((c) => c.key).join(', ')}`);
	if (config['zz_live_unknown.keep'] !== JSON.stringify('unknown key'))
		problems.push(`${label}: the unknown key is gone`);
	if (config['llm.trigger_shortcut'] !== JSON.stringify('^!a'))
		problems.push(`${label}: the outdated key is gone`);
	const after = configBytes(session, 'autohotkey/config.toml');
	if (!after.equals(before)) {
		const fresh = backupNames(session, /\.backup-/).filter((name) => !backups.has(name));
		// Whole stems: a literal ending in "." reads as a locale key prefix to
		// audit-translations.cjs and kept the dead tap_hold.picker keys alive.
		const config = fresh.filter((name) => name.startsWith('config.backup-'));
		const tap = fresh.filter((name) => name.startsWith('tap_hold.backup-'));
		if (config.length !== 1) problems.push(`${label}: ${config.length} configuration backups`);
		else if (!configBytes(session, `autohotkey/${config[0]}`).equals(before))
			problems.push(`${label}: the backup ${config[0]} is not the exact earlier file`);
		// With no tap_hold.toml yet the backup holds the empty source it replaced.
		for (const name of tap)
			if (!configBytes(session, `autohotkey/${name}`).equals(beforeTap ?? Buffer.alloc(0)))
				problems.push(`${label}: the backup ${name} is not the exact earlier file`);
	}
	const dialogs = await session.run('dialogs');
	if (dialogs !== 'dialogs=') problems.push(`${label}: a dialog stays open: ${dialogs}`);
	const afterTap = configBytes(session, 'autohotkey/tap_hold.toml');
	const tapChanged = (afterTap ?? Buffer.alloc(0)).equals(beforeTap ?? Buffer.alloc(0)) ? 0 : 1;
	return { pid: settled.pid, config, changed: changes.length + tapChanged };
}

/** @type {{id: string, title: string, run: (context: object) => Promise<object>}[]} */
const CHECKS = [
	{
		id: 'harness-boot',
		title: 'The isolated driver boots and serves its tray tree',
		async run(context) {
			const { session, pid } = await bootEnglish(context, 'boot');
			const info = await session.run('info');
			const tree = await session.run('tree');
			return pass(`pid ${pid}; ${info}; ${tree}`);
		}
	},
	{
		id: 'reload-click-joins',
		title: 'A second Reload click made during a reload joins it: one reload, one driver afterwards',
		async run(context) {
			const { session, pid } = await bootEnglish(context, 'join');
			await session.run('click_repeat', ['2', '60', RELOAD_ROW], 180000, { followReload: true });
			const settled = await session.quiesce(pid);
			if (!settled.reloaded) return fail('the Reload click did not reload the driver');
			const requests = session.logLines('Reload requested by').length;
			const joined = session.logLines('joined the reload in flight').length;
			if (requests !== 1) return fail(`${requests} reloads were requested, one expected`);
			if (joined !== 1) return fail(`the second click was not logged as joined (${joined} lines)`);
			if (driverCount(session) !== 1)
				return fail(`${driverCount(session)} drivers run after the reload`);
			const errors = session.loggedErrors();
			if (errors.length > 0) return fail(`the log holds an error: ${errors[0]}`);
			return pass(
				`two clicks, one reload (pid ${pid} -> ${settled.pid}), the second logged as joined, one driver`
			);
		}
	},
	{
		id: 'reload-command',
		title: 'tools/control/request_driver_reload.ps1: idle, paused, and during a reload',
		async run(context) {
			const { session, pid: first } = await bootEnglish(context, 'command');
			let pid = first;
			// Idle.
			const idle = requestReload(session);
			if (idle.code !== 0 || idle.outcome?.state !== 'completed')
				return fail(`idle: exit ${idle.code}, ${idle.text}`);
			pid = (await session.quiesce(pid)).pid;
			if (pid === first) return fail('idle: the request completed but the driver did not change');
			if (driverCount(session) !== 1)
				return fail(`idle: ${driverCount(session)} drivers run afterwards`);

			// Paused: the successor keeps the pause.
			await session.run('click', [SUSPEND_ROW]);
			await session.run('pump', ['500']);
			if (!/suspended=1/.test(await session.run('info')))
				return fail('paused: the Suspend row did not pause the driver');
			const paused = requestReload(session);
			if (paused.code !== 0 || paused.outcome?.state !== 'completed')
				return fail(`paused: exit ${paused.code}, ${paused.text}`);
			const afterPause = await session.quiesce(pid);
			if (!afterPause.reloaded) return fail('paused: the driver did not reload');
			pid = afterPause.pid;
			if (!/suspended=1/.test(await session.run('info')))
				return fail('paused: the reload dropped the pause');
			if (driverCount(session) !== 1)
				return fail(`paused: ${driverCount(session)} drivers run afterwards`);
			await session.run('click', [SUSPEND_ROW]);
			await session.run('pump', ['500']);

			// During a reload: the request joins the one in flight.
			const answered = await session.run('reload_request_during_reload', [], 180000, {
				followReload: true
			});
			const during = fields(answered);
			const settled = await session.quiesce(pid);
			if (!settled.reloaded) return fail('during a reload: the driver did not reload');
			if (driverCount(session) !== 1)
				return fail(`during a reload: ${driverCount(session)} drivers run afterwards`);
			if (session.logLines('joined the reload in flight').length < 1)
				return fail('during a reload: the request was not logged as joined');
			const errors = session.loggedErrors();
			if (errors.length > 0) return fail(`the log holds an error: ${errors[0]}`);
			return pass(
				`idle completed (pid ${first} -> ${pid}); paused completed and stayed paused; a request during a reload joined it (${during.result || 'result not read'}); one driver each time`
			);
		}
	},
	{
		id: 'tap-delay-row',
		title: 'Tap-Hold > a key > "Tap delay: N ms" opens the input box with N; OK saves and reloads',
		async run(context) {
			const { session, pid } = await bootEnglish(context, 'delay');
			// The row reads « global (200 ms) » until the key has a delay of its own.
			const row = ['re:Tap-Holds$', 're:^Escape', 're:^Tap delay: '];
			const shown = await session.run('rows', ['^Tap delay: ', 'Escape']);
			const before = /Tap delay: \D*(\d+) ms/.exec(shown);
			if (!before) return fail(`the Escape key shows no delay row: ${shown}`);
			const answer = Number(before[1]) === 333 ? '444' : '333';
			const seen = fields(
				await session.run('answer_inputbox', [
					answer,
					'menu.tapholds.key_tap_delay_dialog_title',
					...row
				])
			);
			if (seen.initial !== before[1])
				return fail(`the input box opened with "${seen.initial}", the row showed ${before[1]} ms`);
			const settled = await session.quiesce(pid);
			if (!settled.reloaded) return fail('OK did not reload the driver');
			const after = await session.run('rows', ['^Tap delay: ', 'Escape']);
			if (!after.includes(`Tap delay: ${answer} ms`))
				return fail(`after the reload the row reads: ${after}`);
			const errors = session.loggedErrors();
			if (errors.length > 0) return fail(`the log holds an error: ${errors[0]}`);
			return pass(
				`opened with ${before[1]}, saved ${answer} ms, reloaded (pid ${pid} -> ${settled.pid}), row re-read`
			);
		}
	},
	{
		id: 'keyboard-group-scope',
		title: 'Shortcuts > a modifier group > Clear all, then Restore: only that group changes',
		async run(context) {
			const { session, pid: first } = await bootEnglish(context, 'group');
			let pid = await ensureCategoryOn(session, first, 're:Shortcuts$', 'Enable shortcuts');
			await session.run('click', ['re:Shortcuts$', 're:Restore recommended']);
			pid = (await session.quiesce(pid)).pid;
			const recommended = live.configSnapshot(session);
			const winKeys = Object.keys(recommended).filter((key) =>
				/^shortcuts\.keyboard\.meta_/.test(key)
			);
			if (winKeys.length < 3)
				return notExecuted(`the recommended preset set ${winKeys.length} Win slots`);

			await session.run('click', ['re:Shortcuts$', 're:Win shortcuts$', 're:Clear all']);
			pid = (await session.quiesce(pid)).pid;
			const cleared = live.configSnapshot(session);
			const clearChanges = live.diffSnapshots(recommended, cleared);
			const stray = clearChanges.filter(
				(change) => !/^shortcuts\.keyboard(_[a-z]+)?\.meta_/.test(change.key)
			);
			if (clearChanges.length === 0) return fail('Clear all in the Win group changed nothing');
			if (stray.length > 0)
				return fail(`Clear all outside its group: ${stray.map((c) => c.key).join(', ')}`);

			await session.run('click', ['re:Shortcuts$', 're:Win shortcuts$', 're:Restore recommended']);
			pid = (await session.quiesce(pid)).pid;
			const restored = live.configSnapshot(session);
			const leftover = live.diffSnapshots(recommended, restored);
			if (leftover.length > 0)
				return fail(
					`Restore did not return to the recommended values: ${leftover.map((c) => c.key).join(', ')}`
				);
			const errors = session.loggedErrors();
			if (errors.length > 0) return fail(`the log holds an error: ${errors[0]}`);
			return pass(
				`Win group cleared (${clearChanges.length} keys) and restored; Ctrl, Ctrl+Shift and the rest untouched`
			);
		}
	},
	{
		id: 'private-browsing-click-during-startup',
		title:
			'The private-browsing metrics filter, clicked during startup, toggles once with no error window',
		async run(context) {
			const { session, pid } = await bootWithMetrics(context, 'startup', {
				startupClicks: [['re:Metrics$', 're:Ignore private browsing']]
			});
			const report = session.startupClickReport();
			if (report.length !== 1 || !report[0].startsWith('clicked'))
				return fail(`the click made during startup was not delivered: ${report.join(' | ')}`);
			const settled = await session.quiesce(pid);
			const config = live.configSnapshot(session);
			if (config[KEY.METRICS_PRIVATE_FILTER_ENABLED] !== 'false')
				return fail(
					`the filter reads ${config[KEY.METRICS_PRIVATE_FILTER_ENABLED]} after one click, false expected`
				);
			const dialogs = await session.run('dialogs');
			if (dialogs !== 'dialogs=') return fail(`a dialog is on screen: ${dialogs}`);
			const errors = session.loggedErrors();
			if (errors.length > 0) return fail(`the log holds an error: ${errors[0]}`);
			const retained = session.logLines(
				'Menu selection retained until input initialization completes'
			).length;
			return pass(
				`clicked before input readiness (retained ${retained}x), toggled once (reload: ${settled.reloaded}), no dialog, no error`
			);
		}
	},
	{
		id: 'private-browsing-click-during-write',
		title:
			'The same click, made while a configuration write is in progress, waits and toggles once',
		async run(context) {
			const { session, pid } = await bootWithMetrics(context, 'write');
			await session.run('lease_hold');
			await session.run('click', ['re:Metrics$', 're:Ignore private browsing']);
			await session.run('pump', ['900']);
			const held = live.configSnapshot(session);
			if (held[KEY.METRICS_PRIVATE_FILTER_ENABLED] === 'false')
				return fail('the click was applied while the configuration write still held its lease');
			if ((await session.run('dialogs')) !== 'dialogs=')
				return fail('an error window opened while the write was in progress');
			await session.run('lease_release');
			const settled = await session.quiesce(pid);
			const config = live.configSnapshot(session);
			if (config[KEY.METRICS_PRIVATE_FILTER_ENABLED] !== 'false')
				return fail(
					`after the write ended the filter reads ${config[KEY.METRICS_PRIVATE_FILTER_ENABLED]}, false expected`
				);
			if (
				session.logLines('Menu command deferred: a configuration write is in progress').length < 1
			)
				return fail('the click was not logged as deferred');
			const errors = session.loggedErrors();
			if (errors.length > 0) return fail(`the log holds an error: ${errors[0]}`);
			return pass(
				`deferred behind the write, applied once after it (reload: ${settled.reloaded}), no dialog, no error`
			);
		}
	},
	{
		id: 'menu-click-replay',
		title: 'Toggles clicked during a startup that requests a reload all apply in the successor',
		async run(context) {
			const { session, pid: first } = await bootWithMetrics(context, 'replay', {
				startupClicks: [
					['re:Metrics$', 're:Ignore private browsing'],
					['re:Metrics$', 're:Ignore password fields'],
					['re:Metrics$', 're:Ignore system authentication'],
					[RELOAD_ROW]
				],
				expectReload: true
			});
			const report = session.startupClickReport();
			if (report.length !== 4 || report.some((line) => !line.startsWith('clicked')))
				return fail(`not every startup click was delivered: ${report.join(' | ')}`);
			const settled = await session.quiesce(first);
			if (!settled.reloaded) return fail('the startup Reload click did not reload the driver');
			const config = live.configSnapshot(session);
			const missing = [
				KEY.METRICS_PRIVATE_FILTER_ENABLED,
				KEY.METRICS_SECURE_FILTER_ENABLED,
				KEY.METRICS_SYSTEM_AUTH_FILTER_ENABLED
			].filter((key) => config[key] !== 'false');
			const dialogs = await session.run('dialogs');
			const handed = session.logLines('menu command(s) handed to the reload successor');
			const replayed = session.logLines('from before the reload replays');
			const errors = session.loggedErrors();
			if (dialogs !== 'dialogs=') return fail(`a dialog is on screen: ${dialogs}`);
			if (errors.length > 0) return fail(`the log holds an error: ${errors[0]}`);
			if (missing.length > 0)
				return fail(
					`${missing.join(', ')} not applied by the successor (handed: ${handed.length}, replayed: ${replayed.length})`
				);
			return pass(
				`three toggles clicked before readiness with a Reload: all applied after the reload (handed ${handed.length} line(s), replayed ${replayed.length}); one driver: ${driverCount(session) === 1}`
			);
		}
	},
	{
		id: 'reload-over-a-log-flush',
		title: 'A reload whose close request lands on a log flush keeps its successor and completes',
		async run(context) {
			const { session, pid: first } = await bootEnglish(context, 'flush');
			await session.run('hold_log_flush');
			await session.run('click', [RELOAD_ROW], 180000, { followReload: true });
			const settled = await session.quiesce(first);
			const refused = session.logLines('Reload refused after launch');
			const errors = session.loggedErrors();
			if (refused.length > 0) return fail(refused[0]);
			if (errors.length > 0) return fail(`the log holds an error: ${errors[0]}`);
			if (!settled.reloaded) return fail('the driver did not reload');
			if (session.logLines('Reload deferred while the log flush').length !== 1)
				return fail('the close request did not land on the held flush');
			const dialogs = await session.run('dialogs');
			if (dialogs !== 'dialogs=') return fail(`a dialog is on screen: ${dialogs}`);
			return pass(
				`the reload was deferred once and completed; one driver: ${driverCount(session) === 1}`
			);
		}
	},
	{
		id: 'quit-over-a-log-flush',
		title: 'One Quit that lands on a log flush exits by itself, with no error window',
		async run(context) {
			const { session } = await bootEnglish(context, 'quitflush');
			await session.run('hold_log_flush');
			await session.run('click', ['re:Quit$'], 20000, { followReload: true });
			const started = Date.now();
			while (session.child.exitCode === null && Date.now() - started < 30000) await live.sleep(100);
			if (session.child.exitCode !== 0)
				return fail(`the Quit ended with ${session.child.exitCode}, 0 expected`);
			const errors = session.loggedErrors();
			if (errors.length > 0) return fail(`the log holds an error: ${errors[0]}`);
			if (session.logLines('Shutdown deferred while the log flush').length !== 1)
				return fail('the Quit did not land on the held flush');
			if (session.logLines('Quit was refused').length > 0)
				return fail('the user was told of a refusal');
			return pass('the Quit was deferred once and exited with no error');
		}
	},
	{
		id: 'win-s-open-target',
		title:
			'Win+S on a selection: a missing path and a bare file name are reported, a folder is opened',
		async run(context) {
			const skip = context.otherDriverReason();
			if (skip) return notExecuted(skip);
			const folder = path.join(context.scratch, 'win s folder');
			fs.mkdirSync(folder, { recursive: true });
			const { session } = await bootEnglish(
				context,
				'wins',
				'[category_enabled]\nshortcuts = true\n[shortcuts.keyboard]\nmeta_s = "copy_selected_path"\n'
			);
			await session.run('pump', ['2500']);
			await session.run('edit_open');
			const cases = [
				{
					name: 'a missing path',
					text: path.join(context.scratch, 'absent folder', 'gone.txt'),
					expect: 'no file or folder exists at that path'
				},
				{
					name: 'a bare file name',
					text: 'notes.txt',
					expect: 'a file name without its folder cannot be located'
				},
				{
					name: 'an existing folder',
					text: folder,
					expect: `Handed the selected path '${folder.replace(os.homedir(), '~')}' to the shell`
				}
			];
			const seen = [];
			try {
				for (const item of cases) {
					await session.run('edit_select', [item.text]);
					const before = new Set(session.logLines(''));
					session.type([
						['mode', 'event'],
						['level', '100'],
						['gap', '80'],
						['key', '#s'],
						['wait', '800']
					]);
					const found = await waitForLog(session, item.expect, before, 12000);
					if (closeWindowsSearch()) {
						seen.push(`${item.name}: Windows Search opened, the driver did not take Win+S`);
					} else if (!found) {
						// A press that never reaches Search ends in the selection capture
						// ([hotstring_engine]) or in the Win broker, so name every owner.
						const logged = session
							.logLines('')
							.filter(
								(line) =>
									!before.has(line) &&
									/\[(Search|hotstring_engine|KeyboardShortcuts|MagicEditor|gestures)\]/.test(line)
							)
							.slice(-6)
							.join(' | ');
						seen.push(
							`${item.name}: no log line "${item.expect}" (Win+S log since the press: ${logged || 'none'})`
						);
					}
				}
			} finally {
				closeWindowsSearch();
				closeExplorerWindows(folder);
			}
			await session.run('edit_close');
			if (seen.length > 0) return fail(seen.join('; '));
			return pass(
				'Win+S reported the missing path and the bare file name, and handed the folder to the shell'
			);
		}
	},
	{
		id: 'backspace-word-start',
		title: 'Backspace word start with real keys: erase, pause, one Backspace, Ctrl+Backspace',
		async run(context) {
			const skip = context.otherDriverReason();
			if (skip) return notExecuted(skip);
			const { session } = await bootEnglish(context, 'bs', MAGIC_KEY_CONFIG);
			await session.run('pump', ['3000']);
			const head = [
				['mode', 'event'],
				['level', '100'],
				['gap', '120']
			];
			const scenarios = [
				{
					name: 'ab, two Backspaces, c★ expands',
					kind: 'edit',
					script: [
						['text', 'ab'],
						['key', '{Backspace}'],
						['key', '{Backspace}'],
						['text', 'c★']
					],
					doc: 'c’est'
				},
				{
					name: 'ab, a pause of 5 s, two Backspaces, c★ expands',
					kind: 'edit',
					script: [
						['text', 'ab'],
						['wait', '5000'],
						['key', '{Backspace}'],
						['key', '{Backspace}'],
						['text', 'c★']
					],
					doc: 'c’est'
				},
				{
					name: 'ab, one Backspace, c★ does not expand',
					kind: 'edit',
					script: [
						['text', 'ab'],
						['key', '{Backspace}'],
						['text', 'c★']
					],
					notDoc: 'c’est'
				},
				{
					name: 'ab, Ctrl+Backspace, c★ expands',
					kind: 'rich',
					script: [
						['text', 'ab'],
						['key', '^{Backspace}'],
						['text', 'c★']
					],
					doc: 'c’est'
				}
			];
			// What the private driver's engine holds is its own verdict. The screen is
			// also the work of any other driver on the desktop, so it counts only when
			// this one is alone.
			const alone = context.otherDriverPids().length === 0;
			const problems = [];
			for (const scenario of scenarios) {
				await session.run('edit_open', [scenario.kind]);
				await session.run('hse_reset');
				session.type([...head, ...scenario.script, ['wait', '900']]);
				const doc = (await session.run('edit_value')).replace(/^value=/, '');
				const engine = (await session.run('hse_buffer')).replace(/^buffer=/, '');
				await session.run('edit_close');
				if (scenario.doc !== undefined && engine !== scenario.doc)
					problems.push(
						`${scenario.name}: the engine holds "${engine}", expected "${scenario.doc}"`
					);
				if (scenario.notDoc !== undefined && engine.includes(scenario.notDoc))
					problems.push(`${scenario.name}: the engine holds "${engine}", which expanded`);
				if (alone && scenario.doc !== undefined && doc !== scenario.doc)
					problems.push(`${scenario.name}: the screen holds "${doc}", expected "${scenario.doc}"`);
			}
			if (problems.length > 0) return fail(problems.join('; '));
			return pass(
				`all four typed scenarios behave as the rules say (${alone ? 'engine and screen judged' : 'engine judged; the screen is not, another driver shares the desktop'})`
			);
		}
	},
	{
		id: 'key-chord-typing',
		title: 'A key chord assigned on Space: the driver boots it, and harness typing keeps its order',
		async run(context) {
			const skip = context.otherDriverReason();
			if (skip) return notExecuted(skip);
			const { session } = await bootEnglish(
				context,
				'chord',
				'[mod_combos.config.space_then_tab]\ncombo = "copy"\n'
			);
			await session.run('pump', ['3000']);
			if (session.logLines('Key chords read: 1 chord').length === 0)
				return fail('the driver did not read the chord of the configuration');
			await session.run('edit_open', ['edit']);
			// A process cannot make a physical press: this input was not seen reaching the
			// chord hotkeys, so a chord firing stays on the maintainer's physical list.
			session.type([
				['mode', 'event'],
				['level', '0'],
				['gap', '5'],
				['key', '{Blind}{SC010}'],
				['key', '{Blind}{SC039}'],
				['key', '{Blind}{SC011}'],
				['wait', '900']
			]);
			const typed = (await session.run('edit_value')).replace(/^value=/, '');
			await session.run('edit_close');
			if (!/^. .$/u.test(typed)) return fail(`letter, Space, letter gave "${typed}" on the screen`);
			const errors = session.loggedErrors();
			if (errors.length > 0) return fail(`the log holds an error: ${errors[0]}`);
			return pass(`the chord is read and harness typing keeps its order ("${typed}")`);
		}
	},
	{
		id: 'number-row-inert-choice',
		title: 'Number row: a choice that has no effect is shown ticked, greyed and suffixed',
		async run(context) {
			const problems = [];
			const seen = [];
			for (const order of ['digits', 'symbols']) {
				const { session } = await bootEnglish(
					context,
					`row-${order}`,
					`[layout]\ndirect_access_digits = "${order}"\nnumber_row_reorder_edges = true\n`
				);
				const rows = (await session.run('rows', ['.', 'Keyboard layout'])).split(' | ');
				const pick = (pattern) => rows.find((row) => pattern.test(row)) || '';
				const wanted = pick(order === 'digits' ? /Digits first/ : /Symbols first/);
				const other = pick(order === 'digits' ? /Symbols first/ : /Digits first/);
				const native = pick(/Native order/);
				const edges = pick(/three edge keys/);
				if (
					!/No effect/.test(wanted) ||
					!/\[checked\]/.test(wanted) ||
					!/\[disabled\]/.test(wanted)
				)
					problems.push(
						`${order}: the chosen order reads "${wanted}", expected ticked, greyed and suffixed`
					);
				if (/\[checked\]/.test(other))
					problems.push(`${order}: the other order is ticked too: "${other}"`);
				if (/\[checked\]/.test(native))
					problems.push(`${order}: Native order is still ticked: "${native}"`);
				if (!/No effect/.test(edges) || !/\[checked\]/.test(edges) || !/\[disabled\]/.test(edges))
					problems.push(
						`${order}: the edge-keys choice reads "${edges}", expected ticked, greyed and suffixed`
					);
				seen.push(wanted.replace(/^.*> /, ''));
				await session.stop();
			}
			if (problems.length > 0) return fail(problems.join('; '));
			return pass(`the inert choices are ticked, greyed and suffixed: ${seen.join(' | ')}`);
		}
	},
	{
		id: 'keycombo-pair-saved',
		title: 'A key-combination pair assignment is saved and still shown after the reload',
		async run(context) {
			const { session, pid: first } = await bootEnglish(context, 'pairsave');
			// Since c0a80da57f a pair row joins its pair and its action through
			// common.label_value ("{1}: {2}" in English), not a hardcoded " : ".
			const locale = JSON.parse(
				fs.readFileSync(
					path.join(live.ROOT, 'static', 'ergopti_plus', '_shared', 'data', 'locales', 'en.json'),
					'utf8'
				)
			);
			const pair = `${locale['key_name.escape']} + ${locale['key_name.tab']}`;
			const head = locale['common.label_value'].split('{2}')[0].replace('{1}', pair);
			const row = [`^${escapeRegExp(head)}`, locale['key_name.escape']];
			const before = await session.run('rows', row);
			if (before.split(' | ').filter(Boolean).length !== 1)
				return fail(`not one pair row matches "${row[0]}" before the assignment: "${before}"`);
			await session.run('pair_assign', ['escape', 'tab', 'tap', 'caps_word'], 180000, {
				followReload: true
			});
			let pid = (await session.quiesce(first)).pid;
			if (pid === first) return fail('the assignment did not reload the driver');
			const config = live.configSnapshot(session);
			const saved = Object.entries(config).filter(
				([key, value]) => /key_combination/.test(key) && value.includes('caps_word')
			);
			if (saved.length === 0)
				return fail('no key-combination entry of the configuration holds caps_word');
			const after = await session.run('rows', row);
			if (after === before || !/caps/i.test(after))
				return fail(`the pair row reads "${after}" after the reload (before: "${before}")`);

			await session.run('pair_assign', ['escape', 'tab', 'hold'], 180000, { followReload: true });
			pid = (await session.quiesce(pid)).pid;
			const final = await session.run('rows', row);
			if (final === after)
				return fail(`the pair row did not change after its hold was assigned: "${final}"`);
			const errors = session.loggedErrors();
			if (errors.length > 0) return fail(`the log holds an error: ${errors[0]}`);
			return pass(
				`tap saved (${saved.map(([key]) => key).join(', ')}) and shown after a reload: ${after.replace(/ \| $/, '')}; hold added: ${final.replace(/ \| $/, '')}`
			);
		}
	},
	{
		id: 'capsword-auto-off',
		title: 'CapsWord ends on each default delimiter, a pointer click and its delay, from real keys',
		async run(context) {
			// CapsWord writes the real CapsLock state, which every keyboard hook of the
			// desktop sees: with another ErgoptiPlus driver there, its CapsLock tap-hold
			// would act on this test. No flag overrides that.
			const others = context.otherDriverPids();
			if (others.length > 0)
				return notExecuted(
					`another ErgoptiPlus driver runs on this desktop (pid ${others.join(', ')}); CapsWord toggles the real CapsLock, which that driver would see`
				);
			const { session } = await bootEnglish(
				context,
				'capsword',
				'[category_enabled]\nshortcuts = true\n[shortcuts.caps_word]\nidle_timeout_seconds = 2\n'
			);
			await session.run('pump', ['2500']);
			const head = [
				['mode', 'event'],
				['level', '100'],
				['gap', '120']
			];
			// A Send that is not blind saves CapsLock, lifts it, and restores it when
			// it ends: measured, {Space} put the toggle back on 15 ms after CapsWord
			// had turned it off, which no physical key can do. So a named key is sent
			// blind and by scan code, what a physical key is and what SC039 and SC01C
			// are bound to. {Text} goes out as a packet and does not touch CapsLock.
			const delimiters = [
				['Space', ['key', '{Blind}{SC039}']],
				['Tab', ['key', '{Blind}{SC00F}']],
				['Enter', ['key', '{Blind}{SC01C}']],
				['comma', ['text', ',']],
				['semicolon', ['text', ';']],
				['period', ['text', '.']],
				['no-break space', ['text', ' ']],
				['narrow no-break space', ['text', ' ']]
			];
			const ends = [
				...delimiters.map(([name, step]) => ({ name: `the ${name}`, between: [step], gap: 0 })),
				{
					// Fast typing: the next key goes down while Space is still held.
					name: 'the Space held over the next key',
					between: [
						['key', '{Blind}{SC039 down}'],
						['key', '{Blind}x'],
						['key', '{Blind}{SC039 up}']
					],
					gap: 0,
					expectEnd: 'xcd'
				},
				{ name: 'a left click', between: [['mouse', 'left']], gap: 0 },
				{
					// The typist cancels the edit control's context menu, which would hold
					// the driver's only thread. The next word still goes to a fresh target,
					// away from the right click.
					name: 'a right click',
					between: [['mouse', 'right']],
					gap: 0,
					freshTarget: true
				},
				{ name: 'the 2 s delay', between: [['wait', '3500']], gap: 0 }
			];
			const problems = [];
			for (const end of ends) {
				await session.run('edit_open');
				if (/enabled=1/.test(await session.run('capsword_state')))
					await session.run('capsword_toggle');
				await session.run('capsword_toggle');
				// Without {Blind} a Send lifts CapsLock around its keys, {Text} included,
				// so only blind letters can show the capitals CapsWord asks for.
				const letters = (word) => [...word].map((letter) => ['key', `{Blind}${letter}`]);
				session.type([...head, ...letters('ab'), ...end.between, ['wait', '150']]);
				// Read before the next word, well inside the 2 s delay: this event ended it.
				const endedByThis = /enabled=0/.test(await session.run('capsword_state'));
				let earlier = '';
				if (end.freshTarget) {
					earlier = (await session.run('edit_value')).replace(/^value=/, '');
					await session.run('edit_close');
					await session.run('edit_open');
				}
				session.type([...head, ...letters('cd'), ['wait', '500']]);
				const value = earlier + (await session.run('edit_value')).replace(/^value=/, '');
				const stillOn = /enabled=1/.test(await session.run('capsword_state'));
				await session.run('edit_close');
				if (stillOn) await session.run('capsword_toggle');
				if (!value.startsWith('AB'))
					problems.push(`${end.name}: the first word is "${value}", expected capitals`);
				else if (!value.endsWith(end.expectEnd || 'cd'))
					problems.push(`${end.name}: the word after it is "${value}", expected lower case`);
				if (!endedByThis) problems.push(`${end.name}: CapsWord was still on right after it`);
				if (stillOn) problems.push(`${end.name}: CapsWord is still on`);
			}
			if (problems.length > 0) return fail(problems.join('; '));
			return pass(
				`CapsWord ended on ${ends.length} events: ${ends.map((end) => end.name).join(', ')}`
			);
		}
	},
	{
		id: 'versions-tabs',
		title: 'Versions: switching channel tabs repaints at once, with no spinner',
		async run(context) {
			const { session } = await bootEnglish(context, 'versions');
			let report;
			try {
				report = await session.run('versions_tabs', ['stable'], 240000);
			} catch (error) {
				if (/no release list arrived/.test(error.message))
					return notExecuted('the Versions window got no release list from the network');
				if (/native fallback/.test(error.message))
					return notExecuted(
						'the driver chose its native Versions window: WebView2 is missing or free memory is too low'
					);
				throw error;
			}
			const tabs = [...report.matchAll(/(\S+)=(\S+)\/spinner:(\S+)\/rows:(\d+)/g)];
			if (tabs.length < 2) return fail(`fewer than two channel tabs: ${report}`);
			const bad = tabs.filter(([, id, active, spinner]) => active !== id || spinner !== '0');
			if (bad.length > 0)
				return fail(`a tab switch showed the spinner or did not activate its tab: ${report}`);
			return pass(`${tabs.length} tabs switched inside the click, no spinner: ${report}`);
		}
	},
	{
		id: 'window-titles',
		title: 'The unused-settings window and the API endpoint dialog show the brand once',
		async run(context) {
			const { session } = await bootEnglish(context, 'titles');
			const seen = fields(await session.run('window_titles'));
			const locale = JSON.parse(
				fs.readFileSync(
					path.join(live.ROOT, 'static', 'ergopti_plus', '_shared', 'data', 'locales', 'en.json'),
					'utf8'
				)
			);
			const expected = {
				unused: `ErgoptiPlus — ${locale['dialog.unused_keys.title']}`,
				api: `ErgoptiPlus — ${locale['menu.llm.api_dialog_title']}`
			};
			for (const [name, title] of Object.entries(expected)) {
				if (seen[name] !== title)
					return fail(`${name}: the window is titled "${seen[name]}", expected "${title}"`);
				if (seen[name].split('ErgoptiPlus').length !== 2)
					return fail(`${name}: the brand is not shown once`);
			}
			return pass(`"${seen.unused}" and "${seen.api}"`);
		}
	},
	{
		id: 'taphold-pickers',
		title: 'A tap-hold key\'s "Tap -> ..." and "Hold -> ..." rows open the shared picker',
		async run(context) {
			const { session } = await bootEnglish(context, 'picker');
			const tap = fields(
				await session.run('open_window', ['re:Tap-Holds$', 're:^Escape', 're:^Tap →'])
			);
			const hold = fields(
				await session.run('open_window', ['re:Tap-Holds$', 're:^Escape', 're:^Hold →'])
			);
			if (!tap.title || !hold.title) return fail('a picker opened without a caption');
			return pass(
				`Tap opened "${tap.title}" (${tap.class}); Hold opened "${hold.title}" (${hold.class})`
			);
		}
	},
	{
		id: 'keycombo-picker',
		title: 'A key-combination pair row opens the shared picker',
		async run(context) {
			const { session } = await bootEnglish(context, 'combo');
			const pair = ['escape', 'tab', 'Escape + Tab'];
			const tap = fields(await session.run('pair_menu_pick', ['tap 2', ...pair]));
			const hold = fields(await session.run('pair_menu_pick', ['hold 2', ...pair]));
			if (!tap.title) return fail(`Tap opened a picker without a caption (menu: ${tap.rows})`);
			if (!hold.title) return fail(`Hold opened a picker without a caption (menu: ${hold.rows})`);
			return pass(
				`the pair menu offers ${tap.rows}; Tap opened "${tap.title}", Hold opened "${hold.title}"`
			);
		}
	},
	{
		id: 'clear-restore-categories',
		title:
			'Clear all and Restore recommended of each category: in scope, unknown keys kept, exact backups, stable over a restart',
		async run(context) {
			const registryBefore = touchpadRegistry();
			const { session, pid: first } = await bootEnglish(context, 'scopes', SENTINELS_TOML);
			// A first boot saves its full state late: wait, or that save reads as the row's.
			let pid = (await session.quiesce(first, { quietMs: 8000 })).pid;
			const personal = configBytes(session, 'hotstrings/personal_hotstrings.toml');
			const problems = [];
			const report = [];
			// Each row's own namespace; category_enabled is the master switch it may set.
			const categories = [
				[
					'Tap-Holds',
					're:Tap-Holds$',
					/^(tap_hold|category_enabled|shortcuts\.key_combinations)/,
					'Enable tap-holds'
				],
				[
					'Shortcuts',
					're:Shortcuts$',
					/^(shortcuts|category_enabled|gestures\.action_parameters)/,
					'Enable shortcuts'
				],
				['Gestures', 're:Gestures$', /^(gestures|category_enabled)/, 'Enable gestures'],
				[
					'Keyboard layout',
					're:Keyboard layout$',
					/^(layout|category_enabled)/,
					'Enable the layout'
				],
				['Hotstrings', 're:Hotstrings \\(', /^(hotstrings|category_enabled)/, 'Enable hotstrings']
			];
			for (const [name, menu, scope, enable] of categories) {
				const restore = [menu, 're:Restore recommended'];
				const clear = [menu, 're:Clear all'];
				// An off category greys its Restore and Clear: switch it on first, and
				// again after Clear all, which may set its switch back to the default.
				pid = await ensureCategoryOn(session, pid, menu, enable);
				const r1 = await clickScoped(session, pid, restore, `${name} Restore`, scope, problems);
				const c = await clickScoped(session, r1.pid, clear, `${name} Clear`, scope, problems);
				const r2 = await clickScoped(
					session,
					await ensureCategoryOn(session, c.pid, menu, enable),
					restore,
					`${name} Restore again`,
					scope,
					problems
				);
				pid = r2.pid;
				if (name === 'Gestures') {
					// A fresh profile has no backup: the clear wrote the factory values to
					// the private key. Removed, so the global clear must write them again.
					const problem = touchpadFactoryProblem(privateTouchpadKey(session), 'the Gestures Clear');
					if (problem) problems.push(problem);
					fs.rmSync(path.join(session.root, 'touchpad_registry_private.txt'), { force: true });
				}
				// A restore never turns the AI preview back on: that consent is the
				// user's (restore_exclude, pinned by test_config_scope_manifest.ahk).
				const drift = live
					.diffSnapshots(r1.config, r2.config)
					.map((change) => change.key)
					.filter((key) => key !== KEY.HOTSTRINGS_PREVIEW_AI_ENABLED);
				if (drift.length > 0)
					problems.push(`${name}: Restore after Clear differs from Restore: ${drift.join(', ')}`);
				if (c.changed === 0 && r2.changed === 0)
					problems.push(`${name}: Clear and Restore changed nothing`);
				report.push(`${name} ${c.changed}/${r2.changed}`);
			}
			const metrics = await clickScoped(
				session,
				await ensureCategoryOn(session, pid, 're:Metrics$', 'Enable metrics', 'Security Warning'),
				['re:Metrics$', 're:Restore recommended'],
				'Metrics Restore',
				/^(metrics|keystats|category_enabled)/,
				problems
			);
			pid = metrics.pid;
			const everything = /./;
			const allClear = await clickScoped(
				session,
				pid,
				['re:Configuration$', 're:Clear all'],
				'Global Clear',
				everything,
				problems
			);
			const allRestore = await clickScoped(
				session,
				allClear.pid,
				// The global Clear also clears the language: the row is named by its mark.
				['re:Configuration$', 're:^↺'],
				'Global Restore',
				everything,
				problems
			);
			report.push(`global ${allClear.changed}/${allRestore.changed}`);
			const touchpadProblem = touchpadFactoryProblem(
				privateTouchpadKey(session),
				'the global Clear'
			);
			if (touchpadProblem) problems.push(touchpadProblem);
			if (allClear.changed === 0 || allRestore.changed === 0)
				problems.push('the global Clear or Restore changed nothing');
			const now = configBytes(session, 'hotstrings/personal_hotstrings.toml');
			if (personal && !personal.equals(now)) problems.push('the personal hotstrings file changed');
			const settledConfig = configBytes(session, 'autohotkey/config.toml');
			await session.restart();
			if (!configBytes(session, 'autohotkey/config.toml').equals(settledConfig))
				problems.push('a restart rewrote the configuration');
			// The outcome is judged on the private key above; this only catches a leak.
			if (touchpadRegistry() !== registryBefore)
				problems.push("the isolated driver changed the machine's touchpad registry values");
			if (
				session.logLines('Isolated profile: the touchpad values go to the private key').length === 0
			)
				problems.push('the driver never said its touchpad writes went to the private key');
			const errors = session.loggedErrors();
			if (errors.length > 0) problems.push(`the log holds an error: ${errors[0]}`);
			if (problems.length > 0) return fail(problems.join('; '));
			return pass(`keys changed by Clear/Restore: ${report.join(', ')}`);
		}
	},
	{
		id: 'number-row-layouts',
		title: 'Number row: each ordering typed with real keys on every installed layout',
		async run(context) {
			const skip = context.otherDriverReason();
			if (skip) return notExecuted(skip);
			const problems = [];
			const seen = [];
			const DIGITS = '1234567890';
			const isDigit = (text) => /^[0-9]$/.test(text);
			for (const order of ['native', 'digits', 'symbols']) {
				const { session } = await bootEnglish(
					context,
					`layouts-${order}`,
					`[category_enabled]\nlayout = true\n[layout]\ndirect_access_digits = "${order}"\n`
				);
				await session.run('pump', ['2000']);
				const layouts = (await session.run('keyboard_layouts')).replace('layouts=', '').split(' ');
				await session.run('edit_open');
				for (const hkl of layouts) {
					await session.run('edit_layout', [hkl]);
					const shown = await session.run('layout_row', [hkl]);
					const mode = /mode=(\S+)/.exec(shown)[1];
					const keys = shown.replace(/^.*row=/, '').split(' ');
					const expected = keys.map((key, index) => {
						const [base, shift] = key.split('/');
						if (mode === 'digits') return DIGITS[index];
						if (mode === 'symbols') return isDigit(base) ? shift : base;
						return base;
					});
					if (expected.includes('dead') || expected.includes('')) {
						seen.push(`${order}/${hkl}: a dead or empty key, not judged`);
						continue;
					}
					await session.run('edit_clear');
					session.type([
						['mode', 'event'],
						['level', '100'],
						['gap', '50'],
						...[...Array(10).keys()].map((index) => [
							'key',
							`{Blind}{SC00${(index + 2).toString(16).toUpperCase()}}`
						]),
						['wait', '300']
					]);
					const typed = (await session.run('edit_value')).replace(/^value=/, '');
					if (typed !== expected.join(''))
						problems.push(
							`${order} on ${hkl} (${mode}): typed "${typed}", expected "${expected.join('')}"`
						);
					else seen.push(`${order}/${hkl}=${mode}`);
				}
				await session.run('edit_close');
				const errors = session.loggedErrors();
				if (errors.length > 0) problems.push(`${order}: the log holds an error: ${errors[0]}`);
				await session.stop();
			}
			if (problems.length > 0) return fail(problems.join('; '));
			return pass(`typed as the system tables say: ${seen.join(', ')}`);
		}
	},
	{
		id: 'hotstring-delays-recommended-cleared',
		// Each family declares 0.5 s in the manifest, which is also the recommended
		// value, and the drivers wait it (the maintainer's decision of 3 November
		// 2026): a restore has nothing to write and a clear leaves the declared delay.
		title: 'Hotstring delays: the declared 0.5 s after Restore recommended and after Clear all',
		async run(context) {
			const { session, pid: booted } = await bootEnglish(context, 'delays');
			const problems = [];
			const menu = 're:Hotstrings \\(';
			// An off category greys its Restore and Clear (77f417280e).
			const first = await ensureCategoryOn(session, booted, menu, 'Enable hotstrings');
			const families = ['names', 'abbreviations', 'technical_terms'];
			const judge = async (label, delay, override) => {
				for (const family of families) {
					const seen = fields(await session.run('hotstring_delay', ['autocorrection', family]));
					if (Number(seen.delay) !== delay || seen.override !== override)
						problems.push(`${label}: ${family} reads ${JSON.stringify(seen)}, ${delay} s expected`);
				}
			};
			await session.run('click_confirming', ['.', menu, 're:Restore recommended'], 180000, {
				followReload: true
			});
			let pid = (await session.quiesce(first)).pid;
			await judge('after Restore', 0.5, '0');
			await session.run('click_confirming', ['.', menu, 're:Clear all'], 180000, {
				followReload: true
			});
			pid = (await session.quiesce(pid)).pid;
			await judge('after Clear', 0.5, '0');
			pid = await ensureCategoryOn(session, pid, menu, 'Enable hotstrings');
			const rows = await session.run('rows', ['Autocorrection delay', 'Delays and colours']);
			// Since c0a80da57f a row joins its label and value through
			// common.label_value ("{1}: {2}" in English), not a hardcoded " : ".
			const locale = JSON.parse(
				fs.readFileSync(
					path.join(live.ROOT, 'static', 'ergopti_plus', '_shared', 'data', 'locales', 'en.json'),
					'utf8'
				)
			);
			const shown = locale['common.label_value']
				.replace('{1}', 'Autocorrection delay')
				.replace('{2}', '500 ms (default)');
			if (!rows.includes(shown))
				problems.push(`after Clear the row reads: ${rows}; expected "${shown}"`);
			await session.restart();
			await judge('after Clear and a restart', 0.5, '0');
			const errors = session.loggedErrors();
			if (errors.length > 0) problems.push(`the log holds an error: ${errors[0]}`);
			if (problems.length > 0) return fail(problems.join('; '));
			return pass(
				`${families.join(', ')}: the declared 0.5 s, no override, after Restore, Clear and a restart`
			);
		}
	},
	{
		id: 'autocorrection-family-alone',
		title:
			'Each common autocorrection family alone expands its own word from real keys, not the others',
		async run(context) {
			const skip = context.otherDriverReason();
			if (skip) return notExecuted(skip);
			const { samples } = JSON.parse(
				fs.readFileSync(
					path.join(
						live.ROOT,
						'static/ergopti_plus/_shared/tests/corpus/hotstrings/family_samples.json'
					),
					'utf8'
				)
			);
			const common = samples.filter((sample) => sample.family === 'autocorrection');
			if (common.length < 3) return fail(`only ${common.length} autocorrection samples`);
			const problems = [];
			for (const alone of common) {
				const master = '[category_enabled]\nhotstrings = true\nautocorrection = true\n';
				const toml = common
					.map(
						(sample) =>
							`[hotstrings.autocorrection.${sample.section}]\nenabled = ${sample === alone}\n`
					)
					.join('');
				const { session } = await bootEnglish(context, `family-${alone.section}`, master + toml);
				await session.run('pump', ['3000']);
				for (const sample of common) {
					await session.run('edit_open');
					// No hse_reset: it declares the word start unknown, and is_word samples then
					// refuse. Each typed word follows a boot or the previous word's Space.
					session.type([
						['mode', 'event'],
						['level', '100'],
						['gap', '120'],
						['text', sample.buffer],
						['key', '{SC039}'],
						['wait', '900']
					]);
					const engine = (await session.run('hse_buffer')).replace(/^buffer=/, '');
					await session.run('edit_close');
					const expanded = engine.includes(sample.expected.replacement);
					if (expanded !== (sample === alone))
						problems.push(
							`${alone.section} alone, ${sample.buffer}: the engine holds "${engine}", ${expanded ? 'expanded' : 'not expanded'}`
						);
				}
				const errors = session.loggedErrors();
				if (errors.length > 0) problems.push(`${alone.section}: the log holds ${errors[0]}`);
				await session.stop();
			}
			if (problems.length > 0) return fail(problems.join('; '));
			return pass(`${common.length} families each expand their own sample and refuse the others`);
		}
	},
	{
		id: 'handwritten-delimiters',
		title: 'Handwritten [[hotstrings.terminators]] through Add, toggle, Delete, save and restart',
		async run(context) {
			const handwritten = [
				'# my own delimiters',
				'[[hotstrings.terminators]]',
				'key = "custom_cur"',
				'char = "¤"',
				'label = "Currency"',
				'consume = true',
				''
			].join('\n');
			const { session, pid: first } = await bootEnglish(context, 'delimiters', handwritten);
			const expanders = ['re:Hotstrings \\(', 're:Hotstring settings', 're:^Expanders'];
			const rows = () => session.run('rows', ['.', 'Expanders']);
			const records = () => {
				const parsed = require('smol-toml').parse(session.configText());
				return parsed.hotstrings?.terminators ?? [];
			};
			const problems = [];
			if (!/Currency/.test(await rows())) problems.push('the handwritten record has no row');

			await session.run(
				'add_delimiter',
				['§', '1', ...expanders, 're:Add custom delimiter'],
				180000,
				{
					followReload: true
				}
			);
			let pid = (await session.quiesce(first)).pid;
			let held = records();
			if (held.length !== 2 || !held.some((r) => r.char === '§' && r.consume === true))
				problems.push(`after Add: ${JSON.stringify(held)}`);
			if (!held.some((r) => r.key === 'custom_cur' && r.char === '¤'))
				problems.push('Add lost the handwritten record');
			if (!session.configText().includes('# my own delimiters'))
				problems.push('Add lost the comment above the handwritten records');

			// The record's own submenu holds its toggle and its Delete.
			const under = [...expanders, 're:Currency'];
			await session.run('click', [...under, 're:^Currency'], 180000, { followReload: true });
			pid = (await session.quiesce(pid)).pid;
			// A record's state is a leaf beside the records, not a field of the record.
			const stateOff = () =>
				require('smol-toml').parse(session.configText()).hotstrings?.terminator_states
					?.custom_cur === false;
			const ticked = async () => /Currency\s+\[checked\]/.test(await rows());
			if (!stateOff()) problems.push('the toggle stored no state');
			if (await ticked()) problems.push('the row stays ticked after the toggle');
			await session.restart();
			pid = Number(/pid=(\d+)/.exec(await session.run('info'))[1]);
			if (!stateOff() || (await ticked())) problems.push('a restart lost the toggle');

			await session.run('click_confirming', ['.', ...under, 're:Delete'], 180000, {
				followReload: true
			});
			pid = (await session.quiesce(pid)).pid;
			held = records();
			if (held.length !== 1 || held[0].char !== '§')
				problems.push(`after Delete: ${JSON.stringify(held)}`);
			if (/Currency/.test(await rows())) problems.push('the deleted record still has a row');
			await session.restart();
			held = records();
			if (held.length !== 1 || held[0].char !== '§')
				problems.push(`after the last restart: ${JSON.stringify(held)}`);
			const errors = session.loggedErrors();
			if (errors.length > 0) problems.push(`the log holds an error: ${errors[0]}`);
			if (problems.length > 0) return fail(problems.join('; '));
			return pass(
				'a handwritten record kept its comment through Add, toggle, Delete and two restarts'
			);
		}
	},
	{
		id: 'consume-submenu',
		title: 'Expanders > Consumed by the expansion: a row ticks, saves and survives a reload',
		async run(context) {
			const { session, pid } = await bootEnglish(context, 'consume');
			const under = [
				're:Hotstrings \\(',
				're:Hotstring settings',
				're:^Expanders',
				're:^Consumed by',
				're:^, : Comma'
			];
			const rows = () => session.run('rows', ['^, : Comma', 'Consumed by']);
			if (/\[checked\]/.test(await rows())) return notExecuted('the comma is already consumed');
			await session.run('click', under, 180000, { followReload: true });
			await session.quiesce(pid);
			const config = live.configSnapshot(session);
			const stored = Object.entries(config).filter(
				([key, value]) => /comma/.test(key) && /consume/.test(key) && value === 'true'
			);
			if (stored.length === 0) return fail('no comma consume key reads true');
			if (!/\[checked\]/.test(await rows())) return fail(`the row is not ticked: ${await rows()}`);
			const shown = await session.run('rows', ['^, : Comma', '> Expanders > $']);
			if (!/consumed/.test(shown)) return fail(`the Expanders row reads: ${shown}`);
			const errors = session.loggedErrors();
			if (errors.length > 0) return fail(`the log holds an error: ${errors[0]}`);
			return pass(`saved as ${stored[0][0]}, ticked after the reload, suffixed in Expanders`);
		}
	},
	{
		id: 'ai-off-inert',
		title: 'AI off: no server sweep, no AI hotkeys, a refused hotkey leaves the driver running',
		async run(context) {
			const skip = context.otherDriverReason();
			if (skip) return notExecuted(skip);
			// Named ollama, not merely mentioning it: the query's own command line does.
			const ollama = () =>
				live
					.processesMatching('ollama')
					.filter((p) => /^ollama/i.test(p.name))
					.map((p) => p.pid)
					.sort();
			const ollamaBefore = ollama();
			const { session } = await bootEnglish(context, 'aioff');
			await session.run('tree');
			await session.run('pump', ['4000']);
			const state = fields(await session.run('ai_state'));
			const problems = [];
			if (state.enabled !== '0') return notExecuted('the AI is on in a default configuration');
			if (state.await !== '1') problems.push('the AI hotkeys do not wait for the switch-on');
			if (state.navslot !== '0')
				problems.push(`a navigation plan is active (slot ${state.navslot})`);
			if (state.scans !== '0') problems.push(`a server sweep reported ${state.scans} servers`);
			// The profile hotkey of the menu, typed for real: the profile must not move.
			const profile = () => session.run('rows', ['Ctrl\\+[234]\\)$', 'Profile']);
			const before = await profile();
			await session.run('edit_open');
			session.type([
				['mode', 'event'],
				['level', '100'],
				['gap', '80'],
				['key', '^{SC003}'],
				['key', '^{SC004}'],
				['wait', '500']
			]);
			await session.run('edit_close');
			if ((await profile()) !== before) problems.push('Ctrl+2/3 changed the AI profile');
			const after = fields(await session.run('ai_state'));
			if (after.scans !== '0') problems.push('a sweep started after the hotkeys');
			if (ollama().join() !== ollamaBefore.join()) problems.push('an Ollama process started');
			if (session.loggedErrors().length > 0)
				problems.push(`the log holds an error: ${session.loggedErrors()[0]}`);
			const refused = fields(await session.run('ai_hotkey_refused'));
			if (refused.settled !== '1' || refused.await !== '1' || refused.notified !== '1')
				problems.push(`a refused hotkey: ${JSON.stringify(refused)}`);
			await session.run('pump', ['500']);
			if (!/pid=/.test(await session.run('info'))) problems.push('the driver stopped answering');
			if (driverCount(session) !== 1) problems.push('the driver did not survive the refusal');
			if ((await waitForLog(session, 'the system refused them', new Set(), 8000)) === null)
				problems.push('the refusal was not logged with its cause');
			if (problems.length > 0) return fail(problems.join('; '));
			return pass(
				'no sweep, no navigation plan, Ctrl+2/3 inert, no Ollama; a refused hotkey settles, notifies, logs and the driver serves'
			);
		}
	},
	{
		id: 'ai-agent-unavailable-row',
		title: 'AI agent in the composed tray: one disabled row says why, the AI submenu works',
		async run(context) {
			const { session } = await bootEnglish(context, 'agent');
			const notReady = (await session.run('translate', ['menu.agent.not_ready'])).replace(
				/^text=/,
				''
			);
			await session.run('tree');
			const tree = fs.readFileSync(path.join(session.live, 'tree.txt'), 'utf8').split('\n');
			const agent = tree.filter((line) => /AI agent/.test(line));
			if (agent.length !== 1) return fail(`the tree holds ${agent.length} AI agent rows`);
			const [row] = agent;
			const problems = [];
			// The manifest declares the unfinished agent once (item 121): a plain root row.
			if (/^\s|\[\+\]/.test(row)) problems.push(`the row is not a root leaf: ${row}`);
			if (!row.includes(notReady)) problems.push(`the row does not say "${notReady}": ${row}`);
			const shown = await session.run('rows', ['AI agent']);
			if (!/\[disabled\]/.test(shown)) problems.push(`the row is enabled: ${shown}`);
			// The AI submenu beside it keeps controls a person can use.
			const usable = (await session.run('rows', ['.', 'Artificial Intelligence']))
				.split(' | ')
				.filter((line) => line && !line.includes('[disabled]'));
			if (usable.length === 0) problems.push('the AI submenu has no enabled row');
			const errors = session.loggedErrors();
			if (errors.length > 0) problems.push(`the log holds an error: ${errors[0]}`);
			if (problems.length > 0) return fail(problems.join('; '));
			return pass(`disabled root row "${notReady}", ${usable.length} AI rows usable`);
		}
	},
	{
		id: 'test-prediction-ai-off',
		// Since 77f417280e (maintainer rule for 1.0.9) an off category greys every row
		// of its menu but its enable row, Test a prediction included, with
		// menu.category_off_reason: the row cannot be clicked, so it says why itself.
		title: 'AI > Test a prediction, with the AI off: greyed, says why, sends nothing',
		async run(context) {
			const { session } = await bootEnglish(context, 'testpred');
			const before = fields(await session.run('ai_state'));
			if (before.enabled !== '0') return notExecuted('the AI is on in a default configuration');
			const started = session.logLines('Test prediction #').length;
			const reason = (await session.run('translate', ['menu.category_off_reason']))
				.replace(/^text=/, '')
				.split(':')[0];
			const row = (await session.run('rows', ['^Test a prediction', 'Artificial Intelligence']))
				.split(' | ')
				.filter(Boolean);
			if (row.length !== 1)
				return fail(`the AI submenu holds ${row.length} Test a prediction rows`);
			const problems = [];
			if (!row[0].includes('[disabled]')) problems.push(`the row is enabled: ${row[0]}`);
			if (!row[0].includes(reason)) problems.push(`the row does not say "${reason}": ${row[0]}`);
			if (session.logLines('Test prediction #').length !== started)
				problems.push('a test prediction was sent');
			if ((await session.run('dialogs')) !== 'dialogs=') problems.push('a dialog opened');
			if (session.loggedErrors().length > 0)
				problems.push(`the log holds an error: ${session.loggedErrors()[0]}`);
			if (problems.length > 0) return fail(problems.join('; '));
			return pass(`greyed with "${reason}", nothing sent, no dialog`);
		}
	},
	{
		id: 'tap-hold-v1-migration',
		title:
			'An unstamped tap_hold.toml: exact backup, v1 stamp, retired delays gone, comments kept, once',
		async run(context) {
			const version = registryVersion('tap_hold/migrations.toml');
			const session = context.newSession('taphold');
			const old = [
				'# my tap-holds',
				'[tap_hold.keys.caps_lock]',
				'time_activation_seconds = 0.35 # retired',
				'[tap_hold.keys.escape]',
				'time_activation_seconds = 0.42 # my own',
				''
			].join('\n');
			session.seed('autohotkey/config.toml', ENGLISH);
			session.seed('autohotkey/tap_hold.toml', old);
			await session.start();
			const text = configBytes(session, 'autohotkey/tap_hold.toml').toString('utf8');
			const parsed = require('smol-toml').parse(text);
			const backups = backupNames(session, /^tap_hold\.pre-v/);
			const problems = [];
			if (backups.length !== 1) problems.push(`${backups.length} backups`);
			else if (!configBytes(session, `autohotkey/${backups[0]}`).equals(Buffer.from(old)))
				problems.push(`the backup ${backups[0]} is not the exact old file`);
			if (parsed._meta?.schema_version !== version)
				problems.push(`the stamp reads ${parsed._meta?.schema_version}, ${version} expected`);
			if (parsed.tap_hold?.keys?.caps_lock?.time_activation_seconds !== undefined)
				problems.push('the retired 0.35 s delay stays');
			if (parsed.tap_hold?.keys?.escape?.time_activation_seconds !== 0.42)
				problems.push("the user's own 0.42 s delay is gone");
			if (!text.includes('# my tap-holds') || !text.includes('# my own'))
				problems.push('a comment is gone');
			const first = configBytes(session, 'autohotkey/tap_hold.toml');
			await session.restart();
			if (!configBytes(session, 'autohotkey/tap_hold.toml').equals(first))
				problems.push('a second boot rewrote the file');
			if (backupNames(session, /^tap_hold\.pre-v/).length !== 1)
				problems.push('a second boot made another backup');
			if (session.loggedErrors().length > 0)
				problems.push(`the log holds an error: ${session.loggedErrors()[0]}`);
			if (problems.length > 0) return fail(problems.join('; '));
			return pass(
				`${backups[0]} is the exact file; stamped v${version}; second boot wrote nothing`
			);
		}
	},
	{
		id: 'old-config-migration',
		title: 'The oldest supported config.toml climbs the registry at boot and keeps its actions',
		async run(context) {
			const version = registryVersion('core/config_schema/migrations.toml');
			// Spellings Windows 1.0.0 wrote: the registry's oldest supported version.
			const old = [
				'# from an old build',
				'[_meta]',
				`schema_version = ${oldestVersion()}`,
				'[script]',
				"locale = 'en'",
				'[category_enabled]',
				'shortcuts = true',
				'dynamichotstrings = false',
				'[llm]',
				"trigger_shortcut = '^!a'",
				'[hotstrings]',
				'cascade_depth = 2',
				'[shortcuts.keyboard]',
				'ctrl_g = "open_hotstrings_editor"',
				'win_e = "search_web"',
				''
			].join('\n');
			const session = context.newSession('oldconfig');
			session.seed('autohotkey/config.toml', old);
			await session.start();
			const config = live.configSnapshot(session);
			const backups = backupNames(session, /^config\.pre-v/);
			const problems = [];
			if (backups.length !== 1) problems.push(`${backups.length} migration backups`);
			else if (!configBytes(session, `autohotkey/${backups[0]}`).equals(Buffer.from(old)))
				problems.push(`the backup ${backups[0]} is not the exact old file`);
			const want = {
				[KEY._META_SCHEMA_VERSION]: String(version),
				'shortcuts.keyboard.primary_g': '"open_hotstrings_editor"',
				'shortcuts.keyboard.meta_e': '"search_web"',
				[KEY.HOTSTRINGS_DYNAMIC_ENABLED]: 'false',
				[KEY.HOTSTRINGS_CASCADE_MAX_ARROWS]: '3',
				'llm.trigger_shortcut': '"^!a"'
			};
			for (const [key, value] of Object.entries(want))
				if (config[key] !== value) problems.push(`${key} reads ${config[key]}, ${value} expected`);
			if (!session.configText().includes('# from an old build'))
				problems.push('the comment is gone');
			const rows = await session.run('rows', ['.', 'Ctrl shortcuts']);
			if (!/hotstrings editor/i.test(rows))
				problems.push(`the Ctrl row does not show the action: ${rows}`);
			const first = configBytes(session, 'autohotkey/config.toml');
			await session.restart();
			if (!configBytes(session, 'autohotkey/config.toml').equals(first))
				problems.push('a second boot rewrote the file');
			if (session.loggedErrors().length > 0)
				problems.push(`the log holds an error: ${session.loggedErrors()[0]}`);
			if (problems.length > 0) return fail(problems.join('; '));
			return pass(`${backups[0]} is exact; v${version}; every action and mapped value kept`);
		}
	},
	{
		id: 'too-old-config-refused',
		title: 'A config.toml older than the registry is refused in words and left byte for byte',
		async run(context) {
			// What a pre-release left: only a real stamp below the floor is refused.
			const old = "# from a pre-release\n[_meta]\nschema_version = 11\n[script]\nlocale = 'en'\n";
			const session = context.newSession('tooold');
			session.seed('autohotkey/config.toml', old);
			await session.start();
			const problems = [];
			if (!configBytes(session, 'autohotkey/config.toml').equals(Buffer.from(old)))
				problems.push('the refused file changed');
			if (backupNames(session, /^config\.pre-v/).length !== 0)
				problems.push('a migration backup was written');
			if (!session.logLines('refused (unsupported)').length)
				problems.push('the refusal is not in the log');
			await session.restart();
			if (!configBytes(session, 'autohotkey/config.toml').equals(Buffer.from(old)))
				problems.push('a second boot changed the file');
			if (problems.length > 0) return fail(problems.join('; '));
			return pass('refused, exact bytes across two boots, no backup written');
		}
	},
	{
		id: 'quit-refused-during-write',
		title: 'Quit during a configuration write waits, gives up with a notice, and quits once free',
		async run(context) {
			const timings = fs.readFileSync(
				path.join(
					live.ROOT,
					'static',
					'ergopti_plus',
					'_shared',
					'modules',
					'timings',
					'constants.toml'
				),
				'utf8'
			);
			const deadline = Number(/user_quit_deadline_ms\s*=\s*(\d+)/.exec(timings)[1]);
			const quit = ['re:Quit$'];
			const { session } = await bootEnglish(context, 'quit');
			await session.run('lease_hold');
			await session.run('click', quit);
			// The dispatcher first holds a menu click 10 s behind a write, then Quit
			// waits for its own deadline, so the refusal takes both.
			const held = 15000 + deadline + 15000;
			if (
				(await waitForLog(
					session,
					'Quit waits: a global configuration writer',
					new Set(),
					held
				)) === null
			)
				return fail('the wait for the writer was not logged');
			if ((await waitForLog(session, 'Quit gave up waiting', new Set(), held)) === null)
				return fail('the give-up was not logged');
			if ((await waitForLog(session, 'Quit was refused', new Set(), 8000)) === null)
				return fail('the user was not told of the refusal');
			if (!/pid=/.test(await session.run('info'))) return fail('the driver exited under the write');
			await session.run('lease_release');
			await session.run('pump', ['1000']);
			if (!/pid=/.test(await session.run('info')))
				return fail('a refused Quit still exited after the write ended');
			await session.run('click', quit, 20000, { followReload: true });
			const started = Date.now();
			while (session.child.exitCode === null && Date.now() - started < 30000) await live.sleep(100);
			if (session.child.exitCode !== 0)
				return fail(`the second Quit ended with ${session.child.exitCode}, 0 expected`);

			// One Quit is enough when the write ends in time.
			const second = await bootEnglish(context, 'quit2');
			await second.session.run('lease_hold');
			await second.session.run('click', quit);
			await live.sleep(1000);
			await second.session.run('lease_release', [], 20000, { followReload: true });
			const since = Date.now();
			while (second.session.child.exitCode === null && Date.now() - since < 30000)
				await live.sleep(100);
			if (second.session.child.exitCode !== 0)
				return fail(`the Quit that waited ended with ${second.session.child.exitCode}, 0 expected`);
			return pass(
				`refused after ${deadline} ms with a notice, the driver kept serving; a later Quit and a Quit that waited both exit 0`
			);
		}
	},
	{
		id: 'hotstring-section-order',
		title:
			'Hotstring section order: Move down through the tray, kept over a restart, Restore default, a stale menu refused',
		async run(context) {
			const locale = englishLocale();
			const order = locale['menu.hotstrings.section_order'];
			const up = locale['menu.hotstrings.move_up'];
			const down = locale['menu.hotstrings.move_down'];
			const reset = locale['hs_config.btn_reset_default'];
			const { session, pid: booted } = await bootEnglish(context, 'order');
			// A first boot saves its full state late: that save would make the menu stale.
			let pid = (await session.quiesce(booted, { quietMs: 8000 })).pid;
			pid = await ensureCategoryOn(session, pid, 're:Hotstrings \\(', 'Enable hotstrings');
			pid = (await session.quiesce(pid, { quietMs: 8000 })).pid;
			// One Move up row per section of every category's order submenu, in menu order.
			const moves = async (caption) =>
				parseRows(
					await session.run('rows', [`^${escapeRegExp(caption)}$`, ` > ${escapeRegExp(order)} > `])
				);
			const categoryOf = (row) => row.path.slice(0, row.path.indexOf(order) + 1);
			const downs = await moves(down);
			const first = downs.find((row) => !row.disabled);
			if (!first)
				return fail(`no enabled "${down}" row under any "${order}" submenu (${downs.length} rows)`);
			const prefix = categoryOf(first);
			const sameCategory = (row) => categoryOf(row).join(' > ') === prefix.join(' > ');
			const sections = async () =>
				(await moves(up)).filter(sameCategory).map((row) => row.path[prefix.length]);
			const where = prefix.slice(0, -1).join(' > ');
			const moveDown = (label) =>
				session.run('click', [...prefix, label, down], 180000, { followReload: true });
			const overrides = (snapshot) =>
				Object.entries(snapshot).filter(([key]) => key.startsWith('hotstrings.order_overrides.'));
			const problems = [];

			const initial = await sections();
			const label = first.path[prefix.length];
			const at = initial.indexOf(label);
			if (at < 0 || at + 1 >= initial.length)
				return fail(`${where}: "${label}" has no section below it in ${initial.join(', ')}`);
			const expected = [...initial];
			[expected[at], expected[at + 1]] = [expected[at + 1], expected[at]];
			const beforeMove = live.configSnapshot(session);
			await moveDown(label);
			pid = (await session.quiesce(pid)).pid;
			const moved = await sections();
			if (moved.join('|') !== expected.join('|'))
				problems.push(`after Move down the order reads ${moved.join(', ')}`);
			const afterMove = live.configSnapshot(session);
			const changed = live.diffSnapshots(beforeMove, afterMove).map((change) => change.key);
			const stored = overrides(afterMove);
			if (stored.length !== 1 || !Array.isArray(JSON.parse(stored[0][1])))
				problems.push(`the move stored ${stored.length} order lists: ${changed.join(', ')}`);
			const stray = changed.filter((key) => !key.startsWith('hotstrings.order_overrides.'));
			if (stray.length > 0) problems.push(`the move changed ${stray.join(', ')}`);

			// Each boot may save late too: the menu is walked, and so built, after that.
			const settle = async () => {
				const served = Number(/pid=(\d+)/.exec(await session.run('info'))[1]);
				return (await session.quiesce(served, { quietMs: 8000 })).pid;
			};
			await session.restart();
			pid = await settle();
			const restarted = await sections();
			if (restarted.join('|') !== expected.join('|'))
				problems.push(`after a restart the order reads ${restarted.join(', ')}`);
			if (JSON.stringify(overrides(live.configSnapshot(session))) !== JSON.stringify(stored))
				problems.push('a restart changed the stored order');

			await session.run('click', [...prefix, reset], 180000, { followReload: true });
			pid = (await session.quiesce(pid)).pid;
			const restored = await sections();
			if (restored.join('|') !== initial.join('|'))
				problems.push(`after ${reset} the order reads ${restored.join(', ')}`);
			if (overrides(live.configSnapshot(session)).length !== 0)
				problems.push(`${reset} left an order list in the configuration`);

			// The rows just walked built the menu over the file as it is now: an edit made
			// outside the driver afterwards makes that menu stale.
			const file = path.join(session.config, 'autohotkey', 'config.toml');
			fs.appendFileSync(file, '\n[zz_live_external]\nedited = true\n');
			const external = fs.readFileSync(file);
			const logged = new Set(session.logLines(''));
			await moveDown(label);
			pid = (await session.quiesce(pid)).pid;
			if (!fs.readFileSync(file).equals(external))
				problems.push('the stale menu wrote over the external edit');
			if (
				(await waitForLog(
					session,
					'Could not persist the hotstring section order',
					logged,
					8000
				)) === null
			)
				problems.push('the stale menu click was not logged as refused');
			const dialogs = await session.run('dialogs');
			if (dialogs !== 'dialogs=') problems.push(`a dialog is on screen: ${dialogs}`);

			// A fresh menu over the edited file moves again and keeps the edit.
			await session.restart();
			pid = await settle();
			await moveDown(label);
			pid = (await session.quiesce(pid)).pid;
			const fresh = live.configSnapshot(session);
			if (overrides(fresh).length !== 1) problems.push('a fresh menu did not store the move');
			if (fresh['zz_live_external.edited'] !== 'true')
				problems.push('the fresh move lost the external edit');
			// The refusal itself logs two errors: the writer's and the commit's.
			const errors = session
				.loggedErrors()
				.filter(
					(line) =>
						!line.includes('Could not persist the hotstring section order') &&
						!line.includes('the source changed during candidate preparation')
				);
			if (errors.length > 0) problems.push(`the log holds an error: ${errors[0]}`);
			if (problems.length > 0) return fail(`${where}: ${problems.join('; ')}`);
			return pass(
				`${where}: "${label}" moved down (${initial.join(', ')} -> ${moved.join(', ')}), kept over a restart, reset, refused over an external edit, moved again once the menu was fresh`
			);
		}
	},
	{
		id: 'layout-emulation-row',
		title:
			'Keyboard layout > Layout to emulate: lists None, Ergopti, Ergopti➕ and the registry; a choice restarts on it; None types the system layout; a missing stored layout stays named',
		async run(context) {
			const skip = context.otherDriverReason();
			if (skip) return notExecuted(skip);
			const locale = englishLocale();
			// The submenu row shows the choice in force: « Layout to emulate: Ergopti ».
			const head = locale['common.label_value']
				.split('{2}')[0]
				.replace('{1}', locale['menu.layout.emulated_layout']);
			const menu = ['re:Keyboard layout$', `re:^${escapeRegExp(head)}`];
			const none = locale['onboarding.layout.emulated_none'];
			const builtIn = [
				none,
				locale['onboarding.layout.emulated_ergopti'],
				locale['onboarding.layout.emulated_ergopti_plus']
			];
			const { layouts } = JSON.parse(
				fs.readFileSync(path.join(live.ROOT, 'static', 'layouts', 'registry', 'index.json'), 'utf8')
			);
			const registry = layouts
				.filter((layout) => layout.id !== 'ergopti' && layout.id !== 'ergopti_plus')
				.map((layout) => layout.name || layout.id);
			const { levels } = JSON.parse(
				fs.readFileSync(
					path.join(live.WINDOWS, 'tests', 'fixtures', 'ergopti_emulation_golden.json'),
					'utf8'
				)
			);
			const codes = ['10', '11', '12', '13'];
			const ergoptiText = codes.map((code) => levels.base[`SC0${code}`].text).join('');
			const choices = async (session) =>
				parseRows(
					await session.run('rows', [
						'.',
						`> ${escapeRegExp(locale['menu.layout.emulated_layout'])}`
					])
				).filter((row) => row.path.length === 3);
			// The menu keeps « Ergopti » and « Ergopti➕ » two native items by suffixing
			// zero-width spaces to the later one (_MR_NativeDistinctRows): the user
			// reads the caption without them, and a click must accept them.
			const shown = (caption) => caption.replace(/\u200B+$/, '');
			const choiceRow = (caption) => `re:^${escapeRegExp(caption)}(?:\\x{200B})*$`;
			const ticked = (rows) =>
				rows
					.filter((row) => row.checked)
					.map((row) => shown(row.path[2]))
					.join(', ');
			const typeRow = async (session) => {
				await session.run('edit_open');
				session.type([
					['mode', 'event'],
					['level', '100'],
					['gap', '80'],
					...codes.map((code) => ['key', `{Blind}{SC0${code}}`]),
					['wait', '500']
				]);
				const typed = (await session.run('edit_value')).replace(/^value=/, '');
				const system = fields(await session.run('foreground_chars', codes));
				await session.run('edit_close');
				return { typed, system: system.chars.split(' ').join(''), hkl: system.hkl };
			};
			const problems = [];
			const { session, pid: booted } = await bootEnglish(
				context,
				'emulation',
				'[category_enabled]\nlayout = true\n'
			);
			let pid = (await session.quiesce(booted, { quietMs: 8000 })).pid;
			const listed = await choices(session);
			const captions = listed.map((row) => shown(row.path[2]));
			if (captions.slice(0, 3).join('|') !== builtIn.join('|'))
				problems.push(`the list starts ${captions.slice(0, 3).join(', ')}`);
			const missing = registry.filter((name) => !captions.slice(3).includes(name));
			if (missing.length > 0)
				problems.push(`the registry layouts ${missing.join(', ')} are not listed`);
			if (ticked(listed) !== none) problems.push(`a fresh profile ticks "${ticked(listed)}"`);

			const choose = async (caption) => {
				const answer = fields(
					await session.run('click_confirming', ['.', ...menu, choiceRow(caption)], 180000, {
						followReload: true
					})
				);
				if (answer.dialog && answer.dialog !== 'none')
					problems.push(`choosing ${caption} showed the dialog "${answer.dialog}"`);
				const settled = await session.quiesce(pid, { quietMs: 4000 });
				if (!settled.reloaded) problems.push(`choosing ${caption} did not restart the driver`);
				pid = settled.pid;
				const rows = await choices(session);
				if (ticked(rows) !== caption)
					problems.push(`after choosing ${caption} the tick is on "${ticked(rows)}"`);
				return live.effectiveConfig(session);
			};
			let config = await choose(builtIn[1]);
			if (
				config[KEY.LAYOUT_ERGOPTI_BASE] !== 'true' ||
				config[KEY.LAYOUT_ERGOPTI_VARIANT] !== '"ergopti"'
			)
				problems.push(
					`Ergopti stored base ${config[KEY.LAYOUT_ERGOPTI_BASE]}, variant ${config[KEY.LAYOUT_ERGOPTI_VARIANT]}`
				);
			const emulated = await typeRow(session);
			if (emulated.typed !== ergoptiText)
				problems.push(
					`with Ergopti the top row typed "${emulated.typed}", "${ergoptiText}" expected`
				);
			config = await choose(builtIn[2]);
			if (config[KEY.LAYOUT_ERGOPTI_VARIANT] !== '"ergopti_plus"')
				problems.push(`Ergopti➕ stored the variant ${config[KEY.LAYOUT_ERGOPTI_VARIANT]}`);
			config = await choose(none);
			if (
				config[KEY.LAYOUT_ERGOPTI_BASE] !== 'false' ||
				config[KEY.LAYOUT_EMULATED_LAYOUT] !== '""'
			)
				problems.push(
					`None stored base ${config[KEY.LAYOUT_ERGOPTI_BASE]}, emulated ${config[KEY.LAYOUT_EMULATED_LAYOUT]}`
				);
			const native = await typeRow(session);
			if (native.system.includes('dead') || native.system.includes('none'))
				problems.push(
					`the system layout ${native.hkl} has a dead or empty key there: ${native.system}`
				);
			else if (native.typed !== native.system)
				problems.push(
					`with None the top row typed "${native.typed}", the system layout ${native.hkl} types "${native.system}"`
				);
			const errors = session.loggedErrors();
			if (errors.length > 0) problems.push(`the log holds an error: ${errors[0]}`);
			await session.stop();

			// A stored id that is neither built in nor installed keeps its own row, ticked.
			const absent = 'zz_live_absent';
			const stale = await bootEnglish(
				context,
				'absent',
				`[category_enabled]\nlayout = true\n[layout]\nemulated_layout = "${absent}"\n`
			);
			await stale.session.quiesce(stale.pid, { quietMs: 8000 });
			const kept = await choices(stale.session);
			if (ticked(kept) !== absent)
				problems.push(`an absent stored layout ticks "${ticked(kept)}", "${absent}" expected`);
			if (!kept.some((row) => row.path[1].endsWith(absent)))
				problems.push(`the submenu does not name ${absent}: ${kept[0]?.path[1]}`);
			if (live.configSnapshot(stale.session)[KEY.LAYOUT_EMULATED_LAYOUT] !== `"${absent}"`)
				problems.push('the boot dropped the absent stored layout');
			if (problems.length > 0) return fail(problems.join('; '));
			return pass(
				`${captions.length} choices (${captions.join(', ')}); Ergopti typed "${emulated.typed}", None typed "${native.typed}" like ${native.hkl}; ${absent} stays named and ticked`
			);
		}
	},
	{
		id: 'hotstring-preview-boundaries',
		title:
			'Hotstring preview: after punctuation, with a custom delimiter and a changed magic key, the bubble and the expansion agree',
		async run(context) {
			const skip = context.otherDriverReason();
			if (skip) return notExecuted(skip);
			const asa = shippedRule('autocorrection.toml', 'asa');
			const cest = shippedRule('french/magickey.toml', 'c★');
			if (!asa || !cest)
				return notExecuted('the shipped data no longer holds asa -> ASA and c★ -> c’est');
			const magic = '¤';
			const { session } = await bootEnglish(
				context,
				'preview',
				[
					'[category_enabled]',
					'hotstrings = true',
					'autocorrection = true',
					'french_magickey = true',
					'[hotstrings]',
					`trigger_char = "${magic}"`,
					// No delay: a bubble whose window ran out is not painted.
					`[hotstrings.autocorrection.${asa.section}]`,
					'enabled = true',
					'time_activation_seconds = 0',
					`[hotstrings.french_magickey.${cest.section}]`,
					'enabled = true',
					'time_activation_seconds = 0',
					'[[hotstrings.terminators]]',
					'key = "custom_section"',
					'char = "§"',
					'label = "Section"',
					'consume = false',
					''
				].join('\n')
			);
			await session.run('pump', ['3000']);
			const cases = [
				{ name: 'a parenthesis before the word', word: '(asa', end: ' ', expected: '(ASA ' },
				{ name: 'the custom delimiter §', word: 'asa', end: '§', expected: 'ASA§' },
				{ name: `the magic key changed to ${magic}`, word: 'c', end: magic, expected: 'c’est' }
			];
			const problems = [];
			const seen = [];
			for (const item of cases) {
				await session.run('edit_open');
				session.type([
					['mode', 'event'],
					['level', '100'],
					['gap', '120'],
					['text', item.word],
					['wait', '900']
				]);
				const preview = JSON.parse(await session.run('preview_state'));
				// The bubble asks the end character and the magic key; a delimiter
				// other than the first is answered by the end-character row.
				const kind = item.end === magic ? magic : null;
				const pick = (rows) =>
					rows.find((row) => (kind ? row.completion === kind : row.completion !== magic));
				const computed = pick(preview.computed);
				const painted = pick(preview.visible);
				session.type([
					['mode', 'event'],
					['level', '100'],
					['gap', '120'],
					item.end === ' ' ? ['key', '{SC039}'] : ['text', item.end],
					['wait', '900']
				]);
				const typed = (await session.run('edit_value')).replace(/^value=/, '');
				await session.run('edit_close');
				if (typed !== item.expected)
					problems.push(`${item.name}: typed "${typed}", "${item.expected}" expected`);
				if (!computed)
					problems.push(
						`${item.name}: no preview row after "${item.word}" (buffer "${preview.buffer}")`
					);
				else if (!typed.includes(computed.output))
					problems.push(
						`${item.name}: the preview offered "${computed.output}", the key typed "${typed}"`
					);
				if (computed && (!painted || painted.output !== computed.output))
					problems.push(
						`${item.name}: the bubble painted ${painted ? `"${painted.output}"` : 'nothing'}, the preview computed "${computed.output}"`
					);
				if (preview.computed.some((row) => row.completion === '★'))
					problems.push(`${item.name}: a row still answers the old magic key ★`);
				seen.push(`${item.name}: "${computed?.output}" -> "${typed}"`);
			}
			const errors = session.loggedErrors();
			if (errors.length > 0) problems.push(`the log holds an error: ${errors[0]}`);
			if (problems.length > 0) return fail(problems.join('; '));
			return pass(seen.join('; '));
		}
	},
	{
		id: 'asa-space-fast',
		title: '`asa` then Space fast, Space down before the last a is up, 20 times: always ASA',
		async run(context) {
			const skip = context.otherDriverReason();
			if (skip) return notExecuted(skip);
			const rule = shippedRule('autocorrection.toml', 'asa');
			if (!rule || !/output = "ASA"/.test(rule.line))
				return notExecuted('the shipped autocorrection data no longer holds asa -> ASA');
			const { session } = await bootEnglish(
				context,
				'asa',
				`[category_enabled]\nhotstrings = true\nautocorrection = true\n[hotstrings.autocorrection.${rule.section}]\nenabled = true\n`
			);
			await session.run('pump', ['3000']);
			const word = [
				['key', '{Blind}a'],
				['key', '{Blind}s'],
				['key', '{Blind}{a down}'],
				['key', '{Blind}{SC039 down}'],
				['key', '{Blind}{a up}'],
				['key', '{Blind}{SC039 up}']
			];
			const times = 20;
			const typed = await typeInto(session, Array.from({ length: times }, () => word).flat(), 15);
			const words = typed.split(' ').slice(0, -1);
			const wrong = words.filter((one) => one !== 'ASA');
			const problems = [];
			if (typed !== 'ASA '.repeat(times))
				problems.push(
					`${words.length} words, ${wrong.length} not ASA (${[...new Set(wrong)].join(', ')}): "${typed}"`
				);
			const errors = session.loggedErrors();
			if (errors.length > 0) problems.push(`the log holds an error: ${errors[0]}`);
			if (problems.length > 0) return fail(problems.join('; '));
			return pass(`${times} fast asa + Space typed ${times} ASA (section ${rule.section})`);
		}
	},
	{
		id: 'personal-priority-and-left',
		title:
			'A personal sru -> SRU at priority 100 beats the bundled sru -> sur; a personal {Left} moves the caret',
		async run(context) {
			const skip = context.otherDriverReason();
			if (skip) return notExecuted(skip);
			const bundled = shippedRule('french/autocorrection.toml', 'sru');
			if (!bundled || !/output = "sur"/.test(bundled.line))
				return notExecuted('the shipped French autocorrection no longer holds sru -> sur');
			const toml = [
				'[category_enabled]',
				'hotstrings = true',
				'french_autocorrection = true',
				`[hotstrings.french_autocorrection.${bundled.section}]`,
				'enabled = true',
				'[hotstrings.personal.live]',
				'enabled = true',
				'time_activation_seconds = 0',
				''
			].join('\n');
			const problems = [];
			// Without the personal file the bundled correction fires: the win below is the priority's.
			const control = await bootEnglish(context, 'bundled', toml);
			await control.session.run('pump', ['3000']);
			const alone = await typeInto(control.session, [
				['text', 'sru'],
				['key', '{SC039}']
			]);
			if (alone !== 'sur ')
				problems.push(`with no personal rule sru typed "${alone}", "sur " expected`);
			await control.session.stop();

			const session = context.newSession('personal');
			session.seed('autohotkey/config.toml', ENGLISH + toml);
			session.seed(
				'hotstrings/personal_hotstrings.toml',
				[
					'[[live]]',
					'"sru" = { output = "SRU", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = true, priority = 100 }',
					'"zqpar" = { output = "(){Left}", is_word = true, auto_expand = true, is_case_sensitive = false, final_result = false }',
					''
				].join('\n')
			);
			await session.start();
			await session.run('pump', ['3000']);
			const won = await typeInto(session, [
				['text', 'sru'],
				['key', '{SC039}']
			]);
			if (won !== 'SRU ')
				problems.push(`with the personal rule sru typed "${won}", "SRU " expected`);
			// The caret is judged by where the next character lands.
			const caret = await typeInto(session, [
				['text', 'zqpar'],
				['wait', '600'],
				['text', 'X']
			]);
			if (caret !== '(X)') problems.push(`zqpar then X typed "${caret}", "(X)" expected`);
			const errors = session.loggedErrors();
			if (errors.length > 0) problems.push(`the log holds an error: ${errors[0]}`);
			if (problems.length > 0) return fail(problems.join('; '));
			return pass(`bundled alone "${alone}", personal priority 100 "${won}", {Left} "${caret}"`);
		}
	},
	{
		id: 'cascade-fb-item-50',
		title:
			'Item 50: fb + Space, Enter and ★ with the abbreviation and brand rules, at 1, 2 and 3 arrows, consumed and not',
		async run(context) {
			const skip = context.otherDriverReason();
			if (skip) return notExecuted(skip);
			const brand = shippedRule('autocorrection.toml', 'facebook');
			if (!brand || !/output = "Facebook"/.test(brand.line))
				return notExecuted('the shipped autocorrection no longer holds facebook -> Facebook');
			// No shipped end-character rule types fb -> facebook: the abbreviation is personal.
			const personal =
				'[[live]]\n"fb" = { output = "facebook", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }\n';
			const ends = [
				{ name: 'Space', step: ['key', '{SC039}'], char: ' ' },
				{ name: 'Enter', step: ['key', '{SC01C}'], char: '\\n' },
				{ name: '★', step: ['text', '★'], char: '★' }
			];
			const problems = [];
			const seen = [];
			for (const arrows of [1, 2, 3]) {
				for (const consumed of [false, true]) {
					const session = context.newSession(`fb-${arrows}-${consumed ? 'c' : 'k'}`);
					session.seed(
						'autohotkey/config.toml',
						ENGLISH +
							[
								'[category_enabled]',
								'hotstrings = true',
								'autocorrection = true',
								'[hotstrings]',
								`cascade_max_arrows = ${arrows}`,
								`[hotstrings.autocorrection.${brand.section}]`,
								'enabled = true',
								'time_activation_seconds = 0',
								'[hotstrings.personal.live]',
								'enabled = true',
								'time_activation_seconds = 0',
								'[hotstrings.terminator_consume]',
								`space = ${consumed}`,
								`enter = ${consumed}`,
								`star = ${consumed}`,
								''
							].join('\n')
					);
					session.seed('hotstrings/personal_hotstrings.toml', personal);
					await session.start();
					await session.run('pump', ['3000']);
					// One arrow is the abbreviation alone; a second carries it to the brand.
					const word = arrows === 1 ? 'facebook' : 'Facebook';
					for (const end of ends) {
						const expected = word + (consumed ? '' : end.char);
						const typed = await typeInto(session, [['text', 'fb'], end.step]);
						const label = `${arrows} arrow(s), ${consumed ? 'consumed' : 'kept'}, ${end.name}`;
						if (typed !== expected) problems.push(`${label}: "${typed}", "${expected}" expected`);
						seen.push(`${label}="${typed}"`);
					}
					const errors = session.loggedErrors();
					if (errors.length > 0) problems.push(`the log holds an error: ${errors[0]}`);
					await session.stop();
				}
			}
			if (problems.length > 0) return fail(problems.join('; '));
			return pass(seen.join(', '));
		}
	},
	{
		id: 'gestures-info-row',
		title: 'Tray > Gestures: exactly one "Info…" row, which opens its explanation',
		async run(context) {
			const locale = englishLocale();
			const caption = locale['menu.gestures.recommended_info'];
			const { session, pid: booted } = await bootEnglish(context, 'gesinfo');
			// An off category greys its rows and suffixes them « — Category off » (77f417280e).
			const infoRows = async () =>
				parseRows(await session.run('rows', [`^${escapeRegExp(caption)}( — |$)`])).filter(
					(row) => row.path.length === 2 && /Gestures$/.test(row.path[0])
				);
			let rows = await infoRows();
			if (rows.length === 1 && rows[0].disabled) {
				await ensureCategoryOn(session, booted, 're:Gestures$', 'Enable gestures');
				rows = await infoRows();
			}
			if (rows.length !== 1)
				return fail(
					`${rows.length} "${caption}" rows in the Gestures menu: ${rows.map((r) => r.path.join(' > ')).join(' | ')}`
				);
			const [row] = rows;
			if (row.disabled || row.path[1] !== caption)
				return fail(
					`with the gestures on the row reads "${row.path[1]}", disabled: ${row.disabled}`
				);
			const title = locale['menu.gestures.notify_title'];
			const seen = fields(
				await session.run('click_read_dialog', [escapeRegExp(title), ...row.path])
			);
			const problems = [];
			if (!seen.title.includes(title))
				problems.push(`the dialog is titled "${seen.title}", "${title}" expected`);
			const reason = squash(locale['menu.gestures.recommended_reason_windows']);
			if (!squash(seen.text).includes(reason))
				problems.push(`the dialog shows "${seen.text}", not the Windows reason`);
			const dialogs = await session.run('dialogs');
			if (dialogs !== 'dialogs=') problems.push(`a dialog stays open after OK: ${dialogs}`);
			const errors = session.loggedErrors();
			if (errors.length > 0) problems.push(`the log holds an error: ${errors[0]}`);
			if (problems.length > 0) return fail(problems.join('; '));
			return pass(`one "${caption}" row; it opened "${seen.title}" with the Windows reason`);
		}
	}
];

module.exports = { CHECKS };
