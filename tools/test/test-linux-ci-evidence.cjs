// tools/test/test-linux-ci-evidence.cjs

/**
 * ============================================================================
 * MODULE: Linux CI Evidence Contract Tests
 * DESCRIPTION:
 * Mutation-tests every GitHub dependency result and the evidence requirements
 * that prevent linux-ok from accepting a skipped or unexecuted mandatory lane.
 * The workflow checks read the Linux box through tools/test/ci-pipeline.cjs,
 * which throws when linux-ok or the box itself is missing, so the negative
 * checks below cannot pass against a file that lost the gate they inspect.
 * The manifest's subjects are floored at the count the per-job layout proved,
 * and every harness of test-linux must run under !cancelled(), so a red E2E
 * hides no later harness and a cancelled run stops at once. The unit and E2E
 * counts must be read from what those suites printed: a review hard-coded the
 * unit count and every test stayed green.
 * ============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { verifyAggregate } = require('./linux-ci-evidence.cjs');
const pipeline = require('./ci-pipeline.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const MANIFEST = JSON.parse(
	fs.readFileSync(path.join(ROOT, '.github', 'linux-ci-coverage.json'), 'utf8')
);
const LINUX_BOX = '.github/workflows/ci-linux.yml';
const WORKFLOW = pipeline.file(LINUX_BOX);
const GATE = pipeline.locate('linux-ok');
const SHA = '0123456789abcdef';

function fixtures() {
	const needs = {};
	const evidence = [];
	for (const [job, contract] of Object.entries(MANIFEST.jobs)) {
		needs[job] = { result: 'success' };
		for (const [subject, count] of Object.entries(contract.subjects))
			evidence.push({
				schema_version: 1,
				job,
				sha: SHA,
				architecture: 'X64',
				distro: 'test-distro',
				session: 'headless',
				interpreter: 'LuaJIT 2.1',
				subjects: { [subject]: count }
			});
	}
	return { needs, evidence };
}

function rejects(mutate, pattern) {
	const state = fixtures();
	mutate(state);
	assert.throws(
		() =>
			verifyAggregate({
				manifest: MANIFEST,
				needs: state.needs,
				evidence: state.evidence,
				expectedSha: SHA
			}),
		pattern
	);
}

verifyAggregate({ manifest: MANIFEST, ...fixtures(), expectedSha: SHA });

for (const job of Object.keys(MANIFEST.jobs)) {
	for (const result of ['failure', 'cancelled', 'skipped', null]) {
		rejects(({ needs }) => {
			needs[job].result = result;
		}, /mandatory job .* concluded/);
	}
}
rejects(({ needs }) => {
	delete needs['test-linux'];
}, /mandatory job test-linux is missing/);
rejects(({ evidence }) => {
	evidence[0].subjects.unit = 0;
}, /no positive executed assertion count/);
rejects(({ evidence }) => {
	delete evidence[0].subjects.unit;
}, /has no evidence for unit/);
rejects(({ evidence }) => {
	evidence[0].sha = 'wrong';
}, /evidence belongs to wrong/);
rejects(({ evidence }) => {
	evidence[0].subjects.unknown = 1;
}, /unclassified subject/);
rejects(({ evidence }) => {
	evidence[0].job = 'unknown';
}, /unclassified job/);
rejects(({ evidence }) => {
	evidence.push({ ...evidence[0] });
}, /duplicate evidence/);
rejects(({ needs }) => {
	needs.unclassified = { result: 'success' };
}, /unclassified Linux job/);

// The gate lives in the Linux box: toJSON(needs) only sees the jobs of its own
// workflow, so from ci.yml it would hold nothing but "linux".
assert.strictEqual(
	GATE.file,
	LINUX_BOX,
	`linux-ok must live in ${LINUX_BOX}, found in ${GATE.file}`
);
assert.match(GATE.body, /node tools\/test\/linux-ci-evidence\.cjs verify/);
assert.match(GATE.body, /pattern:\s*linux-ci-evidence-\*/);
assert.match(GATE.body, /NEEDS:\s*\$\{\{\s*toJSON\(needs\)\s*\}\}/);
assert.strictEqual(
	pipeline.field(GATE.body, 'if'),
	'always()',
	'linux-ok must run after a failed or skipped lane to name it'
);
// needs decides what the gate waits for, the manifest what it fails on. verify
// rejects drift between the two at run time; this fails the same drift locally.
assert.deepStrictEqual(
	[...pipeline.needsOf(GATE.body)].sort(),
	Object.keys(MANIFEST.jobs).sort(),
	'linux-ok needs and .github/linux-ci-coverage.json jobs must name the same Linux jobs'
);
for (const job of Object.keys(MANIFEST.jobs)) {
	assert.strictEqual(
		pipeline.locate(job).file,
		LINUX_BOX,
		`manifest job ${job} must be a job of ${LINUX_BOX}`
	);
}
// The unavailable-environment branches still exist and fail closed; the bans
// below then inspect live text rather than a branch that was deleted.
assert.match(WORKFLOW, /no Wayland socket appeared[^\n]*[\s\S]{0,180}exit 1/);
assert.match(WORKFLOW, /WebKit\/lgi unavailable[^\n]*[\s\S]{0,180}exit 1/);
assert.doesNotMatch(WORKFLOW, /all \$total job\(s\) passed \(or skipped\)/);
assert.doesNotMatch(WORKFLOW, /no Wayland socket appeared[^\n]*[\s\S]{0,180}exit 0/);
assert.doesNotMatch(WORKFLOW, /WebKit\/lgi unavailable[^\n]*[\s\S]{0,180}exit 0/);

