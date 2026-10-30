// tools/test/test-field-log-analyse.cjs

/**
 * ==============================================================================
 * MODULE: Field Log Analyser Tests
 * DESCRIPTION:
 * Runs the real tools/dev/field-log-analyse.py, the one analyser every field
 * report collector (macOS, Linux, Windows) runs on its scrubbed day logs:
 * 1. every vector of tools/test/fixtures/field-log-analyse/vectors.json still
 *    names a template its driver source writes, and the analyser reads the
 *    vector's line as the vector expects; each driver has vectors, and every
 *    measured-event pattern is exercised by one;
 * 2. every budget is the value its declaration holds, and a declaration that
 *    moved stops the analyser instead of turning into "no budget declared";
 * 3. a full run writes analysis.md and analysis.json with the error groups,
 *    the groups new since the previous report of the same OS tag, the budget
 *    verdicts, the reload time, the field check marks and the ranking;
 * 4. a log outside the report folder (a raw, unscrubbed log) is refused;
 * 5. the analyser stays Python 3.8 syntax with the standard library only.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { reportNotExecuted } = require('./lib/host-capabilities.cjs');

const ROOT = path.resolve(__dirname, '../..');
const ANALYSER = path.join(ROOT, 'tools/dev/field-log-analyse.py');
const VECTORS = path.join(ROOT, 'tools/test/fixtures/field-log-analyse/vectors.json');
const DRIVERS = ['macos', 'linux', 'windows'];

/** The first Python that runs on this host, or null. */
function findPython() {
	for (const name of ['python3', 'python']) {
		const probe = spawnSync(name, ['--version'], { encoding: 'utf8' });
		if (probe.status === 0) return name;
	}
	return null;
}

const python = findPython();
if (!python) {
	reportNotExecuted('field log analyser', 'no Python interpreter runs on this host');
	process.exit(0);
}

/** Runs the analyser; returns the spawn result. */
function analyse(args, input) {
	return spawnSync(python, [ANALYSER, ...args], { encoding: 'utf8', input });
}

let checks = 0;
function check(name, body) {
	body();
	checks++;
	console.log(`PASS ${name}`);
}

const { vectors } = JSON.parse(fs.readFileSync(VECTORS, 'utf8'));
const describe = analyse(['--repo', ROOT, '--describe']);
assert.equal(describe.status, 0, describe.stderr);
const described = JSON.parse(describe.stdout);

check('every vector names a template its driver source still writes', () => {
	for (const vector of vectors) {
		assert(DRIVERS.includes(vector.driver), `unknown driver ${vector.driver}`);
		const source = fs.readFileSync(path.join(ROOT, vector.source), 'utf8');
		assert(
			source.includes(vector.template),
			`${vector.source} no longer writes: ${vector.template}`
		);
	}
	for (const driver of DRIVERS)
		assert(
			vectors.filter((vector) => vector.driver === driver).length >= 10,
			`${driver} has too few vectors`
		);
});

const explained = analyse(
	['--repo', ROOT, '--explain'],
	vectors.map((vector) => vector.line).join('\n') + '\n'
);
assert.equal(explained.status, 0, explained.stderr);
const readings = explained.stdout
	.trim()
	.split('\n')
	.map((line) => JSON.parse(line));
assert.equal(readings.length, vectors.length, 'one reading per vector');

check('the analyser reads every vector as it expects', () => {
	vectors.forEach((vector, index) => {
		const reading = readings[index];
		const expect = vector.expect;
		const label = `${vector.driver} ${vector.line}`;
		if (expect.measures) {
			assert.deepEqual(
				reading.measures.map(({ metric, value, declared, budget }) => ({
					metric,
					value,
					declared,
					budget
				})),
				expect.measures,
				label
			);
		}
		for (const key of [
			'summaries',
			'field_check',
			'repeat',
			'template',
			'kind',
			'level',
			'module',
			'lifecycle'
		])
			if (key in expect) assert.deepEqual(reading[key], expect[key], `${key} of ${label}`);
	});
});

