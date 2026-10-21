// tools/test/test-macos-stage-roles.cjs
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const YAML = require('yaml');
const roles = require('../ci/macos-stage-roles.cjs');
let controls = 0;
function check(name, body) {
	body();
	controls++;
	console.log('PASS macos-stage-roles: ' + name);
}
const context = {
	source_sha: 'a'.repeat(40),
	run_id: '1234',
	event_name: 'push',
	release: false,
	scenarios: ['clean', 'karabiner_config', 'upgraded']
};
const host = (cell) => ({
	os: cell.runner === 'ubuntu-latest' ? 'linux' : 'darwin',
	architecture: cell.architecture === 'amd64' ? 'x64' : 'arm64'
});
/** The successful direct predecessor aggregates a receiving stage is given. */
function needsOf(receiver, result = 'success') {
	return Object.fromEntries(
		roles.PREDECESSORS[receiver].map((stage) => [
			roles.JOBS[roles.STAGES.indexOf(stage)],
			{ result }
		])
	);
}
/** Admits one receiving stage from its predecessors' receipts, as the workflow does. */
function admitted(receiver, all, ctx = context, attempt = 1) {
	const displayed = receiver === 'build' ? undefined : roles.displayPlan(receiver, ctx);
	return roles.admit(
		receiver,
		displayed?.matrix.lot[0],
		displayed?.metadata,
		needsOf(receiver),
		ctx,
		attempt,
		() => roles.PREDECESSORS[receiver].flatMap((stage) => all[stage])
	);
}
function complete(ctx = context, attempt = 1) {
	const all = {};
	for (const stage of roles.STAGES) {
		const prior =
			stage === 'unit' ? { context: ctx, chain: [] } : admitted(stage, all, ctx, attempt);
		all[stage] = roles
			.plan(stage, ctx)
			.map((cell) => roles.record(stage, cell, 'success', prior, ctx, host(cell), attempt));
	}
	const proof = roles.union('testbuild', all.testbuild, 'success', ctx, attempt);
	return { all, proof };
}
const completed = complete();
check('exact five visible jobs with only their declared predecessor edges', () => {
	const workflow = YAML.parse(require('./ci-pipeline.cjs').file('.github/workflows/ci-macos.yml'));
	const jobs = ['test-hs', 'e2e-hs', 'package-macos', 'launch', 'macos-ok'];
	assert.deepEqual(Object.keys(workflow.jobs), jobs);
	const needs = {
		'test-hs': [],
		'e2e-hs': ['test-hs'],
		'package-macos': ['test-hs'],
		launch: ['e2e-hs', 'package-macos'],
		'macos-ok': ['launch']
	};
	for (const [index, stage] of roles.STAGES.entries())
		assert.deepEqual(
			needs[roles.JOBS[index]],
			roles.PREDECESSORS[stage].map((name) => roles.JOBS[roles.STAGES.indexOf(name)]),
			'The workflow edges are the stage predecessors'
		);
	for (const id of jobs) {
		assert.deepEqual(workflow.jobs[id].needs || [], needs[id]);
		const ids = workflow.jobs[id].steps.filter((step) => step.id).map((step) => step.id);
		assert.equal(ids.length, new Set(ids).size, 'Merged roles must retain unique step IDs');
	}
	for (const id of ['e2e-hs', 'launch'])
		assert.equal(workflow.jobs[id].strategy['fail-fast'], false);
	// The Unit matrix is exactly the Lua runner's module groups, in order.
	assert.deepEqual(workflow.jobs['test-hs'].strategy, {
		'fail-fast': false,
		matrix: { lot: roles.unitGroups() }
	});
	assert.deepEqual(workflow.jobs['test-hs'].env, { MACOS_STAGE_LOT: '${{ matrix.lot }}' });
	assert.equal(
		workflow.jobs['package-macos'].outputs.scenarios,
		'${{ steps.profile.outputs.scenarios }}'
	);
	assert.equal(workflow.jobs['macos-ok'].if, 'always()');
	const verifier = workflow.jobs['macos-ok'].steps.find(
		(step) => step.name === 'Verify mandatory jobs and launch scenarios'
	);
	assert.equal(verifier.env.NEEDS, '${{ steps.stage-verdict.outputs.needs }}');
	for (const id of ['e2e-hs', 'package-macos', 'launch']) {
		const steps = workflow.jobs[id].steps;
		assert.ok(
			steps
				.find((step) => step.id === 'stage-admission')
				.run.includes('macos-stage-roles.cjs admit')
		);
		for (const step of steps.filter((step) => step.if?.includes('matrix.role')))
			assert.ok(step.if.includes("steps.stage-admission.outcome == 'success'"));
	}
});
check('push E2E includes every mandatory role and both managed architectures', () => {
	assert.deepEqual(
		roles
			.plan('e2e', context)
			.map((cell) => [cell.role, cell.runner, cell.scenario, cell.timeout_minutes]),
		[
			['e2e-hs', 'ubuntu-latest', '', 360],
			['tooltip-canvas', 'macos-15', '', 10],
			['managed-ollama-native', 'macos-15', '', 60],
			// Intel runs its XCTest cohorts beside the runtime receiving.
			['managed-ollama-native', 'macos-15-intel', 'runtime', 60],
			['managed-ollama-native', 'macos-15-intel', 'xctest', 45],
			['managed-ollama-build', 'macos-15', '', 60],
			['managed-ollama-build', 'macos-15-intel', '', 60]
		]
	);
	assert.deepEqual(roles.displayPlan('e2e', context).matrix.lot.slice(2, 5), [
		'Managed Ollama (macOS 15, Apple silicon)',
		'Managed Ollama (macOS 15, Intel)',
		'Native XCTest (macOS 15, Intel)'
	]);
	for (const [architecture, scenario] of [
		['arm64', 'runtime'],
		['arm64', 'xctest'],
		['amd64', 'other']
	])
		assert.throws(() => roles.roleLot('e2e', 'managed-ollama-native', architecture, scenario));
});
/** The managed native steps one cell of each scenario actually runs. */
function managedNativeSteps(workflow) {
	const steps = workflow.jobs['e2e-hs'].steps.filter((step) =>
		(step.if ?? '').includes("env.MACOS_STAGE_ROLE == 'managed-ollama-native'")
	);
	const runs = (step, scenario) =>
		!(step.if ?? '').includes("env.MACOS_STAGE_SCENARIO != '" + scenario + "'");
	return { steps, runs };
}
function checkManagedNativeSplit(workflow) {
	const { steps, runs } = managedNativeSteps(workflow);
	assert.ok(steps.length > 30, 'the managed native role keeps its steps');
	const scenarios = roles
		.plan('e2e', context)
		.filter((cell) => cell.role === 'managed-ollama-native')
		.map((cell) => cell.scenario);
	assert.deepEqual(scenarios, ['', 'runtime', 'xctest']);
	const xctest = steps.filter((step) =>
		/\bswift test\b|run_logger_numeric_native\.sh/.test(step.run ?? '')
	);
	assert.ok(xctest.length >= 6, 'every XCTest cohort is found');
	for (const step of steps) {
		// Apple silicon has no scenario and runs every step of the role.
		assert.ok(runs(step, ''), step.name + ' must run in the Apple-silicon cell');
		assert.ok(runs(step, 'runtime') || runs(step, 'xctest'), step.name + ' must run on Intel');
	}
	for (const step of xctest) {
		assert.ok(!runs(step, 'runtime'), step.name + ' must leave the Intel runtime cell');
		assert.ok(runs(step, 'xctest'), step.name + ' must run in the Intel XCTest cell');
	}
	for (const name of [
		'Build the actual launcher native transport roles',
		'Receive and admit the clean native source asset from its build cell',
		'Receive actual native model create, pull, inference and retirement',
		'Receive actual independent managed HTTP native clients',
		'Upload qualified native inputs for the application catalogue',
		'Upload the actual managed native release asset'
	]) {
		const step = steps.find((candidate) => candidate.name === name);
		assert.ok(step && runs(step, 'runtime') && !runs(step, 'xctest'), name + ' is runtime only');
	}
	// Two Intel cells must never upload one artifact name.
	for (const step of steps.filter(
		(candidate) =>
			/actions\/upload-artifact/.test(candidate.uses ?? '') &&
			runs(candidate, 'runtime') &&
			runs(candidate, 'xctest')
	))
		assert.match(step.with.name, /env\.MACOS_STAGE_SCENARIO/, step.name + ' names its scenario');
}
check('the Intel managed native role splits XCTest from runtime without dropping a step', () => {
	const workflow = YAML.parse(require('./ci-pipeline.cjs').file('.github/workflows/ci-macos.yml'));
	checkManagedNativeSplit(workflow);
	const sdk = 'Qualify actual SDK accepted-owner and deadline XCTest controls';
	const model = 'Receive actual native model create, pull, inference and retirement';
	const upload = 'Retain actual native producer, catalogue and receiving evidence';
	for (const [label, mutate] of [
		[
			'an XCTest cohort back in the runtime cell',
			(step) =>
				step.name === sdk &&
				(step.if = step.if.replace(" && (env.MACOS_STAGE_SCENARIO != 'runtime')", ''))
		],
		[
			'model receiving in the XCTest cell',
			(step) =>
				step.name === model &&
				(step.if = step.if.replace(" && env.MACOS_STAGE_SCENARIO != 'xctest'", ''))
		],
		[
			'a step skipped on Apple silicon',
			(step) => step.name === sdk && (step.if = step.if.replace("'runtime'", "''"))
		],
		[
			'one artifact name for both Intel cells',
			(step) =>
				step.name === upload &&
				(step.with.name = step.with.name.replace(
					"${{ env.MACOS_STAGE_SCENARIO && format('-{0}', env.MACOS_STAGE_SCENARIO) || '' }}",
					''
				))
		]
	]) {
		const mutated = structuredClone(workflow);
		const before = JSON.stringify(mutated);
		mutated.jobs['e2e-hs'].steps.forEach(mutate);
		assert.notEqual(JSON.stringify(mutated), before, label + ' must change the workflow');
		assert.throws(() => checkManagedNativeSplit(mutated), undefined, label);
	}
});
check('manual nonrelease retains Item36 and both lease cells', () => {
	const ctx = { ...context, event_name: 'workflow_dispatch' };
	assert.deepEqual(
		roles
			.plan('e2e', ctx)
			.slice(7)
			.map((cell) => [cell.role, cell.runner, cell.timeout_minutes]),
		[
			['item36-native', 'macos-latest', 25],
			['lease-silence-native', 'macos-15', 20],
			['lease-silence-native', 'macos-15-intel', 20]
		]
	);
	assert.equal(complete(ctx).proof.chain[1].cells.length, 10);
});
check('release launch preserves both arches and every canonical supplied scenario', () => {
	const ctx = { ...context, release: true, event_name: 'workflow_dispatch' };
	assert.equal(roles.plan('e2e', ctx).length, 7);
	assert.deepEqual(
		roles
			.plan('testbuild', ctx)
			.map((cell) => [cell.role, cell.runner, cell.scenario, cell.timeout_minutes]),
		[
			// Two lots per architecture: with the cold bootstrap, five jobs at once.
			...['macos-15', 'macos-15-intel'].flatMap((runner) => [
				['launch', runner, 'clean__karabiner_config', 16],
				['launch', runner, 'upgraded', 11]
			]),
			['cold-bootstrap-native', 'macos-15', '', 90]
		]
	);
	assert.equal(complete(ctx).proof.chain[3].cells.length, 5);
});
check('complete proof preserves original mandatory native verdict map', () => {
	assert.deepEqual(
		roles.legacyNeeds(completed.proof, context),
		Object.fromEntries(
			[
				'test-hs',
				'e2e-hs',
				'package-macos',
				'launch',
				'tooltip-canvas',
				'managed-ollama-native',
				'cold-bootstrap-native'
			].map((id) => [id, { result: 'success' }])
		)
	);
});
for (const stage of roles.STAGES) {
	for (const result of ['failure', 'cancelled', 'skipped', undefined])
		check(stage + ' aggregate ' + result + ' refuses before receipt access', () => {
			const receipts = new Proxy([], {
				get() {
					throw new Error('RECEIPT_ACCESSED');
				}
			});
			assert.throws(
				() => roles.union(stage, receipts, result, context, 1),
				/Direct predecessor aggregate/
			);
		});
	const refuse = (name, change, pattern) =>
		check(stage + ' ' + name, () => {
			const receipts = completed.all[stage].map((row) => structuredClone(row));
			change(receipts);
			assert.throws(() => roles.union(stage, receipts, 'success', context, 1), pattern);
		});
	refuse('missing role', (rows) => rows.pop(), /Missing or extra/);
	refuse('extra role', (rows) => rows.push(structuredClone(rows[0])), /Missing or extra/);
	refuse(
		'failed role',
		(rows) => {
			rows[0].result = 'failure';
		},
		/did not succeed/
	);
	refuse(
		'wrong OS',
		(rows) => {
			rows[0].host.os = 'win32';
		},
		/Wrong OS/
	);
	refuse(
		'wrong role',
		(rows) => {
			rows[0].cell.role = 'foreign-role';
		},
		/Unexpected stage role/
	);
	refuse(
		'wrong runtime bound',
		(rows) => {
			rows[0].cell.timeout_minutes++;
		},
		/Changed role/
	);
	refuse(
		'wrong source',
		(rows) => {
			rows[0].context.source_sha = 'b'.repeat(40);
		},
		/Foreign source/
	);
	refuse(
		'wrong run',
		(rows) => {
			rows[0].context.run_id = '4321';
		},
		/Foreign source/
	);
	refuse(
		'unknown field',
		(rows) => {
			rows[0].bypass = true;
		},
		/Closed stage/
	);
	refuse(
		'wrong stage',
		(rows) => {
			rows[0].stage = 'foreign';
		},
		/Foreign stage/
	);
	refuse(
		'future attempt',
		(rows) => {
			rows[0].attempt = 2;
		},
		/Future producer/
	);
	if (completed.all[stage].length > 1)
		refuse(
			'duplicate replaces a mandatory role',
			(rows) => {
				rows[1] = structuredClone(rows[0]);
			},
			/Duplicate/
		);
	if (stage !== 'unit') {
		refuse(
			'missing predecessor',
			(rows) => {
				rows[0].prior.pop();
			},
			/prior stage/
		);
		refuse(
			'failed predecessor',
			(rows) => {
				rows[0].prior[0].cells[0].result = 'failure';
			},
			/did not succeed/
		);
		refuse(
			'future predecessor',
			(rows) => {
				rows[0].prior.at(-1).cells[0].attempt = 2;
			},
			/future attempt/
		);
	}
}
check('wrong native architecture refuses', () => {
	const rows = completed.all.e2e.map((row) => structuredClone(row));
	rows[2].host.architecture = 'x64';
	assert.throws(() => roles.union('e2e', rows, 'success', context, 1), /Wrong architecture/);
});
check('successful earlier attempts survive a legitimate failed-jobs rerun', () => {
	const rows = completed.all.testbuild.map((row) => structuredClone(row));
	rows[1].attempt = 2;
	for (const stage of rows[1].prior) for (const cell of stage.cells) cell.attempt = 2;
	const proof = roles.union('testbuild', rows, 'success', context, 2);
	assert.equal(proof.chain[3].cells[0].attempt, 1);
	assert.equal(proof.chain[3].cells[1].attempt, 2);
	roles.legacyNeeds(proof, context);
});
check('newer receipt first retains a real oldest successful predecessor witness', () => {
	const rows = completed.all.testbuild.map((row) => structuredClone(row));
	rows[0].attempt = 2;
	for (const stage of rows[0].prior) for (const cell of stage.cells) cell.attempt = 2;
	const proof = roles.union('testbuild', rows, 'success', context, 2);
	assert.deepEqual(proof.chain.slice(0, -1), rows[1].prior);
	roles.legacyNeeds(proof, context);
});
check('backward lineage inside an otherwise current receipt refuses', () => {
	const rows = completed.all.testbuild.map((row) => structuredClone(row));
	rows[0].attempt = 3;
	rows[0].prior[0].cells[0].attempt = 2;
	assert.throws(
		() => roles.union('testbuild', rows, 'success', context, 3),
		/Backward predecessor attempt lineage/
	);
});
check('conflicting otherwise valid earlier host identity refuses', () => {
	const rows = completed.all.testbuild.map((row) => structuredClone(row));
	rows[1].prior[0].cells[0].host.architecture = 'x64';
	assert.throws(
		() => roles.union('testbuild', rows, 'success', context, 1),
		/Conflicting predecessor/
	);
});
check('direct predecessor identity is exact', () => {
	assert.equal(roles.aggregate({ launch: { result: 'success' } }, 'testbuild'), 'success');
	assert.throws(
		() =>
			roles.aggregate({ launch: { result: 'success' }, extra: { result: 'success' } }, 'testbuild'),
		/Closed stage/
	);
	assert.throws(
		() => roles.aggregate({ 'package-macos': { result: 'success' } }, 'testbuild'),
		/Closed stage/
	);
	// The test build's direct predecessors are both E2E and Build.
	assert.equal(roles.aggregate(needsOf('testbuild'), ['e2e', 'build']), 'success');
	for (const job of ['e2e-hs', 'package-macos']) {
		const partial = needsOf('testbuild');
		delete partial[job];
		assert.throws(() => roles.aggregate(partial, ['e2e', 'build']), /Closed stage/);
		const failed = { ...needsOf('testbuild'), [job]: { result: 'failure' } };
		assert.throws(() => roles.aggregate(failed, ['e2e', 'build']), /Direct predecessor aggregate/);
	}
});
check('artifact reader refuses duplicate fields and unexpected members', () => {
	const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-macos-stage-test-'));
	try {
		const file = path.join(directory, 'receipt.json');
		fs.writeFileSync(file, '{"schema":1,"schema":1}');
		assert.throws(() => roles.readReceipts(directory), /Duplicate/);
		fs.writeFileSync(file, JSON.stringify(completed.all.unit[0], null, 2) + '\n');
		assert.deepEqual(roles.readReceipts(directory), [completed.all.unit[0]]);
		fs.writeFileSync(file, JSON.stringify(completed.all.unit[0]));
		assert.throws(() => roles.readReceipts(directory), /not canonical/);
		fs.writeFileSync(file, ' '.repeat(65537));
		assert.throws(() => roles.readReceipts(directory), /size is invalid/);
		fs.writeFileSync(file, JSON.stringify(completed.all.unit[0], null, 2) + '\n');
		fs.writeFileSync(path.join(directory, 'unexpected.json'), '{}');
		assert.throws(() => roles.readReceipts(directory), /Foreign stage/);
	} finally {
		fs.rmSync(directory, { recursive: true });
	}
});
check('existing scope owner admits every retained Mac command after address relocation', () => {
	// Each real file of the lane is projected under its own path, stage files included.
	const real = require('./ci-pipeline.cjs').real();
	const scoped = require('./fixtures/ci-scoped-full-branches.cjs');
	let relocated = 0;
	for (const rel of real.laneFiles('.github/workflows/ci-macos.yml')) {
		const source = real.file(rel);
		const projected = scoped.projectScopedSteps(source, rel);
		assert.ok(projected.length > 0);
		if (projected !== source) relocated++;
	}
	assert.ok(relocated > 0, 'some retained Mac command is projected');
});

