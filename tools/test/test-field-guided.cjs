// tools/test/test-field-guided.cjs

/**
 * ==============================================================================
 * MODULE: Field Guided Steps Tests (collector side)
 * DESCRIPTION:
 * Pins tools/dev/field-guided.py, the collector-side probe and guided steps of
 * a field report (the Linux collector runs
 * static/ergopti_plus/linux/diagnostics/data/field_guided_steps.json):
 * 1. a probe step passes when each probe meets its expectation and fails by
 *    name otherwise (a missing command, a node not writable);
 * 2. an observed step passes once each counted log line or Metrics row rose
 *    during the gesture, and fails when a count meant to stay steady rose;
 * 3. no gesture, no answer or a source that never became readable is never a
 *    pass: needs_person with its bound, or fail with the source named;
 * 4. results have the field run's result shape, and the shipped Linux
 *    declaration validates.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const TOOL = path.join(ROOT, 'tools/dev/field-guided.py');
const LINUX_STEPS = path.join(
	ROOT,
	'static/ergopti_plus/linux/diagnostics/data/field_guided_steps.json'
);
let checks = 0;

/** Runs one named check. */
async function check(name, body) {
	await body();
	checks++;
	console.log(`PASS ${name}`);
}

/** A scratch folder with a declaration of the given steps. */
function scratch(steps) {
	const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'field-guided-'));
	const declaration = path.join(folder, 'steps.json');
	fs.writeFileSync(declaration, JSON.stringify({ schema: 1, poll_seconds: 1, steps }));
	return {
		folder,
		declaration,
		log: path.join(folder, 'day.log'),
		metrics: path.join(folder, 'm.sqlite')
	};
}

/**
 * Runs the tool; `during` runs once it started, while its steps wait.
 * @returns {Promise<{status: number, stdout: string, stderr: string}>}
 */
function run(paths, seconds, during) {
	return new Promise((resolve) => {
		const child = spawn(
			'python3',
			[
				TOOL,
				'--steps',
				paths.declaration,
				'--out',
				paths.folder,
				'--log',
				paths.log,
				'--metrics',
				paths.metrics
			],
			{
				env: { ...process.env, FIELD_GUIDED_SECONDS_OVERRIDE: String(seconds) },
				stdio: ['ignore', 'pipe', 'pipe']
			}
		);
		let stdout = '';
		let stderr = '';
		child.stdout.on('data', (chunk) => (stdout += chunk));
		child.stderr.on('data', (chunk) => (stderr += chunk));
		if (during) setTimeout(during, 1500);
		child.on('close', (status) => resolve({ status, stdout, stderr }));
	});
}

/** The result a step wrote. */
function result(paths, index, id) {
	const name = `${String(index).padStart(2, '0')}_${id}.json`;
	return JSON.parse(fs.readFileSync(path.join(paths.folder, 'field_guided', name), 'utf8'));
}

/** Runs SQL on the scratch Metrics database with Python's sqlite3. */
function sql(paths, statement) {
	const done = spawnSync('python3', [
		'-c',
		'import sqlite3,sys\nc=sqlite3.connect(sys.argv[1]);c.executescript(sys.argv[2]);c.commit()',
		paths.metrics,
		statement
	]);
	assert.equal(done.status, 0, String(done.stderr));
}

const network = (id, kind) => ({
	id,
	kind: 'sqlite_count',
	table: 'events_network',
	row_kind: kind
});

