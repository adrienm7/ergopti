// tools/test/test-linux-updater-temp-registration.cjs

/** Independent mandatory source registration checks; never grants native runtime credit. */
'use strict';
const assert = require('node:assert/strict');
const { assertLinuxQualifiedRun } = require('./ci-linux-qualified-run.cjs');
const fs = require('node:fs');
const path = require('node:path');
const Pipeline = require('./ci-pipeline.cjs');
const Planner = require('./verify-change.cjs');
const ROOT = path.resolve(__dirname, '../..');
const read = (name) => fs.readFileSync(path.join(ROOT, name), 'utf8');
const scripts = JSON.parse(read('package.json')).scripts;
const suite = read('tools/test/run-js-suite.cjs');
const exceptions = read('tools/test/test-npm-aliases-match-the-suite.cjs');
const catalogue = JSON.parse(read('.github/linux-ci-coverage.json'));
const workflow = read('.github/workflows/ci-linux.yml');
const expected = {
	ownership: 'Preserve native updater temporary-file ownership',
	allocation: 'Acknowledge native updater temporary-allocation refusals'
};
const inputs = [
	'tools/test/run-linux-updater-temp-native.cjs',
	'tools/test/prepare-linux-updater-archive-snapshot.py',
	'tools/test/run-linux-managed-http-native.cjs',
	'tools/test/run-linux-managed-http-phase.py',
	'tools/build/stage-linux-network-runtime.py',
	'tools/build/build-linux-native-output.sh',
	'tools/lib/git-bash.cjs',
	'static/ergopti_plus/linux/tests/hardware/run_updater_temp_ownership_receipts.py',
	'static/ergopti_plus/linux/tests/hardware/run_updater_temp_allocation_receipts.py',
	'static/ergopti_plus/linux/modules/updater/manager.lua',
	'static/ergopti_plus/linux/modules/updater/archive_transfer.lua',
	'static/ergopti_plus/linux/infra/archive_output.lua',
	'static/ergopti_plus/linux/infra/fd_sha256.lua',
	'static/ergopti_plus/linux/modules/shortcuts/script_actions.lua',
	'static/ergopti_plus/linux/native/archive_output/archive_publication.c',
	'static/ergopti_plus/linux/native/archive_output/archive_publication.h',
	'.github/workflows/ci-linux.yml',
	'.github/linux-ci-coverage.json'
];
function registration(aliases, inventory, exempt, planner, floors) {
	for (const [alias, file] of [
		['test:linux:updater-temp-native', 'run-linux-updater-temp-native.cjs'],
		['test:linux-updater-temp-receipt', 'test-linux-updater-temp-native.cjs'],
		['test:linux-updater-temp-registration', 'test-linux-updater-temp-registration.cjs']
	])
		assert.equal(aliases[alias], 'node ./tools/test/' + file);
	for (const file of [
		'test-linux-updater-temp-native.cjs',
		'test-linux-updater-temp-registration.cjs'
	])
		assert.equal(inventory.split("args: ['tools/test/" + file + "']").length - 1, 1);
	assert.ok(!inventory.includes("args: ['tools/test/run-linux-updater-temp-native.cjs']"));
	assert.equal(exempt.split("'tools/test/run-linux-updater-temp-native.cjs',").length - 1, 1);
	assert.equal(
		planner.GATE_COMMANDS['linux-updater-temp-native']?.npm,
		'test:linux:updater-temp-native'
	);
	assert.equal(planner.GATE_COMMANDS['linux-updater-temp-native']?.platform, 'linux');
	for (const input of inputs)
		assert.ok(planner.selectGates([input]).has('linux-updater-temp-native'), input);
	assert.equal(floors.jobs['e2e-linux'].classification, 'mandatory');
	for (const family of Object.keys(expected))
		assert.equal(floors.jobs['e2e-linux'].subjects['updater-temp-' + family], 24);
	// Existing independent native gates keep their original floor and ownership.
	for (const [subject, floor] of [
		['managed-http-output', 18],
		['managed-http-public', 30],
		['updater-archive-pipeline', 15]
	])
		assert.equal(floors.jobs['e2e-linux'].subjects[subject], floor);
}
function mandatory(text) {
	const jobs = Pipeline.jobsOfText(text, '.github/workflows/ci-linux.yml').filter(
		(job) => job.id === 'e2e-linux'
	);
	assert.equal(jobs.length, 1);
	const body = jobs[0].body,
		steps = Pipeline.steps(body);
	const preparation = Pipeline.runOf(
		Pipeline.step(body, 'Terminate real descendants after their process leader exits')
	).join('\n');
	for (const name of ['build-essential', 'lua5.4', 'lua-luv', 'strace', 'openssl'])
		assert.ok(preparation.split(/\s+/).includes(name), name);
	const record = Pipeline.runOf(Pipeline.step(body, 'Record mandatory E2E evidence')).join('\n');
	for (const [family, name] of Object.entries(expected)) {
		assert.equal(steps.filter((step) => step.name === name).length, 1);
		const step = Pipeline.step(body, name);
		assert.equal(Pipeline.stepField(step, 'if'), '${{ !cancelled() }}');
		assert.equal(Pipeline.stepField(step, 'continue-on-error'), null);
		assert.equal(Pipeline.stepField(step, 'working-directory'), null);
		assert.equal(Pipeline.stepField(step, 'timeout-minutes'), '22');
		assertLinuxQualifiedRun(Pipeline.runOf(step), [
			'set -euo pipefail',
			'export ERGOPTI_MANAGED_NATIVE_EXPECTED_HEAD="$GITHUB_SHA"',
			'npm run --silent test:linux:updater-temp-native -- --fixture ' +
				family +
				' | tee "$RUNNER_TEMP/linux-updater-temp-' +
				family +
				'.log"'
		]);
		const evidence =
			'updater_temp_' +
			family +
			'_assertions=$(node tools/test/run-linux-updater-temp-native.cjs --evidence ' +
			family +
			' "$RUNNER_TEMP/linux-updater-temp-' +
			family +
			'.log" "$GITHUB_SHA")';
		const subject =
			'--subject "updater-temp-' + family + '=$updater_temp_' + family + '_assertions"';
		assert.equal(record.split(evidence).length - 1, 1);
		assert.equal(record.split(subject).length - 1, 1);
	}
}
let count = 0;
function control(name, body) {
	body();
	count++;
}
control('real registration union', () =>
	registration(scripts, suite, exceptions, Planner, catalogue)
);
control('real mandatory workflow', () => mandatory(workflow));
for (const alias of [
	'test:linux:updater-temp-native',
	'test:linux-updater-temp-receipt',
	'test:linux-updater-temp-registration'
])
	control('missing alias ' + alias, () =>
		assert.throws(() =>
			registration({ ...scripts, [alias]: undefined }, suite, exceptions, Planner, catalogue)
		)
	);