check('every measured-event pattern is exercised by a vector', () => {
	const used = new Set(
		readings.flatMap((reading) => (reading.measures || []).map((measure) => measure.pattern))
	);
	for (let index = 0; index < described.patterns; index++)
		assert(used.has(index), `pattern ${index} of PATTERNS has no vector`);
});

check('every lifecycle category is exercised by a vector', () => {
	const used = new Set(readings.flatMap((reading) => reading.lifecycle || []));
	for (const category of described.lifecycle) {
		if (['permission_refused', 'update_check'].includes(category)) continue;
		assert(used.has(category), `lifecycle ${category} has no vector`);
	}
});

check('the lifecycle categories without a driver vector still read their lines', () => {
	const lines = [
		'2026-10-30 10:00:00:000 [ERROR] [init] Accessibility permission was revoked; input owners stopped.',
		'2026-10-30 10:00:00:000 [INFO] [updater] Update check started (channel dev).'
	];
	const run = analyse(['--repo', ROOT, '--explain'], lines.join('\n') + '\n');
	assert.equal(run.status, 0, run.stderr);
	const [permission, update] = run.stdout
		.trim()
		.split('\n')
		.map((line) => JSON.parse(line));
	assert.deepEqual(permission.lifecycle, ['permission_refused']);
	assert.deepEqual(update.lifecycle, ['update_check']);
});

