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
const { loadPlan } = require('../ci/linux-install-matrix.cjs');
const installPlan = loadPlan(path.resolve(__dirname, '../..'));

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
		if (platform === 'linux' && index === 2) {
			outputs.install_matrix = JSON.stringify(installPlan.matrix);
			outputs.install_metadata = JSON.stringify(installPlan.metadata);
		}
		prior = { [names[platform][index]]: { result: results[index] || 'success', outputs } };
	}
	// The Linux Flatpak job runs beside the install job, from the same package job.
	if (platform === 'linux')
		prior['package-flatpak'] = {
			result: results.flatpak || 'success',
			outputs: {
				ci_source_sha: current.sourceSha,
				ci_run_id: current.runId,
				ci_attempt: '1',
				ci_predecessors: prior['install-linux'].outputs.ci_predecessors
			}
		};
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
			Object.fromEntries(
				[...names[platform], ...(platform === 'linux' ? ['package-flatpak'] : [])].map((name) => [
					name,
					{ result: 'success' }
				])
			)
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
// The Flatpak sibling is mandatory, genuine, and bound to the same package job.
for (const result of ['failure', 'cancelled', 'skipped', 'unknown'])
	check(() => refuse(run('linux', { flatpak: result }), 'linux'));
check(() => {
	const value = run('linux');
	delete value['package-flatpak'];
	refuse(value, 'linux');
});
for (const field of ['ci_source_sha', 'ci_run_id', 'ci_attempt', 'ci_predecessors'])
	check(() => {
		const value = run('linux');
		delete value['package-flatpak'].outputs[field];
		refuse(value, 'linux');
	});
check(() => {
	const value = run('linux');
	value['package-flatpak'].outputs.ci_source_sha = 'b'.repeat(40);
	refuse(value, 'linux');
});
check(() => {
	const value = run('linux');
	value['package-flatpak'].outputs.ci_run_id = '124';
	refuse(value, 'linux');
});
check(() => {
	const value = run('linux');
	value['package-flatpak'].outputs.ci_attempt = '3';
	refuse(value, 'linux');
});
check(() => {
	const value = run('linux');
	value['package-flatpak'].outputs.foreign = 'success';
	refuse(value, 'linux');
});
check(() => {
	const value = run('linux');
	const foreign = JSON.parse(value['package-flatpak'].outputs.ci_predecessors);
	foreign['package-linux'].outputs.ci_run_id = '999';
	value['package-flatpak'].outputs.ci_predecessors = JSON.stringify(foreign);
	refuse(value, 'linux');
});
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