for (const file of [
	'test-linux-updater-temp-native.cjs',
	'test-linux-updater-temp-registration.cjs'
])
	control('missing normal module ' + file, () =>
		assert.throws(() =>
			registration(
				scripts,
				suite.replace("args: ['tools/test/" + file + "']", "args: ['missing']"),
				exceptions,
				Planner,
				catalogue
			)
		)
	);
control('unowned native suite execution refused', () =>
	assert.throws(() =>
		registration(
			scripts,
			suite + "\nargs: ['tools/test/run-linux-updater-temp-native.cjs']",
			exceptions,
			Planner,
			catalogue
		)
	)
);
control('missing native exemption refused', () =>
	assert.throws(() =>
		registration(
			scripts,
			suite,
			exceptions.replace("'tools/test/run-linux-updater-temp-native.cjs',", "'missing',"),
			Planner,
			catalogue
		)
	)
);
control('missing planner command refused', () =>
	assert.throws(() =>
		registration(
			scripts,
			suite,
			exceptions,
			{
				...Planner,
				GATE_COMMANDS: { ...Planner.GATE_COMMANDS, 'linux-updater-temp-native': undefined }
			},
			catalogue
		)
	)
);
for (const input of inputs)
	control('missing planner source ' + input, () =>
		assert.throws(() =>
			registration(
				scripts,
				suite,
				exceptions,
				{
					...Planner,
					selectGates: (sources) =>
						sources.includes(input) ? new Set() : Planner.selectGates(sources)
				},
				catalogue
			)
		)
	);
for (const [family, name] of Object.entries(expected)) {
	control(family + ' reduced native floor refused', () => {
		const copy = JSON.parse(JSON.stringify(catalogue));
		copy.jobs['e2e-linux'].subjects['updater-temp-' + family] = 12;
		assert.throws(() => registration(scripts, suite, exceptions, Planner, copy));
	});
	control(family + ' removed mandatory step refused', () =>
		assert.throws(() =>
			mandatory(workflow.replace('name: ' + name, 'name: Missing temporary updater fixture'))
		)
	);
	control(family + ' optionalized step refused', () =>
		assert.throws(() =>
			mandatory(
				workflow.replace('name: ' + name, 'name: ' + name + '\n        continue-on-error: true')
			)
		)
	);
	control(family + ' duplicated step refused', () =>
		assert.throws(() =>
			mandatory(
				workflow.replace(
					'      - name: ' + name,
					'      - name: ' + name + '\n        run: echo duplicate\n      - name: ' + name
				)
			)
		)
	);
	control(family + ' wrong fixture selector refused', () =>
		assert.throws(() =>
			mandatory(workflow.replace('-- --fixture ' + family, '-- --fixture foreign'))
		)
	);
	control(family + ' static evidence refused', () =>
		assert.throws(() =>
			mandatory(
				workflow.replace(
					'--subject "updater-temp-' + family + '=$updater_temp_' + family + '_assertions"',
					'--subject updater-temp-' + family + '=24'
				)
			)
		)
	);
	control(family + ' wrong source head refused', () =>
		assert.throws(() =>
			mandatory(
				workflow.replace(
					'--evidence ' +
						family +
						' "$RUNNER_TEMP/linux-updater-temp-' +
						family +
						'.log" "$GITHUB_SHA"',
					'--evidence ' + family + ' "$RUNNER_TEMP/linux-updater-temp-' + family + '.log" "HEAD"'
				)
			)
		)
	);
}
control('compiler prerequisite omission refused', () =>
	assert.throws(() =>
		mandatory(
			workflow.replace(
				'lua-luv lua5.4 curl openssl python3 strace build-essential',
				'lua-luv lua5.4 curl openssl python3 strace'
			)
		)
	)
);
assert.equal(count, 43, 'Independent temporary updater registration floor changed');
console.log(
	'[OK] Linux updater temporary registration: 43 source controls passed; no native credit.'
);