// One more than the single-cell Unit: a duplicate Unit row now replaces a mandatory group;
// one more for the Intel managed native split.
assert.equal(controls, 86, 'all original stage and receipt controls remain present');
check('Unit lots are the module groups, each one complete stubbed cell', () => {
	const groups = roles.unitGroups();
	// Deliberately narrow: these are the macOS shard GROUP names, not source trees
	// (platform/ tests belong to the core group), so the source-tree scan gate does not apply.
	const shardGroupNames = 'meta core modules menu_llm menu_input ui other'.split(' ');
	assert.deepEqual(groups, shardGroupNames);
	assert.deepEqual(roles.displayPlan('unit', context), {
		matrix: { lot: groups },
		metadata: Object.fromEntries(
			groups.map((group) => [
				group,
				{
					role: 'lua-unit-meta',
					runner: 'ubuntu-latest',
					architecture: 'stubbed',
					timeout_minutes: 360,
					scenario: group
				}
			])
		)
	});
	for (const [index, group] of groups.entries())
		assert.deepEqual(roles.selectUnitLot(group, context), roles.plan('unit', context)[index]);
	for (const name of [
		undefined,
		'',
		'lua-unit-meta',
		'Lua unit and meta (stubbed)',
		'META',
		'foreign'
	])
		assert.throws(() => roles.selectUnitLot(name, context), /Missing or foreign human lot/);
});
check('E2E human lots retain native architectures and scoped manual roles', () => {
	const push = [
		'Virtual-keyboard replay (stubbed)',
		'Tooltip canvas (macOS 15, Apple silicon)',
		'Managed Ollama (macOS 15, Apple silicon)',
		'Managed Ollama (macOS 15, Intel)',
		'Native XCTest (macOS 15, Intel)',
		'Managed Ollama build (macOS 15, Apple silicon)',
		'Managed Ollama build (macOS 15, Intel)'
	];
	assert.deepEqual(roles.displayPlan('e2e', context).matrix, { lot: push });
	assert.deepEqual(
		roles.displayPlan('e2e', { ...context, event_name: 'workflow_dispatch' }).matrix,
		{
			lot: [
				...push,
				'Archive update controls (macOS 26)',
				'Lease silence (macOS 15, Apple silicon)',
				'Lease silence (macOS 15, Intel)'
			]
		}
	);
	assert.deepEqual(
		roles.displayPlan('e2e', { ...context, event_name: 'workflow_dispatch', release: true }).matrix,
		{ lot: push }
	);
});
check('installed-app lots expose every exact scenario and release architecture', () => {
	assert.deepEqual(roles.displayPlan('testbuild', context).matrix, {
		lot: [
			'Installed app: clean (macOS 15, Apple silicon)',
			'Installed app: karabiner config (macOS 15, Apple silicon)',
			'Installed app: upgraded (macOS 15, Apple silicon)',
			'Cold native bootstrap (macOS 15, Apple silicon)'
		]
	});
	assert.deepEqual(roles.displayPlan('testbuild', { ...context, release: true }).matrix, {
		lot: [
			'Installed app: clean, karabiner config (macOS 15, Apple silicon)',
			'Installed app: upgraded (macOS 15, Apple silicon)',
			'Installed app: clean, karabiner config (macOS 15, Intel)',
			'Installed app: upgraded (macOS 15, Intel)',
			'Cold native bootstrap (macOS 15, Apple silicon)'
		]
	});
});
for (const [name, ctx] of [
	['push', context],
	['manual', { ...context, event_name: 'workflow_dispatch' }],
	['release', { ...context, event_name: 'workflow_dispatch', release: true }]
]) {
	for (const stage of ['unit', 'e2e', 'testbuild']) {
		check(name + ' ' + stage + ' maps each lot back to the complete old cell exactly once', () => {
			const displayed = roles.displayPlan(stage, ctx);
			const original = roles.plan(stage, ctx);
			assert.deepEqual(Object.keys(displayed), ['matrix', 'metadata']);
			assert.deepEqual(Object.keys(displayed.matrix), ['lot']);
			assert.equal(displayed.matrix.lot.length, original.length);
			assert.equal(new Set(displayed.matrix.lot).size, original.length);
			assert.deepEqual(Object.keys(displayed.metadata), displayed.matrix.lot);
			assert.deepEqual(Object.values(displayed.metadata), original);
			assert.deepEqual(
				displayed.matrix.lot.map((lot) => roles.selectLot(stage, lot, displayed.metadata, ctx)),
				original
			);
			for (const lot of displayed.matrix.lot)
				assert.doesNotMatch(lot, /e2e-hs|macos-|ubuntu-|timeout_minutes|\b360\b/);
		});
	}
}
check(
	'human-lot renderer refuses foreign roles, stages, native architectures and scenarios',
	() => {
		const selected = roles.plan('e2e', context)[2];
		assert.throws(() => roles.humanLot('unit', selected), /Unknown human lot stage or role/);
		assert.throws(
			() => roles.humanLot('e2e', { ...selected, architecture: 'host' }),
			/Unknown human lot architecture/
		);
		assert.throws(
			() => roles.humanLot('e2e', { ...selected, scenario: 'clean' }),
			/Unexpected scenario/
		);
		assert.throws(
			() => roles.humanLot('testbuild', { ...roles.plan('testbuild', context)[0], scenario: '' }),
			/Invalid launch lot/
		);
		for (const scenario of ['clean__', 'clean___upgraded', 'clean__clean', 'Clean'])
			assert.throws(
				() => roles.humanLot('testbuild', { ...roles.plan('testbuild', context)[0], scenario }),
				/launch lot/
			);
		assert.throws(() => roles.displayPlan('build', context), /no human lot matrix/);
	}
);
const lotContext = { ...context, event_name: 'workflow_dispatch', release: true };
const lotStage = 'testbuild';
const lotPlan = roles.displayPlan(lotStage, lotContext);
const selectedLot = 'Installed app: clean, karabiner config (macOS 15, Apple silicon)';
for (const [name, mutate] of [
	['missing selected lot', (map) => delete map[selectedLot]],
	[
		'missing unselected lot',
		(map) => delete map['Installed app: clean, karabiner config (macOS 15, Intel)']
	],
	['foreign lot alias', (map) => (map.foreign = structuredClone(map[selectedLot]))],
	[
		'duplicate cell under another authored lot',
		(map) =>
			(map['Installed app: clean, karabiner config (macOS 15, Intel)'] = structuredClone(
				map[selectedLot]
			))
	],
	['wrong role', (map) => (map[selectedLot].role = 'cold-bootstrap-native')],
	['wrong runner', (map) => (map[selectedLot].runner = 'macos-latest')],
	['wrong architecture', (map) => (map[selectedLot].architecture = 'amd64')],
	['wrong runtime bound', (map) => map[selectedLot].timeout_minutes++],
	['wrong scenario', (map) => (map[selectedLot].scenario = 'upgraded')],
	['foreign cell field', (map) => (map[selectedLot].bypass = true)],
	['missing cell field', (map) => delete map[selectedLot].scenario]
]) {
	check('whole lot metadata refuses ' + name, () => {
		const metadata = structuredClone(lotPlan.metadata);
		mutate(metadata);
		assert.throws(
			() => roles.selectLot(lotStage, selectedLot, metadata, lotContext),
			/Complete human lot metadata map differs/
		);
	});
}
check('whole lot metadata refuses a foreign profile and duplicate wire keys', () => {
	assert.throws(
		() => roles.selectLot(lotStage, selectedLot, lotPlan.metadata, context),
		/Complete human lot metadata map differs/
	);
	const { parseClosedJson } = require('../ci/dev-release-qualification.cjs');
	const entry = JSON.stringify(selectedLot) + ':' + JSON.stringify(lotPlan.metadata[selectedLot]);
	assert.throws(
		() =>
			roles.selectLot(
				lotStage,
				selectedLot,
				parseClosedJson('{' + entry + ',' + entry + '}'),
				lotContext
			),
		/Duplicate/
	);
});
check('metadata key order has no meaning while the complete cell values remain exact', () => {
	const reordered = Object.fromEntries(
		Object.entries(lotPlan.metadata)
			.reverse()
			.map(([lot, selected]) => [lot, Object.fromEntries(Object.entries(selected).reverse())])
	);
	assert.deepEqual(
		roles.selectLot(lotStage, selectedLot, reordered, lotContext),
		lotPlan.metadata[selectedLot]
	);
});
for (const lot of [
	undefined,
	null,
	'',
	'launch',
	'Installed app: clean',
	'Installed app: clean (ARM64)'
])
	check('closed lot selection refuses ' + JSON.stringify(lot), () => {
		assert.throws(
			() => roles.selectLot(lotStage, lot, lotPlan.metadata, lotContext),
			/Missing or foreign human lot/
		);
	});
