// tools/test/ahk-parallel.cjs
'use strict';

/**
 * Runs the Windows AHK suite in parallel on one checkout, with a resumable result
 * ledger. Windows only: the suite drives native AutoHotkey and Win32, which macOS
 * and Linux do not have; they own their own Lua suites.
 *
 * Each worker runs the plain tests/run_all.ahk under `/force`, the interpreter's
 * switch for #SingleInstance Off, so workers do not replace one another and no
 * copy of the runner is needed. Each worker also owns a temporary directory:
 * several tests use fixed names under %TEMP%.
 *
 *   npm run test:ahk-parallel                      run or resume
 *   npm run test:ahk-parallel -- --workers=6 --only="config transition"
 *   npm run test:ahk-parallel -- --fresh           forget the ledger first
 *   npm run test:ahk-parallel -- --rerun-failures  each failure alone, one at a time
 *   npm run test:ahk-parallel -- --report=40       slowest tests of the ledger
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const REPO_ROOT = path.resolve(__dirname, '../..');
const TESTS_DIR = path.join(REPO_ROOT, 'static/ergopti_plus/windows/tests');
const DEFAULT_RUN_DIR = path.join(REPO_ROOT, '.ahk-parallel');
const DEFAULT_AHK = 'C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe';
const LEDGER_VERSION = 1;
const OK = 'ok';
const SKIP = 'skip';
const NOT_OK = 'not ok';

// One process parses the whole suite before its first test, so a chunk is sized
// by the time its tests took last run instead of by a fixed count.
const DEFAULTS = Object.freeze({
	chunkSeconds: 300,
	chunkMaxTests: 1000,
	unknownTestMs: 1000,
	processCapMinutes: 30,
	maxEmptyProcesses: 8,
	reportRows: 30,
	planTimeoutMs: 300000
});

/**
 * Parses a run_all results file. RUNNING lines bind each index to its exact name:
 * --list runs in registry order, not in list order.
 * @param {string} text Results file content.
 * @returns {{plan: number|null, results: Array<{name: string, status: string, detail: string, ms: number|null}>}}
 */