(async () => {
	await check(
		'a probe step passes on met expectations and fails each unmet one by name',
		async () => {
			const paths = scratch([
				{
					id: 'probe_ok',
					mode: 'probe',
					proves: 'Everything is there.',
					probes: [
						{ id: 'node_writable', kind: 'path_access', glob: '__FILE__', access: 'write' },
						{ id: 'true_exits_zero', kind: 'command_exit', argv: ['true'], expect: 'zero' }
					]
				},
				{
					id: 'probe_bad',
					mode: 'probe',
					proves: 'Nothing is there.',
					probes: [
						{ id: 'absent_node', kind: 'path_access', glob: '/nonexistent/node*', access: 'read' },
						{
							id: 'no_such_tool',
							kind: 'command_exit',
							argv: ['ergopti-no-such-tool'],
							expect: 'zero'
						},
						{ id: 'false_exits_zero', kind: 'command_exit', argv: ['false'], expect: 'zero' }
					]
				}
			]);
			const text = fs
				.readFileSync(paths.declaration, 'utf8')
				.replace('__FILE__', paths.declaration);
			fs.writeFileSync(paths.declaration, text);
			const outcome = await run(paths, 1);
			assert.equal(outcome.status, 0, outcome.stderr);
			const ok = result(paths, 1, 'probe_ok');
			assert.equal(ok.verdict, 'pass');
			assert.equal(ok.kind, 'probe');
			assert.deepEqual(
				ok.report.steps.map((step) => step.state),
				['pass', 'pass']
			);
			const bad = result(paths, 2, 'probe_bad');
			assert.equal(bad.verdict, 'fail');
			assert.deepEqual(bad.codes, [
				'absent_node_0',
				'no_such_tool_command_missing',
				'false_exits_zero_1'
			]);
		}
	);

	await check(
		'an observed step passes once its log count rose, and needs a person otherwise',
		async () => {
			const paths = scratch([
				{
					id: 'cancel_seen',
					mode: 'observe',
					gesture: 'Move the mouse.',
					gesture_seconds: 60,
					proves: 'The pointer cancels.',
					probes: [
						{ id: 'cancels', kind: 'log_count', pattern: 'User activity \\(pointer [a-z_]+\\)' }
					]
				}
			]);
			fs.writeFileSync(
				paths.log,
				'10:00 [DEBUG] [llm] User activity (pointer motion) — pending prediction cancelled.\n'
			);
			const seen = await run(paths, 6, () =>
				fs.appendFileSync(
					paths.log,
					'10:01 [DEBUG] [llm] User activity (pointer wheel) — pending prediction cancelled.\n'
				)
			);
			assert.equal(seen.status, 0, seen.stderr);
			assert.match(seen.stdout, /👉 GUIDED cancel_seen \(up to 6 s\): Move the mouse\./);
			const observed = result(paths, 1, 'cancel_seen');
			assert.equal(observed.verdict, 'pass');
			assert.deepEqual(observed.codes, ['gesture_observed']);
			assert.equal(observed.report.steps[0].value, '2', 'a count, never the line');
			const quiet = await run(paths, 2);
			assert.equal(quiet.status, 0);
			const missed = result(paths, 1, 'cancel_seen');
			assert.equal(missed.verdict, 'needs_person');
			assert.deepEqual(missed.codes, ['gesture_not_observed_2s']);
		}
	);

	await check(
		'a Metrics count that rose passes, and a steady count that rose fails it',
		async () => {
			const steps = [
				{
					id: 'network_toggle',
					mode: 'observe',
					gesture: 'Unplug and plug back.',
					gesture_seconds: 60,
					proves: 'The network rows fill.',
					probes: [network('down', 'internet_down'), network('up', 'internet_up')],
					steady: [network('vpn', 'vpn_connected')]
				}
			];
			const paths = scratch(steps);
			sql(
				paths,
				'CREATE TABLE events_network (device_id TEXT, id INTEGER, ts TEXT, date TEXT, kind TEXT, app TEXT, meta_json TEXT);'
			);
			const insert = (id, kind) =>
				`INSERT INTO events_network VALUES ('d', ${id}, 't', 'd', '${kind}', 'a', NULL);`;
			const clean = await run(paths, 6, () =>
				sql(paths, insert(1, 'internet_down') + insert(2, 'internet_up'))
			);
			assert.equal(clean.status, 0, clean.stderr);
			assert.equal(result(paths, 1, 'network_toggle').verdict, 'pass');
			const tunnel = await run(paths, 6, () =>
				sql(
					paths,
					insert(3, 'internet_down') + insert(4, 'internet_up') + insert(5, 'vpn_connected')
				)
			);
			assert.equal(tunnel.status, 0);
			const failed = result(paths, 1, 'network_toggle');
			assert.equal(failed.verdict, 'fail');
			assert.deepEqual(failed.codes, ['gesture_observed', 'rose_vpn']);
		}
	);

	await check('no database, no answer: named, never a pass', async () => {
		const paths = scratch([
			{
				id: 'topology',
				mode: 'observe',
				gesture: 'Move a window.',
				gesture_seconds: 60,
				proves: 'The rows fill.',
				probes: [
					{
						id: 'moves',
						kind: 'sqlite_count',
						table: 'events_window_topo',
						row_kind: 'window_move'
					}
				]
			},
			{
				id: 'menus',
				mode: 'attest',
				gesture: 'Look at the menu.',
				gesture_seconds: 60,
				proves: 'It looks right.'
			}
		]);
		const outcome = await run(paths, 1);
		assert.equal(outcome.status, 0);
		const topology = result(paths, 1, 'topology');
		assert.equal(topology.verdict, 'fail');
		assert.deepEqual(topology.codes, ['moves_no_metrics_database']);
		const menus = result(paths, 2, 'menus');
		assert.equal(menus.verdict, 'needs_person', 'no terminal here: nobody answered');
		assert.deepEqual(menus.codes, ['no_answer_1s']);
		assert.match(outcome.stdout, /type y \(it worked\), n \(it did not\) or s \(skip\)/);
	});

	await check('the declaration is validated, and the shipped Linux one is valid', async () => {
		const refuse = async (steps, pattern) => {
			const paths = scratch(steps);
			const outcome = await run(paths, 1);
			assert.notEqual(outcome.status, 0);
			assert.match(outcome.stderr, pattern);
		};
		await refuse([{ id: 'x', mode: 'ask', proves: 'X.' }], /unknown mode/);
		await refuse(
			[{ id: 'x', mode: 'observe', proves: 'X.', gesture: 'Do.', gesture_seconds: 60 }],
			/at least one probe/
		);
		await refuse(
			[
				{
					id: 'x',
					mode: 'probe',
					proves: 'X.',
					probes: [{ id: 'p', kind: 'command_exit', argv: ['true'], pattern: 'y' }]
				}
			],
			/carries a pattern/
		);
		await refuse(
			[
				{
					id: 'x',
					mode: 'probe',
					proves: 'X.',
					probes: [{ id: 'p', kind: 'sqlite_count', table: 'a; DROP', row_kind: 'k' }]
				}
			],
			/not a plain name/
		);
		await refuse(
			[{ id: 'x', mode: 'attest', proves: 'X.', gesture: 'Do.', gesture_seconds: 2 }],
			/at least 10/
		);
		const valid = spawnSync('python3', [
			'-c',
			'import importlib.util,json,sys\ns=importlib.util.spec_from_file_location("g",sys.argv[1])\nm=importlib.util.module_from_spec(s)\ns.loader.exec_module(m)\nm.validate(json.load(open(sys.argv[2])))',
			TOOL,
			LINUX_STEPS
		]);
		assert.equal(valid.status, 0, String(valid.stderr));
	});

	console.log(`[OK] field guided steps (${checks} checks).`);
})().catch((error) => {
	console.error(error);
	process.exit(1);
});