// Runtime custody receives the same full Linux plan that the Package producer emits.
const lotControlStart = controls;
function changeStage(value, platform, index, mutate, cursor = 3) {
	const job = value[names[platform][cursor]];
	if (cursor === index) mutate(job.outputs);
	else {
		const prior = JSON.parse(job.outputs.ci_predecessors);
		changeStage(prior, platform, index, mutate, cursor - 1);
		job.outputs.ci_predecessors = JSON.stringify(prior);
	}
}
check(() => {
	const value = run('linux');
	const output = JSON.parse(value['install-linux'].outputs.ci_predecessors)['package-linux']
		.outputs;
	assert.equal(output.install_matrix, JSON.stringify(installPlan.matrix));
	assert.equal(output.install_metadata, JSON.stringify(installPlan.metadata));
	assert.equal(
		complete('linux', JSON.stringify(value), current)['package-linux'].result,
		'success'
	);
});
const matrix = (output, change) => {
	const value = JSON.parse(output.install_matrix);
	change(value);
	output.install_matrix = JSON.stringify(value);
};
const metadata = (output, change) => {
	const value = JSON.parse(output.install_metadata);
	change(value);
	output.install_metadata = JSON.stringify(value);
};
const packageMutations = [
	[
		'missing matrix',
		(output) => {
			delete output.install_matrix;
		},
		/custody keys/
	],
	[
		'missing metadata',
		(output) => {
			delete output.install_metadata;
		},
		/custody keys/
	],
	[
		'swapped fields',
		(output) => {
			[output.install_matrix, output.install_metadata] = [
				output.install_metadata,
				output.install_matrix
			];
		},
		/package matrix/
	],
	[
		'foreign output',
		(output) => {
			output.foreign = '{}';
		},
		/custody keys/
	],
	[
		'empty matrix',
		(output) => {
			output.install_matrix = '';
		},
		/package matrix/
	],
	[
		'empty metadata',
		(output) => {
			output.install_metadata = '';
		},
		/package metadata/
	],
	[
		'matrix must be transported string',
		(output) => {
			output.install_matrix = installPlan.matrix;
		},
		/package matrix/
	],
	[
		'metadata must be transported string',
		(output) => {
			output.install_metadata = installPlan.metadata;
		},
		/package metadata/
	],
	[
		'invalid matrix JSON',
		(output) => {
			output.install_matrix = '{';
		},
		/package matrix/
	],
	[
		'invalid metadata JSON',
		(output) => {
			output.install_metadata = '{';
		},
		/package metadata/
	],
	[
		'duplicate matrix field',
		(output) => {
			output.install_matrix = '{"lot":[],"lot":' + JSON.stringify(installPlan.matrix.lot) + '}';
		},
		/package matrix/
	],
	[
		'duplicate metadata field',
		(output) => {
			const [lot, cell] = Object.entries(installPlan.metadata)[0];
			output.install_metadata =
				'{' +
				JSON.stringify(lot) +
				':' +
				JSON.stringify(cell) +
				',' +
				output.install_metadata.slice(1);
		},
		/package metadata/
	],
	[
		'foreign lot',
		(output) =>
			matrix(output, (value) => {
				value.lot[0] = 'Foreign lot';
			}),
		/package matrix/
	],
	[
		'missing lot',
		(output) =>
			matrix(output, (value) => {
				value.lot.pop();
			}),
		/package matrix/
	],
	[
		'duplicate lot',
		(output) =>
			matrix(output, (value) => {
				value.lot.push(value.lot[0]);
			}),
		/package matrix/
	],
	[
		'reordered lots',
		(output) =>
			matrix(output, (value) => {
				value.lot.reverse();
			}),
		/package matrix/
	],
	[
		'foreign matrix axis',
		(output) =>
			matrix(output, (value) => {
				value.runner = ['ubuntu-latest'];
			}),
		/package matrix/
	],
	[
		'missing metadata member',
		(output) =>
			metadata(output, (value) => {
				delete value[Object.keys(value)[0]];
			}),
		/package metadata/
	],
	[
		'foreign metadata member',
		(output) =>
			metadata(output, (value) => {
				value['Foreign lot'] = Object.values(value)[0];
			}),
		/package metadata/
	],
	[
		'changed subject',
		(output) =>
			metadata(output, (value) => {
				Object.values(value)[0].id = 'foreign';
			}),
		/package metadata/
	],
	[
		'changed container',
		(output) =>
			metadata(output, (value) => {
				Object.values(value)[0].container = 'foreign:latest';
			}),
		/package metadata/
	],
	[
		'changed preparation',
		(output) =>
			metadata(output, (value) => {
				Object.values(value)[0].prep = 'true';
			}),
		/package metadata/
	],
	[
		'changed kind',
		(output) =>
			metadata(output, (value) => {
				Object.values(value)[0].kind = 'first';
			}),
		/package metadata/
	],
	[
		'changed image',
		(output) =>
			metadata(output, (value) => {
				Object.values(value)[0].image = 'foreign:latest';
			}),
		/package metadata/
	],
	[
		'foreign cell field',
		(output) =>
			metadata(output, (value) => {
				Object.values(value)[0].foreign = 'field';
			}),
		/package metadata/
	],
	[
		'reordered metadata',
		(output) => {
			output.install_metadata = JSON.stringify(
				Object.fromEntries(Object.entries(installPlan.metadata).reverse())
			);
		},
		/package metadata/
	],
	[
		'noncanonical matrix transport',
		(output) => {
			output.install_matrix += ' ';
		},
		/package matrix/
	],
	[
		'noncanonical metadata transport',
		(output) => {
			output.install_metadata += ' ';
		},
		/package metadata/
	]
];
assert.equal(packageMutations.length, 28, 'all whole-map transport refusals are registered');
for (const [label, mutate, reason] of packageMutations)
	check(() => {
		const value = run('linux');
		changeStage(value, 'linux', 2, mutate);
		assert.throws(() => complete('linux', JSON.stringify(value), current), reason, label);
	});
for (const platform of Object.keys(names))
	for (let index = 0; index < 4; index++) {
		if (platform === 'linux' && index === 2) continue;
		check(() => {
			const value = run(platform);
			changeStage(value, platform, index, (output) => {
				output.install_matrix = JSON.stringify(installPlan.matrix);
				output.install_metadata = JSON.stringify(installPlan.metadata);
			});
			assert.throws(
				() => complete(platform, JSON.stringify(value), current),
				/custody keys/,
				'Linux plan is reserved for its exact Package role'
			);
		});
	}
for (const [key, value, reason] of [
	['ci_source_sha', 'b'.repeat(40), /Foreign scheduler source/],
	['ci_run_id', '124', /Foreign scheduler run/],
	['ci_attempt', '3', /Future or invalid producer attempt/]
])
	check(() => {
		const valueTree = run('linux');
		changeStage(valueTree, 'linux', 2, (output) => {
			output[key] = value;
		});
		assert.throws(() => complete('linux', JSON.stringify(valueTree), current), reason);
	});
