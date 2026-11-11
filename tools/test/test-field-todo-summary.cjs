// tools/test/test-field-todo-summary.cjs

/**
 * ==============================================================================
 * MODULE: Field TODO Summary Tests
 * DESCRIPTION:
 * Pins tools/dev/field-todo-summary.py, which gives every point of TODO.md
 * « To confirm on the Mac » its verdict from one macOS field report:
 * 1. a point takes the worst verdict of its checks, a report step it names
 *    decides a passing step, a missing report step fails, a max bounds a count
 *    or a duration, and a collector step is read from steps.txt;
 * 2. a step absent from the run is not_run with its reason (signed_app needs
 *    --installed), never a pass;
 * 3. a point with no check is not_testable with its reason, in the summary
 *    and in the terminal lines;
 * 4. the coverage table of docs/tooling/macos-field-report-coverage.md is the
 *    one the tool generates (--check-doc).
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const TOOL = path.join(ROOT, 'tools/dev/field-todo-summary.py');
const coverage = JSON.parse(
	fs.readFileSync(
		path.join(ROOT, 'static/ergopti_plus/macos/data/field_todo_coverage.json'),
		'utf8'
	)
);
let checks = 0;

/** Runs one named check. */
function check(name, body) {
	body();
	checks++;
	console.log(`PASS ${name}`);
}

/** Runs the tool; returns its status and output. */
function run(...args) {
	const result = spawnSync('python3', [TOOL, ...args], { encoding: 'utf8' });
	return { status: result.status, stdout: result.stdout, stderr: result.stderr };
}

/**
 * Writes a report folder: field_run/NN_<step>.json per result, steps.txt.
 * @param {object[]} results Step result documents.
 * @param {string} steps The steps.txt text.
 */
function report(results, steps = '') {
	const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'todo-summary-'));
	fs.mkdirSync(path.join(folder, 'field_run'));
	results.forEach((document, index) => {
		const name = `${String(index + 1).padStart(2, '0')}_${document.step}.json`;
		fs.writeFileSync(
			path.join(folder, 'field_run', name),
			JSON.stringify({ schema: 1, ...document })
		);
	});
	fs.writeFileSync(path.join(folder, 'steps.txt'), steps);
	return folder;
}

/** The summary of a report folder, by point id. */
function summarize(folder, ...flags) {
	const result = run('--report', folder, ...flags);
	assert.equal(result.status, 0, result.stderr);
	const summary = JSON.parse(fs.readFileSync(path.join(folder, 'todo_summary.json'), 'utf8'));
	assert(
		fs.readFileSync(path.join(folder, 'todo_summary.md'), 'utf8').includes('| Point | Verdict |')
	);
	return {
		byId: Object.fromEntries(summary.points.map((point) => [point.id, point])),
		stdout: result.stdout
	};
}

const lease = (steps, verdict = 'pass') => ({
	step: 'field_lease',
	verdict,
	codes: [],
	report: { check: 'lease', steps }
});

check('a point takes the worst verdict of its checks and its named report steps', () => {
	const { byId } = summarize(
		report([
			lease(
				[
					{ id: 'lease_failure_kinds', state: 'info', value: 'none' },
					{ id: 'memory_free_percent', state: 'info', value: '41' },
					{ id: 'deploy_write_verdict', state: 'fail', value: 'shrink' }
				],
				'fail'
			),
			{ step: 'driver_reload', verdict: 'pass', codes: ['reloaded'], report: { reload_ms: 4812 } },
			{ step: 'field_composer', verdict: 'pass', codes: [] }
		])
	);
	// The step failed, but on another report step: the named ones decide
	assert.equal(byId.lease_117_140.verdict, 'pass');
	assert.equal(byId.lease_deploy_write.verdict, 'fail');
	assert.match(byId.lease_deploy_write.evidence[0], /deploy_write_verdict=fail:shrink/);
	assert.equal(byId.timed_reload.verdict, 'fail', 'reload_ms over its 4000 ms bound');
	assert.match(byId.timed_reload.evidence[0], /reload_ms=4812>4000/);
	assert.equal(byId.composer_l52.verdict, 'pass');
	// A report step the result does not carry is a failure, never a pass
	assert.equal(byId.l24_key_events.verdict, 'fail');
	assert.match(byId.l24_key_events.evidence[0], /key_losses=missing/);
});

check('a step absent from the run is not_run with its reason', () => {
	const { byId } = summarize(report([]));
	assert.equal(byId.composer_l52.verdict, 'not_run');
	assert.match(byId.composer_l52.evidence[0], /field_composer:absent_from_run/);
	assert.match(byId.owned_install_launcher.evidence[0], /field_owned_install:needs_installed_run/);
	assert.match(byId.ctrl_capslock.evidence[0], /guided_capslock_chord:absent_from_run/);
	const installed = summarize(report([]), '--installed').byId;
	assert.match(installed.owned_install_launcher.evidence[0], /field_owned_install:absent_from_run/);
});