for (const receiver of ['e2e', 'testbuild']) {
	check(receiver + ' validates the whole lot map before any predecessor access', () => {
		const displayed = roles.displayPlan(receiver, context);
		const metadata = structuredClone(displayed.metadata);
		delete metadata[displayed.matrix.lot.at(-1)];
		const needs = new Proxy(
			{},
			{
				ownKeys() {
					throw new Error('NEEDS_ACCESSED');
				}
			}
		);
		let reads = 0;
		assert.throws(
			() =>
				roles.admit(receiver, displayed.matrix.lot[0], metadata, needs, context, 1, () => {
					reads++;
					return roles.PREDECESSORS[receiver].flatMap((stage) => completed.all[stage]);
				}),
			/Complete human lot metadata map differs/
		);
		assert.equal(reads, 0);
	});
}
for (const receiver of ['e2e', 'build', 'testbuild']) {
	const displayed = receiver === 'build' ? undefined : roles.displayPlan(receiver, context);
	const lot = displayed?.matrix.lot[0];
	const receipts = () => roles.PREDECESSORS[receiver].flatMap((stage) => completed.all[stage]);
	check(receiver + ' admission retains aggregate custody and the exact prior proof', () => {
		let reads = 0;
		const proof = roles.admit(
			receiver,
			lot,
			displayed?.metadata,
			needsOf(receiver),
			context,
			1,
			() => {
				reads++;
				return receipts();
			}
		);
		assert.deepEqual(proof, { context, chain: completed.all[receiver][0].prior });
		assert.deepEqual(
			proof.chain.map((row) => row.stage),
			roles.priorStages(receiver)
		);
		assert.equal(reads, 1);
	});
	for (const result of ['failure', 'cancelled', 'skipped'])
		check(
			receiver + ' lot admission preserves ' + result + ' aggregate refusal before read',
			() => {
				for (const stage of roles.PREDECESSORS[receiver]) {
					let reads = 0;
					const needs = {
						...needsOf(receiver),
						[roles.JOBS[roles.STAGES.indexOf(stage)]]: { result }
					};
					assert.throws(
						() =>
							roles.admit(receiver, lot, displayed?.metadata, needs, context, 1, () => {
								reads++;
								return receipts();
							}),
						/Direct predecessor aggregate/
					);
					assert.equal(reads, 0);
				}
			}
		);
}
for (const stage of roles.STAGES) {
	check(stage + ' lot recording preserves every original receipt field and complete cell', () => {
		const displayed = stage === 'build' ? undefined : roles.displayPlan(stage, context);
		for (const [index, selected] of roles.plan(stage, context).entries()) {
			const original = completed.all[stage][index];
			assert.deepEqual(
				roles.recordLot(
					stage,
					selected,
					'success',
					{ context, chain: original.prior },
					context,
					host(selected),
					1,
					displayed?.matrix.lot[index],
					displayed?.metadata
				),
				original
			);
		}
	});
	if (stage !== 'build')
		check(stage + ' lot recording refuses a missing or foreign displayed lot', () => {
			const selected = roles.plan(stage, context)[0];
			const prior = { context, chain: completed.all[stage][0].prior };
			const displayed = roles.displayPlan(stage, context);
			for (const lot of [undefined, 'foreign'])
				assert.throws(
					() =>
						roles.recordLot(
							stage,
							selected,
							'success',
							prior,
							context,
							host(selected),
							1,
							lot,
							displayed.metadata
						),
					/Missing or foreign human lot/
				);
		});
}
check('recording refuses another valid cell under the selected human lot', () => {
	const selected = roles.plan('e2e', context)[3];
	const prior = { context, chain: completed.all.e2e[3].prior };
	const displayed = roles.displayPlan('e2e', context);
	assert.throws(
		() =>
			roles.recordLot(
				'e2e',
				selected,
				'success',
				prior,
				context,
				host(selected),
				1,
				'Managed Ollama (macOS 15, Apple silicon)',
				displayed.metadata
			),
		/Selected human lot and receipt cell differ/
	);
});
assert.equal(controls, 140, 'original controls and human lot transport controls all execute');
check('role labels retain the independent authored human names without runtime metadata', () => {
	for (const [stage, role, architecture, scenario, expected] of [
		['unit', 'lua-unit-meta', 'stubbed', 'meta', 'meta'],
		['unit', 'lua-unit-meta', 'stubbed', 'other', 'other'],
		['e2e', 'e2e-hs', 'stubbed', '', 'Virtual-keyboard replay (stubbed)'],
		['e2e', 'tooltip-canvas', 'arm64', '', 'Tooltip canvas (macOS 15, Apple silicon)'],
		['e2e', 'managed-ollama-native', 'arm64', '', 'Managed Ollama (macOS 15, Apple silicon)'],
		['e2e', 'managed-ollama-native', 'amd64', '', 'Managed Ollama (macOS 15, Intel)'],
		['e2e', 'managed-ollama-build', 'arm64', '', 'Managed Ollama build (macOS 15, Apple silicon)'],
		['e2e', 'managed-ollama-build', 'amd64', '', 'Managed Ollama build (macOS 15, Intel)'],
		['e2e', 'item36-native', 'host', '', 'Archive update controls (macOS 26)'],
		['e2e', 'lease-silence-native', 'arm64', '', 'Lease silence (macOS 15, Apple silicon)'],
		['e2e', 'lease-silence-native', 'amd64', '', 'Lease silence (macOS 15, Intel)'],
		[
			'testbuild',
			'launch',
			'arm64',
			'karabiner_config',
			'Installed app: karabiner config (macOS 15, Apple silicon)'
		],
		['testbuild', 'launch', 'amd64', 'upgraded', 'Installed app: upgraded (macOS 15, Intel)'],
		[
			'testbuild',
			'launch',
			'amd64',
			'clean__karabiner_config',
			'Installed app: clean, karabiner config (macOS 15, Intel)'
		],
		[
			'testbuild',
			'cold-bootstrap-native',
			'arm64',
			'',
			'Cold native bootstrap (macOS 15, Apple silicon)'
		]
	])
		assert.equal(roles.roleLot(stage, role, architecture, scenario), expected);
});
check(
	'role labels refuse invalid argument types and foreign stage role architecture or scenario',
	() => {
		const args = ['e2e', 'managed-ollama-native', 'arm64', ''];
		for (let index = 0; index < args.length; index++) {
			for (const value of [undefined, null, 1, [], {}]) {
				const changed = args.slice();
				changed[index] = value;
				assert.throws(() => roles.roleLot(...changed), /Invalid human lot/);
			}
		}
		for (const changed of [
			['unit', 'managed-ollama-native', 'arm64', ''],
			['unit', 'lua-unit-meta', 'stubbed', ''],
			['unit', 'lua-unit-meta', 'stubbed', 'foreign'],
			['unit', 'lua-unit-meta', 'arm64', 'meta'],
			['e2e', 'foreign', 'arm64', ''],
			['e2e', 'managed-ollama-native', 'host', ''],
			['e2e', 'managed-ollama-native', 'arm64', 'clean'],
			['testbuild', 'launch', 'arm64', ''],
			['testbuild', 'launch', 'arm64', 'clean forged']
		])
			assert.throws(() => roles.roleLot(...changed));
	}
);
check('full-cell human labels still reject incomplete cells and foreign fields', () => {
	assert.throws(
		() =>
			roles.humanLot('e2e', {
				role: 'managed-ollama-native',
				architecture: 'arm64',
				scenario: ''
			}),
		/Closed stage receipt fields required/
	);
	assert.throws(
		() => roles.humanLot('e2e', { ...roles.plan('e2e', context)[2], lot: 'forged' }),
		/Closed stage receipt fields required/
	);
});
assert.equal(controls, 143, 'all original, human lot transport and role-label controls execute');
/** Admit the Unit group matrix while preserving its complete receipt-producing source chain. */
function assertLiteralUnit(source) {
	const job = YAML.parse(source, { uniqueKeys: true }).jobs['test-hs'];
	assert.ok(job && Array.isArray(job.steps), 'Missing actual Unit job');
	assert.deepEqual(
		Object.fromEntries(Object.entries(job).filter(([key]) => key !== 'steps')),
		{
			name: 'Unit tests',
			'runs-on': 'ubuntu-latest',
			'timeout-minutes': 360,
			strategy: { 'fail-fast': false, matrix: { lot: roles.unitGroups() } },
			env: { MACOS_STAGE_LOT: '${{ matrix.lot }}' },
			outputs: {
				e2e_matrix: '${{ steps.stage-plan.outputs.e2e_matrix }}',
				e2e_metadata: '${{ steps.stage-plan.outputs.e2e_metadata }}'
			}
		},
		"Unit must be one matrix row per module group, in the groups' order"
	);
	function exact(name, expected) {
		const matches = job.steps.filter((step) => step.name === name);
		assert.equal(matches.length, 1, 'Missing or duplicate Unit custody step');
		assert.deepEqual(matches[0], { name, ...expected }, 'Unit receipt custody source differs');
	}
	exact('Admit the authored unit lot', {
		id: 'stage-selection',
		run: 'node tools/ci/macos-stage-roles.cjs select unit'
	});
	exact('Resolve exact E2E stage roles', {
		id: 'stage-plan',
		run: 'node tools/ci/macos-stage-roles.cjs plan e2e'
	});
	exact('Record actual stage role outcome', {
		if: 'always()',
		env: {
			MACOS_STAGE_CELL: '${{ steps.stage-selection.outputs.cell }}',
			MACOS_STAGE_RESULT: '${{ job.status }}'
		},
		run: 'node tools/ci/macos-stage-roles.cjs record unit - "$RUNNER_TEMP/macos-stage-output/receipt.json"'
	});
	exact('Retain exact stage role outcome', {
		if: 'always()',
		uses: 'actions/upload-artifact@v4',
		with: {
			name: "macos-stage-unit-${{ fromJSON(steps.stage-selection.outputs.cell).role }}-${{ fromJSON(steps.stage-selection.outputs.cell).runner }}-${{ fromJSON(steps.stage-selection.outputs.cell).scenario || 'default' }}-${{ github.run_id }}",
			path: '${{ runner.temp }}/macos-stage-output/receipt.json',
			'if-no-files-found': 'error',
			'retention-days': 7,
			overwrite: true
		}
	});
	// Each row runs only its admitted cell's group, never the whole suite.
	const tests = job.steps.filter((step) => step.name === 'Run unit + meta tests');
	assert.equal(tests.length, 1, 'Missing or duplicate Unit test step');
	assert.equal(
		tests[0].env?.MACOS_UNIT_GROUP,
		'${{ fromJSON(steps.stage-selection.outputs.cell).scenario }}',
		'The test group must come from the admitted cell'
	);
	assert.equal(
		tests[0].run.split('lua5.4 tests/run.lua --module="$MACOS_UNIT_GROUP"\n').length,
		2,
		'The Unit row must run exactly its module group'
	);
	assert.equal(tests[0].run.split('tests/run.lua').length, 2, 'One Unit runner command');
	// The whole-tree lint runs once, on the catch-all lot, so renaming that
	// group cannot silently drop it and no other lot pays for it again.
	const catchAll = roles.unitGroups().at(-1);
	for (const name of ['Install luacheck', 'Run luacheck (non-blocking)']) {
		const lint = job.steps.filter((step) => step.name === name);
		assert.equal(lint.length, 1, 'Missing or duplicate Unit lint step');
		assert.equal(
			lint[0].if,
			`matrix.lot == '${catchAll}'`,
			'The Unit lint must run once, on the catch-all lot'
		);
	}
	assert.equal(
		job.steps.filter((step) => /luacheck/.test(step.run ?? '')).length,
		2,
		'Only the catch-all lint steps may install or run luacheck'
	);
	const selectAt = job.steps.findIndex((step) => step.id === 'stage-selection');
	const testAt = job.steps.findIndex((step) => step.name === 'Run unit + meta tests');
	const planAt = job.steps.findIndex((step) => step.id === 'stage-plan');
	const recordAt = job.steps.findIndex((step) => step.name === 'Record actual stage role outcome');
	assert.ok(
		selectAt >= 0 && selectAt < testAt && testAt < planAt && planAt < recordAt,
		'Unit selection and real tests must precede its plan and receipt'
	);
	return job;
}

