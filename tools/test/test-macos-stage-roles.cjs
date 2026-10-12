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
console.log('macos-stage-roles: ' + controls + ' controls passed');
