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
// The chain of each lane, written here independently of the module under test.
const names = {
	windows: ['test-ahk', 'integration-ahk', 'e2e-ahk', 'package-windows', 'launch-windows'],
	linux: ['test-linux', 'integration-linux', 'e2e-linux', 'package-linux', 'install-linux']
};
// Positions of the stages in each chain.
const I = { unit: 0, integration: 1, e2e: 2, build: 3, install: 4 };
const LAST = I.install;
let controls = 0;
function run(platform, results = {}) {
	let prior = { [names[platform][0]]: { result: results[0] || 'success', outputs: {} } };
	for (let index = 1; index <= LAST; index++) {
		const outputs = {
			ci_source_sha: current.sourceSha,
			ci_run_id: current.runId,
			ci_attempt: '1',
			ci_predecessors: JSON.stringify(prior)
		};
		if (platform === 'linux' && index === I.build) {
			outputs.install_matrix = JSON.stringify(installPlan.matrix);
			outputs.install_metadata = JSON.stringify(installPlan.metadata);
		}
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
		for (let index = 0; index <= LAST; index++)
			check(() => refuse(run(platform, { [index]: result }), platform));
	for (const field of ['ci_source_sha', 'ci_run_id', 'ci_attempt', 'ci_predecessors']) {
		check(() => {
			const value = run(platform);
			delete value[names[platform][LAST]].outputs[field];
			refuse(value, platform);
		});
	}
	check(() => {
		const value = run(platform);
		value[names[platform][LAST]].outputs.ci_source_sha = 'b'.repeat(40);
		refuse(value, platform);
	});
	check(() => {
		const value = run(platform);
		value[names[platform][LAST]].outputs.ci_run_id = '124';
		refuse(value, platform);
	});
	check(() => {
		const value = run(platform);
		value[names[platform][LAST]].outputs.ci_attempt = '3';
		refuse(value, platform);
	});
	check(() => {
		const value = run(platform);
		value[names[platform][LAST]].outputs.ci_predecessors = '';
		refuse(value, platform);
	});
	check(() => {
		const value = run(platform);
		value[names[platform][LAST]].outputs.ci_predecessors = '{';
		refuse(value, platform);
	});
	check(() => {
		const value = run(platform);
		value[names[platform][LAST]].outputs.foreign = 'success';
		refuse(value, platform);
	});
	check(() => {
		const value = run(platform);
		value.foreign = value[names[platform][LAST]];
		refuse(value, platform);
	});
}
// No lane has a job beside its last chain link: a verdict needing a sibling is refused.
for (const platform of Object.keys(names))
	check(() => {
		const value = run(platform);
		value['package-flatpak'] = structuredClone(value[names[platform][LAST]]);
		refuse(value, platform);
	});
// A failed E2E admits no build on any lane or event: a manual dispatch is not special.
for (const platform of Object.keys(names))
	for (const event of ['push', 'pull_request', 'workflow_dispatch'])
		check(() => {
			const value = run(platform, { [I.e2e]: 'failure' });
			const beforeBuild = JSON.parse(value[names[platform][LAST]].outputs.ci_predecessors)[
				names[platform][I.build]
			].outputs.ci_predecessors;
			assert.throws(
				() => admitBuild(platform, beforeBuild, { ...current, event }),
				/E2E does not admit this build/
			);
			refuse(value, platform, { ...current, event });
		});
for (const stage of ['unit', 'integration'])
	check(() => {
		const value = run('linux', { [I[stage]]: 'failure', [I.e2e]: 'failure' });
		const beforeBuild = JSON.parse(value['install-linux'].outputs.ci_predecessors)['package-linux']
			.outputs.ci_predecessors;
		assert.throws(
			() => admitBuild('linux', beforeBuild, { ...current, event: 'workflow_dispatch' }),
			/did not succeed/
		);
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
// The Linux E2E link forwards the custody outputs alone: an extra integration predicate is refused.
check(() => {
	const value = run('linux');
	const packageJob = JSON.parse(value['install-linux'].outputs.ci_predecessors);
	const e2e = JSON.parse(packageJob['package-linux'].outputs.ci_predecessors);
	e2e['e2e-linux'].outputs.ci_integration_result = 'success';
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
function changeStage(value, platform, index, mutate, cursor = LAST) {
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
		changeStage(value, 'linux', I.build, mutate);
		assert.throws(() => complete('linux', JSON.stringify(value), current), reason, label);
	});
for (const platform of Object.keys(names))
	for (let index = 0; index <= LAST; index++) {
		if (platform === 'linux' && index === I.build) continue;
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
		changeStage(valueTree, 'linux', I.build, (output) => {
			output[key] = value;
		});
		assert.throws(() => complete('linux', JSON.stringify(valueTree), current), reason);
	});
for (const platform of Object.keys(names)) {
	check(() => {
		const value = run(platform);
		const before = JSON.parse(value[names[platform][LAST]].outputs.ci_predecessors)[
			names[platform][I.build]
		].outputs.ci_predecessors;
		const admitted = admitBuild(platform, before, current);
		assert.deepEqual(Object.keys(admitted), names[platform].slice(0, I.e2e + 1));
		assert.equal(admitted[names[platform][I.e2e]].result, 'success');
	});
	for (const result of ['cancelled', 'skipped'])
		check(() => {
			const value = run(platform, { [I.e2e]: result });
			const before = JSON.parse(value[names[platform][LAST]].outputs.ci_predecessors)[
				names[platform][I.build]
			].outputs.ci_predecessors;
			assert.throws(
				() => admitBuild(platform, before, { ...current, event: 'workflow_dispatch' }),
				/E2E does not admit/
			);
		});
}
assert.equal(
	controls - lotControlStart,
	47,
	'all Package transport and preserved selective admission controls execute'
);

// The source predicate consumes genuine outputs, never a modeled success flag.
const root = path.resolve(__dirname, '../..');
function validateWorkflow(platform, workflow) {
	for (let index = 1; index <= LAST; index++) {
		const job = workflow.jobs[names[platform][index]];
		assert.deepEqual(job.needs, [names[platform][index - 1]]);
		assert.deepEqual(
			Object.keys(job.outputs).sort(),
			[
				...['ci_attempt', 'ci_predecessors', 'ci_run_id', 'ci_source_sha'],
				...(platform === 'linux' && index === I.build ? ['install_matrix', 'install_metadata'] : [])
			].sort()
		);
		assert.equal(job.outputs.ci_predecessors, '${{ toJSON(needs) }}');
		assert.equal(job.outputs.ci_source_sha, '${{ github.sha }}');
		assert.equal(job.outputs.ci_run_id, '${{ github.run_id }}');
		assert.equal(job.outputs.ci_attempt, '${{ github.run_attempt }}');
	}
	const verdict = workflow.jobs[platform + '-ok'];
	// The verdict needs the last link of the chain and nothing beside it.
	assert.deepEqual(verdict.needs, [names[platform][LAST]]);
	assert.equal(verdict.if, 'always()');
	assert.ok(
		verdict.steps.some((step) =>
			(step.run || '').includes('ci-stage-status.cjs complete ' + platform)
		)
	);
	const build = workflow.jobs[names[platform][I.build]];
	assert.ok(
		build.steps.some(
			(step) =>
				step.run === 'node tools/ci/ci-stage-status.cjs admit-build ' + platform &&
				step.env?.NEEDS === '${{ toJSON(needs) }}'
		)
	);
	if (platform === 'linux') {
		assert.ok(!workflow.jobs['package-flatpak'], 'the Flatpak is built by the package job');
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
	}
	// Build carries the default admission of every lane: success of E2E alone.
	assert.equal(build.if, undefined, 'Build must not carry a manual-dispatch exception');
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
			value.jobs[names[platform][I.e2e]].needs.push(names[platform][I.unit]);
		},
		(value) => {
			value.jobs[names[platform][LAST]].outputs.ci_source_sha = 'a'.repeat(40);
		},
		(value) => {
			value.jobs[names[platform][1]].outputs.ci_run_id = '123';
		},
		(value) => {
			value.jobs[platform + '-ok'].if = 'success()';
		},
		(value) => {
			value.jobs[names[platform][I.build]].if =
				"${{ !cancelled() && (needs['" +
				names[platform][I.e2e] +
				"'].result == 'success' || github.event_name == 'workflow_dispatch') }}";
		},
		(value) => {
			value.jobs[names[platform][I.build]].steps = value.jobs[
				names[platform][I.build]
			].steps.filter((step) => !String(step.run).includes('ci-stage-status.cjs admit-build'));
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
				value.jobs['linux-ok'].needs = ['install-linux', 'package-linux'];
			},
			(value) => {
				value.jobs['package-flatpak'] = structuredClone(value.jobs['install-linux']);
			},
			(value) => {
				value.jobs['install-linux'].needs = ['package-linux', 'e2e-linux'];
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
			changed.jobs['e2e-linux'].outputs.ci_integration_result =
				'${{ needs.integration-linux.result }}';
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
