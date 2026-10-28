// tools/test/test-linux-runner-private-output.cjs

/**
 * ==============================================================================
 * MODULE: Linux Private Runner Output Regression
 * DESCRIPTION:
 * Executes the canonical Linux continuation case and the unchanged reporter CLI.
 * An intentional inner failure belongs to its private fixture; a genuine outer
 * module-load failure must still produce a failing process and public report.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

assert.equal(process.platform, 'linux', 'This regression executes the actual Linux runner.');
const ROOT = path.resolve(__dirname, '../..');
const DRIVER = path.join(ROOT, 'static/ergopti_plus/linux');
const REPORTER = path.join(ROOT, 'tools/test/report.cjs');
const ENTRY = path.join(ROOT, 'static/ergopti_plus/linux/tests/run.lua');
const CONTINUATION = 'linux-unit-module-continuation';
const PRIVATE_FAILURE = 'controlled earlier unit failure';
const workspace = fs.mkdtempSync(
	path.join(fs.realpathSync(os.tmpdir()), 'ergopti-private-runner-')
);
fs.chmodSync(workspace, 0o700);
const env = { ...process.env };
for (const key of Object.keys(env))
	if (/^LUA_(?:INIT|PATH|CPATH)(?:_|$)/.test(key)) delete env[key];
for (const [key, leaf] of [
	['HOME', 'home'],
	['XDG_CONFIG_HOME', 'config'],
	['XDG_DATA_HOME', 'data'],
	['XDG_STATE_HOME', 'state'],
	['XDG_CACHE_HOME', 'cache'],
	['XDG_RUNTIME_DIR', 'runtime'],
	['TMPDIR', 'tmp']
]) {
	const directory = path.join(workspace, leaf);
	fs.mkdirSync(directory, { mode: 0o700 });
	env[key] = directory;
}
const summary = path.join(workspace, 'report-summary.md');
fs.writeFileSync(summary, '', { flag: 'wx', mode: 0o600 });
env.GITHUB_ACTIONS = 'true';
env.GITHUB_STEP_SUMMARY = summary;
const observations = [];

/** Complete process waits precede reading either private stream. */
function execute(label, program, args, cwd = ROOT) {
	const result = spawnSync(program, args, { cwd, env });
	assert.ifError(result.error);
	assert.equal(result.signal, null, label + ' must finish without a termination signal');
	assert.ok(Buffer.isBuffer(result.stdout) && Buffer.isBuffer(result.stderr));
	const transcript = path.join(workspace, label + '.log');
	fs.writeFileSync(transcript, Buffer.concat([result.stdout, result.stderr]), {
		flag: 'wx',
		mode: 0o600
	});
	observations.push({ label, program, args, cwd, status: result.status, transcript });
	fs.writeFileSync(
		path.join(workspace, 'observations.json'),
		JSON.stringify(observations, null, 2) + '\n',
		{ mode: 0o600 }
	);
	return { ...result, transcript };
}

/** Uses the actual PARSE_FILE route, including its process verdict and JSON. */
function report(label, child) {
	const receipt = path.join(workspace, label + '.json');
	const result = execute(label, process.execPath, [
		REPORTER,
		'--name',
		label,
		'--json',
		receipt,
		'--',
		'PARSE_FILE',
		child.transcript
	]);
	return { ...result, receipt: JSON.parse(fs.readFileSync(receipt, 'utf8')) };
}

const provider = execute('generic-lua-provider', 'lua', [
	'-e',
	'assert(_VERSION == "Lua 5.4" and jit == nil); assert(require("luv").os_uname().sysname == "Linux"); print(_VERSION)'
]);
assert.equal(
	provider.status,
	0,
	'The common Linux host requires its actual generic Lua 5.4/libuv provider.'
);
const success = execute('canonical-continuation', 'lua', [ENTRY, '--only', CONTINUATION], DRIVER);
assert.equal(success.status, 0, 'The canonical continuation case itself must pass.');
const accepted = report('private-continuation-report', success);
assert.equal(
	accepted.status,
	0,
	'A passing canonical case cannot leak its deliberate private failure: ' +
		JSON.stringify(accepted.receipt.failures)
);
assert.equal(accepted.receipt.passed, 1);
assert.equal(accepted.receipt.failed, 0);
assert.deepEqual(accepted.receipt.failures, []);
assert.deepEqual(accepted.receipt.timing_errors, []);
assert.ok(!fs.readFileSync(success.transcript, 'utf8').includes(PRIVATE_FAILURE));
console.log(
	'PASS canonical continuation retains one outer pass and a clean actual reporter verdict'
);

const refused = path.join(workspace, 'refused-pair-module.lua');
fs.writeFileSync(
	refused,
	[
		'local native_require, canonical_helpers = require, nil',
		'require = function(name)',
		'  if name == "tests.unit.infra.scope.test_global_shortcuts_pair_scope"',
		'    and canonical_helpers and package.loaded["tests.helpers"] ~= canonical_helpers then',
		'    error("controlled pair module load refusal", 0)',
		'  end',
		'  local value = native_require(name)',
		'  if name == "tests.helpers" and canonical_helpers == nil then canonical_helpers = value end',
		'  return value',
		'end',
		'local entry = table.remove(arg, 1)',
		'arg[0] = entry',
		'dofile(entry)',
		''
	].join('\n'),
	{ flag: 'wx', mode: 0o600 }
);
const failure = execute(
	'canonical-outer-failure',
	'lua',
	[refused, ENTRY, '--only', CONTINUATION],
	DRIVER
);
assert.equal(failure.status, 1, 'A genuine outer module-load failure must remain fatal.');
const rejected = report('genuine-outer-failure-report', failure);
assert.equal(rejected.status, 1);
assert.equal(rejected.receipt.passed, 0);
assert.equal(rejected.receipt.failed, 1);
assert.equal(rejected.receipt.failures.length, 1);
assert.ok(rejected.receipt.failures[0].includes(CONTINUATION));
assert.ok(!rejected.receipt.failures[0].includes(PRIVATE_FAILURE));
assert.ok(
	fs.readFileSync(failure.transcript, 'utf8').includes('controlled pair module load refusal')
);
console.log(
	'PASS genuine outer failure remains visible and fatal to the canonical runner and reporter'
);

const restoration = execute(
	'canonical-capture-restoration',
	'lua',
	[ENTRY, '--only', 'linux-private-runner-restoration'],
	DRIVER
);
assert.equal(restoration.status, 0);
const restored = report('capture-restoration-report', restoration);
assert.equal(restored.status, 0);
assert.equal(restored.receipt.passed, 1);
assert.equal(restored.receipt.failed, 0);
assert.deepEqual(restored.receipt.failures, []);
console.log('PASS a private actor error restores the exact output, exit and module owners');
assert.equal(observations.length, 7, 'Every real provider, child and reporter route must execute.');
const privateSummary = fs.readFileSync(summary, 'utf8');
for (const label of [
	'private-continuation-report',
	'genuine-outer-failure-report',
	'capture-restoration-report'
])
	assert.ok(
		privateSummary.includes('### ' + label),
		'Every reporter writes only its owned summary.'
	);
// Every owner has exited and every receipt was read; failed runs keep their evidence.
fs.rmSync(workspace, { recursive: true });
console.log('PASS Linux private runner output: 3 actual controls; 0 failed; 0 skipped.');