const literalUnitSource = require('./ci-pipeline.cjs').file('.github/workflows/ci-macos.yml');
check('actual Unit source is the group matrix and retains its exact custody', () => {
	assertLiteralUnit(literalUnitSource);
});
for (const [name, mutate] of [
	[
		'old singleton matrix',
		(job) => {
			job.strategy = { 'fail-fast': false, matrix: { lot: ['Lua unit and meta (stubbed)'] } };
		}
	],
	[
		'empty matrix strategy',
		(job) => {
			job.strategy = {};
		}
	],
	[
		'a literal lot instead of the matrix lot',
		(job) => {
			job.env.MACOS_STAGE_LOT = 'meta';
		}
	],
	[
		'a module group missing from the matrix',
		(job) => {
			job.strategy.matrix.lot = job.strategy.matrix.lot.filter((group) => group !== 'other');
		}
	],
	[
		'a foreign group in the matrix',
		(job) => {
			job.strategy.matrix.lot.push('foreign');
		}
	],
	[
		'reordered module groups',
		(job) => {
			job.strategy.matrix.lot.reverse();
		}
	],
	[
		'fail-fast rows',
		(job) => {
			job.strategy['fail-fast'] = true;
		}
	],
	[
		'every row running the whole suite',
		(job) => {
			const step = job.steps.find((entry) => entry.name === 'Run unit + meta tests');
			step.run = step.run.replace(' --module="$MACOS_UNIT_GROUP"', '');
		}
	],
	[
		'a group taken from the matrix instead of the admitted cell',
		(job) => {
			job.steps.find((entry) => entry.name === 'Run unit + meta tests').env.MACOS_UNIT_GROUP =
				'${{ matrix.lot }}';
		}
	],
	[
		'missing lot',
		(job) => {
			delete job.env.MACOS_STAGE_LOT;
		}
	],
	[
		'foreign lot',
		(job) => {
			job.env.MACOS_STAGE_LOT = 'Lua unit and meta (native)';
		}
	],
	[
		'wrong runner',
		(job) => {
			job['runs-on'] = 'macos-latest';
		}
	],
	[
		'changed timeout',
		(job) => {
			job['timeout-minutes']++;
		}
	],
	[
		'matrix-style API title',
		(job) => {
			job.name += ' (Lua unit and meta (stubbed))';
		}
	],
	[
		'missing selection',
		(job) => {
			job.steps = job.steps.filter((step) => step.id !== 'stage-selection');
		}
	],
	[
		'duplicate selection',
		(job) => {
			job.steps.push(structuredClone(job.steps.find((step) => step.id === 'stage-selection')));
		}
	],
	[
		'forgiven selection',
		(job) => {
			job.steps.find((step) => step.id === 'stage-selection')['continue-on-error'] = true;
		}
	],
	[
		'foreign selection command',
		(job) => {
			job.steps.find((step) => step.id === 'stage-selection').run += ' || true';
		}
	],
	[
		'foreign E2E plan',
		(job) => {
			job.steps.find((step) => step.id === 'stage-plan').run =
				'node tools/ci/macos-stage-roles.cjs plan testbuild';
		}
	],
	[
		'foreign receipt cell',
		(job) => {
			job.steps.find(
				(step) => step.name === 'Record actual stage role outcome'
			).env.MACOS_STAGE_CELL = '${{ toJSON(matrix) }}';
		}
	],
	[
		'wrong receipt stage',
		(job) => {
			job.steps.find((step) => step.name === 'Record actual stage role outcome').run =
				'node tools/ci/macos-stage-roles.cjs record e2e - receipt.json';
		}
	],
	[
		'missing receipt file forgiven',
		(job) => {
			job.steps.find((step) => step.name === 'Retain exact stage role outcome').with[
				'if-no-files-found'
			] = 'warn';
		}
	],
	[
		'receipt before tests',
		(job) => {
			const at = job.steps.findIndex((step) => step.name === 'Record actual stage role outcome');
			job.steps.unshift(job.steps.splice(at, 1)[0]);
		}
	]
])
	check('literal Unit source refuses ' + name, () => {
		const changed = YAML.parse(literalUnitSource, { uniqueKeys: true });
		mutate(changed.jobs['test-hs']);
		assert.throws(() => assertLiteralUnit(YAML.stringify(changed)));
	});
