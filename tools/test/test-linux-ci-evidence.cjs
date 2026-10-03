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
const os = require('os');
const { spawnSync } = require('child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');
const { findRuntime } = require('./run-linux-lua.cjs');
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

// The real live-updater probe must expose the same refused HTTP response while
// its original assertion and exit remain red. No release or network is faked as
// accepted: these children deliberately stop at the first release-check refusal.
const updaterProbe = path.join(
	ROOT,
	'static/ergopti_plus/linux/tests/hardware/run_updater_live.lua'
);
const updaterDriver = path.join(ROOT, 'static/ergopti_plus/linux');
const nativeLua = findRuntime();
assert.ok(nativeLua, 'the real updater probe regression requires the shared Lua runtime');
const updaterScratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-updater-live-evidence-'));
try {
	const refusal = JSON.stringify({
		message:
			'API rate limit exceeded. Bearer ABCDEFGHIJKLMNOP; https://private.invalid/path?sig=secret',
		documentation_url: 'https://docs.github.com/rate-limits'
	});
	const injected = `
package.preload.luv = function() return { run = function() error('a synchronous refusal needs no event loop') end } end
local response = { ok = false, status = 403, error = 'HTTP 403', error_body = os.getenv('UPDATER_RESPONSE') }
local headers, options = { Authorization = 'Bearer ORIGINAL_REQUEST_SECRET' }, { owner = 'updater' }
local original_get = function(url, sent_headers, sent_options, callback)
 assert(url == 'https://api.github.com/owned/releases')
 assert(sent_headers == headers and sent_options == options, 'the observational wrapper changed request ownership')
 io.stdout:write('transport stdout preserved\\n')
 io.stderr:write('transport stderr preserved\\n')
 assert(callback(response, 'owned callback receipt') == 'callback return preserved')
 return true
end
local manager = { _http_client = { get = original_get }, init = function() end,
 current_version = function() return '0.0.0-dev.1' end, get_channel = function() return 'dev' end }
manager.check_for_updates = function(_, callback)
 assert(manager._http_client.get('https://api.github.com/owned/releases', headers, options, function(received, receipt)
  assert(receipt == 'owned callback receipt', 'the wrapper changed callback arguments')
  assert(received == response and received.error_body == os.getenv('UPDATER_RESPONSE'), 'the wrapper changed the result')
  callback(false, nil, received.error)
  return 'callback return preserved'
 end) == true, 'the wrapper changed the transport return')
end
package.preload['modules.updater.manager'] = function() return manager end
local native_exit = os.exit
os.exit = function(code)
 assert(manager._http_client.get == original_get, 'the probe did not release its observational wrapper')
 io.stderr:write('probe lifecycle cleanup preserved\\n')
 native_exit(code)
end
`;
	const probe = spawnSync(
		nativeLua,
		['-e', injected, updaterProbe, updaterDriver, updaterScratch],
		{
			encoding: 'utf8',
			env: {
				...process.env,
				LUA_PATH: `${path.join(ROOT, 'static/ergopti_plus/_shared/lua/?.lua')};${path.join(ROOT, 'static/ergopti_plus/_shared/lua/?/init.lua')};;`,
				GITHUB_ACTIONS: 'true',
				ERGOPTI_UPDATER_LIVE_EVIDENCE_DIR: updaterScratch,
				UPDATER_RESPONSE: refusal
			}
		}
	);
	assert.ifError(probe.error);
	assert.strictEqual(
		probe.status,
		1,
		'the original failed release-check assertion remains nonzero'
	);
	assert.match(probe.stdout, /transport stdout preserved\n/);
	assert.match(probe.stderr, /transport stderr preserved\n/);
	assert.match(probe.stderr, /probe lifecycle cleanup preserved\n/);
	assert.match(probe.stdout, /  check: nil HTTP 403\n  FAIL the newest release is found\n/);
	assert.match(
		probe.stderr,
		/::error title=Linux updater live HTTP::.*HTTP 403.*API rate limit exceeded/
	);
	assert.doesNotMatch(
		probe.stderr,
		/ABCDEFGHIJKLMNOP|ORIGINAL_REQUEST_SECRET|private\.invalid|sig=secret/
	);
	const httpReceipt = JSON.parse(fs.readFileSync(path.join(updaterScratch, 'http.json'), 'utf8'));
	assert.strictEqual(httpReceipt.responses.length, 1);
	assert.strictEqual(httpReceipt.responses[0].status, 403);
	assert.strictEqual(
		httpReceipt.responses[0].headers_available,
		false,
		'absent response headers are never invented'
	);
	assert.match(httpReceipt.responses[0].message, /API rate limit exceeded/);
	assert.strictEqual(
		JSON.parse(httpReceipt.responses[0].body).documentation_url,
		'<url>',
		'the same response body is retained with URLs masked'
	);
	assert.doesNotMatch(
		JSON.stringify(httpReceipt),
		/ABCDEFGHIJKLMNOP|ORIGINAL_REQUEST_SECRET|private\.invalid|sig=secret/
	);

	// The bounded same-response detail cannot inject a second workflow command.
	const boundedDir = path.join(updaterScratch, 'bounded');
	fs.mkdirSync(boundedDir);
	const bounded = spawnSync(
		nativeLua,
		['-e', injected, updaterProbe, updaterDriver, updaterScratch],
		{
			encoding: 'utf8',
			env: {
				...process.env,
				LUA_PATH: `${path.join(ROOT, 'static/ergopti_plus/_shared/lua/?.lua')};${path.join(ROOT, 'static/ergopti_plus/_shared/lua/?/init.lua')};;`,
				GITHUB_ACTIONS: 'true',
				ERGOPTI_UPDATER_LIVE_EVIDENCE_DIR: boundedDir,
				UPDATER_RESPONSE: JSON.stringify({
					message: 'refused 100%\r\n::error::foreign ' + 'é'.repeat(2000)
				})
			}
		}
	);
	assert.ifError(bounded.error);
	assert.strictEqual(bounded.status, 1);
	assert.match(bounded.stderr, /probe lifecycle cleanup preserved\n/);
	assert.match(bounded.stderr, /100%25%0D%0A::error::foreign/);
	assert.strictEqual(
		(bounded.stderr.match(/^::error/gm) || []).length,
		1,
		'response text cannot create an extra annotation'
	);
	const boundedMessage = JSON.parse(fs.readFileSync(path.join(boundedDir, 'http.json'), 'utf8'))
		.responses[0].message;
	assert.ok(Buffer.byteLength(boundedMessage) <= 2061, 'response body evidence is bounded');
	assert.ok(boundedMessage.endsWith(' <truncated>'));
	assert.ok(!boundedMessage.includes('�'), 'bounded evidence retains complete UTF-8 characters');

	// A refused evidence write cannot replace the actual HTTP failure or
	// interrupt the callback/return/cleanup assertions in the real probe.
	const blockedEvidence = path.join(updaterScratch, 'not-a-directory');
	fs.writeFileSync(blockedEvidence, 'occupied');
	const blocked = spawnSync(
		nativeLua,
		['-e', injected, updaterProbe, updaterDriver, updaterScratch],
		{
			encoding: 'utf8',
			env: {
				...process.env,
				LUA_PATH: `${path.join(ROOT, 'static/ergopti_plus/_shared/lua/?.lua')};${path.join(ROOT, 'static/ergopti_plus/_shared/lua/?/init.lua')};;`,
				GITHUB_ACTIONS: 'true',
				ERGOPTI_UPDATER_LIVE_EVIDENCE_DIR: blockedEvidence,
				UPDATER_RESPONSE: refusal
			}
		}
	);
	assert.ifError(blocked.error);
	assert.strictEqual(blocked.status, 1);
	assert.match(blocked.stderr, /probe lifecycle cleanup preserved\n/);
	assert.match(blocked.stdout, /  check: nil HTTP 403\n  FAIL the newest release is found\n/);
	assert.match(blocked.stderr, /HTTP refusal evidence could not be captured/);

	// Execute the actual Bash owner with controlled build/install/interpreter
	// ports. This checks diagnostics and cleanup, never claims a real update.
	const runnerFixture = path.join(updaterScratch, 'runner');
	const runnerRelative = 'static/ergopti_plus/linux/tests/hardware/run_updater_live.sh';
	const runner = path.join(runnerFixture, runnerRelative);
	fs.mkdirSync(path.dirname(runner), { recursive: true });
	fs.copyFileSync(path.join(ROOT, runnerRelative), runner);
	fs.mkdirSync(path.join(runnerFixture, 'bin'), { recursive: true });
	fs.mkdirSync(path.join(runnerFixture, 'tools/build'), { recursive: true });
	fs.mkdirSync(path.join(runnerFixture, 'build/linux/linux'), { recursive: true });
	fs.mkdirSync(path.join(runnerFixture, 'build/linux/_shared'), { recursive: true });
	fs.mkdirSync(path.join(runnerFixture, 'build/linux/bin'), { recursive: true });
	fs.writeFileSync(
		path.join(runnerFixture, 'tools/build/build-linux-driver.sh'),
		'#!/usr/bin/env bash\nexit "${UPDATER_TEST_BUILD_STATUS:-0}"\n'
	);
	fs.writeFileSync(
		path.join(runnerFixture, 'build/linux/install.sh'),
		`#!/usr/bin/env bash
mkdir -p "$HOME/.local/lib/ergopti/_shared" "$XDG_STATE_HOME/ergopti_plus/logs"
printf 'version=0.0.0-dev.2\\n' > "$HOME/.local/lib/ergopti/_shared/build_stamp.txt"
printf 'daemon starting (version 0.0.0-dev.2, fixture)\\n' > "$XDG_STATE_HOME/ergopti_plus/logs/daemon.log"
exit "${'${UPDATER_TEST_INSTALL_STATUS:-0}'}"
`
	);
	fs.writeFileSync(
		path.join(runnerFixture, 'bin/luajit'),
		`#!/usr/bin/env bash
if [ "$1" = -e ]; then exit "${'${UPDATER_TEST_ENV_STATUS:-0}'}"; fi
printf '%s' "$UPDATER_TEST_STDOUT"
printf '%s' "$UPDATER_TEST_STDERR" >&2
printf '%s' "${'${HOME%/home}'}" > "$UPDATER_TEST_WORK_REPORT"
exit "$UPDATER_TEST_STATUS"
`,
		{ mode: 0o755 }
	);
	for (const tool of ['curl', 'sha256sum', 'pkill'])
		fs.writeFileSync(path.join(runnerFixture, 'bin', tool), '#!/usr/bin/env bash\nexit 0\n', {
			mode: 0o755
		});
	for (const fixture of [
		{ phase: 'updater', status: 1, child: 7 },
		{ phase: 'complete', status: 0, child: 0 },
		{ phase: 'build', status: 1, child: 0, build: 19 },
		{ phase: 'install', status: 1, child: 0, install: 20 },
		{ phase: 'environment', status: 2, child: 0, environment: 8 },
		{ phase: 'updater', status: 1, child: 7, blocked: true },
		{ phase: 'complete', status: 0, child: 0, blocked: true }
	]) {
		const evidence = path.join(
			updaterScratch,
			`evidence-${fixture.phase}${fixture.blocked ? '-blocked' : ''}`
		);
		if (fixture.blocked) fs.writeFileSync(evidence, 'occupied diagnostic destination');
		const workReport = path.join(updaterScratch, `work-${fixture.phase}.txt`);
		const stdout = 'original stdout é 100%\n';
		const stderr = 'original stderr HTTP 403\n';
		const result = spawnSync(
			bashExecutable(),
			['-c', 'PATH="./bin:$PATH"; exec bash "$UPDATER_TEST_RUNNER"'],
			{
				cwd: runnerFixture,
				encoding: 'utf8',
				env: {
					...process.env,
					GITHUB_ACTIONS: 'true',
					GITHUB_SHA: SHA,
					UPDATER_TEST_RUNNER: runner.replaceAll('\\', '/'),
					UPDATER_TEST_BUILD_STATUS: String(fixture.build || 0),
					UPDATER_TEST_INSTALL_STATUS: String(fixture.install || 0),
					UPDATER_TEST_ENV_STATUS: String(fixture.environment || 0),
					UPDATER_TEST_STATUS: String(fixture.child),
					UPDATER_TEST_STDOUT: stdout,
					UPDATER_TEST_STDERR: stderr,
					UPDATER_TEST_WORK_REPORT: workReport.replaceAll('\\', '/'),
					ERGOPTI_UPDATER_LIVE_EVIDENCE_DIR: evidence.replaceAll('\\', '/')
				}
			}
		);
		assert.ifError(result.error);
		assert.strictEqual(
			result.status,
			fixture.status,
			`${fixture.phase}: diagnostics must retain the actual owner verdict`
		);
		if (!fixture.blocked) {
			const receipt = fs.readFileSync(path.join(evidence, 'result.txt'), 'utf8');
			assert.match(receipt, new RegExp(`^phase=${fixture.phase}$`, 'm'));
			assert.match(receipt, new RegExp(`^exit_status=${fixture.status}$`, 'm'));
			assert.match(
				receipt,
				new RegExp(
					`^cause_exit_status=${fixture.environment || fixture.build || fixture.install || fixture.child}$`,
					'm'
				)
			);
			assert.match(receipt, new RegExp(`^sha=${SHA}$`, 'm'));
		} else {
			assert.match(result.stderr, /Updater evidence directory could not be created/);
			assert.strictEqual(fs.readFileSync(evidence, 'utf8'), 'occupied diagnostic destination');
		}
		if (fixture.phase === 'updater' || fixture.phase === 'complete') {
			assert.ok(result.stdout.startsWith(stdout), 'stdout bytes survive the tee unchanged');
			assert.ok(
				fixture.blocked ? result.stderr.includes(stderr) : result.stderr.startsWith(stderr),
				'stderr bytes survive the tee unchanged'
			);
			if (!fixture.blocked) {
				assert.strictEqual(
					fs.readFileSync(path.join(evidence, 'updater.stdout.log'), 'utf8'),
					stdout
				);
				assert.strictEqual(
					fs.readFileSync(path.join(evidence, 'updater.stderr.log'), 'utf8'),
					stderr
				);
			}
			const cleanup = spawnSync(bashExecutable(), ['-c', 'test ! -d "$UPDATER_TEST_WORK"'], {
				encoding: 'utf8',
				env: { ...process.env, UPDATER_TEST_WORK: fs.readFileSync(workReport, 'utf8') }
			});
			assert.strictEqual(cleanup.status, 0, 'the exact owned work directory is still cleaned');
		}
		if (fixture.status) assert.match(result.stderr, /::error title=Linux updater live::/);
		else assert.doesNotMatch(result.stderr, /::error/);
	}
} finally {
	fs.rmSync(updaterScratch, { recursive: true, force: true });
}

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

