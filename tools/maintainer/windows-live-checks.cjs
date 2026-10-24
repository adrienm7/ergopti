// tools/maintainer/windows-live-checks.cjs

/**
 * ==============================================================================
 * MODULE: Windows Live Checks
 * DESCRIPTION:
 * Runs the "Maintainer checks > Windows PC" lines of docs/ERGOPTIPLUS_TODO.md
 * that need a real driver, against a real ErgoptiPlus.ahk booted from the
 * working tree in an isolated profile (the startup smoke's: LOCALAPPDATA and
 * ERGOPTI_STARTUP_SMOKE_DIR name a scratch folder). The driver serves the
 * commands of static/ergopti_plus/windows/tests/live/ (see live_harness.ahk);
 * this tool writes them, judges what comes back, reads the configuration and
 * logs the driver wrote, and prints one verdict per check: pass, fail, or not
 * executed with the reason. Run it on the maintainer's PC:
 *
 *   node tools/maintainer/windows-live-checks.cjs [--list] [--only a,b] [--keep]
 *
 * FEATURES & RATIONALE:
 * 1. Never touches the maintainer's driver or profile. It starts a private
 *    driver under a wrapper of its own, and every process it started, the
 *    successor of a reload included, is stopped before it returns.
 * 2. Says which other AutoHotkey scripts were running: AutoHotkey's SendInput
 *    falls back to SendEvent while another script holds a keyboard hook, so a
 *    measurement is only meaningful next to that list.
 * 3. Not part of CI and not a test-*.cjs gate: it needs a desktop session.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');
const crypto = require('node:crypto');
const { parse: parseToml } = require('smol-toml');
const {
	createStartupCodeFixture,
	prepareStartupPersonalInclude
} = require('../test/lib/ahk-startup-fixture.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const WINDOWS = path.join(ROOT, 'static', 'ergopti_plus', 'windows');
const LIVE_SOURCES = ['live_harness.ahk', 'live_checks.ahk'];
const AHK_CANDIDATES = [
	'C:\\Program Files\\AutoHotkey\\v2\\AutoHotkey64.exe',
	'C:\\Program Files\\AutoHotkey\\v2\\AutoHotkey.exe',
	'C:\\Program Files (x86)\\AutoHotkey\\v2\\AutoHotkey.exe'
];
const COMMAND_TIMEOUT_MS = 180000;
// Driver sources replaced in every private copy (--without-fix-of); relative to windows/.
let overlay = {};
const BOOT_TIMEOUT_MS = 120000;

/**
 * Pauses without blocking the event loop.
 * @param {number} ms Milliseconds.
 * @returns {Promise<void>}
 */
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Lists the processes whose command line contains a marker.
 * @param {string} marker A distinctive fragment of the command line.
 * @returns {{pid: number, name: string, command: string}[]}
 */
