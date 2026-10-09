// tools/test/test-linux-updater-archive-registration.cjs

/** Independent mandatory archive/source-control registration and receipt refusals. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Pipeline = require('./ci-pipeline.cjs');
const Planner = require('./verify-change.cjs');
const Evidence = require('./linux-updater-archive-evidence.cjs');
const Controls = require('./run-linux-archive-source-controls.cjs');
const ROOT = path.resolve(__dirname, '../..');
const read = (name) => fs.readFileSync(path.join(ROOT, name), 'utf8');
const aliases = JSON.parse(read('package.json')).scripts;
const inventory = read('tools/test/run-js-suite.cjs');
const coverage = JSON.parse(read('.github/linux-ci-coverage.json'));
const workflow = read('.github/workflows/ci-linux.yml');
const ARCHIVE = 'Qualify native updater archive pipeline';
const SOURCE = 'Qualify archive crypto and bin parent source controls';
const SUBJECTS = {
	'updater-archive-pipeline': 15,
	'archive-source-crypto': 8,
	'archive-source-bin-parent': 4
};
const commands = {
	'linux-updater-archive-native': 'test:linux:updater-archive-native',
	'linux-archive-source-controls': 'test:linux:archive-source-controls'
};
const sources = {
	'linux-updater-archive-native': [
		'tools/test/run-linux-updater-archive-native.cjs',
		'tools/test/prepare-linux-updater-archive-snapshot.py',
		'tools/test/run-linux-managed-http-phase.py',
		'static/ergopti_plus/linux/tests/hardware/run_updater_archive_pipeline.lua',
		'static/ergopti_plus/linux/tests/hardware/run_updater_archive_pipeline.py',
		'static/ergopti_plus/linux/modules/updater/manager.lua',
		'static/ergopti_plus/linux/modules/updater/installer.lua',
		'static/ergopti_plus/linux/modules/updater/archive_transfer.lua',
		'static/ergopti_plus/linux/infra/archive_output.lua',
		'static/ergopti_plus/linux/infra/fd_sha256.lua',
		'static/ergopti_plus/linux/native/archive_output/archive_publication.c',
		'static/ergopti_plus/linux/native/archive_output/archive_publication.h',
		'tools/build/build-linux-native-output.sh',
		'tools/build/build-linux-driver.sh'
	],
	'linux-archive-source-controls': [
		'tools/test/fixtures/linux-explicit-crypto-staging.py',
		'tools/test/fixtures/linux-native-bin-parents.py',
		'tools/build/stage-linux-network-runtime.py',
		'static/ergopti_plus/linux/install.sh',
		'tools/test/run-linux-archive-source-controls.cjs'
	]
};
let passed = 0;
function control(name, body) {
	body();
	passed++;
}
function validateRegistration(scripts, suite, planner, catalogue) {
	for (const [alias, file] of [
		['test:linux:updater-archive-native', 'run-linux-updater-archive-native.cjs'],
		['test:linux-updater-archive-receipt', 'test-linux-updater-archive-receipt.cjs'],
		['test:linux-updater-archive-registration', 'test-linux-updater-archive-registration.cjs'],
		['test:linux:archive-source-controls', 'run-linux-archive-source-controls.cjs']
	])
		assert.equal(scripts[alias], 'node ./tools/test/' + file);
	for (const file of [
		'test-linux-updater-archive-receipt.cjs',
		'test-linux-updater-archive-registration.cjs'
	])
		assert.ok(suite.includes("args: ['tools/test/" + file + "']"));
	for (const file of [
		'run-linux-updater-archive-native.cjs',
		'run-linux-archive-source-controls.cjs'
	])
		assert.ok(!suite.includes("args: ['tools/test/" + file + "']"));
	for (const [gate, alias] of Object.entries(commands)) {
		assert.equal(planner.GATE_COMMANDS[gate]?.npm, alias);
		assert.equal(planner.GATE_COMMANDS[gate]?.platform, 'linux');
		for (const source of [
			...sources[gate],
			'.github/workflows/ci-linux.yml',
			'.github/linux-ci-coverage.json'
		])
			assert.ok(planner.selectGates([source]).has(gate), source);
	}
	assert.equal(catalogue.jobs['e2e-linux'].classification, 'mandatory');
	for (const [subject, floor] of Object.entries(SUBJECTS))
		assert.equal(catalogue.jobs['e2e-linux'].subjects[subject], floor);
	// Existing native receipts retain their independent required floors.
	assert.equal(catalogue.jobs['e2e-linux'].subjects['managed-http-output'], 18);
	assert.equal(catalogue.jobs['e2e-linux'].subjects['managed-http-public'], 30);
}
function validateWorkflow(text) {
	const jobs = Pipeline.jobsOfText(text, '.github/workflows/ci-linux.yml').filter(
		(job) => job.id === 'e2e-linux'
	);
	assert.equal(jobs.length, 1);
	const body = jobs[0].body;
	const steps = Pipeline.steps(body);
	const at = steps.findIndex((step) => step.name === ARCHIVE);
	assert.ok(at > 0);
	assert.equal(steps[at - 1].name, 'Qualify native managed HTTP public and retained output');
	assert.equal(steps[at + 1].name, SOURCE);
	for (const [name, timeout] of [
		[ARCHIVE, '35'],
		[SOURCE, '3']
	]) {
		assert.equal(steps.filter((step) => step.name === name).length, 1);
		const step = Pipeline.step(body, name);
		assert.equal(Pipeline.stepField(step, 'if'), '${{ !cancelled() }}');
		assert.equal(Pipeline.stepField(step, 'continue-on-error'), null);
		assert.equal(Pipeline.stepField(step, 'timeout-minutes'), timeout);
	}
	assert.deepEqual(Pipeline.runOf(Pipeline.step(body, ARCHIVE)), [
		'set -euo pipefail',
		'export ERGOPTI_MANAGED_NATIVE_EXPECTED_HEAD="$GITHUB_SHA"',
		'env -u PKG_CONFIG_SYSROOT_DIR -u ERGOPTI_MANAGED_NATIVE_GIO_SYSROOT npm run --silent test:linux:updater-archive-native | tee "$RUNNER_TEMP/linux-updater-archive-native.log"'
	]);
	assert.deepEqual(Pipeline.runOf(Pipeline.step(body, SOURCE)), [
		'set -euo pipefail',
		'npm run --silent test:linux:archive-source-controls | tee "$RUNNER_TEMP/linux-archive-source-controls.log"'
	]);
	const setup = Pipeline.runOf(
		Pipeline.step(body, 'Prepare authenticated managed HTTP validation tools')
	).join('\n');
	for (const dependency of [
		'build-essential',
		'pkg-config',
		'libssl-dev',
		'luajit',
		'lua-luv',
		'openssl'
	])
		assert.ok(setup.split(/\s+/).includes(dependency), dependency);
	const record = Pipeline.runOf(Pipeline.step(body, 'Record mandatory E2E evidence')).join('\n');
	for (const line of [
		'updater_archive_assertions=$(node tools/test/linux-updater-archive-evidence.cjs archive "$RUNNER_TEMP/linux-updater-archive-native.log")',
		'archive_crypto_assertions=$(node tools/test/linux-updater-archive-evidence.cjs crypto "$RUNNER_TEMP/linux-archive-source-controls.log")',
		'archive_bin_parent_assertions=$(node tools/test/linux-updater-archive-evidence.cjs parents "$RUNNER_TEMP/linux-archive-source-controls.log")',
		'--subject "updater-archive-pipeline=$updater_archive_assertions"',
		'--subject "archive-source-crypto=$archive_crypto_assertions"',
		'--subject "archive-source-bin-parent=$archive_bin_parent_assertions"'
	])
		assert.ok(record.includes(line), line);
}
control('actual registration', () => validateRegistration(aliases, inventory, Planner, coverage));
control('actual mandatory workflow', () => validateWorkflow(workflow));
for (const alias of [
	'test:linux:updater-archive-native',
	'test:linux-updater-archive-receipt',
	'test:linux-updater-archive-registration',
	'test:linux:archive-source-controls'
])
	control('missing alias ' + alias, () =>
		assert.throws(() =>
			validateRegistration({ ...aliases, [alias]: undefined }, inventory, Planner, coverage)
		)
	);
for (const file of [
	'test-linux-updater-archive-receipt.cjs',
	'test-linux-updater-archive-registration.cjs'
])
	control('missing normal registration ' + file, () =>
		assert.throws(() =>
			validateRegistration(
				aliases,
				inventory.replace("args: ['tools/test/" + file + "']", "args: ['missing']"),
				Planner,
				coverage
			)
		)
	);
for (const gate of Object.keys(commands)) {
	control('missing planner ' + gate, () =>
		assert.throws(() =>
			validateRegistration(
				aliases,
				inventory,
				{ ...Planner, GATE_COMMANDS: { ...Planner.GATE_COMMANDS, [gate]: undefined } },
				coverage
			)
		)
	);
	control('missing selected gate ' + gate, () =>
		assert.throws(() =>
			validateRegistration(
				aliases,
				inventory,
				{
					...Planner,
					selectGates: (files) =>
						new Map([...Planner.selectGates(files)].filter(([key]) => key !== gate))
				},
				coverage
			)
		)
	);
}
for (const subject of Object.keys(SUBJECTS))
	control('missing coverage ' + subject, () =>
		assert.throws(() =>
			validateRegistration(aliases, inventory, Planner, {
				...coverage,
				jobs: {
					...coverage.jobs,
					'e2e-linux': {
						...coverage.jobs['e2e-linux'],
						subjects: { ...coverage.jobs['e2e-linux'].subjects, [subject]: undefined }
					}
				}
			})
		)
	);
function mutate(needle, replacement) {
	if (needle === 'export ERGOPTI_MANAGED_NATIVE_EXPECTED_HEAD="$GITHUB_SHA"') {
		const jobs = Pipeline.jobsOfText(workflow, '.github/workflows/ci-linux.yml').filter(
			(job) => job.id === 'e2e-linux'
		);
		assert.equal(jobs.length, 1, 'The archive mutation needs its actual E2E job');
		const archive = Pipeline.step(jobs[0].body, ARCHIVE);
		assert.equal(archive.split(needle).length - 1, 1, 'The archive step needs one source HEAD');
		const changedArchive = archive.replace(needle, replacement);
		assert.notEqual(changedArchive, archive, 'The archive source HEAD must actually change');
		needle = archive;
		replacement = changedArchive;
	}
	assert.equal(workflow.split(needle).length - 1, 1, 'Independent mutation needs one target');
	const mutated = workflow.replace(needle, () => replacement);
	assert.notEqual(mutated, workflow, 'The workflow mutation must actually change source');
	assert.throws(() => validateWorkflow(mutated));
}
for (const [needle, replacement] of [
	['- name: ' + ARCHIVE, '- name: Removed archive'],
	['- name: ' + SOURCE, '- name: Removed source controls'],
	[
		'- name: ' + ARCHIVE + '\n        if: ${{ !cancelled() }}',
		'- name: ' + ARCHIVE + '\n        if: false'
	],
	[
		'- name: ' + SOURCE + '\n        if: ${{ !cancelled() }}',
		'- name: ' + SOURCE + '\n        if: false'
	],
	[
		'- name: ' + ARCHIVE + '\n        if: ${{ !cancelled() }}',
		'- name: ' + ARCHIVE + '\n        if: ${{ !cancelled() }}\n        continue-on-error: true'
	],
	[
		'export ERGOPTI_MANAGED_NATIVE_EXPECTED_HEAD="$GITHUB_SHA"',
		'export ERGOPTI_MANAGED_NATIVE_EXPECTED_HEAD="foreign"'
	],
	['test:linux:updater-archive-native | tee', 'test:linux:updater-archive-native || true | tee'],
	['test:linux:archive-source-controls | tee', 'test:linux:archive-source-controls || true | tee'],
	[
		'linux-updater-archive-evidence.cjs archive "$RUNNER_TEMP/linux-updater-archive-native.log"',
		'linux-updater-archive-evidence.cjs archive "$RUNNER_TEMP/missing.log"'
	],
	[
		'--subject "updater-archive-pipeline=$updater_archive_assertions"',
		'--subject "updater-archive-pipeline=15"'
	],
	[
		'--subject "archive-source-bin-parent=$archive_bin_parent_assertions"',
		'--subject "archive-source-bin-parent=4"'
	]
])
	control('workflow omission/refusal ' + needle, () => mutate(needle, replacement));
const archiveReceipt =
	'[OK] Linux updater archive pipeline: 3 actual native cases; 15 checks; 0 skipped; closure complete.\n';
const sourceReceipt =
	'[OK] Linux archive source crypto: 8 controls passed; 0 skipped; controlled metadata only.\n' +
	'[OK] Linux archive source bin parents: 4 controls passed; 0 skipped; filesystem guards only.\n';
control('exact native console receipt', () =>
	assert.equal(Evidence.readArchiveCount(archiveReceipt), 15)
);
control('exact source scope console receipt', () =>
	assert.deepEqual(Evidence.readSourceCounts(sourceReceipt), { crypto: 8, parents: 4 })
);
for (const [reader, good] of [
	[Evidence.readArchiveCount, archiveReceipt],
	[Evidence.readSourceCounts, sourceReceipt]
])
	for (const invalid of [
		'',
		good.trimEnd(),
		good + good,
		good.replace('0 skipped', '1 skipped'),
		good.replace('[OK]', '[FAIL]'),
		good.replace(/\n/g, '\r\n'),
		good + 'private extra\n'
	])
		control('partial/extra/skipped evidence', () => assert.throws(() => reader(invalid)));
const cases = {
	crypto: [
		'missing descriptor refuses',
		'invalid descriptor refuses',
		'implicit transitive crypto is insufficient',
		'relative metadata library path refuses',
		'wrong native SONAME refuses',
		'absent SONAME refuses',
		'ambiguous SONAME refuses',
		'explicit actual-metadata root is retained independently of curl'
	],
	parents: [
		'checkout source bin symlink',
		'release payload bin symlink',
		'installed bin symlink',
		'ordinary recovery'
	]
};
for (const [kind, labels] of Object.entries(cases)) {
	const end =
		kind === 'crypto'
			? '8 PASS, 0 FAIL, 0 SKIP; controlled metadata only'
			: '4 PASS, 0 FAIL, 0 SKIP; filesystem guard only';
	const good = {
		status: 0,
		signal: null,
		error: null,
		stderr: '',
		stdout: [...labels.map((label) => 'PASS ' + label), end, ''].join('\n')
	};
	control('literal original complete control ' + kind, () =>
		assert.equal(Controls.receipt(kind, good), true)
	);
	for (const change of [
		{ status: 1 },
		{ signal: 'SIGTERM' },
		{ error: 'owned_cleanup_pending' },
		{ stderr: 'private error' },
		{ stdout: good.stdout.replace('PASS ' + labels[0] + '\n', '') },
		{ stdout: good.stdout + 'PASS ' + labels[0] + '\n' },
		{ stdout: good.stdout.replace('0 SKIP', '1 SKIP') },
		{ stdout: good.stdout.trimEnd() }
	])
		control('control physical/partial/skipped refusal ' + kind, () =>
			assert.equal(Controls.receipt(kind, { ...good, ...change }), false)
		);
}
assert.equal(passed, 60, 'Independent registration/control-receipt floor');
console.log('Archive mandatory registration: 60 controls passed; 0 skipped.');

// Separate follow-up controls leave the entire original sixty-case prefix exact.
const followup =
	'[OK] Linux archive snapshot: 5 controls passed; 0 skipped; actual private Git snapshots only.\n' +
	'[OK] Linux CONNECT terminal protocol: 9 controls passed; 0 skipped; modeled socket/select only.\n';
function validateFollowup(catalogue, planner, text) {
	assert.equal(catalogue.jobs['e2e-linux'].subjects['archive-private-snapshot'], 5);
	assert.equal(catalogue.jobs['e2e-linux'].subjects['connect-terminal-protocol-model'], 9);
	for (const source of [
		'tools/test/test-linux-updater-archive-snapshot.py',
		'tools/test/prepare-linux-updater-archive-snapshot.py',
		'tools/test/fixtures/linux-connect-terminal-protocol.py',
		'static/ergopti_plus/linux/tests/hardware/run_managed_http_native.py'
	])
		assert.ok(planner.selectGates([source]).has('linux-archive-source-controls'), source);
	const jobs = Pipeline.jobsOfText(text, '.github/workflows/ci-linux.yml').filter(
		(job) => job.id === 'e2e-linux'
	);
	assert.equal(jobs.length, 1);
	const record = Pipeline.runOf(Pipeline.step(jobs[0].body, 'Record mandatory E2E evidence')).join(
		'\n'
	);
	for (const line of [
		'archive_snapshot_assertions=$(node tools/test/linux-updater-archive-evidence.cjs snapshot "$RUNNER_TEMP/linux-archive-source-controls.log")',
		'connect_protocol_assertions=$(node tools/test/linux-updater-archive-evidence.cjs connect "$RUNNER_TEMP/linux-archive-source-controls.log")',
		'--subject "archive-private-snapshot=$archive_snapshot_assertions"',
		'--subject "connect-terminal-protocol-model=$connect_protocol_assertions"'
	])
		assert.ok(record.includes(line), line);
}
control('follow-up mandatory source/model registration', () =>
	validateFollowup(coverage, Planner, workflow)
);
for (const subject of ['archive-private-snapshot', 'connect-terminal-protocol-model'])
	control('missing follow-up scope coverage ' + subject, () =>
		assert.throws(() =>
			validateFollowup(
				{
					...coverage,
					jobs: {
						...coverage.jobs,
						'e2e-linux': {
							...coverage.jobs['e2e-linux'],
							subjects: { ...coverage.jobs['e2e-linux'].subjects, [subject]: undefined }
						}
					}
				},
				Planner,
				workflow
			)
		)
	);
control('missing follow-up planner selection', () =>
	assert.throws(() =>
		validateFollowup(coverage, { ...Planner, selectGates: () => new Map() }, workflow)
	)
);
for (const [needle, replacement] of [
	[
		'--subject "archive-private-snapshot=$archive_snapshot_assertions"',
		'--subject "archive-private-snapshot=5"'
	],
	[
		'--subject "connect-terminal-protocol-model=$connect_protocol_assertions"',
		'--subject "connect-terminal-protocol-model=5"'
	]
])
	control('follow-up workflow receiving omission', () => {
		assert.equal(workflow.split(needle).length - 1, 1);
		assert.throws(() => validateFollowup(coverage, Planner, workflow.replace(needle, replacement)));
	});
control('whole follow-up frame scopes four actual Git and five protocol models', () =>
	assert.deepEqual(Evidence.readFollowupCounts(sourceReceipt + followup), {
		snapshot: 5,
		connect: 9
	})
);
for (const bad of [
	sourceReceipt,
	followup,
	sourceReceipt + followup.trimEnd(),
	sourceReceipt + followup + followup,
	sourceReceipt + followup.replace('0 skipped', '1 skipped'),
	sourceReceipt + followup.replace('5 controls', '4 controls')
])
	control('missing/partial/duplicated/skipped follow-up frame', () =>
		assert.throws(() => Evidence.readFollowupCounts(bad))
	);
for (const [kind, line] of [
	['snapshot', 'Archive snapshot controls: 5 passed; 0 skipped.\n'],
	[
		'connect',
		'CONNECT terminal protocol controls: 9 passed; 0 skipped; modeled socket/select only.\n'
	]
]) {
	const good = { status: 0, signal: null, error: null, stdout: line, stderr: '' };
	control('fixed follow-up complete child ' + kind, () =>
		assert.equal(Controls.receipt(kind, good), true)
	);
	for (const change of [
		{ status: 1 },
		{ signal: 'SIGTERM' },
		{ error: 'owned_cleanup_pending' },
		{ stderr: 'private failure' },
		{ stdout: '' },
		{ stdout: line + line },
		{ stdout: line.trimEnd() }
	])
		control('follow-up child/physical/partial refusal ' + kind, () =>
			assert.equal(Controls.receipt(kind, { ...good, ...change }), false)
		);
}
assert.equal(passed, 89, 'Separate follow-up fixed receiving control floor');
console.log('Archive mandatory follow-up registration: 29 additional controls passed; 0 skipped.');

// Rollback activation is atomic with its authentic marker and whole old-root oracle.
let rollbackControls = 0;
function rollbackControl(name, body) {
	body();
	rollbackControls++;
}
const rollbackPython = read(
	'static/ergopti_plus/linux/tests/hardware/run_updater_archive_pipeline.py'
);
const rollbackLua = read(
	'static/ergopti_plus/linux/tests/hardware/run_updater_archive_pipeline.lua'
);
rollbackControl('exact three unique modes', () =>
	assert.match(rollbackPython, /MODES = \("happy", "wrong_digest", "smoke_rollback"\)/)
);
rollbackControl('ordinary literal executed smoke writes fixed receipt before exit42', () => {
	assert.match(rollbackPython, /ERGOPTI_PIPELINE_SMOKE_EXECUTED_EXIT42/);
	assert.match(rollbackPython, /shlex\.quote\(str\(observation\)\)/);
	assert.match(rollbackPython, /exit 43/);
	assert.match(rollbackPython, /exit 42/);
});
rollbackControl('observation is precreated outside installed tree', () => {
	assert.match(rollbackPython, /smoke_observation = work \/ "smoke-executed.receipt"/);
	assert.match(rollbackPython, /with smoke_observation\.open\("xb"\) as marker:/);
	assert.match(rollbackPython, /ordinary\(smoke_observation\) != b""/);
});
rollbackControl('exact observed execution identity and bytes', () => {
	assert.match(rollbackPython, /marker_identity\(smoke_observation\) != smoke_identity/);
	assert.match(rollbackPython, /ordinary\(smoke_observation\) != SMOKE_RECEIPT/);
});
rollbackControl('whole old root inode path modes and contents restored', () => {
	assert.match(rollbackPython, /fact\.st_dev, fact\.st_ino/);
	assert.match(rollbackPython, /stat\.S_IMODE\(fact\.st_mode\)/);
	assert.match(rollbackPython, /tree_identity\(installed\) != original_tree/);
	assert.match(rollbackPython, /ordinary\(installed \/ MARKER\) != BEFORE/);
});
rollbackControl('actual smoke-failure callback never substitutes success', () =>
	assert.match(
		rollbackLua,
		/installed\.ok == false and installed\.detail == "updated wrapper smoke failed; previous installation restored"/
	)
);
rollbackControl('rollback artifact actual cancellation and physical drain remain', () => {
	assert.match(rollbackLua, /Manager\.cancel_update\(\) == true/);
	assert.match(rollbackLua, /uv\.loop_alive\(\) == false and namespace_descriptors\(\) == 0/);
});
rollbackControl('old exact native two-case console refuses after activation', () =>
	assert.throws(() =>
		Evidence.readArchiveCount(
			'[OK] Linux updater archive pipeline: 2 actual native cases; 10 checks; 0 skipped; closure complete.\n'
		)
	)
);
assert.equal(rollbackControls, 8, 'Independent rollback receiving registration floor');
console.log('Archive rollback registration: 8 additional source/model controls passed; 0 skipped.');