check('literal Unit lot produces the unchanged complete role and receipt', () => {
	const job = assertLiteralUnit(literalUnitSource),
		lot = job.strategy.matrix.lot[0];
	assert.equal(job.env.MACOS_STAGE_LOT, '${{ matrix.lot }}');
	const selected = roles.selectUnitLot(lot, context);
	assert.deepEqual(selected, roles.plan('unit', context)[0]);
	const receipt = roles.recordLot(
		'unit',
		selected,
		'success',
		{ context, chain: [] },
		context,
		{ os: 'linux', architecture: 'x64' },
		1,
		lot,
		undefined
	);
	assert.deepEqual(
		receipt,
		roles.record(
			'unit',
			selected,
			'success',
			{ context, chain: [] },
			context,
			{ os: 'linux', architecture: 'x64' },
			1
		)
	);
	// The stage admits only a receipt from every module group.
	assert.throws(() => roles.union('unit', [receipt], 'success', context, 1), /Missing or extra/);
	const receipts = roles
		.plan('unit', context)
		.map((cell) =>
			roles.recordLot(
				'unit',
				cell,
				'success',
				{ context, chain: [] },
				context,
				{ os: 'linux', architecture: 'x64' },
				1,
				cell.scenario,
				undefined
			)
		);
	const proof = roles.union('unit', receipts, 'success', context, 1);
	assert.deepEqual(proof.chain[0].cells[0].cell, selected);
	assert.deepEqual(
		proof.chain[0].cells.map((row) => row.cell.scenario),
		roles.unitGroups()
	);
	for (const cell of [
		{ ...selected, role: 'e2e-hs' },
		{ ...selected, architecture: 'arm64' },
		{ ...selected, timeout_minutes: 359 }
	])
		assert.throws(() =>
			roles.recordLot(
				'unit',
				cell,
				'success',
				{ context, chain: [] },
				context,
				{ os: 'linux', architecture: 'x64' },
				1,
				lot,
				undefined
			)
		);
});
assert.equal(controls, 168, 'all prior 143 controls and 25 Unit matrix controls execute');

