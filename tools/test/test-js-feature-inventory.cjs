// tools/test/test-js-feature-inventory.cjs

/** Exercise literal feature ownership, platform projections and the real runner dispatch. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { loadInventory, selectFeature } = require('./lib/js-feature-inventory.cjs');

const ROOT = path.resolve(__dirname, '../..');
const inventory = loadInventory(ROOT);
for (const platform of ['win32', 'linux', 'darwin']) {
	const selected = selectFeature(inventory, null, platform);
	const union = inventory.features
		.flatMap((feature) => selectFeature(inventory, feature, platform))
		.sort((a, b) => a.ordinal - b.ordinal);
	assert.deepEqual(
		union,
		selected,
		`${platform}: every active check has exactly one feature owner`
	);
	assert.equal(new Set(union.map((check) => check.id)).size, selected.length);
	for (const leaf of ['test-js-feature-inventory.cjs', 'test-js-feature-results.cjs'])
		assert.equal(
			selected.filter(
				(check) => check.args[0] === `tools/test/${leaf}` && check.feature === 'test-infrastructure'
			).length,
			1
		);
}
const nativeReceiver = inventory.checks.filter(
	(check) => check.args[0] === 'tools/test/test-macos-release-stage-native-receiving.cjs'
);
assert.equal(nativeReceiver.length, 1);
assert.deepEqual(nativeReceiver[0].platforms, ['linux']);
assert.equal(
	selectFeature(inventory, null, 'win32').some((check) => check.id === nativeReceiver[0].id),
	false
);
assert.equal(
	selectFeature(inventory, null, 'darwin').some((check) => check.id === nativeReceiver[0].id),
	false
);
assert.equal(
	selectFeature(inventory, null, 'linux').some((check) => check.id === nativeReceiver[0].id),
	true
);

const portableNavigation = inventory.checks.filter(
	(check) => check.args[0] === 'tools/test/run-nav-event-owner-portable.cjs'
);
assert.equal(portableNavigation.length, 1, 'portable navigation retains one execution owner');
assert.deepEqual(portableNavigation[0].platforms, ['linux']);
for (const platform of ['linux', 'win32', 'darwin']) {
	assert.equal(
		selectFeature(inventory, 'input-and-actions', platform).some(
			(check) => check.id === portableNavigation[0].id
		),
		platform === 'linux',
		`${platform}: the POSIX navigation fixture runs only on its supported host`
	);
}

const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-js-feature-inventory-'));
const fixtureRoot = path.join(temporaryRoot, 'fixture');
const featuresRoot = path.join(fixtureRoot, 'tools/test/features');
const fixtures = [
	{
		schema_version: 1,
		feature: 'alpha',
		checks: [
			{
				id: 'one',
				ordinal: 1,
				name: 'first',
				cmd: 'node',
				args: ['one.cjs'],
				repro: 'node one.cjs'
			},
			{
				id: 'three',
				ordinal: 3,
				name: 'third',
				cmd: '$NODE_EXECUTABLE',
				args: ['three.cjs'],
				repro: 'node three.cjs',
				platforms: ['linux']
			}
		]
	},
	{
		schema_version: 1,
		feature: 'beta',
		checks: [
			{
				id: 'two',
				ordinal: 2,
				name: 'second',
				cmd: 'npm',
				args: ['run', '--silent', 'two'],
				repro: 'npm run two'
			}
		]
	}
];

function writeFixtures(manifests = fixtures) {
	fs.rmSync(featuresRoot, { recursive: true, force: true });
	for (const manifest of manifests) {
		const directory = path.join(featuresRoot, manifest.feature);
		fs.mkdirSync(directory, { recursive: true });
		fs.writeFileSync(path.join(directory, 'suite.json'), JSON.stringify(manifest) + '\n');
	}
}

function refuses(mutate) {
	const manifests = structuredClone(fixtures);
	mutate(manifests);
	writeFixtures(manifests);
	assert.throws(() => loadInventory(fixtureRoot));
}

try {
	writeFixtures();
	const plan = loadInventory(fixtureRoot);
	assert.deepEqual(plan.features, ['alpha', 'beta']);
	assert.deepEqual(
		plan.checks.map((check) => [check.id, check.ordinal, check.cmd]),
		[
			['one', 1, 'node'],
			['two', 2, 'npm'],
			['three', 3, '$NODE_EXECUTABLE']
		]
	);
	assert.deepEqual(
		selectFeature(plan, null, 'linux').map((check) => check.id),
		['one', 'two', 'three']
	);
	assert.deepEqual(
		selectFeature(plan, null, 'win32').map((check) => check.id),
		['one', 'two']
	);
	assert.deepEqual(
		selectFeature(plan, 'alpha', 'linux').map((check) => check.id),
		['one', 'three']
	);
	for (const selector of ['', 'missing', undefined])
		assert.throws(() => selectFeature(plan, selector));
	assert.throws(() => selectFeature(plan, null, 'foreign'));
	const copy = selectFeature(plan, 'alpha', 'linux');
	copy[0].name = 'changed';
	copy[0].args.push('foreign');
	copy[1].platforms.push('win32');
	assert.deepEqual(
		selectFeature(plan, 'alpha', 'linux').map((check) => check.name),
		['first', 'third']
	);
	assert.deepEqual(
		selectFeature(plan, 'alpha', 'win32').map((check) => check.id),
		['one']
	);
	assert.deepEqual(plan.checks[0].args, ['one.cjs']);
	const reorderedKeys = fixtures.map((manifest) => ({
		checks: manifest.checks.map((check) => Object.fromEntries(Object.entries(check).reverse())),
		feature: manifest.feature,
		schema_version: 1
	}));
	writeFixtures(reorderedKeys);
	assert.equal(
		loadInventory(fixtureRoot).digest,
		plan.digest,
		'formatting/key order does not create a different plan'
	);
	const changed = structuredClone(fixtures);
	changed[0].checks[0].repro = 'node changed.cjs';
	writeFixtures(changed);
	assert.notEqual(
		loadInventory(fixtureRoot).digest,
		plan.digest,
		'every load observes the current literal content'
	);

	for (const mutate of [
		(manifests) => {
			manifests[0].schema_version = 2;
		},
		(manifests) => {
			manifests[0].unknown = true;
		},
		(manifests) => {
			manifests[0].checks = [];
		},
		(manifests) => {
			manifests[0].checks[0].foreign = true;
		},
		(manifests) => {
			delete manifests[0].checks[0].repro;
		},
		(manifests) => {
			manifests[0].checks[0].cmd = 'foreign';
		},
		(manifests) => {
			manifests[1].checks[0].cmd = 'node';
			manifests[1].checks[0].args = ['one.cjs'];
		},
		(manifests) => {
			manifests[1].checks[0].cmd = '$NODE_EXECUTABLE';
			manifests[1].checks[0].args = ['one.cjs'];
		},
		(manifests) => {
			manifests[0].checks[0].args = [];
		},
		(manifests) => {
			manifests[0].checks[0].args = [0];
		},
		(manifests) => {
			manifests[0].checks[0].name = '';
		},
		(manifests) => {
			manifests[0].checks[0].id = '';
		},
		(manifests) => {
			manifests[0].checks[0].id = 'two';
		},
		(manifests) => {
			manifests[0].checks[0].name = 'second';
		},
		(manifests) => {
			manifests[0].checks[0].name = 'cases are reported NOT EXECUTED';
		},
		(manifests) => {
			manifests[0].checks[0].ordinal = 2;
		},
		(manifests) => {
			manifests[0].checks[0].ordinal = 0;
		},
		(manifests) => {
			manifests[0].checks[1].ordinal = 4;
		},
		(manifests) => {
			manifests[0].checks.reverse();
		},
		(manifests) => {
			manifests[0].checks[1].platforms = [];
		},
		(manifests) => {
			manifests[0].checks[1].platforms = ['linux', 'linux'];
		},
		(manifests) => {
			manifests[0].checks[1].platforms = ['foreign'];
		},
		(manifests) => {
			manifests.splice(0, 1);
		}
	])
		refuses(mutate);
	writeFixtures();
	fs.writeFileSync(path.join(featuresRoot, 'orphan.json'), '{}');
	assert.throws(() => loadInventory(fixtureRoot));
	writeFixtures();
	fs.writeFileSync(path.join(featuresRoot, 'alpha', 'orphan.json'), '{}');
	assert.throws(() => loadInventory(fixtureRoot));
	writeFixtures();
	fs.rmSync(path.join(featuresRoot, 'alpha', 'suite.json'));
	assert.throws(() => loadInventory(fixtureRoot));
	writeFixtures();

	const source = fs.readFileSync(path.join(__dirname, 'run-js-suite.cjs'), 'utf8');
	function run(arguments_, platform = 'linux') {
		const stopped = {};
		const calls = [];
		const output = [];
		const timingRoot = fs.mkdtempSync(path.join(temporaryRoot, 'run-'));
		let exitCode;
		let error;
		let clock = 0;
		try {
			vm.runInNewContext(source, {
				__dirname,
				require(name) {
					if (name === './lib/js-feature-inventory.cjs')
						return {
							loadInventory(root) {
								assert.equal(root, ROOT);
								return loadInventory(fixtureRoot);
							},
							selectFeature
						};
					if (name === 'child_process')
						return {
							spawnSync(cmd, args) {
								calls.push({ cmd, args: [...args] });
								return { status: 0 };
							}
						};
					if (name === 'node:perf_hooks') return { performance: { now: () => ++clock } };
					assert.ok(
						[
							'path',
							'node:fs',
							'node:os',
							'./lib/js-suite-spawn.cjs',
							'./lib/host-capabilities.cjs'
						].includes(name),
						`unexpected import ${name}`
					);
					return require(name);
				},
				console: { log: (value) => output.push(String(value)) },
				process: {
					argv: ['node', 'run-js-suite.cjs', ...arguments_],
					platform,
					arch: process.arch,
					version: process.version,
					execPath: process.execPath,
					env: {
						RUNNER_TEMP: timingRoot,
						GITHUB_SHA: 'a'.repeat(40),
						GITHUB_RUN_ID: '123',
						GITHUB_RUN_ATTEMPT: '2'
					},
					exit(code) {
						exitCode = code;
						throw stopped;
					}
				}
			});
		} catch (caught) {
			if (caught !== stopped) error = caught;
		}
		const directories = fs.readdirSync(timingRoot);
		const rows = directories.length
			? fs
					.readFileSync(path.join(timingRoot, directories[0], 'timings.ndjson'), 'utf8')
					.trim()
					.split('\n')
					.map(JSON.parse)
			: [];
		return { calls, output, exitCode, error, rows };
	}
	const listed = run(['--list-features']);
	assert.equal(listed.exitCode, 0);
	assert.equal(listed.error, undefined);
	assert.equal(listed.calls.length, 0);
	assert.equal(listed.rows.length, 0);
	assert.deepEqual(JSON.parse(listed.output[0]).features, ['alpha', 'beta']);
	const defaultRun = run([]);
	assert.equal(defaultRun.exitCode, 0);
	assert.equal(defaultRun.error, undefined);
	assert.deepEqual(defaultRun.calls, [
		{ cmd: 'node', args: ['one.cjs'] },
		{ cmd: 'npm', args: ['run', '--silent', 'two'] },
		{ cmd: process.execPath, args: ['three.cjs'] }
	]);
	const featureRun = run(['--feature', 'alpha']);
	assert.equal(featureRun.exitCode, 0);
	assert.equal(featureRun.rows[0].mode, 'feature');
	assert.equal(featureRun.rows[0].feature, 'alpha');
	assert.equal(featureRun.rows[0].inventory_sha256, plan.digest);
	assert.equal(featureRun.rows[0].ci_source_sha, 'a'.repeat(40));
	assert.equal(featureRun.rows[0].ci_run_id, '123');
	assert.equal(featureRun.rows[0].ci_run_attempt, '2');
	assert.deepEqual(
		featureRun.rows
			.filter((row) => row.type === 'result')
			.map((row) => [row.ordinal, row.global_ordinal, row.check_id, row.name, row.reproduce]),
		[
			[1, 1, 'one', 'first', 'node one.cjs'],
			[2, 3, 'three', 'third', 'node three.cjs']
		]
	);
	assert.deepEqual(run(['--feature=alpha'], 'win32').calls, [{ cmd: 'node', args: ['one.cjs'] }]);
	const full = run(['--full']);
	assert.equal(full.exitCode, 0);
	assert.deepEqual(full.calls.slice(-2), [
		{ cmd: 'npm', args: ['run', '--silent', 'test:properties'] },
		{ cmd: 'npm', args: ['run', '--silent', 'test:mutation'] }
	]);
	assert.equal(full.rows[0].mode, 'full');
	assert.equal(full.rows[0].feature, null);
	for (const arguments_ of [
		['--unknown'],
		['--full', '--full'],
		['--feature'],
		['--feature='],
		['--feature', 'missing'],
		['--feature', 'alpha', '--feature', 'beta'],
		['--feature=alpha', '--full'],
		['--list-features', '--full'],
		['--list-features', '--feature=alpha'],
		['--list-features', '--list-features']
	]) {
		const refused = run(arguments_);
		assert.ok(refused.error);
		assert.equal(refused.calls.length, 0);
		assert.equal(refused.rows.length, 0);
	}
} finally {
	fs.rmSync(temporaryRoot, { recursive: true, force: true });
}

console.log('PASS literal feature inventory, platform projections and actual runner dispatch');