for (const platform of Object.keys(names)) {
	check(() => {
		const value = run(platform);
		const before = JSON.parse(value[names[platform][3]].outputs.ci_predecessors)[names[platform][2]]
			.outputs.ci_predecessors;
		assert.equal(admitBuild(platform, before, current)[names[platform][1]].result, 'success');
	});
	for (const result of ['cancelled', 'skipped'])
		check(() => {
			const value = run(platform, { 1: result });
			const before = JSON.parse(value[names[platform][3]].outputs.ci_predecessors)[
				names[platform][2]
			].outputs.ci_predecessors;
			assert.throws(
				() => admitBuild(platform, before, { ...current, event: 'workflow_dispatch' }),
				/E2E does not admit/
			);
		});
}
assert.equal(
	controls - lotControlStart,
	45,
	'all Package transport and preserved selective admission controls execute'
);

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
				...(platform === 'linux' && index === 1 ? ['ci_unit_result'] : []),
				...(platform === 'linux' && index === 2 ? ['install_matrix', 'install_metadata'] : [])
			].sort()
		);
		assert.equal(job.outputs.ci_predecessors, '${{ toJSON(needs) }}');
		assert.equal(job.outputs.ci_source_sha, '${{ github.sha }}');
		assert.equal(job.outputs.ci_run_id, '${{ github.run_id }}');
		assert.equal(job.outputs.ci_attempt, '${{ github.run_attempt }}');
	}
	const verdict = workflow.jobs[platform + '-ok'];
	assert.deepEqual(
		verdict.needs,
		platform === 'linux' ? [names[platform][3], 'package-flatpak'] : [names[platform][3]]
	);
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
		// The Flatpak job is the install job's sibling: same package predecessor,
		// same custody outputs, and no other consumer than the verdict.
		const flatpak = workflow.jobs['package-flatpak'];
		assert.deepEqual(flatpak.needs, ['package-linux']);
		assert.deepEqual(Object.keys(flatpak.outputs).sort(), [
			'ci_attempt',
			'ci_predecessors',
			'ci_run_id',
			'ci_source_sha'
		]);
		assert.equal(flatpak.outputs.ci_predecessors, '${{ toJSON(needs) }}');
		assert.equal(flatpak.outputs.ci_source_sha, '${{ github.sha }}');
		assert.equal(flatpak.outputs.ci_run_id, '${{ github.run_id }}');
		assert.equal(flatpak.outputs.ci_attempt, '${{ github.run_attempt }}');
		assert.equal(flatpak.if, undefined, 'a failed or skipped package job must skip the Flatpak');
		assert.deepEqual(workflow.jobs['install-linux'].needs, ['package-linux']);
		assert.equal(
			build.outputs.install_matrix,
			'${{ steps.install-plan.outputs.matrix }}',
			'Linux Build must forward the actual canonical install plan matrix'
		);
		assert.equal(
			build.outputs.install_metadata,
			'${{ steps.install-plan.outputs.metadata }}',
			'Linux Build must forward the actual complete install metadata'
		);
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
	// Each lane, read inlined with its stage files: one workflow per OS.
	const workflow = yaml.parse(
		require('./ci-pipeline.cjs').file('.github/workflows/ci-' + platform + '.yml')
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
		for (const mutate of [
			(value) => {
				value.jobs['linux-ok'].needs = ['install-linux'];
			},
			(value) => {
				value.jobs['package-flatpak'].needs = ['e2e-linux'];
			},
			(value) => {
				value.jobs['package-flatpak'].outputs.ci_run_id = '123';
			},
			(value) => {
				value.jobs['install-linux'].needs = ['package-linux', 'package-flatpak'];
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
	if (platform === 'linux') {
		for (const mutate of [
			(value) => {
				delete value.jobs['package-linux'].outputs.install_matrix;
			},
			(value) => {
				delete value.jobs['package-linux'].outputs.install_metadata;
			},
			(value) => {
				value.jobs['package-linux'].outputs.install_matrix =
					'${{ steps.install-plan.outputs.metadata }}';
			},
			(value) => {
				value.jobs['package-linux'].outputs.install_metadata =
					'${{ steps.install-plan.outputs.matrix }}';
			},
			(value) => {
				value.jobs['package-linux'].outputs.foreign_metadata = '{}';
			}
		])
			check(() => {
				const changed = structuredClone(workflow);
				mutate(changed);
				assert.throws(() => validateWorkflow(platform, changed));
			});
	}
}
console.log('Adjacent scheduler custody: ' + controls + ' controls passed');