/** The native composition validator needs the approved commit's complete HEAD ancestry. */
function assertManagedNativeHistory(workflow) {
	const condition =
		"${{ steps.stage-admission.outcome == 'success' && env.MACOS_STAGE_ROLE == 'managed-ollama-native' }}";
	const checkouts = workflow.jobs['e2e-hs'].steps.filter(
		(step) => step.uses === 'actions/checkout@v4' && step.if === condition
	);
	assert.equal(checkouts.length, 1, 'Exact managed native checkout required');
	assert.deepEqual(
		checkouts[0].with,
		{ 'fetch-depth': 0 },
		'Managed native ancestry requires complete Git history'
	);
	return checkouts[0];
}
check('managed native checkout retains full history for approved source ancestry', () => {
	assertManagedNativeHistory(YAML.parse(literalUnitSource, { uniqueKeys: true }));
});
for (const [name, mutate] of [
	['missing history input', (checkout) => delete checkout.with],
	['depth one', (checkout) => (checkout.with['fetch-depth'] = 1)],
	['boolean depth', (checkout) => (checkout.with['fetch-depth'] = false)],
	['other finite depth', (checkout) => (checkout.with['fetch-depth'] = 2)],
	[
		'full history on the wrong role',
		(checkout, workflow) => {
			delete checkout.with;
			const other = workflow.jobs['e2e-hs'].steps.find(
				(step) => step.uses === 'actions/checkout@v4' && step.if !== checkout.if
			);
			assert.ok(other, 'A distinct checkout must witness wrong-role refusal');
			other.with = { 'fetch-depth': 0 };
		}
	],
	[
		'changed role guard',
		(checkout) => {
			checkout.if = checkout.if.replace("'managed-ollama-native'", "'tooltip-canvas'");
		}
	]
])
	check('managed native history refuses ' + name, () => {
		const changed = YAML.parse(literalUnitSource, { uniqueKeys: true });
		mutate(assertManagedNativeHistory(changed), changed);
		assert.throws(() => assertManagedNativeHistory(changed), assert.AssertionError);
	});