check('every budget is the value its declaration holds', () => {
	const read = (relative) => fs.readFileSync(path.join(ROOT, relative), 'utf8');
	const toml = read('static/ergopti_plus/_shared/modules/timings/constants.toml');
	const logger = toml.slice(toml.indexOf('\n[logger]'));
	const hotpath = Number(logger.match(/^hotpath_slow_ms = (\d+)/m)[1]);
	assert.equal(described.budgets['hotpath:'], hotpath);
	assert.equal(
		described.budgets['main_thread.hold'],
		Number(
			read('static/ergopti_plus/macos/infra/logger.lua').match(
				/^local SLOW_TIMER_CALLBACK_COUNT_MS = (\d+)/m
			)[1]
		)
	);
	assert.equal(
		described.budgets['preferences.save'],
		Number(
			read('static/ergopti_plus/macos/infra/preferences.lua').match(
				/^local SLOW_SAVE_REPORT_MS = (\d+)/m
			)[1]
		)
	);
	assert.equal(
		described.budgets['keystats.ingest'],
		Number(
			read('static/ergopti_plus/macos/modules/keystats/ingest_trace.lua').match(
				/^M\.REPORT_THRESHOLD_MS = (\d+)/m
			)[1]
		)
	);
	const windows = read('static/ergopti_plus/windows/infra/hotpath_profiler.ahk');
	assert.equal(
		described.segments['UIA.SelectionPoll'],
		Number(windows.match(/"UIA\.SelectionPoll", (\d+(?:\.\d+)?)/)[1])
	);
});

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-analyse-'));
try {
	check('a budget declaration that moved stops the analyser', () => {
		const repo = path.join(scratch, 'repo');
		const copy = (relative, edit = (text) => text) => {
			fs.mkdirSync(path.dirname(path.join(repo, relative)), { recursive: true });
			fs.writeFileSync(
				path.join(repo, relative),
				edit(fs.readFileSync(path.join(ROOT, relative), 'utf8'))
			);
		};
		copy('static/ergopti_plus/_shared/modules/timings/constants.toml');
		copy('static/ergopti_plus/macos/infra/logger.lua');
		copy('static/ergopti_plus/macos/infra/preferences.lua', (text) =>
			text.replace(/^local SLOW_SAVE_REPORT_MS = /m, 'local SAVE_REPORT_MS = ')
		);
		copy('static/ergopti_plus/macos/modules/keystats/ingest_trace.lua');
		copy('static/ergopti_plus/windows/infra/hotpath_profiler.ahk');
		const run = analyse(['--repo', repo, '--describe']);
		assert.notEqual(run.status, 0, 'a moved declaration must fail the run');
		assert.match(run.stderr, /preferences\.lua no longer declares the preferences\.save budget/);
	});

	const reports = path.join(scratch, 'reports');
	const day = '2026-10-30';
	const log = (folder, lines) => {
		fs.mkdirSync(folder, { recursive: true });
		const file = path.join(folder, `ErgoptiPlus_${day}.log`);
		fs.writeFileSync(file, lines.join('\n') + '\n');
		return file;
	};
	const stamp = (clock) => `${day} ${clock}:000`;
	const previous = path.join(reports, 'win-2026-10-30_080000');
	const current = path.join(reports, 'win-2026-10-30_120000');
	const otherOs = path.join(reports, 'mac-2026-10-30_110000');
	const oldLog = log(previous, [
		`${stamp('08:00:00')} [ERROR] [Updater] The release list could not be read: HTTP 503.`
	]);
	assert.equal(analyse(['--repo', ROOT, '--out', previous, oldLog]).status, 0);
	const macLog = log(otherOs, [`${stamp('11:00:00')} [ERROR] [Menu] A mac only error 1.`]);
	assert.equal(analyse(['--repo', ROOT, '--out', otherOs, macLog]).status, 0);
	const dayLog = log(current, [
		'',
		`===== ${stamp('09:00:00')} — ErgoptiPlus session opened =====`,
		`${stamp('09:00:01')} [INFO] [BootProfile] Boot timing started.`,
		`${stamp('09:00:03')} [INFO] [BootProfile] Boot complete in 2410 ms (since process start).`,
		`${stamp('09:10:00')} [ERROR] [Updater] The release list could not be read: HTTP 502.`,
		`${stamp('09:11:00')} [ERROR] [Updater] The release list could not be read: HTTP 504.`,
		`${stamp('09:12:00')} [ERROR] [Keystats] Session reset refused: pending text was not accepted.`,
		`${stamp('09:13:00')} [WARNING] [HotPath] Slow HSE.Dispatch: 7.25 ms (trigger matched).`,
		`${stamp('09:14:00')} [WARNING] [HotPath] Slow UIA.SelectionPoll: 41.0 ms (poll).`,
		`${stamp('09:15:00')} [INFO] [HotPath] Latency 'Hook.KeyDown': count=400, mean=0.3000 ms, min=0.0500 ms, max=3.2000 ms, slow=0, ge1=1, ge5=0, ge10=0, ge50=0.`,
		`${stamp('09:20:00')} [INFO] [Lifecycle] Reload requested by tray (suspended=0).`,
		'',
		`===== ${stamp('09:20:02')} — ErgoptiPlus session opened =====`,
		`${stamp('09:20:04')} [INFO] [BootProfile] Boot complete in 1900 ms (since process start).`,
		`${stamp('09:30:00')} [INFO] [ComposerCheck] Composer check result: check=composer verdict=fail steps=4 layout=fail`,
		`${stamp('09:40:00')} [INFO] [ComposerCheck] Composer check result: check=composer verdict=pass steps=4 layout=pass`,
		'  a continuation line'
	]);
	fs.writeFileSync(
		path.join(current, 'collector_checks.txt'),
		'check=autohotkey verdict=skip codes=missing\n'
	);
	const run = analyse(['--repo', ROOT, '--out', current, dayLog]);
	const document = JSON.parse(fs.readFileSync(path.join(current, 'analysis.json'), 'utf8'));
	const markdown = fs.readFileSync(path.join(current, 'analysis.md'), 'utf8');

	check('a full run groups errors by module and template, and marks the new ones', () => {
		assert.equal(run.status, 0, run.stderr);
		assert.equal(
			document.previous,
			'win-2026-10-30_080000',
			'the previous report of the same OS tag'
		);
		const updater = document.errors.find((group) => group.module === 'Updater');
		assert.equal(updater.count, 2);
		assert.equal(updater.first, stamp('09:10:00'));
		assert.equal(updater.last, stamp('09:11:00'));
		assert.equal(updater.new, false, 'the previous report already had this template');
		assert.equal(document.errors.find((group) => group.module === 'Keystats').new, true);
		assert.equal(document.continuations, 1);
	});

	check('a full run gives each measure its declared budget verdict', () => {
		const row = (metric) => document.performance.find((item) => item.metric === metric);
		assert.equal(row('hotpath:HSE.Dispatch').verdict, 'over');
		assert.equal(
			row('hotpath:UIA.SelectionPoll').verdict,
			'within',
			'the Windows per-segment budget applies'
		);
		assert.equal(row('latency:Hook.KeyDown').verdict, 'within');
		assert.equal(row('boot.total').verdict, 'no_budget');
		assert.equal(row('boot.total').count, 2);
		assert.equal(row('boot.total').p95, 2410);
		assert.equal(row('reload.total').worst[0].value, 4000, 'from the request to the next boot');
		assert.match(markdown, /\| boot\.total \| 2 \| .* \| no budget declared \|/);
		assert.match(markdown, /\| hotpath:HSE\.Dispatch \| 1 \| .*❌ over \(1\)/);
	});

	check('a full run counts the lifecycle and keeps the last verdict of each check', () => {
		assert.equal(document.lifecycle.start.count, 2, 'the banners, not the boot timing lines too');
		assert.equal(document.lifecycle.reload.count, 1);
		const composer = document.field_checks.items.find((item) => item.id === 'composer');
		assert.equal(composer.verdict, 'pass');
		assert.equal(composer.runs, 2);
		assert.equal(composer.failures, 1);
		assert.deepEqual(document.field_checks.counts, { pass: 1, skip: 1 });
		assert.match(run.stdout, /✅ check composer: pass/);
		assert.match(run.stdout, /⏭️ check autohotkey: skip/);
		assert.match(
			run.stdout,
			/Check verdicts summary: ✅ 1 pass, ❌ 0 fail, ⏭️ 1 skip, ⌨️ 0 needs_typing, ⚠️ 0 other\./
		);
	});

	check('what to fix first ranks severity times frequency', () => {
		const [first, second] = document.top_fixes;
		assert.equal(first.kind, 'error');
		assert.match(first.what, /^\[Updater\]/);
		assert.equal(first.score, 10);
		assert.equal(second.score, 5);
		assert(
			!document.top_fixes.some((item) => item.what.startsWith('[HotPath]')),
			'a measure is ranked once'
		);
	});

	check('a log outside the report folder is refused', () => {
		const refused = analyse(['--repo', ROOT, '--out', current, oldLog]);
		assert.notEqual(refused.status, 0);
		assert.match(refused.stderr, /only scrubbed copies are analysed/);
	});
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}

check('the analyser is Python 3.8 syntax with the standard library only', () => {
	const probe = spawnSync(
		python,
		[
			'-c',
			[
				'import ast, sys',
				'source = open(sys.argv[1], encoding="utf-8").read()',
				'tree = ast.parse(source, feature_version=(3, 8))',
				'names = {a.name.split(".")[0] for n in ast.walk(tree) if isinstance(n, ast.Import) for a in n.names}',
				'names |= {n.module.split(".")[0] for n in ast.walk(tree) if isinstance(n, ast.ImportFrom) and n.module}',
				'print(" ".join(sorted(names)))'
			].join('\n'),
			ANALYSER
		],
		{ encoding: 'utf8' }
	);
	assert.equal(probe.status, 0, probe.stderr);
	assert.deepEqual(probe.stdout.trim().split(' '), [
		'argparse',
		'json',
		'math',
		'pathlib',
		're',
		'sys'
	]);
	const source = fs.readFileSync(ANALYSER, 'utf8');
	assert.doesNotMatch(source, /removeprefix|removesuffix|tomllib|\bmatch \w+:\n/);
});

console.log(`\n${checks} field log analyser check(s) passed.`);
