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
	for (const id of ['test-hs', 'e2e-hs', 'launch'])
		assert.equal(workflow.jobs[id].strategy['fail-fast'], false);
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
			['managed-ollama-native', 'macos-15-intel', 60]
		]
	);
});
check('manual nonrelease retains Item36 and both lease cells', () => {
	const ctx = { ...context, event_name: 'workflow_dispatch' };
	assert.deepEqual(
		roles
			.plan('e2e', ctx)
			.slice(4)
			.map((cell) => [cell.role, cell.runner, cell.timeout_minutes]),
		[
			['item36-native', 'macos-latest', 25],
			['lease-silence-native', 'macos-15', 20],
			['lease-silence-native', 'macos-15-intel', 20]
		]
	);
	assert.equal(complete(ctx).proof.chain[1].cells.length, 7);
});
check('release launch preserves both arches and every canonical supplied scenario', () => {
	const ctx = { ...context, release: true, event_name: 'workflow_dispatch' };
	assert.equal(roles.plan('e2e', ctx).length, 4);
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
		assert.deepEqual(roles.readReceipts(directory), completed.all.unit);
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

assert.equal(controls, 84, 'all original stage and receipt controls remain present');
check('Unit has one truthful display axis and the unchanged complete cell', () => {
	assert.deepEqual(roles.displayPlan('unit', context), {
		matrix: { lot: ['Lua unit and meta (stubbed)'] },
		metadata: {
			'Lua unit and meta (stubbed)': {
				role: 'lua-unit-meta',
				runner: 'ubuntu-latest',
				architecture: 'stubbed',
				timeout_minutes: 360,
				scenario: ''
			}
		}
	});
	assert.deepEqual(
		roles.selectUnitLot('Lua unit and meta (stubbed)', context),
		roles.plan('unit', context)[0]
	);
	for (const name of [
		undefined,
		'lua-unit-meta',
		'Lua unit and meta',
		'Lua unit and meta (native)'
	])
		assert.throws(() => roles.selectUnitLot(name, context), /Missing or foreign human lot/);
});
check('E2E human lots retain native architectures and scoped manual roles', () => {
	const push = [
		'Virtual-keyboard replay (stubbed)',
		'Tooltip canvas (Apple silicon)',
		'Managed Ollama (Apple silicon)',
		'Managed Ollama (Intel)'
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
assert.equal(controls, 138, 'original controls and human lot transport controls all execute');
check('role labels retain the independent authored human names without runtime metadata', () => {
	for (const [stage, role, architecture, scenario, expected] of [
		['unit', 'lua-unit-meta', 'stubbed', '', 'Lua unit and meta (stubbed)'],
		['e2e', 'e2e-hs', 'stubbed', '', 'Virtual-keyboard replay (stubbed)'],
		['e2e', 'tooltip-canvas', 'arm64', '', 'Tooltip canvas (Apple silicon)'],
		['e2e', 'managed-ollama-native', 'arm64', '', 'Managed Ollama (Apple silicon)'],
		['e2e', 'managed-ollama-native', 'amd64', '', 'Managed Ollama (Intel)'],
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
assert.equal(controls, 141, 'all original, human lot transport and role-label controls execute');
console.log('macos-stage-roles: ' + controls + ' controls passed');