assert.equal(
	controls,
	175,
	'all prior 168 controls and seven managed native history controls execute'
);

// The stage graph: Build admits Unit beside E2E, and the test build joins both.
const testbuildLot = roles.displayPlan('testbuild', context);
const admitTestbuild = (receipts, needs = needsOf('testbuild'), ctx = context, attempt = 1) =>
	roles.admit(
		'testbuild',
		testbuildLot.matrix.lot[0],
		testbuildLot.metadata,
		needs,
		ctx,
		attempt,
		() => receipts
	);
check('stage graph keeps every earlier stage once, in order, on every chain', () => {
	assert.deepEqual(roles.PREDECESSORS, {
		unit: [],
		e2e: ['unit'],
		build: ['unit'],
		testbuild: ['e2e', 'build']
	});
	assert.deepEqual(
		roles.STAGES.map((stage) => roles.priorStages(stage)),
		[[], ['unit'], ['unit'], ['unit', 'e2e', 'build']]
	);
	assert.deepEqual(
		completed.proof.chain.map((row) => row.stage),
		roles.STAGES
	);
	assert.deepEqual(
		completed.all.build[0].prior.map((row) => row.stage),
		['unit']
	);
	assert.deepEqual(
		completed.all.e2e[0].prior.map((row) => row.stage),
		['unit']
	);
	assert.throws(
		() => roles.admit('unit', undefined, undefined, {}, context, 1, () => []),
		/Unknown receiving stage/
	);
});
for (const [name, receipts, pattern] of [
	['missing Build', () => completed.all.e2e, /Missing or extra/],
	['missing E2E', () => completed.all.build, /Missing or extra/],
	[
		'one missing E2E cell',
		() => [...completed.all.e2e.slice(1), ...completed.all.build],
		/Missing or extra/
	],
	[
		'a Unit receipt',
		() => [...completed.all.e2e, ...completed.all.build, completed.all.unit[0]],
		/Foreign stage receipt/
	],
	[
		'a test-build receipt',
		() => [...completed.all.e2e, ...completed.all.build, completed.all.testbuild[0]],
		/Foreign stage receipt/
	],
	[
		'a Build receipt from another run',
		() => {
			const build = structuredClone(completed.all.build);
			build[0].context.run_id = '4321';
			return [...completed.all.e2e, ...build];
		},
		/Foreign source/
	],
	[
		'an E2E receipt from another source',
		() => {
			const e2e = structuredClone(completed.all.e2e);
			e2e[0].context.source_sha = 'b'.repeat(40);
			return [...e2e, ...completed.all.build];
		},
		/Foreign source/
	],
	[
		'a Build receipt over another Unit history',
		() => {
			const build = structuredClone(completed.all.build);
			for (const row of build) row.prior[0].cells[0].host.architecture = 'x64';
			return [...completed.all.e2e, ...build];
		},
		/Conflicting predecessor/
	],
	[
		'a Build receipt with no Unit predecessor',
		() => {
			const build = structuredClone(completed.all.build);
			build[0].prior = [];
			return [...completed.all.e2e, ...build];
		},
		/prior stage/
	],
	[
		'a Build receipt claiming an E2E predecessor',
		() => {
			const build = structuredClone(completed.all.build);
			build[0].prior.push(structuredClone(completed.all.testbuild[0].prior[1]));
			return [...completed.all.e2e, ...build];
		},
		/prior stage/
	]
])
	check('test-build admission refuses ' + name, () => {
		const rows = receipts();
		assert.throws(() => admitTestbuild(rows), pattern);
	});
check('test-build admission refuses a missing or failed predecessor aggregate', () => {
	const receipts = [...completed.all.e2e, ...completed.all.build];
	assert.throws(() => admitTestbuild(receipts, { launch: { result: 'success' } }), /Closed stage/);
	assert.throws(
		() => admitTestbuild(receipts, { 'package-macos': { result: 'success' } }),
		/Closed stage/
	);
	assert.throws(
		() => admitTestbuild(receipts, { 'e2e-hs': { result: 'success' } }),
		/Closed stage/
	);
});
check('a rerun of E2E alone keeps the earlier Build and still admits', () => {
	const e2e = completed.all.e2e.map((row) => ({ ...structuredClone(row), attempt: 2 }));
	const proof = admitTestbuild([...e2e, ...completed.all.build], needsOf('testbuild'), context, 2);
	assert.deepEqual(
		proof.chain.map((row) => [row.stage, Math.max(...row.cells.map((cell) => cell.attempt))]),
		[
			['unit', 1],
			['e2e', 2],
			['build', 1]
		]
	);
	const receipt = roles.record(
		'testbuild',
		roles.plan('testbuild', context)[0],
		'success',
		proof,
		context,
		host(roles.plan('testbuild', context)[0]),
		2
	);
	assert.deepEqual(receipt.prior, proof.chain);
});
check('a Build older than its Unit predecessor is a backward lineage', () => {
	const unit = completed.all.unit.map((row) => ({ ...structuredClone(row), attempt: 2 }));
	const prior = roles.admit(
		'build',
		undefined,
		undefined,
		needsOf('build'),
		context,
		2,
		() => unit
	);
	assert.throws(
		() =>
			roles.validateChain(
				[
					...prior.chain,
					{ stage: 'e2e', cells: structuredClone(completed.proof.chain[1].cells) },
					{ stage: 'build', cells: structuredClone(completed.proof.chain[2].cells) }
				],
				'testbuild',
				context
			),
		/Backward predecessor attempt lineage/
	);
});
assert.equal(controls, 189, 'all prior 175 controls and fourteen stage graph controls execute');