function processesMatching(marker) {
	const script =
		"Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*" +
		marker.replace(/'/g, "''") +
		'*\' } | ForEach-Object { "$($_.ProcessId)`t$($_.Name)`t$($_.CommandLine)" }';
	const out = spawnSync('powershell.exe', ['-NoProfile', '-Command', script], {
		encoding: 'utf8',
		windowsHide: true
	});
	return out.stdout
		.split(/\r?\n/)
		.filter(Boolean)
		.map((line) => {
			const [pid, name, ...command] = line.split('\t');
			return { pid: Number(pid), name, command: command.join('\t') };
		});
}

/**
 * Names the AutoHotkey scripts running on this PC, for the report.
 * @returns {string[]} One "pid script" entry per process.
 */
function runningAutoHotkeyScripts() {
	const script =
		'Get-CimInstance Win32_Process -Filter "Name like \'AutoHotkey%\'" | ForEach-Object { "$($_.ProcessId)`t$($_.CommandLine)" }';
	const out = spawnSync('powershell.exe', ['-NoProfile', '-Command', script], {
		encoding: 'utf8',
		windowsHide: true
	});
	return out.stdout
		.split(/\r?\n/)
		.filter(Boolean)
		.map((line) => {
			const [pid, command] = line.split('\t');
			const match = /([^\\"\s]+\.ahk)/i.exec(command || '');
			return `${pid} ${match ? match[1] : command}`;
		});
}

/**
 * The other ErgoptiPlus drivers on this desktop (the maintainer's own, a build
 * under test), not the private ones this tool starts.
 * @param {string} scratch This run's scratch folder.
 * @returns {number[]} Their pids.
 */
function otherDriverPids(scratch) {
	return processesMatching('ErgoptiPlus')
		.filter(
			(p) => /AutoHotkey|ErgoptiPlus/i.test(p.name) && !p.command.includes(path.basename(scratch))
		)
		.map((p) => p.pid);
}

/**
 * Whether a process still exists.
 * @param {number} pid Process id.
 * @returns {boolean}
 */
function alive(pid) {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

/** One isolated driver and the command channel to it. */
class LiveSession {
	/**
	 * @param {string} ahk Interpreter path.
	 * @param {string} scratch Exclusive scratch folder.
	 * @param {string} name Label used in the folder and the report.
	 */
	constructor(ahk, scratch, name) {
		this.ahk = ahk;
		this.name = name;
		this.root = path.join(scratch, name);
		this.live = path.join(this.root, 'live');
		this.nextId = 1;
		this.child = null;
		this.code = null;
		this.wrapper = '';
		fs.mkdirSync(this.live, { recursive: true });
	}

	/** The folder of the driver's configuration. */
	get config() {
		return path.join(this.root, 'config');
	}

	/** The driver's log folder. */
	get logs() {
		return path.join(this.root, 'ergopti_plus', 'logs');
	}

	/**
	 * Writes a configuration file before the boot.
	 * @param {string} relative Path under the configuration folder.
	 * @param {string} text File content.
	 */
	seed(relative, text) {
		const file = path.join(this.config, relative);
		fs.mkdirSync(path.dirname(file), { recursive: true });
		fs.writeFileSync(file, text);
	}

	/**
	 * Stages the clicks the driver makes while it starts (see LiveShellHook).
	 * @param {string[][]} rows One array of path specifiers per click.
	 */
	stageStartupClicks(rows) {
		fs.writeFileSync(
			path.join(this.live, 'shell.txt'),
			rows.map((row) => ['click', ...row].join('\t')).join('\n') + '\n'
		);
	}

	/**
	 * Reads what the startup clicks reported.
	 * @returns {string[]} One "clicked<TAB>caption" or "failed<TAB>reason" line per click.
	 */
	startupClickReport() {
		const file = path.join(this.live, 'shell-result.txt');
		return fs.existsSync(file) ? fs.readFileSync(file, 'utf8').split(/\r?\n/).filter(Boolean) : [];
	}

	/**
	 * Starts the driver and waits until it serves commands.
	 * @param {object} [options] env: extra environment; expectReload: the boot itself requests a reload.
	 * @returns {Promise<number>} The serving pid.
	 */
	async start(options = {}) {
		if (!this.code) this.code = createStartupCodeFixture(path.join(this.root, 'code'), WINDOWS);
		for (const [relative, text] of Object.entries(overlay)) {
			const target = path.join(this.code.windows, relative);
			if (text === null) fs.rmSync(target, { force: true });
			else fs.writeFileSync(target, text);
		}
		this.wrapper = path.join(this.code.windows, `.ergopti_live_${process.pid}_${this.name}.ahk`);
		const sources = LIVE_SOURCES.map((file) =>
			fs.readFileSync(path.join(WINDOWS, 'tests', 'live', file), 'utf8').replace(/^\uFEFF/, '')
		).join('\n');
		// The live sources register their commands at top level, so they must run
		// before the driver's own auto-execute section, which never returns here.
		fs.writeFileSync(
			this.wrapper,
			'\uFEFF#Requires AutoHotkey v2.0+\n_DriverStartupSmokeInspect := LiveServe\n' +
				'_DriverStartupSmokeInspectShell := LiveShellHook\n' +
				sources +
				'\n#Include ErgoptiPlus.ahk\n',
			'utf8'
		);
		prepareStartupPersonalInclude(this.code.windows, this.config);
		this.env = {
			...process.env,
			LOCALAPPDATA: this.root,
			ERGOPTI_STARTUP_SMOKE_DIR: this.root,
			ERGOPTI_STARTUP_SMOKE_NONCE: crypto.randomBytes(16).toString('hex'),
			...(options.env || {})
		};
		this.child = spawn(this.ahk, ['/ErrorStdOut', this.wrapper], {
			cwd: this.code.windows,
			env: this.env,
			stdio: ['ignore', 'pipe', 'pipe'],
			windowsHide: false
		});
		this.output = '';
		this.child.stdout.on('data', (chunk) => (this.output += chunk));
		this.child.stderr.on('data', (chunk) => (this.output += chunk));
		// A reload requested while it starts replaces the first process before it serves.
		this.reloading = Boolean(options.expectReload);
		try {
			return await this.awaitServing(0, BOOT_TIMEOUT_MS);
		} finally {
			this.reloading = false;
		}
	}

	/**
	 * Waits for a serving driver whose pid differs from `previous`.
	 * @param {number} previous Pid to move away from, 0 for none.
	 * @param {number} timeoutMs Limit.
	 * @returns {Promise<number>} The serving pid.
	 */
	async awaitServing(previous, timeoutMs) {
		const file = path.join(this.live, 'alive.txt');
		const deadline = Date.now() + timeoutMs;
		while (Date.now() < deadline) {
			if (fs.existsSync(file)) {
				const pid = Number(fs.readFileSync(file, 'utf8').trim());
				if (pid > 0 && pid !== previous && alive(pid)) return pid;
			}
			if (this.child && this.child.exitCode !== null && !this.reloading)
				throw new Error(
					`the driver exited with ${this.child.exitCode} before serving:\n${this.output.slice(-2000)}`
				);
			await sleep(100);
		}
		throw new Error(`no driver served within ${timeoutMs} ms:\n${this.output.slice(-2000)}`);
	}

	/** Size and time stamps of what a busy driver changes: configuration, logs, serving pid. */
	activityStamp() {
		const parts = [];
		const cfg = path.join(this.config, 'autohotkey', 'config.toml');
		if (fs.existsSync(cfg)) {
			const stat = fs.statSync(cfg);
			parts.push(`${stat.size}:${stat.mtimeMs}`);
		}
		if (fs.existsSync(this.logs))
			for (const name of fs.readdirSync(this.logs))
				parts.push(`${name}:${fs.statSync(path.join(this.logs, name)).size}`);
		const alivePath = path.join(this.live, 'alive.txt');
		parts.push(fs.existsSync(alivePath) ? fs.readFileSync(alivePath, 'utf8').trim() : '');
		return parts.join('|');
	}

	/**
	 * Waits until the driver is quiet: it answers a command (so no click is still
	 * running on its only thread), and its configuration, logs and serving pid
	 * have not changed for `quietMs`. A reload that starts meanwhile is followed.
	 * @param {number} pid The pid serving before the command.
	 * @param {object} [options] quietMs, maxMs.
	 * @returns {Promise<{pid: number, reloaded: boolean}>} The serving pid and whether it changed.
	 */
	async quiesce(pid, { quietMs = 2500, maxMs = 120000 } = {}) {
		let current = pid;
		let reloaded = false;
		let last = this.activityStamp();
		let since = Date.now();
		const deadline = Date.now() + maxMs;
		const alivePath = path.join(this.live, 'alive.txt');
		this.reloading = true;
		try {
			while (Date.now() < deadline) {
				await sleep(150);
				if (!alive(current)) {
					current = await this.awaitServing(current, BOOT_TIMEOUT_MS);
					reloaded = true;
					since = Date.now();
				}
				const serving = fs.existsSync(alivePath)
					? Number(fs.readFileSync(alivePath, 'utf8').trim())
					: current;
				if (serving !== current && serving > 0 && alive(serving)) {
					current = serving;
					reloaded = true;
				}
				const stamp = this.activityStamp();
				if (stamp !== last) {
					last = stamp;
					since = Date.now();
					continue;
				}
				if (Date.now() - since < quietMs) continue;
				// A successor still loading logs nothing for seconds: two live processes
				// of this session mean a reload is under way.
				if (this.processes().length > 1) {
					since = Date.now();
					continue;
				}
				// Quiet logs do not prove an idle thread: a click may be inside a long
				// native call. Only an answered command does.
				try {
					await this.run('info', [], Math.max(5000, deadline - Date.now()));
				} catch (error) {
					if (alive(current)) throw error;
					continue;
				}
				const after = this.activityStamp();
				if (after === last) return { pid: current, reloaded };
				last = after;
				since = Date.now();
			}
			throw new Error(`the driver was still busy after ${maxMs} ms`);
		} finally {
			this.reloading = false;
		}
	}

	/**
	 * Runs one command in the driver.
	 * @param {string} name Registered command.
	 * @param {string[]} [args] Arguments.
	 * @param {number} [timeoutMs] Limit.
	 * @param {object} [options] followReload: a command that starts a reload may
	 *     end with its process, so no answer then returns null instead of failing.
	 * @returns {Promise<string|null>} The command's detail line.
	 */
	async run(name, args = [], timeoutMs = COMMAND_TIMEOUT_MS, options = {}) {
		const servingPath = path.join(this.live, 'alive.txt');
		const serving = fs.existsSync(servingPath)
			? Number(fs.readFileSync(servingPath, 'utf8').trim())
			: 0;
		const id = String(this.nextId++);
		const result = path.join(this.live, `res-${id}.txt`);
		const stage = path.join(this.live, `cmd.tmp${id}`);
		fs.writeFileSync(stage, [id, name, ...args].join('\t') + '\n');
		fs.renameSync(stage, path.join(this.live, 'cmd.txt'));
		const deadline = Date.now() + timeoutMs;
		while (Date.now() < deadline) {
			if (fs.existsSync(result)) {
				let text = null;
				try {
					text = fs.readFileSync(result, 'utf8');
				} catch {
					// The driver is replacing the file at this moment: read it again.
				}
				if (text !== null) {
					const [state, ...detail] = text.replace(/\r?\n$/, '').split('\t');
					if (state === 'ok') return detail.join('\t');
					throw new Error(`${name}: ${detail.join('\t')}`);
				}
			}
			if (options.followReload && serving > 0 && !alive(serving)) return null;
			await sleep(40);
		}
		throw new Error(`${name}: no answer within ${timeoutMs} ms`);
	}

	/**
	 * Types into the window that has the keyboard focus, from a separate hook-free
	 * process (tests/live/typist.ahk), so the driver sees the input as a person's.
	 * @param {string[][]} lines [kind, argument] pairs: key, text, wait, gap.
	 * @param {number} [timeoutMs] Limit for the whole script.
	 */
	type(lines, timeoutMs = 120000) {
		const script = path.join(this.live, `typist-${this.nextId++}.txt`);
		fs.writeFileSync(script, lines.map((line) => line.join('\t')).join('\n') + '\n');
		const out = spawnSync(
			this.ahk,
			['/ErrorStdOut', path.join(WINDOWS, 'tests', 'live', 'typist.ahk'), script],
			{ encoding: 'utf8', timeout: timeoutMs, windowsHide: true }
		);
		if (out.status !== 0)
			throw new Error(`the typist exited with ${out.status}: ${out.stdout}${out.stderr}`);
	}

	/**
	 * Every ERROR or FATAL line the driver logged so far.
	 * @returns {string[]}
	 */
	loggedErrors() {
		const found = [];
		if (!fs.existsSync(this.logs)) return found;
		for (const name of fs.readdirSync(this.logs)) {
			if (!name.endsWith('.log') || name.includes('errors_')) continue;
			for (const line of fs.readFileSync(path.join(this.logs, name), 'utf8').split(/\r?\n/))
				if (/\[(ERROR|FATAL)\]/.test(line)) found.push(line.trim());
		}
		return found;
	}

	/**
	 * Every log line that contains a fragment.
	 * @param {string} fragment Text to find.
	 * @returns {string[]}
	 */
	logLines(fragment) {
		const found = [];
		if (!fs.existsSync(this.logs)) return found;
		for (const name of fs.readdirSync(this.logs)) {
			if (!name.endsWith('.log') || name.includes('errors_')) continue;
			for (const line of fs.readFileSync(path.join(this.logs, name), 'utf8').split(/\r?\n/))
				if (line.includes(fragment)) found.push(line.trim());
		}
		return found;
	}

	/**
	 * The configuration file the driver writes, as text.
	 * @returns {string} The content, or '' when absent.
	 */
	configText() {
		const file = path.join(this.config, 'autohotkey', 'config.toml');
		return fs.existsSync(file) ? fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '') : '';
	}

	/** Every process of this session, the wrapper's successors included. */
	processes() {
		return processesMatching(path.basename(this.wrapper)).filter((p) => /AutoHotkey/i.test(p.name));
	}

	/** Stops the driver and everything it started, then removes the private tree. */
	async stop() {
		try {
			fs.writeFileSync(path.join(this.live, 'stop.txt'), 'stop\n');
		} catch {
			// The folder may be gone already.
		}
		const deadline = Date.now() + 8000;
		while (Date.now() < deadline && this.wrapper && this.processes().length > 0) await sleep(200);
		for (const p of this.wrapper ? this.processes() : []) {
			spawnSync('taskkill.exe', ['/PID', String(p.pid), '/T', '/F'], { windowsHide: true });
		}
		if (this.child && this.child.exitCode === null) this.child.kill();
	}

	/**
	 * Stops the driver and boots it again over the same profile, as a user who quits
	 * and starts the application. The configuration and logs stay.
	 * @param {object} [options] startupClicks: rows to click while it starts; env, expectReload as for start().
	 * @returns {Promise<number>} The serving pid.
	 */
	async restart(options = {}) {
		await this.stop();
		for (const name of fs.readdirSync(this.live))
			fs.rmSync(path.join(this.live, name), { force: true });
		this.nextId = 1;
		this.child = null;
		if (options.startupClicks) this.stageStartupClicks(options.startupClicks);
		return this.start(options);
	}

	/** Releases the code fixture's junctions; the caller deletes the scratch tree. */
	release() {
		if (this.code) this.code.close();
		this.code = null;
	}
}

/**
 * The driver sources some commits changed, as they were before the earliest of
 * them to touch each file: the way to show that a check fails without the fixes
 * it guards. Tests are not part of the driver.
 * @param {string} commits Comma-separated commits that changed driver files.
 * @returns {Object<string, string|null>} Path under windows/ to old content (null when new).
 */
function driverSourcesBefore(commits) {
	const prefix = 'static/ergopti_plus/windows/';
	const git = (...gitArgs) =>
		spawnSync('git', gitArgs, { cwd: ROOT, encoding: 'utf8', maxBuffer: 1 << 28 });
	const ordered = git('log', '--no-walk', '--reverse', '--format=%H', ...commits.split(','))
		.stdout.split(/\r?\n/)
		.filter(Boolean);
	const sources = {};
	for (const commit of ordered) {
		const names = git('diff-tree', '--no-commit-id', '--name-only', '-r', commit).stdout.split(
			/\r?\n/
		);
		for (const name of names) {
			if (!name.startsWith(prefix) || name.startsWith(prefix + 'tests/')) continue;
			const key = name.slice(prefix.length);
			if (key in sources) continue;
			const before = git('show', `${commit}^:${name}`);
			sources[key] = before.status === 0 ? before.stdout : null;
		}
	}
	if (Object.keys(sources).length === 0) throw new Error(`${commits} changed no driver source`);
	return sources;
}

/**
 * Flattens a parsed TOML value into dotted-key to JSON text pairs.
 * @param {*} value A parsed value.
 * @param {string} [prefix] Key path so far.
 * @param {object} [out] Accumulator.
 * @returns {Object<string, string>}
 */
function flattenToml(value, prefix = '', out = {}) {
	if (value && typeof value === 'object' && !Array.isArray(value)) {
		for (const [key, inner] of Object.entries(value))
			flattenToml(inner, prefix ? prefix + '.' + key : key, out);
	} else out[prefix] = JSON.stringify(value);
	return out;
}

/**
 * The driver's configuration as dotted keys, `{}` when there is none yet.
 * @param {LiveSession} session The session.
 * @returns {Object<string, string>}
 */
function configSnapshot(session) {
	const text = session.configText();
	return text ? flattenToml(parseToml(text)) : {};
}

/**
 * The keys whose value differs between two snapshots.
 * @param {Object<string, string>} before Earlier snapshot.
 * @param {Object<string, string>} after Later snapshot.
 * @returns {{key: string, before: string|undefined, after: string|undefined}[]}
 */
function diffSnapshots(before, after) {
	const keys = new Set([...Object.keys(before), ...Object.keys(after)]);
	return [...keys]
		.sort()
		.filter((key) => before[key] !== after[key])
		.map((key) => ({ key, before: before[key], after: after[key] }));
}

/**
 * Formats the verdict table.
 * @param {{id: string, state: string, detail: string}[]} results Verdicts.
 * @returns {string}
 */
function table(results) {
	const width = Math.max(...results.map((r) => r.id.length));
	return results.map((r) => `${r.state.padEnd(12)} ${r.id.padEnd(width)}  ${r.detail}`).join('\n');
}

module.exports = {
	LiveSession,
	sleep,
	processesMatching,
	runningAutoHotkeyScripts,
	configSnapshot,
	diffSnapshots,
	table,
	WINDOWS,
	ROOT
};

/**
 * Entry point: runs the selected checks.
 * @returns {Promise<number>} Exit code: 0 all pass, 1 a check failed, 2 not runnable.
 */
async function main() {
	if (process.platform !== 'win32') {
		console.log('Windows live checks: not executed, this is not Windows.');
		return 2;
	}
	const args = process.argv.slice(2);
	const { CHECKS } = require('./windows-live-checks-list.cjs');
	if (args.includes('--list')) {
		for (const check of CHECKS) console.log(`${check.id}  ${check.title}`);
		return 0;
	}
	const allowOtherDriver = args.includes('--allow-other-driver');
	const revertIndex = args.indexOf('--without-fix-of');
	if (revertIndex >= 0) overlay = driverSourcesBefore(args[revertIndex + 1]);
	const onlyIndex = args.indexOf('--only');
	const only = onlyIndex >= 0 ? args[onlyIndex + 1].split(',') : null;
	const ahk = process.env.ERGOPTI_AHK_EXE || AHK_CANDIDATES.find((c) => fs.existsSync(c));
	if (!ahk) {
		console.log('Windows live checks: not executed, AutoHotkey v2 is not installed.');
		return 2;
	}
	const selected = CHECKS.filter((check) => !only || only.includes(check.id));
	if (selected.length === 0) {
		console.error('No check matches --only.');
		return 2;
	}
	const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-live-'));
	const others = runningAutoHotkeyScripts();
	console.log(`Other AutoHotkey processes during this run (${others.length}):`);
	for (const line of others) console.log(`  ${line}`);
	const results = [];
	const sessions = [];
	try {
		for (const check of selected) {
			const started = Date.now();
			const context = {
				ahk,
				scratch,
				/**
				 * A check that types real keys asks whether another ErgoptiPlus driver
				 * shares the desktop: its hooks see the same keys and expand or remap
				 * them too, so the screen would hold the work of two drivers.
				 * @returns {string|null} The reason to skip, or null when the desktop is quiet.
				 */
				otherDriverReason: () => {
					if (allowOtherDriver) return null;
					const drivers = otherDriverPids(scratch);
					return drivers.length === 0
						? null
						: `another ErgoptiPlus driver runs on this desktop (pid ${drivers.join(', ')}) and its hooks would act on the same keys; close it, or pass --allow-other-driver to run anyway`;
				},
				/** The pids of other ErgoptiPlus drivers, whatever --allow-other-driver says. */
				otherDriverPids: () => otherDriverPids(scratch),
				newSession: (name) => {
					const session = new LiveSession(ahk, scratch, `${check.id}-${name}`);
					sessions.push(session);
					return session;
				}
			};
			let verdict;
			try {
				verdict = await check.run(context);
			} catch (error) {
				verdict = { state: 'FAIL', detail: String(error.message || error).split('\n')[0] };
			}
			results.push({
				id: check.id,
				...verdict,
				seconds: ((Date.now() - started) / 1000).toFixed(1)
			});
			console.log(`${verdict.state.padEnd(12)} ${check.id}  ${verdict.detail}`);
			for (const session of sessions.splice(0)) {
				await session.stop();
				session.release();
			}
		}
	} finally {
		for (const session of sessions) {
			await session.stop();
			session.release();
		}
		if (!args.includes('--keep')) {
			fs.rmSync(scratch, { recursive: true, force: true, maxRetries: 12, retryDelay: 200 });
		} else console.log(`Scratch kept at ${scratch}`);
	}
	console.log(`\n${table(results)}`);
	fs.writeFileSync(
		path.join(os.tmpdir(), 'ergopti-live-checks-report.json'),
		JSON.stringify({ others, results }, null, 2)
	);
	return results.some((r) => r.state === 'FAIL') ? 1 : 0;
}

if (require.main === module) {
	main().then(
		(code) => {
			process.exitCode = code;
		},
		(error) => {
			console.error(error);
			process.exitCode = 2;
		}
	);
}
