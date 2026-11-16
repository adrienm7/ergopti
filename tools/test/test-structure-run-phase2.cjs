// tools/test/test-structure-run-phase2.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Step Runner Contract
 * DESCRIPTION:
 * run-phase2.cjs applies the steps of the structure plan in order, one commit
 * per step. The first real application of S01 stopped on gates no rewrite can
 * satisfy: the formatter, the banner widths a longer path changes, the
 * generated outputs and the folder-bounds ratchet. The runner owns those
 * follow-ups, so the day of phase 2 is one command. This pins its refusals
 * (no go, a dirty tree) and its arguments without moving anything.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const Runner = require('../audit/structure/run-phase2.cjs');

const RUNNER = path.join(__dirname, '..', 'audit', 'structure', 'run-phase2.cjs');

function run() {
	assert.deepEqual(
		Runner.parseArgs(['--from', '_shared', '--to', 'core/ui', '--gate', 'npm test']),
		{
			gates: ['npm test'],
			from: '_shared',
			to: 'core/ui',
			receipt: null,
			commit: true
		}
	);
	assert.equal(Runner.parseArgs(['--no-commit']).commit, false);
	assert.throws(() => Runner.parseArgs(['--fast']), /unknown argument --fast/);

	// Without the coordinator's go, nothing runs.
	const env = { ...process.env };
	delete env.ERGOPTI_STRUCTURE_PHASE;
	const refused = spawnSync(process.execPath, [RUNNER, '--no-commit'], { encoding: 'utf8', env });
	assert.notEqual(refused.status, 0, 'the runner refuses without ERGOPTI_STRUCTURE_PHASE=2');
	assert.match(refused.stderr, /ERGOPTI_STRUCTURE_PHASE=2/);

	// Only the runner may raise a folder bound, and only by naming the rise.
	const bounds = spawnSync(
		process.execPath,
		[path.join(__dirname, 'test-structure-folder-bounds.cjs'), '--update-baseline', '--allow-rise'],
		{ encoding: 'utf8', env }
	);
	assert.notEqual(bounds.status, 0, 'a bound rises only under ERGOPTI_STRUCTURE_PHASE=2');
	assert.match(bounds.stderr, /for the structure phase 2 runner only/);

	// The follow-ups a step needs and no path rewrite can do, in order.
	// The derived pins are recorded by the tree before the step applies.
	const order = [
		"'--derive-out'",
		"'--apply'",
		'--fix-banners',
		"'--write'",
		"'--derived-before'",
		'settleCodegen(key',
		"'--allow-rise'",
		"'--fail-on-violations'"
	];
	const source = require('node:fs').readFileSync(RUNNER, 'utf8');
	let at = 0;
	for (const marker of order) {
		const next = source.indexOf(marker, at);
		assert.ok(next > at, `the runner runs ${marker} after the previous follow-up`);
		at = next;
	}
	// A generator the step broke fails on the staged tree too, and stops the
	// step: the first S01 apply committed with the Linux bundle unbuildable.
	const settle = (statuses, changes = [[], []]) => {
		const receipt = { actions: [] };
		const runs = [...statuses];
		const lists = [...changes];
		const staged = [];
		Runner.settleCodegen('S', receipt, {
			codegen: () => ({ status: runs.shift(), tail: 'build:linux failed' }),
			unstaged: () => ({ changed: lists.shift() || [], added: [] }),
			stage: (paths) => staged.push(...paths)
		});
		return { receipt, staged };
	};
	assert.throws(() => settle([1, 1]), /S: codegen does not settle:\nbuild:linux failed/);
	// Drift against HEAD alone settles once the regenerated files are staged.
	const settled = settle([1, 0], [['a/_generated/x.lua'], []]);
	assert.deepEqual(settled.staged, ['a/_generated/x.lua']);
	assert.deepEqual(
		settled.receipt.actions.map((a) => a.label),
		['codegen', 'codegen (after staging)']
	);
	assert.equal(settle([0]).receipt.actions.length, 1, 'a clean run is not repeated');
	// On Windows the Linux bundle never builds (its native output needs Linux):
	// a run that stops at the step the tree before the step stopped at counts
	// for the steps before it, and any other stop still fails the step.
	const aborted = (name) => `x\n  Pipeline aborted after failed step: ${name}\n`;
	assert.equal(Runner.abortedPipelineStep(aborted('build:linux — b')), 'build:linux — b');
	assert.equal(Runner.abortedPipelineStep('Total: 3 step(s)'), null);
	const hostRun = (output) => {
		const receipt = { actions: [] };
		Runner.settleCodegen('S', receipt, {
			codegen: () => ({ status: 1, tail: 'stopped', output }),
			unstaged: () => ({ changed: [], added: [] }),
			stage: () => {},
			hostAborted: 'build:linux — b'
		});
		return receipt;
	};
	assert.equal(hostRun(aborted('build:linux — b')).actions.length, 1);
	assert.throws(() => hostRun(aborted('build:menu — m')), /S: codegen does not settle/);
	assert.throws(() => hostRun('crashed'), /S: codegen does not settle/);
	assert.ok(source.indexOf('baseCodegenAborted =') < source.indexOf("'--apply'"));
	// Every leaf generator runs too: npm run codegen alone left the layer editor
	// and unicode case outputs to regenerate later with old paths. A generator
	// the host already refuses is reported; one the step broke stops it.
	const genOutput = '  \x1b[31mFAILED\x1b[0m  codegen/a.cjs\n  ok  codegen/b.cjs\n';
	assert.deepEqual(Runner.failedGenerators(genOutput), ['codegen/a.cjs']);
	const gen =
		(output, status = 1) =>
		() => ({ status, tail: '', output });
	Runner.runGenerators('S', { actions: [] }, ['codegen/a.cjs'], { gen: gen(genOutput) });
	assert.throws(
		() => Runner.runGenerators('S', { actions: [] }, [], { gen: gen(genOutput) }),
		/S: the step broke generator\(s\) codegen\/a\.cjs/
	);
	assert.throws(
		() => Runner.runGenerators('S', { actions: [] }, [], { gen: gen('crashed') }),
		/S: npm run gen failed/
	);
	assert.ok(source.indexOf('runGenerators(key') < source.indexOf('settleCodegen(key'));
	// The first S21 run on Windows stopped at once: git status and git add were
	// handed 2,700 paths, past the 32,767 characters a Windows command line
	// holds (spawnSync ENAMETOOLONG), and npm, a .cmd shim there, never started
	// without a shell. Paths go to Git in batches; npm gets a shell on Windows.
	const { pathBatches } = require('../audit/structure/apply-step.cjs');
	const many = Array.from({ length: 2700 }, (_, i) => `static/ergopti_plus/linux/tests/x/${i}.lua`);
	const batches = pathBatches(many);
	assert.ok(batches.length > 1, 'a step of thousands of paths is split');
	assert.deepEqual(batches.flat(), many, 'every path is kept, in order');
	for (const b of batches) assert.ok(b.join(' ').length < 32767 / 2);
	assert.deepEqual(pathBatches([]), []);
	assert.equal(Runner.needsShell('npm', 'win32'), true);
	assert.equal(Runner.needsShell('npm', 'linux'), false);
	assert.equal(Runner.needsShell(process.execPath, 'win32'), false);
	assert.doesNotMatch(
		source,
		/git\('add', '--', \.\.\.(?!batch\))/,
		'the runner stages in batches'
	);
	const applySource = require('node:fs').readFileSync(
		path.join(__dirname, '..', 'audit', 'structure', 'apply-step.cjs'),
		'utf8'
	);
	assert.doesNotMatch(
		applySource,
		/git\(\s*'(?:add|status)',[^)]*'--'/,
		'apply-step lists paths in batches'
	);
	// S33 empties windows/adapters: gates that found a driver by its adapters/
	// folder saw two drivers. A driver is found by its _generated tree.
	const { driverNames } = require('../lib/driver-roots.cjs');
	const os = require('node:os');
	const fsx = require('node:fs');
	const drivers = fsx.mkdtempSync(path.join(os.tmpdir(), 'ergopti-drivers-'));
	for (const dir of ['windows/_generated', '_shared/_generated', 'docs', 'old/adapters'])
		fsx.mkdirSync(path.join(drivers, dir), { recursive: true });
	assert.deepEqual(driverNames(drivers), ['windows']);
	fsx.rmSync(drivers, { recursive: true, force: true });
	// S02 grew the union of driver directories past I1's record: the runner
	// moves that ratchet with the step, named in the commit like the bounds.
	assert.match(
		source,
		/'tools\/test\/test-driver-tree-parity\.cjs', '--update-baseline', '--allow-rise'/
	);
	const parityRefusal = spawnSync(
		process.execPath,
		[path.join(__dirname, 'test-driver-tree-parity.cjs'), '--update-baseline'],
		{ encoding: 'utf8', env: { ...process.env, ERGOPTI_STRUCTURE_PHASE: '' } }
	);
	assert.equal(parityRefusal.status, 1, 'outside the runner, I1 records are never moved');
	// S05 brought both drivers' i18n scope_ready to one spelling, a duplicate
	// the shared literal inventory (Rule A) then counted: the runner moves that
	// baseline with the step too, and the gate allows it only under the runner.
	assert.match(
		source,
		/'tools\/test\/test-shared-literal-inventory\.cjs', '--update-baseline', '--allow-rise'/
	);
	const inventoryGate = fsx.readFileSync(
		path.join(__dirname, 'test-shared-literal-inventory.cjs'),
		'utf8'
	);
	assert.match(inventoryGate, /process\.env\.ERGOPTI_STRUCTURE_PHASE === '2'/);
	// On a tree S01 already rearranged, the next step is still S02: its commit
	// named it S01, its rank among the steps left.
	const Plan = require('../audit/structure/plan.cjs');
	const tsv = 'old\tnew\tstep\nstatic/ergopti_plus/a/x.lua\tstatic/ergopti_plus/b/x.lua\tS01\n';
	const done = Plan.committedSteps(
		`${tsv}static/ergopti_plus/core/crypto/y.lua\tstatic/ergopti_plus/core/crypto/z/y.lua\tS02\n`,
		(f) => f === 'static/ergopti_plus/b/x.lua' || f === 'static/ergopti_plus/core/crypto/y.lua'
	);
	assert.equal(done.stepped, true);
	const left = Plan.steps(new Map([['core/crypto/y.lua', 'core/crypto/z/y.lua']]), done);
	assert.deepEqual(
		left.map((s) => s.id),
		['S02']
	);
	assert.throws(
		() => Plan.steps(new Map([['core/other.lua', 'core/z/other.lua']]), done),
		/does not number it/
	);
	// A file added after the map was committed joins its folder's step.
	const joined = Plan.steps(
		new Map([
			['core/crypto/y.lua', 'core/crypto/z/y.lua'],
			['core/crypto/new.lua', 'core/crypto/z/new.lua']
		]),
		done
	);
	assert.deepEqual(
		joined.map((s) => [s.id, s.moves.length]),
		[['S02', 2]]
	);
	console.log(
		'[OK] the phase 2 runner refuses without its go and owns the follow-ups of each step.'
	);
}

run();
