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
function complete(ctx = context, attempt = 1) {
	let proof = { context: ctx, chain: [] };
	const all = {};
	for (const stage of roles.STAGES) {
		all[stage] = roles
			.plan(stage, ctx)
			.map((cell) => roles.record(stage, cell, 'success', proof, ctx, host(cell), attempt));
		proof = roles.union(stage, all[stage], 'success', ctx, attempt);
	}
	return { all, proof };
}
const completed = complete();
check('exact five visible jobs with only immediate predecessor edges', () => {
	const workflow = YAML.parse(
		fs.readFileSync(path.resolve(__dirname, '../../.github/workflows/ci-macos.yml'), 'utf8')
	);
	const jobs = ['test-hs', 'e2e-hs', 'package-macos', 'launch', 'macos-ok'];
	assert.deepEqual(Object.keys(workflow.jobs), jobs);
	for (const [index, id] of jobs.entries()) {
		assert.deepEqual(workflow.jobs[id].needs || [], index === 0 ? [] : [jobs[index - 1]]);
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
		roles.plan('e2e', context).map((cell) => [cell.role, cell.runner, cell.timeout_minutes]),
		[
			['e2e-hs', 'ubuntu-latest', 360],
			['tooltip-canvas', 'macos-15', 10],
			['managed-ollama-native', 'macos-15', 60],
			['managed-ollama-native', 'macos-15-intel', 60],
			['managed-ollama-build', 'macos-15', 60],
			['managed-ollama-build', 'macos-15-intel', 60]
		]
	);
});
check('manual nonrelease retains Item36 and both lease cells', () => {
	const ctx = { ...context, event_name: 'workflow_dispatch' };
	assert.deepEqual(
		roles
			.plan('e2e', ctx)
			.slice(6)
			.map((cell) => [cell.role, cell.runner, cell.timeout_minutes]),
		[
			['item36-native', 'macos-latest', 25],
			['lease-silence-native', 'macos-15', 20],
			['lease-silence-native', 'macos-15-intel', 20]
		]
	);
	assert.equal(complete(ctx).proof.chain[1].cells.length, 9);
});
check('release launch preserves both arches and every canonical supplied scenario', () => {
	const ctx = { ...context, release: true, event_name: 'workflow_dispatch' };
	assert.equal(roles.plan('e2e', ctx).length, 6);
	assert.deepEqual(
		roles
			.plan('testbuild', ctx)
			.map((cell) => [cell.role, cell.runner, cell.scenario, cell.timeout_minutes]),
		[
			...['macos-15', 'macos-15-intel'].flatMap((runner) =>
				context.scenarios.map((scenario) => ['launch', runner, scenario, 12])
			),
			['cold-bootstrap-native', 'macos-15', '', 90]
		]
	);
	assert.equal(complete(ctx).proof.chain[3].cells.length, 7);
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
	const source = fs.readFileSync(
		path.resolve(__dirname, '../../.github/workflows/ci-macos.yml'),
		'utf8'
	);
	const scoped = require('./fixtures/ci-scoped-full-branches.cjs');
	const projected = scoped.projectScopedSteps(source, '.github/workflows/ci-macos.yml');
	assert.ok(projected.length > 0 && projected !== source);
});