check('guided outcomes and collector steps reach their points', () => {
	const { byId } = summarize(
		report(
			[
				{
					step: 'guided_capslock_chord',
					verdict: 'needs_person',
					codes: ['gesture_not_observed_90s']
				},
				{
					step: 'field_capslock_chord',
					verdict: 'pass',
					codes: [],
					report: {
						steps: [{ id: 'capslock_chord_delivered', state: 'pass', value: 'delivered:1' }]
					}
				},
				{ step: 'guided_input_policies', verdict: 'pass', codes: ['attested_pass'] }
			],
			'scpt_recompile               exit=0\nversions                     exit=0\n'
		)
	);
	assert.equal(byId.ctrl_capslock.verdict, 'needs_person', 'no gesture is never a pass');
	assert.equal(byId.input_policies.verdict, 'pass');
	assert.equal(byId.scpt_recompile.verdict, 'pass');
	assert.match(byId.scpt_recompile.evidence[0], /scpt_recompile:exit_0/);
	const failed = summarize(report([], 'scpt_recompile               exit=3\n')).byId;
	assert.equal(failed.scpt_recompile.verdict, 'fail');
});

check('a point no run can test says why, in the summary and the terminal', () => {
	const untestable = coverage.points.filter((point) => point.checks.length === 0);
	assert(untestable.length > 0);
	const { byId, stdout } = summarize(report([]));
	for (const point of untestable) {
		assert.equal(byId[point.id].verdict, 'not_testable');
		assert.equal(byId[point.id].not_testable, point.not_testable);
		assert(point.not_testable.length > 20, `${point.id} gives no reason`);
		assert.match(stdout, new RegExp(`not_testable +${point.id} +\\(not field-testable: `));
	}
	assert.equal(Object.keys(byId).length, coverage.points.length, 'one record per point');
});

check('a Linux report reads the field run and the collector steps of its own coverage', () => {
	const folder = report([]);
	fs.mkdirSync(path.join(folder, 'field_guided'));
	const guided = (index, step, verdict, codes, steps = []) =>
		fs.writeFileSync(
			path.join(folder, 'field_guided', `${String(index).padStart(2, '0')}_${step}.json`),
			JSON.stringify({ schema: 1, step, verdict, codes, report: { check: step, steps } })
		);
	guided(
		1,
		'linux_input_access',
		'pass',
		['probes_met'],
		[
			{ id: 'uinput_writable', state: 'pass', value: '1' },
			{ id: 'evdev_readable', state: 'pass', value: '9' }
		]
	);
	guided(
		2,
		'linux_autostart',
		'pass',
		['probes_met'],
		[{ id: 'unit_enabled', state: 'pass', value: '0' }]
	);
	guided(
		3,
		'linux_polkit_agent',
		'fail',
		['polkit_agent_1'],
		[{ id: 'polkit_agent', state: 'fail', value: '1' }]
	);
	guided(11, 'linux_physical_hands', 'pass', ['attested_pass']);
	guided(13, 'linux_layout_emulation_kde', 'needs_person', ['no_answer_420s']);
	const result = run('--os', 'linux', '--report', folder);
	assert.equal(result.status, 0, result.stderr);
	const summary = JSON.parse(fs.readFileSync(path.join(folder, 'todo_summary.json'), 'utf8'));
	const byId = Object.fromEntries(summary.points.map((point) => [point.id, point]));
	const linux = JSON.parse(
		fs.readFileSync(
			path.join(ROOT, 'static/ergopti_plus/linux/data/field_todo_coverage.json'),
			'utf8'
		)
	);
	assert.deepEqual(
		Object.keys(byId),
		linux.points.map((point) => point.id)
	);
	assert.equal(byId.physical_acceptance.verdict, 'fail', 'no polkit agent fails the point by name');
	assert.match(byId.physical_acceptance.evidence.join(' '), /polkit_agent=fail:1/);
	assert.equal(byId.layout_emulation_w1_w4.verdict, 'needs_person');
	assert.equal(byId.owned_gtk_host.verdict, 'not_run');
	assert.equal(byId.physical_shortcut_delivery.verdict, 'not_testable');
	assert(
		fs
			.readFileSync(path.join(folder, 'todo_summary.md'), 'utf8')
			.includes('« To confirm on Linux »')
	);
});

check('a count bound reads a minimum as well as a maximum', () => {
	const { byId } = summarize(
		report([
			{
				step: 'field_log_signals',
				verdict: 'pass',
				codes: [],
				report: { steps: [{ id: 'log_boot_completions', state: 'info', value: '2' }] }
			}
		])
	);
	assert.equal(byId.production_profile.verdict, 'fail', 'two boots today are fewer than four');
	assert.match(byId.production_profile.evidence.join(' '), /log_boot_completions=info:2<4/);
});

check('the documentation carries the generated coverage table', () => {
	const result = run('--check-doc');
	assert.equal(result.status, 0, result.stderr);
	const linux = run('--os', 'linux', '--check-doc');
	assert.equal(linux.status, 0, linux.stderr);
	const doc = fs.readFileSync(
		path.join(ROOT, 'docs/tooling/macos-field-report-coverage.md'),
		'utf8'
	);
	for (const point of coverage.points)
		assert(doc.includes(`\`${point.id}\``), `${point.id} is not in the doc`);
});

console.log(`[OK] field TODO summary (${checks} checks).`);
