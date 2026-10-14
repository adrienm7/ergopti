// tools/test/test-js-feature-results.cjs

/** Reject incomplete, mixed-source and duplicate feature evidence before aggregation. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { validateFeatureJournals } = require('./lib/js-feature-results.cjs');
const { collectJournals } = require('../ci/validate-js-feature-results.cjs');
const { createMatrix, displayPlan, selectLot } = require('../ci/js-feature-matrix.cjs');

const context = { source: 'a'.repeat(40), run_id: '123', run_attempt: '2', platform: 'linux' };
const inventory = {
	digest: 'b'.repeat(64),
	features: ['menus', 'input'],
	checks: [
		{
			id: 'menu-readers',
			feature: 'menus',
			ordinal: 1,
			name: 'Menu readers',
			repro: 'node readers.cjs'
		},
		{
			id: 'input-routing',
			feature: 'input',
			ordinal: 2,
			name: 'Input routing',
			repro: 'node routing.cjs'
		},
		{ id: 'menu-query', feature: 'menus', ordinal: 3, name: 'Menu query', repro: 'node query.cjs' }
	]
};

function journals(subject = inventory, invocation = context) {
	return subject.features.map((feature) => {
		const checks = subject.checks.filter(
			(check) =>
				check.feature === feature &&
				(!check.platforms || check.platforms.includes(invocation.platform))
		);
		return [
			{
				type: 'suite',
				platform: invocation.platform,
				schema_version: 1,
				suite: 'js',
				mode: 'feature',
				feature,
				planned_count: checks.length,
				inventory_sha256: subject.digest,
				ci_source_sha: invocation.source,
				ci_run_id: invocation.run_id,
				ci_run_attempt: invocation.run_attempt
			},
			...checks.flatMap((check, index) => {
				const identity = {
					ordinal: index + 1,
					check_id: check.id,
					global_ordinal: check.ordinal,
					name: check.name
				};
				return [
					{ type: 'start', ...identity },
					{
						type: 'result',
						...identity,
						reproduce: check.repro,
						status: 'PASS',
						exit_code: 0,
						signal: null,
						error_code: null,
						duration_ms: 2.125
					}
				];
			}),
			{
				type: 'complete',
				executed_count: checks.length,
				passed: checks.length,
				failed: 0,
				child_duration_ms: checks.length * 2.125,
				duration_ms: 10
			}
		];
	});
}

assert.equal(validateFeatureJournals(inventory, journals(), context).checks, 3);
assert.equal(validateFeatureJournals(inventory, journals().reverse(), context).checks, 3);
const projectedInventory = structuredClone(inventory);
projectedInventory.checks[2].platforms = ['linux'];
for (const platform of ['linux', 'darwin', 'win32']) {
	const invocation = { ...context, platform };
	assert.equal(
		validateFeatureJournals(
			projectedInventory,
			journals(projectedInventory, invocation),
			invocation
		).checks,
		platform === 'linux' ? 3 : 2
	);
}
assert.throws(
	() =>
		validateFeatureJournals(
			projectedInventory,
			journals(inventory, { ...context, platform: 'win32' }),
			{ ...context, platform: 'win32' }
		),
	/incomplete planned inventory/
);
assert.throws(
	() =>
		validateFeatureJournals(
			inventory,
			journals(projectedInventory, { ...context, platform: 'win32' }),
			{ ...context, platform: 'win32' }
		),
	/incomplete planned inventory/
);
for (const ref of [
	'refs/heads/main',
	'refs/heads/dev',
	'refs/heads/fix/example',
	'refs/pull/42/merge'
]) {
	const matrix = createMatrix(inventory, ref).include;
	assert.deepEqual(
		matrix.filter((row) => row.suite === 'js').map((row) => row.feature),
		inventory.features
	);
	assert.equal(matrix.filter((row) => row.suite === 'properties').length, 1);
	assert.equal(matrix.filter((row) => row.suite === 'hotstrings-format').length, 1);
	assert.equal(
		matrix.filter((row) => row.suite === 'mutation').length,
		ref === 'refs/heads/main' ? 1 : 0
	);
	assert.equal(matrix.length, inventory.features.length + (ref === 'refs/heads/main' ? 3 : 2));
}
assert.throws(() => createMatrix(inventory, 'main'), /full GitHub ref/);
assert.throws(() => createMatrix(inventory, 'refs/heads/'), /full GitHub ref/);
assert.throws(() => createMatrix(inventory, 'refs/heads/main\n'), /full GitHub ref/);
assert.throws(() => createMatrix({ features: [] }, 'refs/heads/main'), /empty/);
assert.throws(() => createMatrix({ features: ['menus', 'menus'] }, 'refs/heads/main'), /unique/);
assert.throws(() => createMatrix({ features: ['menus;echo'] }, 'refs/heads/main'), /slugs/);
for (const feature of ['properties', 'mutation', 'hotstrings-format'])
	assert.throws(
		() => createMatrix({ features: [feature] }, 'refs/heads/main'),
		/unique literal slugs/
	);
// The single human axis must resolve back to every original suite without a second roster.
for (const ref of ['refs/heads/main', 'refs/heads/dev', 'refs/pull/42/merge']) {
	const displayed = displayPlan(inventory, ref);
	assert.deepEqual(Object.keys(displayed.matrix), ['lot']);
	assert.deepEqual(displayed.matrix.lot, Object.keys(displayed.metadata));
	assert.deepEqual(Object.values(displayed.metadata), createMatrix(inventory, ref).include);
	const encoded = JSON.stringify(displayed.metadata);
	for (const lot of displayed.matrix.lot)
		assert.deepEqual(selectLot(inventory, ref, lot, encoded), displayed.metadata[lot]);
	for (const lot of ['', 'foreign', undefined, null])
		assert.throws(() => selectLot(inventory, ref, lot, encoded), /Unknown Common lot/);
	for (const mutate of [
		(value) => {
			delete value.Menus;
		},
		(value) => {
			value.Foreign = value.Menus;
		},
		(value) => {
			value.Menus.feature = 'input';
		},
		(value) => {
			value.Menus.suite = 'properties';
		},
		(value) => {
			value.Menus.extra = true;
		},
		(value) => {
			delete value['Hotstring TOML formatting'];
		}
	]) {
		const changed = structuredClone(displayed.metadata);
		mutate(changed);
		assert.throws(
			() => selectLot(inventory, ref, displayed.matrix.lot[0], JSON.stringify(changed)),
			/complete authored inventory/
		);
	}
	assert.throws(
		() => selectLot(inventory, ref, displayed.matrix.lot[0], encoded.replace('{', '{"Menus":{},')),
		/complete authored inventory/
	);
}
assert.throws(
	() => displayPlan({ features: ['property-tests'] }, 'refs/heads/dev'),
	/human lot labels must be unique/
);

// Reused success is bound to the same immutable literal plan, not a fabricated plan attempt.
const mixed = journals();
mixed[0][0].ci_run_attempt = '1';
const mixedResult = validateFeatureJournals(inventory, mixed, context);
assert.equal(mixedResult.checks, 3);
assert.equal(mixedResult.run_id, context.run_id);
assert.equal(mixedResult.run_attempt, '2');
assert.deepEqual(
	mixedResult.features.map((row) => [row.feature, row.producer_run_attempt]),
	[
		['input', '2'],
		['menus', '1']
	]
);
const retained = journals();
for (const rows of retained) rows[0].ci_run_attempt = '1';
assert.equal(validateFeatureJournals(inventory, retained, context).checks, 3);
assert.equal(validateFeatureJournals(inventory, mixed.reverse(), context).checks, 3);
for (const run_attempt of ['', '0', '02', '-1', '9007199254740992', 2, null, undefined]) {
	assert.throws(() => validateFeatureJournals(inventory, journals(), { ...context, run_attempt }));
	const malformed = journals();
	malformed[0][0].ci_run_attempt = run_attempt;
	assert.throws(() => validateFeatureJournals(inventory, malformed, context));
}
for (const mutate of [
	(rows) => {
		rows[0][0].ci_source_sha = 'c'.repeat(40);
	},
	(rows) => {
		rows[0][0].ci_run_id = '124';
	},
	(rows) => {
		rows[0][0].inventory_sha256 = 'd'.repeat(64);
	},
	(rows) => {
		rows[0][2].status = 'FAIL';
	},
	(rows) => {
		rows[0][2].exit_code = 1;
	},
	(rows) => {
		rows[0].pop();
	},
	(rows) => {
		rows[0][2].check_id = 'foreign';
	},
	(rows) => {
		rows[1] = structuredClone(rows[0]);
	}
]) {
	const old = journals();
	old[0][0].ci_run_attempt = '1';
	mutate(old);
	assert.throws(() => validateFeatureJournals(inventory, old, context));
}
const mutations = [
	[
		'wrong platform',
		(rows) => {
			rows[0][0].platform = 'win32';
		}
	],
	['missing feature', (rows) => rows.pop()],
	[
		'duplicate feature',
		(rows) => {
			rows[1] = structuredClone(rows[0]);
		}
	],
	[
		'unknown feature',
		(rows) => {
			rows[0][0].feature = 'foreign';
		}
	],
	[
		'default mode',
		(rows) => {
			rows[0][0].mode = 'default';
		}
	],
	[
		'source mismatch',
		(rows) => {
			rows[0][0].ci_source_sha = 'c'.repeat(40);
		}
	],
	[
		'run mismatch',
		(rows) => {
			rows[0][0].ci_run_id = '124';
		}
	],
	[
		'future producer attempt',
		(rows) => {
			rows[0][0].ci_run_attempt = '3';
		}
	],
	[
		'inventory mismatch',
		(rows) => {
			rows[0][0].inventory_sha256 = 'd'.repeat(64);
		}
	],
	['missing result', (rows) => rows[0].splice(2, 1)],
	['unfinished', (rows) => rows[0].pop()],
	['duplicate result', (rows) => rows[0].splice(2, 0, structuredClone(rows[0][2]))],
	[
		'result before start',
		(rows) => {
			[rows[0][1], rows[0][2]] = [rows[0][2], rows[0][1]];
		}
	],
	[
		'wrong local ordinal',
		(rows) => {
			rows[0][2].ordinal = 2;
		}
	],
	[
		'wrong global ordinal',
		(rows) => {
			rows[0][2].global_ordinal = 2;
		}
	],
	[
		'wrong check id',
		(rows) => {
			rows[0][2].check_id = 'input-routing';
		}
	],
	[
		'wrong name',
		(rows) => {
			rows[0][2].name = 'Different';
		}
	],
	[
		'wrong command',
		(rows) => {
			rows[0][2].reproduce = 'echo passed';
		}
	],
	[
		'failed result hidden by green footer',
		(rows) => {
			rows[0][2].status = 'FAIL';
		}
	],
	[
		'nonzero exit',
		(rows) => {
			rows[0][2].exit_code = 1;
		}
	],
	[
		'unexecuted result',
		(rows) => {
			rows[0][2].exit_code = null;
		}
	],
	[
		'signal',
		(rows) => {
			rows[0][2].signal = 'SIGTERM';
		}
	],
	[
		'spawn failure',
		(rows) => {
			rows[0][2].error_code = 'ENOENT';
		}
	],
	[
		'invalid duration',
		(rows) => {
			rows[0][2].duration_ms = null;
		}
	],
	[
		'wrong planned count',
		(rows) => {
			rows[0][0].planned_count = 1;
		}
	],
	[
		'wrong executed count',
		(rows) => {
			rows[0].at(-1).executed_count = 1;
		}
	],
	[
		'failed summary',
		(rows) => {
			rows[0].at(-1).failed = 1;
		}
	],
	[
		'wrong passed count',
		(rows) => {
			rows[0].at(-1).passed = 1;
		}
	],
	[
		'wrong timing total',
		(rows) => {
			rows[0].at(-1).child_duration_ms = 0;
		}
	],
	[
		'impossible suite duration',
		(rows) => {
			rows[0].at(-1).duration_ms = 1;
		}
	]
];
for (const [name, mutate] of mutations) {
	const rows = journals();
	mutate(rows);
	assert.throws(
		() => validateFeatureJournals(inventory, rows, context),
		/Re-run the affected feature lot/,
		name
	);
}
assert.throws(
	() => validateFeatureJournals(inventory, journals(), { ...context, source: '' }),
	/Invalid CI source/
);
assert.throws(
	() => validateFeatureJournals(inventory, journals(), { ...context, run_attempt: '0' }),
	/Invalid CI run_attempt/
);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-feature-results-'));
try {
	for (const [index, rows] of journals().entries()) {
		const folder = path.join(temporary, `artifact-${index}`, 'execution');
		fs.mkdirSync(folder, { recursive: true });
		fs.writeFileSync(
			path.join(folder, 'timings.ndjson'),
			rows.map((row) => JSON.stringify(row)).join('\n') + '\n'
		);
	}
	assert.equal(validateFeatureJournals(inventory, collectJournals(temporary), context).checks, 3);
	const target = path.join(temporary, 'artifact-0', 'execution', 'timings.ndjson');
	fs.appendFileSync(target, '{');
	assert.throws(() => collectJournals(temporary), /Truncated feature evidence/);
	fs.appendFileSync(target, '\n');
	assert.throws(() => collectJournals(temporary), SyntaxError);
} finally {
	fs.rmSync(temporary, { recursive: true, force: true });
}
console.log(
	`Feature union: two complete-order controls and ${mutations.length + 2} refusal controls passed.`
);

require('./fixtures/common-unit-admission-controls.cjs')
	.run()
	.then((count) => {
		assert.equal(count, 58, 'complete source plan, Unit writer admission and refusal diagnostics');
	})
	.catch((error) => {
		console.error(error);
		process.exitCode = 1;
	});
