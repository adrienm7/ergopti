/*
 * tools/test/test-ci-stage-status.cjs
 * ============================================================================
 * Tests adjacent scheduler custody without executing workflows or native code.
 * ============================================================================
 */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const yaml = require('yaml');
const { complete, admitBuild } = require('../ci/ci-stage-status.cjs');

const current = { sourceSha: 'a'.repeat(40), runId: '123', attempt: '2', event: 'push' };
const names = {
	windows: ['test-ahk', 'e2e-ahk', 'package-windows', 'launch-windows'],
	linux: ['test-linux', 'e2e-linux', 'package-linux', 'install-linux']
};
let controls = 0;
function run(platform, results = {}) {
	let prior = { [names[platform][0]]: { result: results[0] || 'success', outputs: {} } };
	for (let index = 1; index < 4; index++) {
		const outputs = {
			ci_source_sha: current.sourceSha,
			ci_run_id: current.runId,
			ci_attempt: '1',
			ci_predecessors: JSON.stringify(prior)
		};
		if (platform === 'linux' && index === 1)
			outputs.ci_unit_result = prior[names[platform][0]].result;
		prior = { [names[platform][index]]: { result: results[index] || 'success', outputs } };
	}
	return prior;
}
function check(callback) {
	callback();
	controls++;
}
function refuse(value, platform = 'windows', ctx = current) {
	assert.throws(() => complete(platform, JSON.stringify(value), ctx));
}
for (const platform of Object.keys(names)) {
	check(() =>
		assert.deepEqual(
			complete(platform, JSON.stringify(run(platform)), current),
			Object.fromEntries(names[platform].map((name) => [name, { result: 'success' }]))
		)
	);
	for (const result of ['failure', 'cancelled', 'skipped', 'unknown'])
		for (let index = 0; index < 4; index++)
			check(() => refuse(run(platform, { [index]: result }), platform));
	for (const field of ['ci_source_sha', 'ci_run_id', 'ci_attempt', 'ci_predecessors']) {
		check(() => {
			const value = run(platform);
			delete value[names[platform][3]].outputs[field];
			refuse(value, platform);
		});
	}
	check(() => {
		const value = run(platform);
		value[names[platform][3]].outputs.ci_source_sha = 'b'.repeat(40);
		refuse(value, platform);
	});
	check(() => {
		const value = run(platform);
		value[names[platform][3]].outputs.ci_run_id = '124';
		refuse(value, platform);
	});
	check(() => {
		const value = run(platform);
		value[names[platform][3]].outputs.ci_attempt = '3';
		refuse(value, platform);
	});
	check(() => {
		const value = run(platform);
		value[names[platform][3]].outputs.ci_predecessors = '';
		refuse(value, platform);
	});
	check(() => {
		const value = run(platform);
		value[names[platform][3]].outputs.ci_predecessors = '{';
		refuse(value, platform);
	});
	check(() => {
		const value = run(platform);
		value[names[platform][3]].outputs.foreign = 'success';
		refuse(value, platform);
	});
	check(() => {
		const value = run(platform);
		value.foreign = value[names[platform][3]];
		refuse(value, platform);
	});
}
check(() => {
	const value = run('linux', { 1: 'failure' });
	const packageJob = JSON.parse(value['install-linux'].outputs.ci_predecessors)['package-linux'];
	const beforeBuild = packageJob.outputs.ci_predecessors;
	assert.throws(() => admitBuild('linux', beforeBuild, current));
	assert.equal(
		admitBuild('linux', beforeBuild, { ...current, event: 'workflow_dispatch' })['e2e-linux']
			.result,
		'failure'
	);
	refuse(value, 'linux', { ...current, event: 'workflow_dispatch' });
});
check(() => {
	const value = run('linux', { 0: 'failure', 1: 'failure' });
	const beforeBuild = JSON.parse(value['install-linux'].outputs.ci_predecessors)['package-linux']
		.outputs.ci_predecessors;
	assert.throws(() => admitBuild('linux', beforeBuild, { ...current, event: 'workflow_dispatch' }));
});
check(() => {
	const value = run('windows');
	value['launch-windows'].outputs.ci_attempt = '1';
	const prior = JSON.parse(value['launch-windows'].outputs.ci_predecessors);
	prior['package-windows'].outputs.ci_attempt = '2';
	value['launch-windows'].outputs.ci_predecessors = JSON.stringify(prior);
	refuse(value);
});
check(() =>
	assert.throws(() => complete('windows', '{"launch-windows":{},"launch-windows":{}}', current))
);
check(() =>
	assert.throws(() =>
		complete('windows', '{"launch-windows":{},"launch-\\u0077indows":{}}', current)
	)
);
check(() => {
	const value = run('windows');
	value['launch-windows'].outputs.ci_predecessors = '{"package-windows":{},"package-windows":{}}';
	refuse(value);
});
check(() => {
	const value = run('linux');
	const packageJob = JSON.parse(value['install-linux'].outputs.ci_predecessors);
	const e2e = JSON.parse(packageJob['package-linux'].outputs.ci_predecessors);
	e2e['e2e-linux'].outputs.ci_unit_result = 'failure';
	packageJob['package-linux'].outputs.ci_predecessors = JSON.stringify(e2e);
	value['install-linux'].outputs.ci_predecessors = JSON.stringify(packageJob);
	refuse(value, 'linux');
});
check(() => {
	const value = run('windows');
	value['launch-windows'].outputs.ci_attempt = '2';
	assert.equal(complete('windows', JSON.stringify(value), current)['test-ahk'].result, 'success');
	value['launch-windows'].result = 'failure';
	refuse(value);
});
check(() => {
	const value = run('windows');
	function attempt(direct) {
		const job = Object.values(direct)[0];
		if (!Object.hasOwn(job.outputs, 'ci_attempt')) return;
		job.outputs.ci_attempt = '2';
		const prior = JSON.parse(job.outputs.ci_predecessors);
		attempt(prior);
		job.outputs.ci_predecessors = JSON.stringify(prior);
	}
	attempt(value);
	assert.equal(
		complete('windows', JSON.stringify(value), current)['launch-windows'].result,
		'success'
	);
});