// Every subject the per-job layout proved at ca1a4d64a is still required: the
// manifest and linux-ok's needs can shrink together, and verify would then
// accept a box that silently stopped proving something.
const MIN_SUBJECTS = 41;
const subjectCount = Object.values(MANIFEST.jobs).reduce(
	(count, contract) => count + Object.keys(contract.subjects).length,
	0
);
assert.ok(
	subjectCount >= MIN_SUBJECTS,
	`.github/linux-ci-coverage.json requires ${subjectCount} subject(s); the floor is ${MIN_SUBJECTS}`
);
// The six subjects of the former packaging jobs, now all proved by package-linux.
const PACKAGE_SUBJECTS = [
	'build-appimage',
	'build-deb',
	'build-flatpak',
	'build-rpm',
	'smoke-flatpak-run',
	'smoke-tarball-install'
];

// One graph block still owns every former installation and package-run row.
// Pin both the subjects and their execution environments: Docker first-run
// tests need a host runner, while rpm must resolve its own LuaJIT dependency.
const INSTALL_ROWS = [
	['distro-debian', 'install', 'debian:stable-slim'],
	['distro-fedora', 'install', 'fedora:latest'],
	['distro-arch', 'install', 'archlinux:latest'],
	['distro-alpine', 'install', 'alpine:latest'],
	['distro-opensuse', 'install', 'opensuse/tumbleweed:latest'],
	['first-install-ubuntu-22.04', 'first', 'ubuntu:22.04'],
	['first-install-ubuntu-24.04', 'first', 'ubuntu:24.04'],
	['first-install-debian-12', 'first', 'debian:12'],
	['first-install-debian-13', 'first', 'debian:13'],
	['first-install-fedora-41', 'first', 'fedora:41'],
	['first-install-fedora-latest', 'first', 'fedora:latest'],
	['first-install-arch', 'first', 'archlinux:latest'],
	['first-install-opensuse-tumbleweed', 'first', 'opensuse/tumbleweed:latest'],
	['first-install-alpine', 'first', 'alpine:latest'],
	['smoke-deb-install', 'deb', ''],
	['smoke-rpm-install', 'rpm', 'fedora:latest'],
	['smoke-appimage-run', 'appimage', '']
];

/**
 * Assert the single matrix retains every scenario and its host/container split.
 * @param {string} body Installation job body.
 */