// One more than the single-cell Unit: a duplicate Unit row now replaces a mandatory group.
assert.equal(controls, 85, 'all original stage and receipt controls remain present');
check('Unit lots are the module groups, each one complete stubbed cell', () => {
	const groups = roles.unitGroups();
	assert.deepEqual(groups, ['meta', 'core', 'modules', 'menu_llm', 'menu_input', 'ui', 'other']);
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
		'Tooltip canvas (Apple silicon)',
		'Managed Ollama (Apple silicon)',
		'Managed Ollama (Intel)',
		'Managed Ollama build (Apple silicon)',
		'Managed Ollama build (Intel)'
	];
	assert.deepEqual(roles.displayPlan('e2e', context).matrix, { lot: push });
	assert.deepEqual(
		roles.displayPlan('e2e', { ...context, event_name: 'workflow_dispatch' }).matrix,
		{
			lot: [
				...push,
				'Archive update controls',
				'Lease silence (Apple silicon)',
				'Lease silence (Intel)'
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
			'Installed app: clean (Apple silicon)',
			'Installed app: karabiner config (Apple silicon)',
			'Installed app: upgraded (Apple silicon)',
			'Cold native bootstrap (Apple silicon)'
		]
	});
	assert.deepEqual(roles.displayPlan('testbuild', { ...context, release: true }).matrix, {
		lot: [
			'Installed app: clean (Apple silicon)',
			'Installed app: karabiner config (Apple silicon)',
			'Installed app: upgraded (Apple silicon)',
			'Installed app: clean (Intel)',
			'Installed app: karabiner config (Intel)',
			'Installed app: upgraded (Intel)',
			'Cold native bootstrap (Apple silicon)'
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
			/regular expression/
		);
		assert.throws(() => roles.displayPlan('build', context), /no human lot matrix/);
	}
);
const lotContext = { ...context, event_name: 'workflow_dispatch', release: true };
const lotStage = 'testbuild';
const lotPlan = roles.displayPlan(lotStage, lotContext);
const selectedLot = 'Installed app: clean (Apple silicon)';
for (const [name, mutate] of [
	['missing selected lot', (map) => delete map[selectedLot]],
	['missing unselected lot', (map) => delete map['Installed app: clean (Intel)']],
	['foreign lot alias', (map) => (map.foreign = structuredClone(map[selectedLot]))],
	[
		'duplicate cell under another authored lot',
		(map) => (map['Installed app: clean (Intel)'] = structuredClone(map[selectedLot]))
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
for (const [priorStage, receiver] of [
	['unit', 'e2e'],
	['build', 'testbuild']
]) {
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
				roles.admit(priorStage, displayed.matrix.lot[0], metadata, needs, context, 1, () => {
					reads++;
					return completed.all[priorStage];
				}),
			/Complete human lot metadata map differs/
		);
		assert.equal(reads, 0);
	});
}
for (const [index, stage] of ['unit', 'e2e', 'build'].entries()) {
	const receiver = roles.STAGES[index + 1];
	const displayed = receiver === 'build' ? undefined : roles.displayPlan(receiver, context);
	const lot = displayed?.matrix.lot[0];
	check(stage + ' admission retains aggregate custody and the exact prior proof', () => {
		let reads = 0;
		const proof = roles.admit(
			stage,
			lot,
			displayed?.metadata,
			{ [roles.JOBS[index]]: { result: 'success' } },
			context,
			1,
			() => {
				reads++;
				return completed.all[stage];
			}
		);
		assert.deepEqual(proof, roles.union(stage, completed.all[stage], 'success', context, 1));
		assert.equal(reads, 1);
	});
	for (const result of ['failure', 'cancelled', 'skipped'])
		check(stage + ' lot admission preserves ' + result + ' aggregate refusal before read', () => {
			let reads = 0;
			assert.throws(
				() =>
					roles.admit(
						stage,
						lot,
						displayed?.metadata,
						{ [roles.JOBS[index]]: { result } },
						context,
						1,
						() => {
							reads++;
							return completed.all[stage];
						}
					),
				/Direct predecessor aggregate/
			);
			assert.equal(reads, 0);
		});
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
				'Managed Ollama (Apple silicon)',
				displayed.metadata
			),
		/Selected human lot and receipt cell differ/
	);
});
assert.equal(controls, 139, 'original controls and human lot transport controls all execute');
check('role labels retain the independent authored human names without runtime metadata', () => {
	for (const [stage, role, architecture, scenario, expected] of [
		['unit', 'lua-unit-meta', 'stubbed', 'meta', 'meta'],
		['unit', 'lua-unit-meta', 'stubbed', 'other', 'other'],
		['e2e', 'e2e-hs', 'stubbed', '', 'Virtual-keyboard replay (stubbed)'],
		['e2e', 'tooltip-canvas', 'arm64', '', 'Tooltip canvas (Apple silicon)'],
		['e2e', 'managed-ollama-native', 'arm64', '', 'Managed Ollama (Apple silicon)'],
		['e2e', 'managed-ollama-native', 'amd64', '', 'Managed Ollama (Intel)'],
		['e2e', 'managed-ollama-build', 'arm64', '', 'Managed Ollama build (Apple silicon)'],
		['e2e', 'managed-ollama-build', 'amd64', '', 'Managed Ollama build (Intel)'],
		['e2e', 'item36-native', 'host', '', 'Archive update controls'],
		['e2e', 'lease-silence-native', 'arm64', '', 'Lease silence (Apple silicon)'],
		['e2e', 'lease-silence-native', 'amd64', '', 'Lease silence (Intel)'],
		[
			'testbuild',
			'launch',
			'arm64',
			'karabiner_config',
			'Installed app: karabiner config (Apple silicon)'
		],
		['testbuild', 'launch', 'amd64', 'upgraded', 'Installed app: upgraded (Intel)'],
		['testbuild', 'cold-bootstrap-native', 'arm64', '', 'Cold native bootstrap (Apple silicon)']
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
assert.equal(controls, 142, 'all original, human lot transport and role-label controls execute');
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

const literalUnitSource = fs.readFileSync(
	path.resolve(__dirname, '../../.github/workflows/ci-macos.yml'),
	'utf8'
);
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
assert.equal(controls, 167, 'all prior 142 controls and 25 Unit matrix controls execute');

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
	174,
	'all prior 167 controls and seven managed native history controls execute'
);

console.log('macos-stage-roles: ' + controls + ' controls passed');
