// tools/test/fixtures/common-unit-admission-controls.cjs

/** Recording-only controls for the canonical source plan and actual Unit writer census. */
'use strict';

const assert = require('node:assert/strict');
const { createPlan, admitPlan, selectPlannedLot } = require('../../ci/js-feature-matrix.cjs');
const { selectUnitJobs, receiveUnit } = require('../../ci/validate-js-feature-results.cjs');

/** Exercise the real admission functions without a Git, network or child-process actor. */
async function run() {
	let controls = 0;
	const inventory = { digest: 'b'.repeat(64), features: ['menus', 'input'], checks: [] };
	const context = { source: 'a'.repeat(40), ref: 'refs/heads/feature/example' };
	const plan = createPlan(inventory, context),
		encoded = JSON.stringify(plan);
	assert.deepEqual(admitPlan(inventory, context, encoded), plan);
	controls++;
	for (const lot of plan.matrix.lot)
		assert.deepEqual(selectPlannedLot(inventory, context, lot, encoded), plan.metadata[lot]);
	controls++;
	for (const mutate of [
		(p) => {
			p.source_sha = 'c'.repeat(40);
		},
		(p) => {
			p.ref = 'refs/heads/main';
		},
		(p) => {
			p.inventory_sha256 = 'd'.repeat(64);
		},
		(p) => {
			p.matrix.lot.pop();
		},
		(p) => {
			p.metadata.Menus.feature = 'input';
		},
		(p) => {
			delete p.metadata.Menus;
		},
		(p) => {
			p.metadata.Foreign = p.metadata.Menus;
		},
		(p) => {
			p.extra = true;
		}
	]) {
		const changed = structuredClone(plan);
		mutate(changed);
		assert.throws(
			() => admitPlan(inventory, context, JSON.stringify(changed)),
			/complete authored inventory/
		);
		controls++;
	}
	for (const missing of [undefined, '', '{}', encoded.replace('{', '{"schema_version":0,')]) {
		assert.throws(() => admitPlan(inventory, context, missing), /complete authored inventory/);
		controls++;
	}
	assert.throws(
		() => selectPlannedLot(inventory, context, 'foreign', encoded),
		/Unknown Common lot/
	);
	controls++;
	const identity = { head_sha: context.source, run_id: '123', run_attempt: '2' };
	const jobs = plan.matrix.lot.map((lot, index) => ({
		id: index + 1,
		run_id: 123,
		run_attempt: 2,
		head_sha: context.source,
		name: 'YAML, shared code & web / Unit tests (' + lot + ')',
		status: 'completed',
		conclusion: 'success',
		steps: [{ name: 'Run shared validation suite', status: 'completed', conclusion: 'success' }]
	}));
	assert.equal(Object.keys(selectUnitJobs(plan, jobs, identity)).length, 4);
	controls++;
	const retained = structuredClone(jobs);
	retained[0].run_attempt = 1;
	assert.equal(selectUnitJobs(plan, retained, identity).menus.run_attempt, '1');
	controls++;
	const older = { ...structuredClone(jobs[0]), id: 99, run_attempt: 1, conclusion: 'failure' };
	assert.equal(selectUnitJobs(plan, [...jobs, older], identity).menus.run_attempt, '2');
	controls++;
	// The refusal must identify the exact API observation, without copying arbitrary step text.
	for (const mutate of [
		(job) => {
			delete job.steps;
		},
		(job) => {
			job.steps = [];
		},
		(job) => {
			job.steps[0].status = 'in_progress';
		},
		(job) => {
			job.steps[0].conclusion = 'failure';
		},
		(job) => {
			job.steps[0].conclusion = 'skipped';
		},
		(job) => {
			job.steps.push(structuredClone(job.steps[0]));
		},
		(job) => {
			job.steps = Array.from({ length: 4 }, () => structuredClone(job.steps[0]));
		},
		(job) => {
			delete job.steps[0].status;
		},
		(job) => {
			job.steps[0].conclusion = null;
		}
	]) {
		const changed = structuredClone(jobs);
		changed[0].steps[0].number = 17;
		changed[0].steps.push({
			name: 'Private unrelated step text',
			status: 'completed',
			conclusion: 'success'
		});
		mutate(changed[0]);
		assert.throws(
			() => selectUnitJobs(plan, changed, identity),
			(error) => {
				const prefix = 'Common Unit admission refused: missing or failed Unit writer: ';
				assert.ok(error.message.startsWith(prefix));
				const detail = JSON.parse(error.message.slice(prefix.length));
				const writers =
					changed[0].steps?.filter((step) => step.name === 'Run shared validation suite') || [];
				assert.equal(detail.lot, changed[0].name);
				assert.equal(detail.feature, 'menus');
				assert.equal(detail.suite, 'js');
				assert.equal(detail.job_id, '1');
				assert.equal(detail.run_attempt, '2');
				assert.equal(detail.writer_count, writers.length);
				assert.equal(detail.writers_truncated, writers.length > 3);
				assert.deepEqual(
					detail.writers,
					writers.slice(0, 3).map((step) => ({
						number: 17,
						status: typeof step.status === 'string' ? step.status : null,
						conclusion: typeof step.conclusion === 'string' ? step.conclusion : null
					}))
				);
				assert.ok(!error.message.includes('Private unrelated step text'));
				return true;
			}
		);
		controls++;
	}
	for (const mutate of [
		(j) => {
			j.pop();
		},
		(j) => {
			j[0].name = 'Common / Unit tests (Menus)';
		},
		(j) => {
			j[0].name = 'YAML, shared code & web / Unit tests (foreign)';
		},
		(j) => {
			j[0].head_sha = 'c'.repeat(40);
		},
		(j) => {
			j[0].run_id = 124;
		},
		(j) => {
			j[0].run_attempt = 3;
		},
		(j) => {
			j[0].run_attempt = 0;
		},
		(j) => {
			j[0].conclusion = 'failure';
		},
		(j) => {
			j[0].status = 'in_progress';
		},
		(j) => {
			j[0].steps = [];
		},
		(j) => {
			j[0].steps[0].conclusion = 'skipped';
		},
		(j) => {
			j[0].steps.push(structuredClone(j[0].steps[0]));
		},
		(j) => {
			j.push({ ...structuredClone(j[0]), id: 90 });
		},
		(j) => {
			j.push(structuredClone(j[0]));
		},
		(j) => {
			j.push({ ...structuredClone(j[0]), id: 90, run_attempt: 1 });
			j[0].conclusion = 'failure';
		},
		(j) => {
			j.push({ ...structuredClone(j[0]), id: 90, name: 'Foreign writer' });
		}
	]) {
		const changed = structuredClone(jobs);
		mutate(changed);
		assert.throws(() => selectUnitJobs(plan, changed, identity), /Common Unit admission refused/);
		controls++;
	}
	for (const result of ['', undefined, 'failure', 'cancelled', 'skipped']) {
		let calls = 0;
		await assert.rejects(
			() =>
				receiveUnit(
					inventory,
					{ COMMON_PREDECESSOR_RESULT: result },
					() => {
						calls++;
					},
					() => {
						calls++;
					}
				),
			/matrix did not succeed/
		);
		assert.equal(calls, 0);
		controls++;
	}
	let calls = 0;
	await assert.rejects(
		() =>
			receiveUnit(
				inventory,
				{
					COMMON_PREDECESSOR_RESULT: 'success',
					GITHUB_SHA: context.source,
					GITHUB_REF: context.ref,
					COMMON_PLAN: '{}'
				},
				() => {
					calls++;
				},
				() => {
					calls++;
				}
			),
		/complete authored inventory/
	);
	assert.equal(calls, 0);
	controls++;
	const { fixture, reader } = require('./site-deploy-admission-controls.cjs');
	const actualEnv = {
		GITHUB_ACTIONS: 'true',
		GITHUB_REPOSITORY: 'adrienm7/ergopti',
		GITHUB_REPOSITORY_ID: '11',
		GITHUB_WORKFLOW: 'CI',
		GITHUB_EVENT_NAME: 'push',
		GITHUB_SHA: context.source,
		GITHUB_REF: context.ref,
		GITHUB_RUN_ID: '123',
		GITHUB_RUN_ATTEMPT: '2',
		COMMON_PREDECESSOR_RESULT: 'success',
		COMMON_PLAN: encoded
	};
	const model = () => {
		const value = fixture();
		value.jobs = structuredClone(jobs);
		value.run.status = 'in_progress';
		value.run.conclusion = null;
		return value;
	};
	const admitted = await receiveUnit(inventory, actualEnv, reader(model()).readApi, null);
	assert.equal(admitted.result, null);
	assert.equal(Object.keys(admitted.selected).length, 4);
	controls++;
	const singleInventory = {
		...inventory,
		checks: inventory.features.map((feature, index) => ({
			id: feature,
			feature,
			ordinal: index + 1,
			name: feature,
			repro: 'node fixture.cjs'
		}))
	};
	const evidence = () =>
		singleInventory.checks.map((check) => [
			{
				type: 'suite',
				platform: 'linux',
				schema_version: 1,
				suite: 'js',
				mode: 'feature',
				feature: check.feature,
				planned_count: 1,
				inventory_sha256: inventory.digest,
				ci_source_sha: context.source,
				ci_run_id: '123',
				ci_run_attempt: '2'
			},
			{
				type: 'start',
				ordinal: 1,
				check_id: check.id,
				global_ordinal: check.ordinal,
				name: check.name
			},
			{
				type: 'result',
				ordinal: 1,
				check_id: check.id,
				global_ordinal: check.ordinal,
				name: check.name,
				reproduce: check.repro,
				status: 'PASS',
				exit_code: 0,
				signal: null,
				error_code: null,
				duration_ms: 1
			},
			{
				type: 'complete',
				executed_count: 1,
				passed: 1,
				failed: 0,
				child_duration_ms: 1,
				duration_ms: 2
			}
		]);
	assert.equal(
		(await receiveUnit(singleInventory, actualEnv, reader(model()).readApi, evidence)).result
			.checks,
		2
	);
	controls++;
	const stale = evidence();
	stale[0][0].ci_run_attempt = '1';
	await assert.rejects(
		() => receiveUnit(singleInventory, actualEnv, reader(model()).readApi, () => stale),
		/highest actual Unit writer attempt/
	);
	controls++;
	const failed = model();
	failed.jobs[0].conclusion = 'failure';
	calls = 0;
	await assert.rejects(
		() =>
			receiveUnit(singleInventory, actualEnv, reader(failed).readApi, () => {
				calls++;
				return evidence();
			}),
		/did not succeed/
	);
	assert.equal(calls, 0);
	controls++;
	const changed = model();
	changed.finalRun = { ...changed.run, head_branch: 'changed' };
	await assert.rejects(
		() => receiveUnit(singleInventory, actualEnv, reader(changed).readApi, evidence),
		/identity changed/
	);
	controls++;
	return controls;
}

module.exports = { run };