function assertInstallMatrix(body) {
	assert.strictEqual(pipeline.field(body, 'container'), '${{ matrix.container }}');
	assert.deepStrictEqual(pipeline.needsOf(body), ['package-linux']);
	assert.match(body, /^      fail-fast: false$/m);
	const rows = [...body.matchAll(/^          - id: ([^\n]+)\n((?:            [^\n]*\n)+)/gm)];
	assert.deepStrictEqual(
		rows.map((row) => row[1]).sort(),
		INSTALL_ROWS.map((row) => row[0]).sort()
	);
	for (const [id, kind, image] of INSTALL_ROWS) {
		const row = rows.find((candidate) => candidate[1] === id)[2];
		const value = (key) =>
			row.match(new RegExp(`^            ${key}: (.*)$`, 'm'))?.[1].replace(/^'(.*)'$/, '$1');
		assert.strictEqual(value('kind'), kind, `${id} scenario`);
		assert.strictEqual(
			value('container'),
			['install', 'rpm'].includes(kind) ? image : '',
			`${id} container`
		);
		if (['install', 'first'].includes(kind))
			assert.strictEqual(value('image'), image, `${id} image`);
		if (id.startsWith('first-install-fedora-')) assert.strictEqual(value('known'), 'webkit');
	}
}

const installJob = pipeline.job('install-linux');
assertInstallMatrix(installJob);
assert.deepStrictEqual(
	Object.keys(MANIFEST.jobs['install-linux'].subjects).sort(),
	INSTALL_ROWS.map((row) => row[0]).sort()
);
assert.deepStrictEqual(
	pipeline
		.jobs(LINUX_BOX)
		.map((job) => job.id)
		.sort(),
	['e2e-linux', 'install-linux', 'linux-ok', 'package-linux', 'test-linux']
);
for (const [id] of INSTALL_ROWS) {
	rejects(({ evidence }) => {
		evidence.splice(
			evidence.findIndex((doc) => id in doc.subjects),
			1
		);
	}, /has no evidence for/);
	assert.throws(() =>
		assertInstallMatrix(
			installJob.replace(`          - id: ${id}\n`, `          - id: lost-${id}\n`)
		)
	);
}
assert.throws(() =>
	assertInstallMatrix(
		installJob.replace("            container: ''", '            container: ubuntu:24.04')
	)
);
const prepare = pipeline.step(installJob, 'Prepare the container');
assert.strictEqual(
	pipeline.stepField(prepare, 'shell'),
	'sh',
	'Alpine needs sh before bash is installed'
);
assert.ok(installJob.indexOf(prepare) < installJob.indexOf('      - uses: actions/checkout@v4'));
const installAsUser = pipeline.step(
	installJob,
	'Install as an ordinary user without runtime dependencies'
);
assert.deepStrictEqual(
	pipeline.runOf(installAsUser),
	[
		'set -euo pipefail',
		'# Model a login, not a nested sudo invocation whose SUDO_UID is root.',
		'sudo -H -u ergopti-ci env -u SUDO_UID -u SUDO_GID -u SUDO_USER bash install.sh --no-deps'
	],
	'the installer must configure a real desktop UID, never root with a substituted HOME'
);
const createUser = pipeline.step(installJob, 'Create the installation user');
assert.match(createUser, /test "\$\(id -u ergopti-ci\)" -ge 1000/);
assert.ok(installJob.indexOf(createUser) < installJob.indexOf(installAsUser));
for (const step of pipeline.steps(installJob)) {
	if (pipeline.runOf(step.body) && step.name !== 'Prepare the container') {
		assert.strictEqual(
			pipeline.stepField(step.body, 'shell'),
			'bash',
			`${step.name} requires pipefail-capable bash`
		);
	}
}

assert.deepStrictEqual(
	Object.keys(MANIFEST.jobs['package-linux']?.subjects ?? {}).sort(),
	PACKAGE_SUBJECTS,
	'package-linux must be the mandatory owner of the six packaging subjects'
);
const packageRecord = pipeline.step(
	pipeline.job('package-linux'),
	'Record mandatory package evidence'
);
for (const subject of PACKAGE_SUBJECTS) {
	assert.match(
		packageRecord,
		new RegExp(`--subject ${subject}=1\\b`),
		`package-linux must record the ${subject} subject`
	);
}

