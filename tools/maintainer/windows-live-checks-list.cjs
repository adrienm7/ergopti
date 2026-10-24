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
			const row = ['re:Tap-Holds$', 're:^Escape', 're:^Tap delay: \\d+ ms$'];
			const shown = await session.run('rows', ['^Tap delay: \\d+ ms$', 'Escape']);
			const before = /Tap delay: (\d+) ms/.exec(shown);
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
			const after = await session.run('rows', ['^Tap delay: \\d+ ms$', 'Escape']);
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
			if (config['metrics.private_filter_enabled'] !== 'false')
				return fail(
					`the filter reads ${config['metrics.private_filter_enabled']} after one click, false expected`
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
			if (held['metrics.private_filter_enabled'] === 'false')
				return fail('the click was applied while the configuration write still held its lease');
			if ((await session.run('dialogs')) !== 'dialogs=')
				return fail('an error window opened while the write was in progress');
			await session.run('lease_release');
			const settled = await session.quiesce(pid);
			const config = live.configSnapshot(session);
			if (config['metrics.private_filter_enabled'] !== 'false')
				return fail(
					`after the write ended the filter reads ${config['metrics.private_filter_enabled']}, false expected`
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
				'metrics.private_filter_enabled',
				'metrics.secure_filter_enabled',
				'metrics.system_auth_filter_enabled'
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
				'[category_enabled]\nshortcuts = true\n[shortcuts.search]\nenabled = true\n[shortcuts.keyboard]\nwin_s = "search_web"\n'
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
			const delimiters = [
				['Space', ['key', '{Space}']],
				['Tab', ['key', '{Tab}']],
				['Enter', ['key', '{Enter}']],
				['comma', ['text', ',']],
				['semicolon', ['text', ';']],
				['period', ['text', '.']],
				['no-break space', ['text', ' ']],
				['narrow no-break space', ['text', ' ']]
			];
			const ends = [
				...delimiters.map(([name, step]) => ({ name: `the ${name}`, between: [step], gap: 0 })),
				{ name: 'a left click', between: [['mouse', 'left']], gap: 0 },
				{ name: 'a right click', between: [['mouse', 'right']], gap: 0 },
				{ name: 'the 2 s delay', between: [['wait', '3500']], gap: 0 }
			];
			const problems = [];
			for (const end of ends) {
				await session.run('edit_open');
				if (/enabled=1/.test(await session.run('capsword_state')))
					await session.run('capsword_toggle');
				await session.run('capsword_toggle');
				session.type([...head, ['text', 'ab'], ...end.between, ['text', 'cd'], ['wait', '500']]);
				const value = (await session.run('edit_value')).replace(/^value=/, '');
				const stillOn = /enabled=1/.test(await session.run('capsword_state'));
				await session.run('edit_close');
				if (stillOn) await session.run('capsword_toggle');
				if (!value.startsWith('AB'))
					problems.push(`${end.name}: the first word is "${value}", expected capitals`);
				else if (!value.endsWith('cd'))
					problems.push(`${end.name}: the word after it is "${value}", expected lower case`);
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
	}
];

module.exports = { CHECKS };