// Native physical admission must retain its real X11 group/map evidence.
assert.strictEqual(MANIFEST.jobs['e2e-linux'].subjects['xkb-source-qualification'], 17);
rejects(({ evidence }) => {
	const document = evidence.find((row) => 'xkb-source-qualification' in row.subjects);
	delete document.subjects['xkb-source-qualification'];
}, /has no evidence for xkb-source-qualification/);
const sourceStep = pipeline.step(
	pipeline.job('e2e-linux'),
	'Qualify actual X11 physical shortcut sources'
);
assert.match(
	pipeline.stepField(sourceStep, 'run') ?? '',
	/run_xkb_source_qualification\.lua \| tee "\$RUNNER_TEMP\/linux-xkb-source\.log"/
);
assert.match(pipeline.stepField(sourceStep, 'run') ?? '', /set -euo pipefail/);
const nativeRecord =
	pipeline.stepField(
		pipeline.step(pipeline.job('e2e-linux'), 'Record mandatory E2E evidence'),
		'run'
	) ?? '';
assert.match(nativeRecord, /xkb_source_assertions=\$\(sed[^\n]+linux-xkb-source\.log/);
assert.match(nativeRecord, /--subject "xkb-source-qualification=\$xkb_source_assertions"/);

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
const updaterStep = pipeline.step(
	pipeline.job('e2e-linux'),
	'Update to the newest release and restart'
);
assert.match(
	updaterStep,
	/^          ERGOPTI_UPDATER_LIVE_EVIDENCE_DIR: \$\{\{ runner\.temp \}\}\/linux-updater-live$/m
);
const updaterEvidence = pipeline.step(
	pipeline.job('e2e-linux'),
	'Upload live updater diagnostic evidence'
);

/**
 * Keep failed updater observations separate from mandatory success receipts.
 * @param {string} step The diagnostic artifact upload step.
 */
function assertUpdaterEvidence(step) {
	assert.strictEqual(pipeline.stepField(step, 'if'), '${{ !cancelled() }}');
	assert.strictEqual(pipeline.stepField(step, 'uses'), 'actions/upload-artifact@v4');
	assert.strictEqual(pipeline.stepField(step, 'continue-on-error'), null);
	assert.match(step, /^          name: linux-updater-live-diagnostics$/m);
	assert.match(step, /^          path: \$\{\{ runner\.temp \}\}\/linux-updater-live$/m);
	assert.match(step, /^          if-no-files-found: error$/m);
}
assertUpdaterEvidence(updaterEvidence);
assert.throws(() =>
	assertUpdaterEvidence(updaterEvidence.replace('${{ !cancelled() }}', '${{ success() }}'))
);
assert.throws(() =>
	assertUpdaterEvidence(
		updaterEvidence.replace('linux-updater-live-diagnostics', 'linux-ci-evidence-e2e-linux')
	)
);
assert.throws(() =>
	assertUpdaterEvidence(
		updaterEvidence.replace('if-no-files-found: error', 'if-no-files-found: ignore')
	)
);
assert.ok(
	pipeline.job('e2e-linux').indexOf(updaterStep) <
		pipeline.job('e2e-linux').indexOf(updaterEvidence)
);
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

// Three subjects are counts, and each must be read from what its suite printed:
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
	'e2e_assertions=$(sed -n \'s/^1\\.\\.\\([0-9][0-9]*\\)$/\\1/p\' "$RUNNER_TEMP/linux-e2e.log" | tail -1)',
	'xkb_source_assertions=$(sed -n \'s/^=== \\([0-9][0-9]*\\) check(s), 0 failure(s) ===$/\\1/p\' "$RUNNER_TEMP/linux-xkb-source.log" | tail -1)'
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
	const expected =
		{
			unit: '$unit_assertions',
			'hotstring-e2e': '$e2e_assertions',
			'xkb-source-qualification': '$xkb_source_assertions'
		}[subject] ?? '1';
	assert.strictEqual(
		value,
		expected,
		`the test-linux subject ${subject} must record ${expected}, got ${value}`
	);
}

process.stdout.write('PASS: Linux CI requires successful jobs and complete assertion evidence.\n');