// A failed harness must not hide the ones after it (N2), and a cancelled run
// must not keep them running for minutes (always() did). Every step from the
// E2E harness to the evidence record runs under !cancelled(); the record and
// its upload run only when every harness passed.
const testLinuxSteps = pipeline.steps(pipeline.job('e2e-linux'));
const unitAt = testLinuxSteps.findIndex((candidate) => candidate.name === 'Install LuaJIT');
const recordAt = testLinuxSteps.findIndex(
	(candidate) => candidate.name === 'Record mandatory E2E evidence'
);
assert.ok(
	unitAt >= 0 && recordAt > unitAt + 1,
	'test-linux must run its harnesses between the unit suite and the record'
);
assert.strictEqual(
	testLinuxSteps[unitAt + 1].name,
	'Run virtual-keyboard E2E harness (stubbed)',
	'the stubbed E2E harness must run right after the unit suite'
);
for (const harness of testLinuxSteps.slice(unitAt + 1, recordAt)) {
	assert.strictEqual(
		pipeline.stepField(harness.body, 'if'),
		'${{ !cancelled() }}',
		`test-linux step "${harness.name}" must run under if: \${{ !cancelled() }}`
	);
}
for (const tail of testLinuxSteps.slice(recordAt)) {
	assert.strictEqual(
		pipeline.stepField(tail.body, 'if'),
		null,
		`test-linux step "${tail.name}" must run only when every harness passed`
	);
}
for (const boxJob of pipeline.jobs(LINUX_BOX)) {
	for (const boxStep of pipeline.steps(boxJob.body)) {
		assert.doesNotMatch(
			pipeline.stepField(boxStep.body, 'if') ?? '',
			/\balways\(\)/,
			`${boxJob.id} step "${boxStep.name}" must use !cancelled(), not always(), so a cancelled run stops`
		);
	}
}

// Two subjects are counts, and each must be read from what its suite printed:
// a literal count keeps a floor satisfied by a suite that ran nothing. Every
// other subject is the literal 1 of a step that passed. That no step before a
// record can be skipped, or swallow a failure with `|| true` or a `| tee`
// without pipefail, is pinned pipeline-wide by
// tools/test/test-ci-pipeline-wiring.cjs.
const testLinux = pipeline.job('test-linux');
assert.match(
	pipeline.stepField(pipeline.step(testLinux, 'Run the driver unit test suite'), 'run') ?? '',
	/^node \.\.\/\.\.\/\.\.\/tools\/test\/report\.cjs --name linux-lua --json "\$\{\{ runner\.temp \}\}\/linux-lua\.json" -- luajit tests\/run\.lua$/,
	'the unit suite must write the report its evidence counts'
);
assert.ok(
	(
		pipeline.runOf(
			pipeline.step(pipeline.job('e2e-linux'), 'Run virtual-keyboard E2E harness (stubbed)')
		) ?? []
	).includes('luajit tests/e2e/run_e2e.lua | tee "$RUNNER_TEMP/linux-e2e.log"'),
	'the stubbed E2E harness must keep the log its evidence counts'
);
const unitRecord = pipeline.runOf(pipeline.step(testLinux, 'Record mandatory unit evidence')) ?? [];
const e2eRecord =
	pipeline.runOf(pipeline.step(pipeline.job('e2e-linux'), 'Record mandatory E2E evidence')) ?? [];
const recordScript = [...unitRecord, ...e2eRecord];
for (const line of [
	'unit_assertions=$(jq -r \'.passed\' "$RUNNER_TEMP/linux-lua.json")',
	'e2e_assertions=$(sed -n \'s/^1\\.\\.\\([0-9][0-9]*\\)$/\\1/p\' "$RUNNER_TEMP/linux-e2e.log" | tail -1)'
]) {
	assert.ok(
		recordScript.includes(line),
		`the test-linux evidence must read its count with: ${line}`
	);
}
const recorded = [...recordScript.join('\n').matchAll(/--subject "?([a-z0-9-]+)=([^\s"]+)"?/g)];
assert.deepStrictEqual(
	recorded.map((match) => match[1]).sort(),
	[
		...Object.keys(MANIFEST.jobs['test-linux'].subjects),
		...Object.keys(MANIFEST.jobs['e2e-linux'].subjects)
	].sort(),
	'the test-linux record must name exactly the manifest subjects of test-linux'
);
for (const [, subject, value] of recorded) {
	const expected = { unit: '$unit_assertions', 'hotstring-e2e': '$e2e_assertions' }[subject] ?? '1';
	assert.strictEqual(
		value,
		expected,
		`the test-linux subject ${subject} must record ${expected}, got ${value}`
	);
}

process.stdout.write('PASS: Linux CI requires successful jobs and complete assertion evidence.\n');