// The source predicate consumes genuine outputs, never a modeled success flag.
const root = path.resolve(__dirname, '../..');
function validateWorkflow(platform, workflow) {
	for (let index = 1; index < 4; index++) {
		const job = workflow.jobs[names[platform][index]];
		assert.deepEqual(job.needs, [names[platform][index - 1]]);
		assert.deepEqual(
			Object.keys(job.outputs).sort(),
			[
				...['ci_attempt', 'ci_predecessors', 'ci_run_id', 'ci_source_sha'],
				...(platform === 'linux' && index === 1 ? ['ci_unit_result'] : [])
			].sort()
		);
		assert.equal(job.outputs.ci_predecessors, '${{ toJSON(needs) }}');
		assert.equal(job.outputs.ci_source_sha, '${{ github.sha }}');
		assert.equal(job.outputs.ci_run_id, '${{ github.run_id }}');
		assert.equal(job.outputs.ci_attempt, '${{ github.run_attempt }}');
	}
	const verdict = workflow.jobs[platform + '-ok'];
	assert.deepEqual(verdict.needs, [names[platform][3]]);
	assert.equal(verdict.if, 'always()');
	assert.ok(
		verdict.steps.some((step) =>
			(step.run || '').includes('ci-stage-status.cjs complete ' + platform)
		)
	);
	const build = workflow.jobs[names[platform][2]];
	assert.ok(
		build.steps.some(
			(step) =>
				step.run === 'node tools/ci/ci-stage-status.cjs admit-build ' + platform &&
				step.env?.NEEDS === '${{ toJSON(needs) }}'
		)
	);
	if (platform === 'linux') {
		assert.equal(
			workflow.jobs['e2e-linux'].outputs.ci_unit_result,
			'${{ needs.test-linux.result }}'
		);
		assert.equal(
			build.if,
			"${{ !cancelled() && needs.e2e-linux.outputs.ci_unit_result == 'success' && (needs.e2e-linux.result == 'success' || (github.event_name == 'workflow_dispatch' && needs.e2e-linux.result == 'failure')) }}"
		);
	}
}
for (const platform of Object.keys(names)) {
	const workflow = yaml.parse(
		fs.readFileSync(path.join(root, '.github/workflows/ci-' + platform + '.yml'), 'utf8')
	);
	validateWorkflow(platform, workflow);
	controls++;
	for (const mutate of [
		(value) => {
			value.jobs[names[platform][1]].outputs.ci_predecessors = '{"success":true}';
		},
		(value) => {
			value.jobs[names[platform][2]].needs.push(names[platform][0]);
		},
		(value) => {
			value.jobs[names[platform][3]].outputs.ci_source_sha = 'a'.repeat(40);
		},
		(value) => {
			value.jobs[names[platform][1]].outputs.ci_run_id = '123';
		},
		(value) => {
			value.jobs[platform + '-ok'].if = 'success()';
		},
		(value) => {
			value.jobs[names[platform][2]].steps = value.jobs[names[platform][2]].steps.filter(
				(step) => !String(step.run).includes('ci-stage-status.cjs admit-build')
			);
		}
	])
		check(() => {
			const changed = structuredClone(workflow);
			mutate(changed);
			assert.throws(() => validateWorkflow(platform, changed));
		});
	if (platform === 'linux')
		check(() => {
			const changed = structuredClone(workflow);
			changed.jobs['e2e-linux'].outputs.ci_unit_result = 'success';
			assert.throws(() => validateWorkflow(platform, changed));
		});
}
console.log('Adjacent scheduler custody: ' + controls + ' controls passed');