function parseTap(text) {
	let plan = null;
	const names = new Map();
	const byIndex = new Map();
	for (const line of text.replace(/^\uFEFF/, '').split(/\r?\n/)) {
		let match = line.match(/^1\.\.(\d+)$/);
		if (match) {
			plan = Number(match[1]);
			continue;
		}
		match = line.match(/^RUNNING (\d+)\/\d+ - (.*)$/);
		if (match) {
			names.set(match[1], match[2]);
			continue;
		}
		match = line.match(/^(not )?ok (\d+) - (.*)$/);
		if (match && names.has(match[2])) {
			const status = match[1] ? NOT_OK : /NOT EXECUTED/.test(match[3]) ? SKIP : OK;
			byIndex.set(match[2], {
				name: names.get(match[2]),
				status,
				detail:
					status === OK ? '' : match[3].slice(names.get(match[2]).length).trim().slice(0, 500),
				ms: null
			});
			continue;
		}
		match = line.match(/^# duration_ms (\d+) ([\d.]+)/);
		if (match && byIndex.has(match[1])) byIndex.get(match[1]).ms = Number(match[2]);
	}
	return { plan, results: [...byIndex.values()] };
}

/**
 * Folds results into the ledger. Tests may share a name; --list selects them
 * together, so the entry keeps the worst status and the summed duration.
 * @param {object} entries Ledger entries by test name, changed in place.
 * @param {Array<object>} results Results of one process.
 * @returns {Set<string>} Names that received a result.
 */
function foldResults(entries, results) {
	const seen = new Set();
	for (const result of results) {
		const prior = seen.has(result.name) ? entries[result.name] : null;
		const failed = prior && prior.status === NOT_OK;
		entries[result.name] = {
			status: failed ? NOT_OK : result.status,
			detail: failed ? prior.detail : result.detail,
			ms: (prior && prior.ms ? prior.ms : 0) + (result.ms || 0)
		};
		seen.add(result.name);
	}
	return seen;
}

/**
 * Cuts a list of test names into process-sized chunks.
 * @param {string[]} names Remaining names, in order.
 * @param {Object<string, number>} durations Known durations in ms, by name.
 * @param {{chunkSeconds: number, chunkMaxTests: number, unknownTestMs: number}} limits Sizing limits.
 * @returns {string[]} The names of the next chunk, removed from `names`.
 */
function takeChunk(names, durations, limits) {
	const budget = limits.chunkSeconds * 1000;
	let spent = 0;
	let count = 0;
	while (count < names.length && count < limits.chunkMaxTests) {
		const known = durations[names[count]];
		const cost = known === undefined ? limits.unknownTestMs : known;
		if (count > 0 && spent + cost > budget) break;
		spent += cost;
		count += 1;
	}
	return names.splice(0, count);
}

/**
 * Formats the slowest tests and files of a ledger.
 * @param {object} ledger Ledger with entries and plan rows.
 * @param {number} rows Rows per table.
 * @returns {string} The report.
 */
function formatReport(ledger, rows) {
	const timed = Object.entries(ledger.entries).filter(([, entry]) => entry.ms);
	const total = timed.reduce((sum, [, entry]) => sum + entry.ms, 0);
	const sorted = timed.map(([, entry]) => entry.ms).sort((a, b) => a - b);
	const median = sorted.length ? sorted[Math.floor(sorted.length / 2)] : 0;
	const seconds = (ms) => (ms / 1000).toFixed(1).padStart(8);
	const out = [
		`${timed.length} timed tests, ${(total / 60000).toFixed(1)} CPU-minutes of test time, median ${median.toFixed(1)} ms.`
	];
	out.push('', 'Slowest tests (s):');
	for (const [name, entry] of timed.sort((a, b) => b[1].ms - a[1].ms).slice(0, rows))
		out.push(`${seconds(entry.ms)}  ${name}`);
	const byFile = new Map();
	for (const [name, entry] of timed) {
		const file = (ledger.plan && ledger.plan[name]) || '(not in plan)';
		byFile.set(file, (byFile.get(file) || 0) + entry.ms);
	}
	out.push('', 'Slowest files (s):');
	for (const [file, ms] of [...byFile].sort((a, b) => b[1] - a[1]).slice(0, rows))
		out.push(`${seconds(ms)}  ${file}`);
	return out.join('\n');
}

function readLedger(file) {
	if (!fs.existsSync(file)) return null;
	const ledger = JSON.parse(fs.readFileSync(file, 'utf8'));
	if (ledger.version !== LEDGER_VERSION)
		throw new Error(`Unknown ledger version in ${file}; rerun with --fresh.`);
	return ledger;
}

// A kill between the two steps leaves the previous complete ledger.
function writeLedger(file, ledger) {
	fs.writeFileSync(file + '.tmp', JSON.stringify(ledger));
	fs.renameSync(file + '.tmp', file);
}

function parseArguments(argv) {
	const options = {
		workers: Math.max(1, Math.floor(os.cpus().length / 2)),
		runDir: DEFAULT_RUN_DIR,
		only: '',
		fresh: false,
		rerunFailures: false,
		report: 0,
		acceptStale: false,
		...DEFAULTS
	};
	for (const argument of argv) {
		const [flag, value] = argument.split(/=(.*)/s);
		if (flag === '--workers') options.workers = Number(value);
		else if (flag === '--run-dir') options.runDir = path.resolve(value);
		else if (flag === '--only') options.only = value;
		else if (flag === '--chunk-seconds') options.chunkSeconds = Number(value);
		else if (flag === '--fresh') options.fresh = true;
		else if (flag === '--accept-stale') options.acceptStale = true;
		else if (flag === '--rerun-failures') options.rerunFailures = true;
		else if (flag === '--report')
			options.report = value === undefined ? DEFAULTS.reportRows : Number(value);
		else throw new Error(`Unknown option: ${argument}`);
	}
	for (const name of ['workers', 'chunkSeconds']) {
		if (!Number.isInteger(options[name]) || options[name] < 1)
			throw new Error(`--${name} needs a positive integer.`);
	}
	if (options.fresh && options.rerunFailures)
		throw new Error('--fresh forgets the failures --rerun-failures would rerun.');
	return options;
}

function ahkExecutable() {
	const exe = process.env.ERGOPTI_AHK_EXE || DEFAULT_AHK;
	if (!fs.existsSync(exe)) throw new Error('AutoHotkey v2 is missing; set ERGOPTI_AHK_EXE.');
	return exe;
}

function headCommit() {
	const result = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: REPO_ROOT, encoding: 'utf8' });
	if (result.status !== 0) throw new Error(`git rev-parse failed: ${result.stderr}`);
	return result.stdout.trim();
}