// Additional independent mandatory direct-C subject; original 43 controls stay intact.
const launcher = read('tools/test/run-linux-updater-temp-native.cjs');
const namespaceFixture =
	'static/ergopti_plus/linux/tests/hardware/run_native_artifact_cleanup_retry.py';
function namespaceRegistration(floors, planner, text, producer) {
	assert.equal(floors.jobs['e2e-linux'].subjects['updater-native-namespace-cleanup'], 5);
	assert.ok(planner.selectGates([namespaceFixture]).has('linux-updater-temp-native'));
	const job = Pipeline.jobsOfText(text, '.github/workflows/ci-linux.yml').find(
		(value) => value.id === 'e2e-linux'
	);
	assert.ok(job);
	const record = Pipeline.runOf(Pipeline.step(job.body, 'Record mandatory E2E evidence')).join(
		'\n'
	);
	assert.equal(
		record.split(
			'updater_native_namespace_assertions=$(node tools/test/run-linux-updater-temp-native.cjs --evidence namespace "$RUNNER_TEMP/linux-updater-temp-ownership.log" "$GITHUB_SHA")'
		).length - 1,
		1
	);
	assert.equal(
		record.split(
			'--subject "updater-native-namespace-cleanup=$updater_native_namespace_assertions"'
		).length - 1,
		1
	);
	assert.ok(
		producer.includes("const NAMESPACE = 'tests/hardware/run_native_artifact_cleanup_retry.py';")
	);
	assert.ok(
		/'--library'\s*,\s*generated\s*,\s*'--library-sha256'\s*,\s*nativeSha\s*,\s*'--source-root'\s*,\s*clone\s*\]/.test(
			producer
		)
	);
	assert.ok(
		producer.indexOf("phase = 'canonical-native-build'") <
			producer.indexOf("phase = 'actual-native-namespace-cleanup'")
	);
	const namespaceAdmission =
		/if\s*\(\s*!\s*namespaceReceipt\s*\(\s*namespace\s*\)\s*\)\s*refused\s*\(\s*\)\s*;/.exec(
			producer
		);
	assert.ok(namespaceAdmission, 'The actual direct C receipt refusal guard must be present');
	assert.ok(namespaceAdmission.index < producer.indexOf('for (const selected of families)'));
	assert.ok(producer.includes("const ABIS = ['luajit', 'lua5.4'];"));
}
control('direct C mandatory registration', () =>
	namespaceRegistration(catalogue, Planner, workflow, launcher)
);
control('missing direct C subject refused', () => {
	const copy = JSON.parse(JSON.stringify(catalogue));
	delete copy.jobs['e2e-linux'].subjects['updater-native-namespace-cleanup'];
	assert.throws(() => namespaceRegistration(copy, Planner, workflow, launcher));
});
control('partial direct C subject refused', () => {
	const copy = JSON.parse(JSON.stringify(catalogue));
	copy.jobs['e2e-linux'].subjects['updater-native-namespace-cleanup'] = 4;
	assert.throws(() => namespaceRegistration(copy, Planner, workflow, launcher));
});
control('direct C omitted from planner refused', () =>
	assert.throws(() =>
		namespaceRegistration(
			catalogue,
			{
				...Planner,
				selectGates: (sources) =>
					sources.includes(namespaceFixture) ? new Set() : Planner.selectGates(sources)
			},
			workflow,
			launcher
		)
	)
);
control('direct C static evidence refused', () =>
	assert.throws(() =>
		namespaceRegistration(
			catalogue,
			Planner,
			workflow.replace(
				'--subject "updater-native-namespace-cleanup=$updater_native_namespace_assertions"',
				'--subject updater-native-namespace-cleanup=5'
			),
			launcher
		)
	)
);
control('direct C source head mismatch refused', () =>
	assert.throws(() =>
		namespaceRegistration(
			catalogue,
			Planner,
			workflow.replace(
				'--evidence namespace "$RUNNER_TEMP/linux-updater-temp-ownership.log" "$GITHUB_SHA"',
				'--evidence namespace "$RUNNER_TEMP/linux-updater-temp-ownership.log" "HEAD"'
			),
			launcher
		)
	)
);
control('missing direct C receipt admission refused', () => {
	const mutated = launcher.replace(
		/if\s*\(\s*!\s*namespaceReceipt\s*\(\s*namespace\s*\)\s*\)\s*refused\s*\(\s*\)\s*;/,
		''
	);
	assert.notEqual(mutated, launcher, 'The direct C refusal mutation must change actual source');
	assert.throws(() => namespaceRegistration(catalogue, Planner, workflow, mutated));
});
control('one Lua ABI cannot replace original mandatory pair', () =>
	assert.throws(() =>
		namespaceRegistration(
			catalogue,
			Planner,
			workflow,
			launcher.replace("const ABIS = ['luajit', 'lua5.4'];", "const ABIS = ['luajit'];")
		)
	)
);
assert.equal(count, 51, 'Independent direct C registration extension floor changed');
console.log(
	'[OK] Linux updater namespace registration: 8 source controls passed; no native credit.'
);

