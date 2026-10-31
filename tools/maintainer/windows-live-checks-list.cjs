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
 * The HKCU touchpad values, so a check that clicks Restore proves it left them alone.
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
			let pid = first;
			await session.run('click', ['re:Shortcuts$', 're:Restore recommended']);
			pid = (await session.quiesce(pid)).pid;
			const recommended = live.configSnapshot(session);
			const winKeys = Object.keys(recommended).filter((key) =>
				/^shortcuts\.keyboard\.win_/.test(key)
			);
			if (winKeys.length < 3)
				return notExecuted(`the recommended preset set ${winKeys.length} Win slots`);

			await session.run('click', ['re:Shortcuts$', 're:Win shortcuts$', 're:Clear all']);
			pid = (await session.quiesce(pid)).pid;
			const cleared = live.configSnapshot(session);
			const clearChanges = live.diffSnapshots(recommended, cleared);
			const stray = clearChanges.filter(
				(change) => !/^shortcuts\.keyboard(_[a-z]+)?\.win_/.test(change.key)
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
				'[category_enabled]\nshortcuts = true\n[shortcuts.keyboard]\nmeta_s = "search_web"\n'
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
				if (!found) {
					const logged = session.logLines('[Search]').slice(-3).join(' | ');
					seen.push(`${item.name}: no log line "${item.expect}" (Search log: ${logged})`);
				}
			}
			closeExplorerWindows(folder);
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
			const row = ['^Escape \\+ Tab : ', 'Escape'];
			const before = await session.run('rows', row);
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
				['Tap-Holds', 're:Tap-Holds$', /^(tap_hold|category_enabled|shortcuts\.key_combinations)/],
				['Shortcuts', 're:Shortcuts$', /^(shortcuts|category_enabled|gestures\.action_parameters)/],
				['Gestures', 're:Gestures$', /^(gestures|category_enabled)/],
				['Keyboard layout', 're:Keyboard layout$', /^(layout|category_enabled)/],
				['Hotstrings', 're:Hotstrings \\(', /^(hotstrings|category_enabled)/]
			];
			for (const [name, menu, scope] of categories) {
				const restore = [menu, 're:Restore recommended'];
				const clear = [menu, 're:Clear all'];
				const r1 = await clickScoped(session, pid, restore, `${name} Restore`, scope, problems);
				const c = await clickScoped(session, r1.pid, clear, `${name} Clear`, scope, problems);
				const r2 = await clickScoped(
					session,
					c.pid,
					restore,
					`${name} Restore again`,
					scope,
					problems
				);
				pid = r2.pid;
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
				pid,
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
			if (allClear.changed === 0 || allRestore.changed === 0)
				problems.push('the global Clear or Restore changed nothing');
			const now = configBytes(session, 'hotstrings/personal_hotstrings.toml');
			if (personal && !personal.equals(now)) problems.push('the personal hotstrings file changed');
			const settledConfig = configBytes(session, 'autohotkey/config.toml');
			await session.restart();
			if (!configBytes(session, 'autohotkey/config.toml').equals(settledConfig))
				problems.push('a restart rewrote the configuration');
			if (touchpadRegistry() !== registryBefore)
				problems.push('the touchpad registry values changed');
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
		title: 'Hotstring delays: 0.5 s after Restore recommended, 1.0 s after Clear all',
		async run(context) {
			const { session, pid: first } = await bootEnglish(context, 'delays');
			const problems = [];
			const menu = 're:Hotstrings \\(';
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
			await judge('after Restore', 0.5, '1');
			await session.run('click_confirming', ['.', menu, 're:Clear all'], 180000, {
				followReload: true
			});
			pid = (await session.quiesce(pid)).pid;
			await judge('after Clear', 1, '0');
			const rows = await session.run('rows', ['Autocorrection delay', 'Delays and colours']);
			if (!/Autocorrection delay : 1000 ms/.test(rows))
				problems.push(`after Clear the row reads: ${rows}`);
			await session.restart();
			await judge('after Clear and a restart', 1, '0');
			const errors = session.loggedErrors();
			if (errors.length > 0) problems.push(`the log holds an error: ${errors[0]}`);
			if (problems.length > 0) return fail(problems.join('; '));
			return pass(
				`${families.join(', ')}: 0.5 s after Restore, inherited 1.0 s after Clear and a restart`
			);
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
		id: 'test-prediction-ai-off',
		title: 'AI > Test a prediction, with the AI off: refused, says why, sends nothing',
		async run(context) {
			const { session } = await bootEnglish(context, 'testpred');
			const before = fields(await session.run('ai_state'));
			if (before.enabled !== '0') return notExecuted('the AI is on in a default configuration');
			const started = session.logLines('Test prediction #').length;
			const state = await session.run('click_read_notice', [
				're:Artificial Intelligence$',
				're:^Test a prediction'
			]);
			const expected = (await session.run('translate', ['llm.manual_prediction.disabled'])).replace(
				/^text=/,
				''
			);
			if (!state.includes(expected))
				return fail(`the notice reads: ${state}; expected "${expected}"`);
			if (session.logLines('Test prediction #').length !== started)
				return fail('a test prediction was sent');
			if ((await session.run('dialogs')) !== 'dialogs=') return fail('a dialog opened');
			if (session.loggedErrors().length > 0)
				return fail(`the log holds an error: ${session.loggedErrors()[0]}`);
			return pass(`refused with the notice "${expected}", nothing sent, no dialog`);
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
		title: 'An old config.toml climbs the whole registry at boot and keeps its actions',
		async run(context) {
			const version = registryVersion('core/config_schema/migrations.toml');
			// Spellings a Windows build wrote before each step, unstamped (v2).
			const old = [
				'# from an old build',
				'[script]',
				"locale = 'en'",
				'[category_enabled]',
				'shortcuts = true',
				'dynamichotstrings = false',
				'[llm]',
				"trigger_shortcut = '^!a'",
				'[hotstrings]',
				'cascade_depth = 2',
				'magic_key_source_scan = "SC029"',
				'[hotstrings.autocorrection.caps]',
				'enabled = true',
				'[layout]',
				'direct_access_digits = true',
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
				[KEY.LAYOUT_DIRECT_ACCESS_DIGITS]: '"digits"',
				'hotstrings.autocorrection.names.enabled': 'true',
				[KEY.HOTSTRINGS_MAGIC_KEY_SOURCE]: '"Backquote"',
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
	}
];

module.exports = { CHECKS };