// Launch lots: four launch jobs beside the cold bootstrap, each scenario once.
function checkLaunchLotLoop(workflow) {
	const steps = workflow.jobs.launch.steps.filter((step) =>
		(step.if ?? '').includes("env.MACOS_STAGE_ROLE == 'launch'")
	);
	const names = steps.map((step) => step.name);
	const fresh = names.indexOf('Record the fresh runner state before the first launch');
	const loop = names.indexOf('Install, launch and judge every scenario of the lot');
	assert.ok(fresh >= 0 && loop === fresh + 1, 'the fresh runner is recorded right before the lot');
	assert.match(steps[fresh].run, /macos_launch_reset_test\.py\n/);
	assert.match(
		steps[fresh].run,
		/macos_launch_reset\.py snapshot "\$RUNNER_TEMP\/launch-fresh-runner\.json"/
	);
	const run = steps[loop].run;
	assert.match(run, /read -r -a scenarios <<< "\$\{MACOS_STAGE_SCENARIO\/\/__\/ \}"/);
	const body = run.slice(run.indexOf('for scenario in "${scenarios[@]}"; do'));
	// The scenario runs with errexit in its own subshell; its failure is recorded, not fatal.
	assert.match(
		body,
		/\n\s+set \+e\n\s+\(set -euo pipefail; launch_one "\$scenario"\)\n\s+scenario_status=\$\?\n\s+set -e\n/
	);
	// The reset runs after every scenario, outside the scenario's own failure.
	assert.match(
		body,
		/scenario_status=\$\?[\s\S]*python3 tools\/diagnostics\/macos_launch_reset\.py restore "\$RUNNER_TEMP\/launch-fresh-runner\.json"\ndone\nexit "\$lot_status"/
	);
	for (const command of [
		'--ci-install "$RUNNER_TEMP/package" /Applications "$stamp"',
		'--scope macos-launch-appleevents',
		'python3 tools/diagnostics/macos_launch_gate.py /Applications/ErgoptiPlus.app',
		'node tools/test/desktop-ci-evidence.cjs record-macos'
	])
		assert.equal(run.split(command).length, 2, command + ' runs once per scenario');
	assert.ok(!names.includes('Install the package the way a user does'));
}
check(
	'launch lots run every scenario once, four jobs at a time, from a proved fresh runner',
	() => {
		for (const [scenarios, runners, sizes] of [
			[context.scenarios, 1, [1, 1, 1]],
			[Array.from({ length: 11 }, (_, index) => 's' + index), 1, [3, 3, 2, 3]],
			[Array.from({ length: 13 }, (_, index) => 's' + index), 2, [7, 6]],
			[['clean'], 2, [1]]
		]) {
			const lots = roles.launchLots(scenarios, runners);
			assert.deepEqual(
				lots.map((lot) => lot.length),
				sizes
			);
			assert.deepEqual(lots.flat(), scenarios);
		}
		assert.throws(() => roles.launchLots(['a__b'], 1), /lot separator/);
		assert.throws(() => roles.launchLots(['clean'], 3), /runner count/);
		for (const release of [false, true]) {
			const cells = roles.plan('testbuild', { ...context, release });
			const launches = cells.filter((cell) => cell.role === 'launch');
			assert.ok(launches.length <= 4, 'at most four launch jobs');
			assert.deepEqual(
				launches.flatMap((cell) => [cell.runner + '/' + roles.lotScenarios(cell.scenario)].flat()),
				launches.map((cell) => cell.runner + '/' + roles.lotScenarios(cell.scenario))
			);
			for (const runner of release ? ['macos-15', 'macos-15-intel'] : ['macos-15'])
				assert.deepEqual(
					launches
						.filter((cell) => cell.runner === runner)
						.flatMap((cell) => roles.lotScenarios(cell.scenario)),
					context.scenarios
				);
		}
		const workflow = YAML.parse(
			require('./ci-pipeline.cjs').file('.github/workflows/ci-macos.yml')
		);
		checkLaunchLotLoop(workflow);
		const loopName = 'Install, launch and judge every scenario of the lot';
		for (const [label, mutate] of [
			[
				'no reset after a scenario',
				(run) =>
					run.replace(
						'\n  python3 tools/diagnostics/macos_launch_reset.py restore "$RUNNER_TEMP/launch-fresh-runner.json"',
						''
					)
			],
			['a scenario failure that stops the reset', (run) => run.replace('set +e\n', '')],
			[
				'one scenario per job',
				(run) => run.replace('${MACOS_STAGE_SCENARIO//__/ }', '$MACOS_STAGE_SCENARIO')
			]
		]) {
			const mutated = structuredClone(workflow);
			const step = mutated.jobs.launch.steps.find((candidate) => candidate.name === loopName);
			const before = step.run;
			step.run = mutate(step.run);
			assert.notEqual(step.run, before, label + ' must change the workflow');
			assert.throws(() => checkLaunchLotLoop(mutated), undefined, label);
		}
	}
);
assert.equal(controls, 190, 'all prior 189 controls and the launch lot control execute');

// Every macOS cell, job and repeated step states its macOS version from HOSTS.
check('macOS cells name their version from one host table and refuse another', () => {
	assert.deepEqual(
		Object.fromEntries(Object.entries(roles.HOSTS).map(([key, host]) => [key, host.runner])),
		{ stubbed: 'ubuntu-latest', arm64: 'macos-15', amd64: 'macos-15-intel', host: 'macos-latest' }
	);
	const ctx = { ...context, event_name: 'workflow_dispatch' };
	for (const stage of ['e2e', 'testbuild']) {
		const displayed = roles.displayPlan(stage, ctx);
		for (const lot of displayed.matrix.lot) {
			const selected = displayed.metadata[lot];
			assert.equal(selected.runner, roles.HOSTS[selected.architecture].runner);
			if (roles.HOSTS[selected.architecture].macos)
				assert.ok(lot.includes(roles.macosName(selected.architecture)), lot + ' names its macOS');
		}
	}
	const build = roles.plan('build', context)[0];
	const workflow = YAML.parse(require('./ci-pipeline.cjs').file('.github/workflows/ci-macos.yml'));
	const packaging = workflow.jobs['package-macos'];
	assert.equal(packaging['runs-on'], build.runner);
	// GitHub renders 'macOS / Build / ErgoptiPlus.app (macOS 26)': the stage job
	// in its own file states the version, its caller names the stage.
	assert.equal(packaging.name, 'Build');
	const stage = YAML.parse(
		require('./ci-pipeline.cjs').real().file('.github/workflows/ci-macos-build.yml')
	).jobs['package-macos'];
	assert.equal(stage.name, 'ErgoptiPlus.app (' + roles.macosName(build.architecture) + ')');
	assert.ok(
		packaging.steps.some(
			(step) => step.name === 'Run Swift launcher tests on ' + roles.macosName(build.architecture)
		),
		'the repeated Swift run names its macOS'
	);
	const source = require('./ci-pipeline.cjs').file('.github/workflows/ci-macos.yml');
	assert.match(
		source,
		/deliberate cross-version coverage, not\n# duplicated work; do not deduplicate it\./
	);
	roles.confirmMacosVersion(build, '26.0.1');
	roles.confirmMacosVersion({ runner: 'macos-15-intel' }, '15.7');
	for (const [selected, version] of [
		[build, '15.6'],
		[{ runner: 'macos-15' }, '26.0'],
		[{ runner: 'ubuntu-latest' }, '15.6'],
		[build, 'Sequoia'],
		[build, '']
	])
		assert.throws(() => roles.confirmMacosVersion(selected, version));
});
assert.equal(controls, 191, 'all prior 190 controls and the macOS version control execute');

console.log('macos-stage-roles: ' + controls + ' controls passed');
