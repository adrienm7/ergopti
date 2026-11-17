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
	const toml = read('static/ergopti_plus/_shared/core/timing/data/constants.toml');
	const logger = toml.slice(toml.indexOf('\n[logger]'));
	const hotpath = Number(logger.match(/^hotpath_slow_ms = (\d+)/m)[1]);
	assert.equal(described.budgets['hotpath:'], hotpath);
	assert.equal(
		described.budgets['main_thread.hold'],
		Number(
			read('static/ergopti_plus/macos/core/lifecycle/engine/main_thread_hold.lua').match(
				/^\s*COUNT_MS = (\d+)/m
			)[1]
		)
	);
	assert.equal(
		described.budgets['preferences.save'],
		Number(
			read('static/ergopti_plus/macos/settings/engine/preferences/preferences.lua').match(
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
	// The [budgets] section: every key the analyser judges a measure against.
	const section = toml.slice(toml.indexOf('\n[budgets]'));
	const key = (name) => Number(section.match(new RegExp(`^${name} = (\\d+)`, 'm'))[1]);
	for (const [prefix, name] of [
		['boot.total', 'boot_total_ms'],
		['reload.total', 'driver_reload_ms'],
		['reload.request_to_boot', 'driver_reload_ms'],
		['menu.rebuild', 'menu_rebuild_ms'],
		['llm.local:', 'llm_local_request_ms'],
		['llm.remote:', 'llm_remote_request_ms'],
		['llm.ttft', 'prediction_display_ms']
	])
		assert.equal(described.budgets[prefix], key(name), `${prefix} reads [budgets] ${name}`);
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
		copy('static/ergopti_plus/_shared/core/timing/data/constants.toml');
		copy('static/ergopti_plus/macos/core/lifecycle/engine/main_thread_hold.lua');
		copy('static/ergopti_plus/macos/settings/engine/preferences/preferences.lua', (text) =>
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
		`${stamp('09:00:04')} [INFO] [BootProfile] Complete configured menu usable at 1980 ms since process start; input initialization pending=0.`,
		`${stamp('09:10:00')} [ERROR] [Updater] The release list could not be read: HTTP 502.`,
		`${stamp('09:11:00')} [ERROR] [Updater] The release list could not be read: HTTP 504.`,
		`${stamp('09:12:00')} [ERROR] [Keystats] Session reset refused: pending text was not accepted.`,
		`${stamp('09:13:00')} [WARNING] [HotPath] Slow HSE.Dispatch: 7.25 ms own, 7.25 ms total, parent none (0 similar since the last line).`,
		`${stamp('09:14:00')} [WARNING] [HotPath] Slow UIA.SelectionPoll: 41.00 ms own, 41.00 ms total, parent none (0 similar since the last line).`,
		`${stamp('09:15:00')} [INFO] [HotPath] Latency 'Hook.KeyDown': count=400, mean=0.3000 ms, min=0.0500 ms, max=3.2000 ms, slow=0, ge1=1, ge5=0, ge10=0, ge50=0.`,
		`${stamp('09:20:00')} [INFO] [Lifecycle] Reload requested by tray (suspended=0).`,
		'',
		`===== ${stamp('09:20:02')} — ErgoptiPlus session opened =====`,
		`${stamp('09:20:04')} [INFO] [BootProfile] Boot complete in 1900 ms (since process start).`,
		`${stamp('09:25:00')} [INFO] [LLM] LLM request: kind=remote provider=mistral family=mistral-small outcome=ok in 3400 ms.`,
		`${stamp('09:25:00')} [WARNING] [LLM] Over budget: llm.remote took 3400 ms (budget 3000 ms).`,
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
		assert.equal(row('boot.total').verdict, 'within', 'within [budgets] boot_total_ms');
		assert.equal(row('menu.usable').verdict, 'no_budget');
		assert.equal(row('llm.remote:mistral').verdict, 'over');
		assert.equal(row('boot.total').count, 2);
		assert.equal(row('boot.total').p95, 2410);
		assert.equal(
			row('reload.request_to_boot').worst[0].value,
			4000,
			'from the request to the next boot'
		);
		assert.match(markdown, /\| menu\.usable \| 1 \| .* \| no budget declared \|/);
		assert.match(markdown, /\| boot\.total \| 2 \| .*\u2705 within/);
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
			!document.top_fixes.some((item) => /^\[(HotPath|LLM)\]/.test(item.what)),
			'a measure is ranked once, not again through its warning'
		);
		assert(document.top_fixes.some((item) => item.what.startsWith('llm.remote:mistral over')));
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

// The machine facts (tools/dev/field-report-facts.py): the 2026-11-15 macOS
// report could not tell whether a release and a developer app ran at once,
// nor which process spent the 785 ms of idle CPU no timer explained. A report
// folder with the collectors' fact lines, step timings and field run results
// must give env.json, the timeline and the analysis findings that say so.
const FACTS = path.join(ROOT, 'tools/dev/field-report-facts.py');

/** Writes a report folder holding fact lines, step timings and results. */
function factsFolder() {
	const reports = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-facts-'));
	const folder = path.join(reports, 'mac-2026-11-15_235348');
	fs.mkdirSync(path.join(folder, 'field_run'), { recursive: true });
	const fact = (...fields) => ['fact', ...fields].join('\t');
	const instance = (phase, t, role, name, pid, origin, cpu, version) =>
		fact(
			'instance',
			`phase=${phase}`,
			`t=${t}`,
			`role=${role}`,
			`name=${name}`,
			`pid=${pid}`,
			'ppid=1',
			'parent=launchd',
			`started=start-${pid}`,
			`cpu_s=${cpu}`,
			'rss_kb=180000',
			`origin=${origin}`,
			`path=/Applications/${name}`,
			`version=${version}`
		);
	// The idle field check ran from 22:54:48Z to 22:55:18Z (epoch below).
	const start = Date.UTC(2026, 10, 15, 22, 54, 48) / 1000;
	fs.writeFileSync(
		path.join(folder, 'instances_start.txt'),
		[
			'raw evidence a person reads',
			fact('sample', 'phase=start', `t=${start - 100}`),
			instance('start', start - 100, 'driver', 'ErgoptiPlus', 28064, 'release', 10, '1.0.4'),
			instance('start', start - 100, 'engine', 'Hammerspoon', 28072, 'release', 50, '1.0.4'),
			instance('start', start - 100, 'driver', 'ErgoptiPlus', 30001, 'dev', 3, '1.0.5-dev')
		].join('\n') + '\n'
	);
	fs.writeFileSync(
		path.join(folder, 'instances_timeline.txt'),
		[
			fact('sample', 'phase=sample', `t=${start - 2}`),
			instance('sample', start - 2, 'engine', 'Hammerspoon', 28072, 'release', 60.0, ''),
			fact('sample', 'phase=sample', `t=${start + 32}`),
			instance('sample', start + 32, 'engine', 'Hammerspoon', 28072, 'release', 61.7, '')
		].join('\n') + '\n'
	);
	fs.writeFileSync(
		path.join(folder, 'remappers.txt'),
		fact(
			'remapper',
			'name=Karabiner-Elements',
			'running=yes',
			'version=16.0.0',
			'conflict=yes',
			'detail=core_services=2 owned_runtime_processes=3'
		) +
			'\n' +
			fact('remapper', 'name=ibus-daemon', 'running=yes', 'conflict=no', 'detail=input method') +
			'\n'
	);
	fs.writeFileSync(
		path.join(folder, 'permissions.txt'),
		fact('permission', 'name=ListenEvent', 'state=denied', 'subject=com.ergoptiplus.app') + '\n'
	);
	fs.writeFileSync(
		path.join(folder, 'environment.txt'),
		fact('env', 'os_name=macOS', 'os_version=15.1', 'displays=2') + '\n'
	);
	fs.writeFileSync(
		path.join(folder, 'idle_cpu.txt'),
		fact(
			'cpu',
			'window=idle',
			'name=Hammerspoon',
			'pid=28072',
			'cpu_ms=900',
			'window_ms=20000',
			'percent=4.5'
		) + '\n'
	);
	fs.writeFileSync(
		path.join(folder, 'step_times.tsv'),
		'name\tkind\tstart\tend\tstatus\tbudget\n' +
			`versions\tcollector\t${start - 200}\t${start - 199}\t0\t30\n` +
			`unified_log\tcollector\t${start + 100}\t${start + 280}\t143\t180\n` +
			`field_run\tphase\t${start - 50}\t${start + 600}\t0\t21430\n`
	);
	fs.writeFileSync(
		path.join(folder, 'field_run', '11_field_idle_cost.json'),
		JSON.stringify({
			step: 'field_idle_cost',
			verdict: 'fail',
			started_at: '2026-11-15T22:54:48Z',
			finished_at: '2026-11-15T22:55:18Z',
			elapsed_ms: 30029,
			deadline_ms: 45000
		})
	);
	fs.writeFileSync(
		path.join(folder, 'field_run', '27_ollama_runtime.json'),
		JSON.stringify({
			step: 'ollama_runtime',
			verdict: 'timeout',
			started_at: '2026-11-15T22:56:00Z',
			finished_at: '2026-11-15T23:01:00Z',
			elapsed_ms: 300000,
			deadline_ms: 240000
		})
	);
	return { reports, folder };
}

check(
	'the facts give env.json: two drivers at once, the remappers, the idle window per process',
	() => {
		const { reports, folder } = factsFolder();
		try {
			const built = spawnSync(python, [FACTS, 'build', folder, '--os', 'mac'], {
				encoding: 'utf8'
			});
			assert.equal(built.status, 0, built.stderr);
			assert.match(built.stdout, /Facts: 2 driver instance\(s\) at most at once/);
			const env = JSON.parse(fs.readFileSync(path.join(folder, 'env.json'), 'utf8'));
			assert.equal(env.instances.max_drivers, 2, 'the release and the developer launcher');
			assert.deepEqual(env.instances.overlapping_drivers.map((row) => row.origin).sort(), [
				'dev',
				'release'
			]);
			assert.equal(env.instances.driver_restarts, 0, 'an engine-only sample is no restart');
			assert.equal(env.environment.displays, '2');
			assert.equal(env.remappers.length, 2);
			// 1.7 s of CPU between the samples around the 30 s idle window (34 s apart).
			const engine = env.idle_window_cpu.processes.find((row) => row.pid === '28072');
			assert.equal(engine.cpu_ms, 1700);
			assert.equal(engine.percent, 5);
			const timeline = fs.readFileSync(path.join(folder, 'timeline.txt'), 'utf8');
			assert.match(timeline, /^## Slowest steps$/m);
			assert.match(timeline, /^ 1\. +650\.0 s {2}\[phase\] field_run/m, 'the slowest first');
			assert.match(timeline, /^- \[collector\] unified_log: 180\.0 s \(budget 180 s\)$/m);
			assert.match(timeline, /^- \[field_run\] ollama_runtime: 300\.0 s \(budget 240 s\)$/m);
			assert.match(timeline, /^## Chronological$/m);
			const json = JSON.parse(fs.readFileSync(path.join(folder, 'timeline.json'), 'utf8'));
			assert.equal(json.over_budget.length, 2);
		} finally {
			fs.rmSync(reports, { recursive: true, force: true });
		}
	}
);

check(
	'the analysis ranks two drivers first, then the remapper, the permission and the idle CPU',
	() => {
		const { reports, folder } = factsFolder();
		try {
			assert.equal(
				spawnSync(python, [FACTS, 'build', folder, '--os', 'mac'], { encoding: 'utf8' }).status,
				0
			);
			const result = analyse(['--repo', ROOT, '--out', folder]);
			assert.equal(result.status, 0, result.stderr);
			const document = JSON.parse(fs.readFileSync(path.join(folder, 'analysis.json'), 'utf8'));
			const kinds = document.top_fixes.map((item) => item.kind);
			assert.equal(kinds[0], 'multiple_drivers');
			assert.equal(kinds[1], 'foreign_remapper');
			assert.equal(kinds[2], 'permission');
			assert(kinds.includes('idle_cpu'), kinds.join(','));
			assert(kinds.includes('slow_step'), kinds.join(','));
			assert.equal(
				document.top_fixes.filter((item) => item.kind === 'foreign_remapper').length,
				1,
				'an input method is not a conflicting remapper'
			);
			assert.match(
				document.top_fixes[1].what,
				/another remapper is active: Karabiner-Elements 16\.0\.0/
			);
			const idle = document.top_fixes.filter((item) => item.kind === 'idle_cpu');
			assert(
				idle.some((item) => /field_idle_cost window/.test(item.what)),
				'the field run window'
			);
			assert(
				idle.some((item) => /idle window/.test(item.what)),
				"the collector's quiet window"
			);
			assert.match(idle[0].detail, /field_check_session\.lua/, 'the declared idle budget');
			const markdown = fs.readFileSync(path.join(folder, 'analysis.md'), 'utf8');
			assert.match(markdown, /^## Machine and instances$/m);
			assert.match(markdown, /^## Slowest steps$/m);
			assert.match(markdown, /Ergopti drivers at most at once: 2 \(start phase\)/);
			assert.match(markdown, /No DEBUG record in the logs/);
			assert.match(result.stdout, /!! multiple_drivers: 2 Ergopti drivers ran at once/);
		} finally {
			fs.rmSync(reports, { recursive: true, force: true });
		}
	}
);

check(
	'the Karabiner and keyboard summaries publish counts and ids, never names, commands or serials',
	() => {
		const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-karabiner-'));
		try {
			const config = path.join(dir, 'karabiner.json');
			fs.writeFileSync(
				config,
				JSON.stringify({
					profiles: [
						{
							name: 'SECRETPROFILE',
							selected: true,
							simple_modifications: [{ from: {}, to: [] }],
							complex_modifications: {
								rules: [
									{
										description: 'SECRETRULE',
										manipulators: [{ to: [{ shell_command: 'echo SECRETCMD' }] }]
									}
								]
							},
							devices: [
								{
									identifiers: { vendor_id: 1452, product_id: 832, is_keyboard: true },
									ignore: true
								}
							]
						}
					]
				})
			);
			const devices = path.join(dir, 'devices.json');
			fs.writeFileSync(
				devices,
				JSON.stringify([
					{
						product: 'Apple Internal Keyboard',
						is_built_in_keyboard: true,
						device_identifiers: {
							vendor_id: 1452,
							product_id: 832,
							is_keyboard: true,
							device_address: 'aa-bb-cc-dd-ee-ff'
						}
					},
					{
						product: 'Ergo Board',
						device_identifiers: { vendor_id: 7, product_id: 9, is_keyboard: true }
					}
				])
			);
			const summary = spawnSync(python, [FACTS, 'karabiner', config, devices], {
				encoding: 'utf8'
			});
			assert.equal(summary.status, 0, summary.stderr);
			assert.doesNotMatch(summary.stdout, /SECRET|aa-bb-cc/);
			assert.match(summary.stdout, /complex_rules=1 manipulators=1 shell_commands=1/);
			assert.match(summary.stdout, /name=Apple Internal Keyboard\t.*\tgrabbed=no$/m);
			assert.match(summary.stdout, /name=Ergo Board\t.*\tgrabbed=yes$/m);
			const plist = path.join(dir, 'hid.plist');
			fs.writeFileSync(
				plist,
				'<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><array><dict>' +
					'<key>PrimaryUsagePage</key><integer>1</integer><key>PrimaryUsage</key><integer>6</integer>' +
					'<key>Product</key><string>Ergo Board</string><key>SerialNumber</key><string>SERIALCANARY</string>' +
					'<key>VendorID</key><integer>7</integer><key>Built-In</key><false/>' +
					'</dict></array></plist>'
			);
			const hid = spawnSync(python, [FACTS, 'hid', plist], { encoding: 'utf8' });
			assert.equal(hid.status, 0, hid.stderr);
			assert.doesNotMatch(hid.stdout, /SERIALCANARY/);
			assert.match(hid.stdout, /^fact\tdevice\tsource=ioreg\tname=Ergo Board\t/m);
			assert.match(hid.stdout, /^fact\tenv\tkeyboards=1$/m);
		} finally {
			fs.rmSync(dir, { recursive: true, force: true });
		}
	}
);

check('the facts builder is Python 3.8 syntax with the standard library only', () => {
	const probe = spawnSync(
		python,
		[
			'-c',
			'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read(), feature_version=(3, 8))',
			FACTS
		],
		{ encoding: 'utf8' }
	);
	assert.equal(probe.status, 0, probe.stderr);
});

console.log(`\n${checks} field log analyser check(s) passed.`);