// Required native writer/hash closure and component lookup ports retain their gate.
const closureInputs = [
	'static/ergopti_plus/linux/infra/managed_http_deadline.lua',
	'static/ergopti_plus/linux/infra/native_timer.lua',
	'static/ergopti_plus/linux/infra/monotonic.lua',
	'static/ergopti_plus/linux/infra/paths.lua'
];
function closureRegistration(planner) {
	for (const input of closureInputs)
		assert.ok(planner.selectGates([input]).has('linux-updater-temp-native'), input);
}
for (const input of closureInputs) {
	control('actual native closure dependency ' + input, () =>
		assert.ok(Planner.selectGates([input]).has('linux-updater-temp-native'))
	);
	control('omitted native closure dependency ' + input, () =>
		assert.throws(() =>
			closureRegistration({
				...Planner,
				selectGates: (sources) =>
					sources.includes(input) ? new Set() : Planner.selectGates(sources)
			})
		)
	);
}
assert.equal(count, 59, 'Independent native closure dependency floor changed');
console.log(
	'[OK] Linux updater native closure registration: 8 source controls passed; no native credit.'
);

// Genuine Lua54 tool provision; source/model checks grant no native product credit.
const Provider = require('./prepare-linux-lua54-native-provider.cjs');
const providerSource = read('tools/test/prepare-linux-lua54-native-provider.cjs');
const providerEntrySource = read('tools/test/fixtures/lua54-provider-entry.c');
const vendorNames = [
	'simple example',
	'abi example',
	'variadic calls',
	'fundamental type passing',
	'structs, arrays, unions',
	'struct passing',
	'structs, unions array fields',
	'unions by value',
	'global variables',
	'memory-related utilities',
	'memory serialization',
	'callbacks',
	'table initializers',
	'parameterized types',
	'scalar types',
	'symbol redirection',
	'calling conventions',
	'constant expressions',
	'redefinitions',
	'casting rules',
	'type checks',
	'metatype',
	'metatype (5.4)'
];
function vendorRows() {
	return vendorNames.map((name) => ({
		name,
		result: name === 'unions by value' ? 'SKIP' : 'OK',
		returncode: name === 'unions by value' ? 77 : 0
	}));
}
function providerRegistration(source, producer, planner, text, entry) {
	assert.match(source, /const\s+COMMIT\s*=\s*'2621884230c9072ad77f7379609b74c9d6dbeb86'/);
	assert.match(source, /const\s+TREE\s*=\s*'016c13e960e1776898fd49322f70e2e849339ad1'/);
	assert.match(
		source,
		/const\s+MESON_BEFORE\s*=\s*'011b150827402869c5f2d742868510644f92c6abdafd0dfd1fa87e350601241c'/
	);
	assert.match(
		source,
		/const\s+MESON_AFTER\s*=\s*'7172cb0c5e29f0ac3469ea4cbdc7b4c64f2ca87017b7ddfb0cb33ff83121d0dc'/
	);
	assert.ok(!source.includes('cpp_link_args') && !source.includes('child_process'));
	assert.match(source, /python:\s*executable\s*\(\s*'\/usr\/bin\/python3'\s*,\s*env\s*\)/);
	assert.match(source, /path\.join\(build,\s*'tests\/libtestlib\.so'\)/);
	assert.match(source, /lstatSync\(filename,\s*\{\s*bigint:\s*true\s*\}\)/);
	assert.match(source, /await\s+child\s*\(command,\s*args,\s*phaseEnv,\s*cwd,\s*budgetMs\)/);
	assert.match(producer, /lua54Provider\s*=\s*await\s+prepareLua54Provider\s*\(/);
	assert.match(
		producer,
		/if\s*\(abi\s*===\s*'lua5\.4'\)\s*fixtureEnvironment\.LUA_CPATH\s*=\s*lua54Provider\.cpath/
	);
	assert.match(
		producer,
		/if\s*\(abi\s*===\s*'luajit'\s*&&\s*environment\.ERGOPTI_NATIVE_LUA_CPATH\)/
	);
	assert.match(entry, /cffi\s*!=\s*NULL\s*&&\s*ffi\s*!=\s*NULL\s*&&\s*cffi\s*==\s*ffi/);
	for (const file of [
		'tools/test/prepare-linux-lua54-native-provider.cjs',
		'tools/test/fixtures/lua54-provider-entry.c'
	])
		assert.ok(planner.selectGates([file]).has('linux-updater-temp-native'));
	const job = Pipeline.jobsOfText(text, '.github/workflows/ci-linux.yml').find(
		(value) => value.id === 'e2e-linux'
	);
	assert.ok(job);
	const steps = Pipeline.steps(job.body);
	const prepName = 'Terminate real descendants after their process leader exits';
	const prep = Pipeline.runOf(Pipeline.step(job.body, prepName)).join('\n');
	for (const pkg of ['meson', 'ninja-build', 'liblua5.4-dev', 'libffi-dev', 'pkg-config'])
		assert.ok(prep.split(/\s+/).includes(pkg), pkg);
	for (const name of Object.values(expected))
		assert.ok(
			steps.findIndex((step) => step.name === prepName) <
				steps.findIndex((step) => step.name === name)
		);
}
let providerCount = 0;
function providerControl(name, body) {
	body();
	providerCount++;
}
providerControl('all pinned vendor names and precise optional skip', () => {
	assert.deepEqual(Provider.TEST_NAMES, vendorNames);
	assert.deepEqual(Provider.vendorReceipt(vendorRows(), false), {
		passed: 22,
		vendor_optional_skipped: 1,
		registered: 23
	});
});
providerControl('missing vendor test refused', () =>
	assert.throws(() => Provider.vendorReceipt(vendorRows().slice(1), false))
);
providerControl('duplicate vendor test refused', () => {
	const rows = vendorRows();
	rows[1] = rows[0];
	assert.throws(() => Provider.vendorReceipt(rows, false));
});
providerControl('foreign vendor test refused', () => {
	const rows = vendorRows();
	rows[0].name = 'foreign';
	assert.throws(() => Provider.vendorReceipt(rows, false));
});
providerControl('required vendor skip refused', () => {
	const rows = vendorRows();
	rows[0].result = 'SKIP';
	rows[0].returncode = 77;
	assert.throws(() => Provider.vendorReceipt(rows, false));
});
providerControl('optional skip cannot be reported as pass', () => {
	const rows = vendorRows();
	rows[7].result = 'OK';
	rows[7].returncode = 0;
	assert.throws(() => Provider.vendorReceipt(rows, false));
});
providerControl('supported union ABI cannot skip', () =>
	assert.throws(() => Provider.vendorReceipt(vendorRows(), true))
);
providerControl('vendor nonzero pass refused', () => {
	const rows = vendorRows();
	rows[0].returncode = 1;
	assert.throws(() => Provider.vendorReceipt(rows, false));
});
providerControl('malformed feature refused', () =>
	assert.throws(() => Provider.vendorReceipt(vendorRows(), 'false'))
);
const providerFact = (ino = 7, nlink = 2, link = false) => ({
	dev: 3n,
	ino: BigInt(ino),
	nlink: BigInt(nlink),
	isFile: () => true,
	isSymbolicLink: () => link
});
const providerHash = 'a'.repeat(64);
providerControl('same genuine provider identity accepted', () =>
	Provider.sameProvider(providerFact(), providerFact(), providerHash, providerHash)
);
providerControl('different provider inode refused', () =>
	assert.throws(() =>
		Provider.sameProvider(providerFact(), providerFact(8), providerHash, providerHash)
	)
);
providerControl('different provider bytes refused', () =>
	assert.throws(() =>
		Provider.sameProvider(providerFact(), providerFact(), providerHash, 'b'.repeat(64))
	)
);
providerControl('provider symlink refused', () =>
	assert.throws(() =>
		Provider.sameProvider(providerFact(), providerFact(7, 2, true), providerHash, providerHash)
	)
);
providerControl('non-hardlinked provider refused', () =>
	assert.throws(() =>
		Provider.sameProvider(providerFact(7, 1), providerFact(), providerHash, providerHash)
	)
);
providerControl('unbound Meson source refused', () =>
	assert.throws(() => Provider.bindMeson(Buffer.from('foreign source')))
);
providerControl('real provider prerequisite registration', () =>
	providerRegistration(providerSource, launcher, Planner, workflow, providerEntrySource)
);
for (const pkg of ['meson', 'ninja-build', 'liblua5.4-dev', 'libffi-dev', 'pkg-config']) {
	providerControl('missing genuine SDK package ' + pkg, () => {
		const mutated = workflow.replace(
			' build-essential meson ninja-build liblua5.4-dev libffi-dev pkg-config',
			' build-essential meson ninja-build liblua5.4-dev libffi-dev pkg-config'.replace(
				' ' + pkg,
				''
			)
		);
		assert.notEqual(mutated, workflow);
		assert.throws(() =>
			providerRegistration(providerSource, launcher, Planner, mutated, providerEntrySource)
		);
	});
}
for (const file of [
	'tools/test/prepare-linux-lua54-native-provider.cjs',
	'tools/test/fixtures/lua54-provider-entry.c'
]) {
	providerControl('provider gate source selected ' + file, () =>
		assert.ok(Planner.selectGates([file]).has('linux-updater-temp-native'))
	);
	providerControl('omitted provider source selector ' + file, () =>
		assert.throws(() =>
			providerRegistration(
				providerSource,
				launcher,
				{
					...Planner,
					selectGates: (names) => (names.includes(file) ? new Set() : Planner.selectGates(names))
				},
				workflow,
				providerEntrySource
			)
		)
	);
}
providerControl('wrong native binding commit refused', () => {
	const mutated = providerSource.replace(
		'2621884230c9072ad77f7379609b74c9d6dbeb86',
		'0'.repeat(40)
	);
	assert.notEqual(mutated, providerSource);
	assert.throws(() =>
		providerRegistration(mutated, launcher, Planner, workflow, providerEntrySource)
	);
});
providerControl('missing actual nonnull entry guard refused', () => {
	const mutated = providerEntrySource.replace(
		'cffi != NULL && ffi != NULL && cffi == ffi',
		'cffi == ffi'
	);
	assert.notEqual(mutated, providerEntrySource);
	assert.throws(() => providerRegistration(providerSource, launcher, Planner, workflow, mutated));
});
providerControl('adjacent exact high inode cannot borrow provider', () =>
	assert.throws(() =>
		Provider.sameProvider(
			providerFact(9007199254740992n),
			providerFact(9007199254740993n),
			providerHash,
			providerHash
		)
	)
);
providerControl('exact high inode hardlink remains admitted', () =>
	Provider.sameProvider(
		providerFact(9007199254740993n),
		providerFact(9007199254740993n),
		providerHash,
		providerHash
	)
);
providerControl('rounded Number inode facts cannot authorize hardlink', () => {
	const first = { ...providerFact(), dev: 3, ino: 9007199254740992, nlink: 2 };
	const second = { ...first, ino: Number(9007199254740993n) };
	assert.throws(() => Provider.sameProvider(first, second, providerHash, providerHash));
});
providerControl('different exact high device cannot borrow provider', () => {
	const first = { ...providerFact(), dev: 9007199254740992n };
	const second = { ...providerFact(), dev: 9007199254740993n };
	assert.throws(() => Provider.sameProvider(first, second, providerHash, providerHash));
});
assert.equal(providerCount, 31, 'Independent genuine provider source/model floor changed');
console.log(
	'[OK] Linux Lua54 native provider prerequisite: 31 source/model controls passed; no native credit.'
);

// Versioned Lua54 native paths outrank LUA_CPATH in the genuine interpreter.
let versionedCpathCount = 0;
function cpathControl(name, body) {
	body();
	versionedCpathCount++;
}
cpathControl('private provider precedes genuine default native Lua54 paths', () => {
	assert.equal(
		Provider.providerCpath('/private/provider/build', undefined),
		'/private/provider/build/?.so;;'
	);
});
cpathControl('versioned native Lua54 luv and lfs paths retained exactly', () => {
	const native = '/native/lua/5.4/?.so;/native/lua/5.4/?/init.so;;';
	assert.equal(
		Provider.providerCpath('/private/provider/build', native),
		'/private/provider/build/?.so;' + native
	);
});
cpathControl('wrong type versioned native path refused', () =>
	assert.throws(() => Provider.providerCpath('/private/provider/build', true))
);
cpathControl('empty versioned native path refused', () =>
	assert.throws(() => Provider.providerCpath('/private/provider/build', ''))
);
cpathControl('NUL versioned native path refused', () =>
	assert.throws(() => Provider.providerCpath('/private/provider/build', '/native/\0/?.so'))
);
cpathControl('newline versioned native path refused', () =>
	assert.throws(() => Provider.providerCpath('/private/provider/build', '/native/\n/?.so'))
);
function versionedCpathRegistration(helper, producer) {
	assert.match(
		helper,
		/const\s+cpath\s*=\s*providerCpath\s*\(path\.join\(directory,\s*'build'\),\s*env\.LUA_CPATH_5_4\)/
	);
	assert.match(helper, /LUA_CPATH:\s*cpath/);
	assert.match(helper, /LUA_CPATH_5_4:\s*cpath/);
	assert.match(
		producer,
		/if\s*\(abi\s*===\s*'lua5\.4'\)\s*fixtureEnvironment\.LUA_CPATH_5_4\s*=\s*lua54Provider\.cpath/
	);
}
cpathControl('actual helper and fixture versioned admission is mandatory', () =>
	versionedCpathRegistration(providerSource, launcher)
);
cpathControl('legacy-only fixture Cpath cannot satisfy versioned admission', () => {
	const pattern =
		/if\s*\(abi\s*===\s*'lua5\.4'\)\s*fixtureEnvironment\.LUA_CPATH_5_4\s*=\s*lua54Provider\.cpath\s*;/;
	assert.ok(pattern.test(launcher));
	const mutated = launcher.replace(pattern, '');
	assert.notEqual(mutated, launcher);
	assert.throws(() => versionedCpathRegistration(providerSource, mutated));
});
assert.equal(versionedCpathCount, 8, 'Independent versioned native Lua54 Cpath floor changed');
console.log(
	'[OK] Linux Lua54 versioned native paths: 8 source/model controls passed; no native credit.'
);

// Extra genuine C4 is a private prerequisite, never extra public CI native credit.
const Capture = require('./run-linux-updater-temp-native.cjs');
const captureFixture =
	'static/ergopti_plus/linux/tests/hardware/run_native_artifact_capture_completion.c';
const captureLines = [
	'PASS invalid literal component refuses before any native owner acquisition',
	'PASS missing component retains then closes exact acquired descriptors',
	'PASS non-directory component retains then closes exact acquired descriptors',
	'PASS completed reserve still refuses actual foreign namespace noise',
	'Native capture completion: 4 passed; 0 skipped; exact native retirement complete.'
];
const captureOutput = captureLines.join('\n') + '\n';
const captureResult = () => ({ status: 0, signal: null, stdout: captureOutput, stderr: '' });
let captureCount = 0;
function captureControl(name, body) {
	body();
	captureCount++;
}
captureControl('exact closed native capture four receipt admitted', () =>
	assert.equal(Capture.captureReceipt(captureResult()), true)
);
captureControl('native capture failure exit refused', () =>
	assert.equal(Capture.captureReceipt({ ...captureResult(), status: 1 }), false)
);
captureControl('native capture signal refused', () =>
	assert.equal(Capture.captureReceipt({ ...captureResult(), signal: 'SIGTERM' }), false)
);
captureControl('native capture stderr refused', () =>
	assert.equal(Capture.captureReceipt({ ...captureResult(), stderr: 'diagnostic' }), false)
);
captureControl('missing native capture case refused', () =>
	assert.equal(
		Capture.captureReceipt({ ...captureResult(), stdout: captureLines.slice(1).join('\n') + '\n' }),
		false
	)
);
captureControl('extra native capture output refused', () =>
	assert.equal(
		Capture.captureReceipt({ ...captureResult(), stdout: captureOutput + 'PASS extra\n' }),
		false
	)
);
captureControl('partial native capture summary refused', () =>
	assert.equal(
		Capture.captureReceipt({
			...captureResult(),
			stdout: captureOutput.replace('4 passed', '3 passed')
		}),
		false
	)
);
captureControl('native capture skip refused', () =>
	assert.equal(
		Capture.captureReceipt({
			...captureResult(),
			stdout: captureOutput.replace('0 skipped', '1 skipped')
		}),
		false
	)
);
function captureRegistration(producer, planner) {
	assert.ok(planner.selectGates([captureFixture]).has('linux-updater-temp-native'));
	assert.match(producer, /'static\/ergopti_plus\/linux\/'\s*\+\s*CAPTURE/);
	assert.match(
		producer,
		/await\s+child\s*\(\s*compiler,\s*\[\s*'-std=c11',\s*'-I',\s*sourceDirectory,\s*path\.join\(\s*driver,\s*CAPTURE\),\s*generated,\s*'-Wl,-rpath,'\s*\+\s*outputDirectory,\s*'-o',\s*captureBinary\s*\]/
	);
	assert.match(
		producer,
		/await\s+child\s*\(\s*captureBinary,\s*\[work\],\s*captureEnvironment,\s*work,\s*10000,\s*true\)/
	);
	assert.match(producer, /if\s*\(!captureReceipt\(capture\)\)\s*refused\(\)/);
	const captured = producer.indexOf("phase = 'actual-native-capture-completion'");
	const namespace = producer.indexOf("phase = 'actual-native-namespace-cleanup'");
	assert.ok(captured >= 0 && namespace > captured);
	assert.match(producer, /LD_LIBRARY_PATH:\s*outputDirectory/);
	assert.match(producer, /delete\s+captureEnvironment\.LD_PRELOAD/);
	assert.match(producer, /delete\s+captureEnvironment\.LD_AUDIT/);
	assert.match(producer, /fixture:\s*'capture-completion',\s*abi:\s*'native-C'/);
	assert.match(producer, /admitted_checks:\s*4,\s*skipped:\s*0,\s*physical_phase_closed:\s*true/);
	assert.match(
		producer,
		/library_sha256:\s*nativeSha,\s*executable_sha256:\s*captureExecutable\.sha256/
	);
}
captureControl('capture four mandatory phase and private row registered', () =>
	captureRegistration(launcher, Planner)
);
captureControl('omitted capture source watch refused', () =>
	assert.throws(() =>
		captureRegistration(launcher, {
			...Planner,
			selectGates: (sources) =>
				sources.includes(captureFixture) ? new Set() : Planner.selectGates(sources)
		})
	)
);
captureControl('missing mandatory capture refusal is not optional', () => {
	const pattern = /if\s*\(!captureReceipt\(capture\)\)\s*refused\(\)\s*;/;
	assert.ok(pattern.test(launcher));
	const mutated = launcher.replace(pattern, '');
	assert.notEqual(mutated, launcher);
	assert.throws(() => captureRegistration(mutated, Planner));
});
captureControl('old public receipts remain exact namespace5 plus family24', () => {
	const head = 'a'.repeat(40);
	const ownership =
		'[OK] Linux updater namespace cleanup: SHA=' +
		head +
		'; 5 actual checks; 0 skipped; closure complete.\n[OK] Linux updater temporary ownership: SHA=' +
		head +
		'; 24 actual checks; 0 skipped; closure complete.\n';
	assert.equal(Capture.evidenceCount('ownership', ownership, head), 24);
	assert.equal(Capture.evidenceCount('namespace', ownership, head), 5);
	assert.throws(() => Capture.evidenceCount('ownership', captureOutput + ownership, head));
});
assert.equal(
	captureCount,
	12,
	'Independent native capture prerequisite source/model floor changed'
);
console.log(
	'[OK] Linux native capture prerequisite: 12 source/model controls passed; no native credit.'
);

const cryptoOutput =
	'PASS actual native SHA256 abc\nPASS actual native SHA256 one zero byte\nPASS actual native SHA256 empty\nSUMMARY 3 passed, 0 failed, 0 skipped\n';
const cryptoResult = () => ({ status: 0, signal: null, stdout: cryptoOutput, stderr: '' });
let cryptoCount = 0;
function cryptoControl(name, body) {
	body();
	cryptoCount++;
}
cryptoControl('exact three genuine native digest inputs admitted', () =>
	assert.equal(Capture.cryptoReceipt(cryptoResult()), true)
);
cryptoControl('native digest exit failure refused', () =>
	assert.equal(Capture.cryptoReceipt({ ...cryptoResult(), status: 1 }), false)
);
cryptoControl('missing native digest input refused', () =>
	assert.equal(
		Capture.cryptoReceipt({
			...cryptoResult(),
			stdout: cryptoOutput.replace('PASS actual native SHA256 one zero byte\n', '')
		}),
		false
	)
);
cryptoControl('wrong digest receipt cannot replace zero-byte case', () =>
	assert.equal(
		Capture.cryptoReceipt({
			...cryptoResult(),
			stdout: cryptoOutput.replace('one zero byte', 'one nonzero byte')
		}),
		false
	)
);
cryptoControl('native digest skip or diagnostic refused', () => {
	assert.equal(
		Capture.cryptoReceipt({
			...cryptoResult(),
			stdout: cryptoOutput.replace('0 skipped', '1 skipped')
		}),
		false
	);
	assert.equal(Capture.cryptoReceipt({ ...cryptoResult(), stderr: 'diagnostic' }), false);
});
const cryptoInputs = [
	'static/ergopti_plus/linux/tests/hardware/run_openssl_byte_input_native.lua',
	'static/ergopti_plus/linux/infra/openssl_digest.lua'
];
function cryptoRegistration(producer, planner) {
	for (const input of cryptoInputs)
		assert.ok(planner.selectGates([input]).has('linux-updater-temp-native'));
	assert.match(
		producer,
		/path\.join\(\s*driver,\s*CRYPTO\),\s*path\.join\(\s*driver,\s*'infra\/openssl_digest\.lua'\)/
	);
	assert.match(producer, /if\s*\(!cryptoReceipt\(crypto\)\)\s*refused\(\)/);
	assert.match(producer, /cryptoEnvironment\.LUA_CPATH_5_4\s*=\s*lua54Provider\.cpath/);
	assert.match(producer, /fixture:\s*'openssl-byte-input',\s*abi,/);
	assert.match(producer, /admitted_checks:\s*3,\s*skipped:\s*0,\s*physical_phase_closed:\s*true/);
}
cryptoControl('mandatory two ABI digest phase uses exact module path', () =>
	cryptoRegistration(launcher, Planner)
);
cryptoControl('missing digest dependency watch refused', () => {
	for (const input of cryptoInputs)
		assert.throws(() =>
			cryptoRegistration(launcher, {
				...Planner,
				selectGates: (sources) =>
					sources.includes(input) ? new Set() : Planner.selectGates(sources)
			})
		);
});
assert.equal(cryptoCount, 7, 'Independent native digest prerequisite source/model floor changed');
console.log(
	'[OK] Linux native digest prerequisite: 7 source/model controls passed; no native credit.'
);