// The dry run also proves that the whole suite parses before workers start.
function dumpPlan(exe, runDir) {
	const planFile = path.join(runDir, 'plan.tsv');
	fs.rmSync(planFile, { force: true });
	const result = spawnSync(
		exe,
		['/force', '/ErrorStdOut', 'run_all.ahk', '--dry-run', `--dump-plan=${planFile}`],
		{
			cwd: TESTS_DIR,
			env: { ...process.env, ERGOPTI_AHK_RESULTS_FILE: path.join(runDir, 'plan.tap') },
			encoding: 'utf8',
			maxBuffer: 1 << 28,
			timeout: DEFAULTS.planTimeoutMs
		}
	);
	if (!fs.existsSync(planFile))
		throw new Error(
			`The suite produced no plan (exit ${result.status}): ${String(result.stderr).slice(0, 2000)}`
		);
	const rows = fs
		.readFileSync(planFile, 'utf8')
		.replace(/^\uFEFF/, '')
		.split(/\r?\n/)
		.filter(Boolean);
	const plan = {};
	for (const row of rows) {
		const [, file, ...name] = row.split('\t');
		plan[name.join('\t')] = path.relative(TESTS_DIR, file).replace(/\\/g, '/');
	}
	return plan;
}

function killTree(pid) {
	spawnSync('taskkill', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore' });
}

/**
 * Runs one process over a list of tests and folds its results into the ledger.
 * The first test without a result is the one the process died in; the rest are
 * returned to run again.
 */
function runProcess(context, worker, list) {
	const { exe, options, ledger, ledgerFile } = context;
	const workerDir = path.join(options.runDir, `w${worker}`);
	const tempDir = path.join(workerDir, 'temp');
	fs.mkdirSync(tempDir, { recursive: true });
	const tap = path.join(workerDir, 'results.tap');
	const listFile = path.join(workerDir, 'list.txt');
	fs.writeFileSync(listFile, list.join('\n') + '\n');
	fs.rmSync(tap, { force: true });
	const started = Date.now();
	return new Promise((resolve) => {
		const child = spawn(exe, ['/force', '/ErrorStdOut', 'run_all.ahk', `--list=${listFile}`], {
			cwd: TESTS_DIR,
			env: { ...process.env, ERGOPTI_AHK_RESULTS_FILE: tap, TEMP: tempDir, TMP: tempDir },
			stdio: 'ignore'
		});
		const cap = setTimeout(() => killTree(child.pid), options.processCapMinutes * 60000);
		child.on('close', (status) => {
			clearTimeout(cap);
			const { results } = parseTap(fs.existsSync(tap) ? fs.readFileSync(tap, 'utf8') : '');
			const seen = foldResults(ledger.entries, results);
			const missing = list.filter((name) => !seen.has(name));
			if (missing.length)
				ledger.entries[missing[0]] = {
					status: NOT_OK,
					detail: `no result: the process ended with status ${status}`,
					ms: 0
				};
			writeLedger(ledgerFile, ledger);
			const counts = countStatuses(ledger.entries);
			console.log(
				`w${worker}: ${seen.size}/${list.length} in ${((Date.now() - started) / 60000).toFixed(1)} min; ok ${counts.ok}, skip ${counts.skip}, not ok ${counts.notOk}, of ${Object.keys(ledger.plan).length}`
			);
			fs.rmSync(tempDir, { recursive: true, force: true });
			resolve({ requeue: missing.slice(1), empty: seen.size === 0 });
		});
	});
}

function countStatuses(entries) {
	const values = Object.values(entries);
	return {
		ok: values.filter((entry) => entry.status === OK).length,
		skip: values.filter((entry) => entry.status === SKIP).length,
		notOk: values.filter((entry) => entry.status === NOT_OK).length
	};
}

async function runQueue(context, queue, workers, chunkOf) {
	let emptyProcesses = 0;
	const worker = async (id) => {
		while (queue.length && emptyProcesses < DEFAULTS.maxEmptyProcesses) {
			const { requeue, empty } = await runProcess(context, id, chunkOf(queue));
			queue.unshift(...requeue);
			emptyProcesses = empty ? emptyProcesses + 1 : 0;
		}
	};
	await Promise.all(Array.from({ length: workers }, (_, index) => worker(index + 1)));
	if (queue.length)
		throw new Error(
			`Stopped: ${DEFAULTS.maxEmptyProcesses} processes in a row produced no result.`
		);
}

async function main() {
	const options = parseArguments(process.argv.slice(2));
	const ledgerFile = path.join(options.runDir, 'ledger.json');
	if (options.report) {
		const ledger = readLedger(ledgerFile);
		if (!ledger) throw new Error(`No ledger at ${ledgerFile}.`);
		console.log(formatReport(ledger, options.report));
		return 0;
	}
	if (process.platform !== 'win32')
		throw new Error(
			'The AHK suite needs native Windows; macOS and Linux run their own Lua suites.'
		);
	fs.mkdirSync(options.runDir, { recursive: true });
	const commit = headCommit();
	const prior = options.fresh ? null : readLedger(ledgerFile);
	if (prior && prior.commit !== commit && !options.acceptStale) {
		throw new Error(
			`The ledger belongs to ${prior.commit}, HEAD is ${commit}: use --fresh, or --accept-stale to keep its results.`
		);
	}
	const exe = ahkExecutable();
	// Durations survive --fresh: they only size chunks.
	const durationsFile = path.join(options.runDir, 'durations.json');
	const durations = fs.existsSync(durationsFile)
		? JSON.parse(fs.readFileSync(durationsFile, 'utf8'))
		: {};
	const ledger = prior || { version: LEDGER_VERSION, commit, plan: {}, entries: {} };
	ledger.commit = commit;
	ledger.plan = dumpPlan(exe, options.runDir);
	const context = { exe, options, ledger, ledgerFile };
	const selected = Object.keys(ledger.plan).filter(
		(name) => !options.only || name.toLowerCase().includes(options.only.toLowerCase())
	);
	if (options.rerunFailures) {
		// Alone and one at a time: what still fails here does not owe it to a neighbour.
		const failures = selected.filter(
			(name) => ledger.entries[name] && ledger.entries[name].status === NOT_OK
		);
		console.log(`Rerunning ${failures.length} failure(s) alone.`);
		for (const name of failures) delete ledger.entries[name];
		await runQueue(context, failures, 1, (queue) => queue.splice(0, 1));
	} else {
		const queue = selected.filter((name) => !ledger.entries[name]);
		console.log(
			`Plan ${selected.length}, left ${queue.length}, ${options.workers} worker(s), run dir ${options.runDir}.`
		);
		await runQueue(context, queue, options.workers, (remaining) =>
			takeChunk(remaining, durations, options)
		);
	}
	for (const [name, entry] of Object.entries(ledger.entries))
		if (entry.ms) durations[name] = entry.ms;
	fs.writeFileSync(durationsFile, JSON.stringify(durations));
	for (let id = 1; id <= options.workers; id += 1)
		fs.rmSync(path.join(options.runDir, `w${id}`), { recursive: true, force: true });
	console.log(formatReport(ledger, DEFAULTS.reportRows));
	const failures = selected.filter(
		(name) => ledger.entries[name] && ledger.entries[name].status === NOT_OK
	);
	const absent = selected.filter((name) => !ledger.entries[name]);
	for (const name of failures) console.log(`not ok - ${name} ${ledger.entries[name].detail}`);
	if (absent.length) console.log(`${absent.length} planned test(s) have no result.`);
	console.log(
		`${selected.length - failures.length - absent.length}/${selected.length} green. Ledger: ${ledgerFile}`
	);
	return failures.length || absent.length ? 1 : 0;
}

if (require.main === module) {
	main().then(
		(code) => process.exit(code),
		(error) => {
			console.error(error.message);
			process.exit(2);
		}
	);
}

module.exports = { parseTap, foldResults, takeChunk, formatReport, parseArguments };
