// tools/test/test-desktop-ci-evidence.cjs

/**
 * ==============================================================================
 * MODULE: Desktop CI Verdict Regression Tests
 * DESCRIPTION:
 * Rejects missing or failed launch observations, incorrect commits and incomplete
 * matrices. Pins the parallel shared-core gate and the published-byte boundary.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const { verify, recordMac, recordWindows } = require('./desktop-ci-evidence.cjs');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const timerContract = require('../diagnostics/hs_delayed_timer_contract.json');
const karabinerContract = require('../diagnostics/hs_karabiner_config_contract.json');
const pipeline = require('./ci-pipeline.cjs');

/** Returns the measured native admission summary that every clean launch owes. */
function timerSummary() {
	return {
		schema_version: 1,
		contract: timerContract.contract,
		runtime: 'native Hammerspoon',
		version: timerContract.runtime_version,
		complete: true,
		checks:
			Object.keys(timerContract.boolean_observations).length +
			Object.keys(timerContract.remaining_limits).length +
			Object.keys(timerContract.deliveries).length,
		nonce: 'a'.repeat(32),
		pid: 42,
		executable:
			'/Applications/ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app/Contents/MacOS/Hammerspoon',
		preference_restored: true
	};
}

/** Declares the complete private-file native qualification admission receipt. */
function karabinerSummary() {
	return {
		...karabinerContract.summary_fixed,
		version: '1.1.1',
		nonce: 'a'.repeat(32),
		pid: 42,
		executable:
			'/Applications/ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app/Contents/MacOS/Hammerspoon',
		variant_count: 8,
		manipulator_count: 480,
		preference_restored: true
	};
}

/** Returns the parent observation and the receipt from the exact compiled child. */
function windowsStartup() {
	const nonce = 'c'.repeat(32);
	const executable = 'C:\\private\\ErgoptiPlus.exe';
	return {
		nonce,
		pid: 42,
		executable,
		launched_sha256: 'b'.repeat(64),
		exit_code: 0,
		log_files: 1,
		logged_errors: [],
		receipt: {
			schema_version: 1,
			nonce,
			pid: 42,
			executable,
			compiled: true,
			build_commit: 'a'.repeat(40),
			bundle_identity: '0.0.0-dev\n' + 'a'.repeat(40),
			phase: 'ready',
			driver_ready: true,
			menu_ready: true,
			logs_flushed: true
		}
	};
}

/** An independently authored cold native receipt; this never executes macOS. */
function coldBootstrapRecord() {
	const hash = (relative) =>
		crypto
			.createHash('sha256')
			.update(fs.readFileSync(path.resolve(__dirname, '../..', relative)))
			.digest('hex');
	const paths = [
		'/Applications/Xcode.app/Contents/Developer/usr/bin/python3',
		'/Library/Frameworks/Python.framework/Versions/Current/bin/python3',
		'/opt/homebrew/bin/python3',
		'/opt/homebrew/bin/uv',
		'/usr/bin/python3',
		'/usr/bin/uv',
		'/usr/local/bin/python3',
		'/usr/local/bin/uv'
	];
	const profile =
		'(version 1)\n(allow default)\n(deny file-read* process-exec\n' +
		'  (literal "/Applications/Xcode.app/Contents/Developer/usr/bin/python3")\n' +
		'  (literal "/Library/Frameworks/Python.framework/Versions/Current/bin/python3")\n' +
		'  (literal "/opt/homebrew/bin/python3")\n  (literal "/opt/homebrew/bin/uv")\n' +
		'  (literal "/usr/bin/python3")\n  (literal "/usr/bin/uv")\n' +
		'  (literal "/usr/local/bin/python3")\n  (literal "/usr/local/bin/uv")\n)\n';
	const nonce = '01234567-89ab-cdef-0123-456789abcdef';
	const sources = Object.fromEntries(
		[
			'macos/modules/llm/network-retry.sh',
			'macos/modules/llm/ensure-mlx-deps.sh',
			'macos/modules/llm/managed_bootstrap_http.py',
			'macos/modules/llm/mlx_deps_checker.lua',
			'macos/modules/llm/uv-release.sh',
			'macos/modules/llm/managed-python-release.sh',
			'macos/modules/llm/managed-python-downloads.json',
			'macos/adapters/native_bootstrap_pty.lua',
			'macos/adapters/python_interpreter.lua',
			'macos/platform/network/native_http.py',
			'_shared/python/network_proxy_policy.py',
			'_shared/lua/core/llm/native_pty_receipt.lua',
			'_shared/modules/network/proxy_policy.json',
			'_shared/modules/llm/managed_python_release.json',
			'macos/uv.lock',
			'macos/pyproject.toml'
		].map((relative) => [relative, hash('static/ergopti_plus/' + relative)])
	);
	return {
		schema_version: 1,
		contract: 'macos-native-cold-bootstrap-v1',
		runner: 'macos-15',
		sha: 'a'.repeat(40),
		receipt: {
			version: 1,
			status: 'passed',
			sha: 'a'.repeat(40),
			build_commit: 'a'.repeat(40),
			platform: 'darwin',
			architecture: 'arm64',
			runtime_environment: 'controlled isolated cold environment',
			signature_verified: true,
			uv: 'uv 0.12.21',
			python: '3.11.16',
			imports: 'passed',
			helpers_retired: true,
			cleanup: true,
			managed_runtime_isolated_exec: true,
			launcher_sha256: '1'.repeat(64),
			hammerspoon_sha256: '2'.repeat(64),
			official_hammerspoon: {
				version: '1.1.1',
				sha256: '11bb1c90faf5427f37c7bd4fe7eab9774ae43e1d5cb020c5b3088dac32849efa',
				bytes: 9704557
			},
			sources,
			diagnostics: {
				'tools/diagnostics/macos_cold_bootstrap.lua': hash(
					'tools/diagnostics/macos_cold_bootstrap.lua'
				),
				'tools/diagnostics/macos_cold_bootstrap.py': hash(
					'tools/diagnostics/macos_cold_bootstrap.py'
				)
			},
			fingerprint: sources['macos/pyproject.toml'] + ':' + sources['macos/uv.lock'],
			isolation: {
				profile_sha256: crypto.createHash('sha256').update(profile).digest('hex'),
				paths,
				host_files_preserved: true,
				observations: [
					{
						path: '/usr/bin/python3',
						sha256: '3'.repeat(64),
						device: 27,
						inode: 123,
						bytes: 1234,
						read_denied: true,
						native: true,
						exec_denied: true
					}
				]
			},
			caller: {
				version: 1,
				success: true,
				state: 'ready',
				runtime_installed: true,
				runtime: 'native Hammerspoon',
				tasks: 1,
				absent_python_selected: true,
				python_resolver: 'unmodified production resolver',
				python_state: 'python_missing',
				native_python_candidates_count: 0,
				denied_runtime_paths: paths,
				receipt_retired: true,
				receipt_removed: true,
				worker_status: 0,
				source_sha256: sources['macos/modules/llm/ensure-mlx-deps.sh'],
				native_cli: ['--managed-pty-worker', '1800000'],
				worker_pid: 123,
				receipt_path: '/private/owned/retired-receipt',
				nonce,
				physical_receipt: {
					version: 1,
					nonce,
					state: 'retired',
					group_retired: true,
					guardian_reaped: true,
					pty_eof: true,
					handles_closed: true,
					status_valid: true,
					exit_status: 0,
					worker_status: 0,
					source_admitted: true
				}
			}
		}
	};
}

for (const platform of ['windows', 'macos']) {
	for (const release of [false, true]) {
		const jobs =
			platform === 'windows'
				? ['test-ahk', 'e2e-ahk', 'package-windows', 'launch-windows']
				: [
						'test-hs',
						'e2e-hs',
						'package-macos',
						'launch',
						'tooltip-canvas',
						'managed-ollama-native',
						'cold-bootstrap-native'
					];
		const runners =
			platform === 'windows'
				? ['windows-latest']
				: release
					? ['macos-15', 'macos-15-intel']
					: ['macos-15'];
		const scenarios =
			platform === 'windows' ? ['startup'] : ['clean', 'upgraded', 'karabiner_config'];
		const state = {
			platform,
			release,
			scenarios,
			sha: 'a'.repeat(40),
			coldBootstrap: platform === 'macos' ? [coldBootstrapRecord()] : [],
			needs: Object.fromEntries(jobs.map((job) => [job, { result: 'success' }])),
			evidence: runners.flatMap((runner) =>
				scenarios.map((scenario) => ({
					schema_version: 1,
					platform,
					runner,
					scenario,
					sha: 'a'.repeat(40),
					package_sha256: 'b'.repeat(64),
					failures: [],
					marker_seen: true,
					crashed_early: false,
					...(platform === 'windows' ? { native_startup: windowsStartup() } : {}),
					...(platform === 'macos' && scenario === 'clean'
						? { native_delayed_timer: timerSummary() }
						: {}),
					...(platform === 'macos' && scenario === 'karabiner_config'
						? { native_karabiner_config: karabinerSummary() }
						: {})
				}))
			)
		};
		verify(state);
		const rejects = (mutate) => {
			const changed = structuredClone(state);
			mutate(changed);
			assert.throws(() => verify(changed));
		};
		for (const job of jobs) {
			for (const status of ['failure', 'cancelled', 'skipped', undefined]) {
				rejects((value) => {
					value.needs[job].result = status;
				});
			}
			rejects((value) => {
				delete value.needs[job];
			});
		}
		rejects((value) => value.evidence.pop());
		rejects((value) => value.evidence.push(value.evidence[0]));
		rejects((value) => {
			value.evidence[0].sha = 'c'.repeat(40);
		});
		rejects((value) => {
			value.evidence[0].failures = ['crash'];
		});
		rejects((value) => {
			value.evidence[0].scenario = 'unknown';
		});
		rejects((value) => {
			value.evidence[0].package_sha256 = '';
		});
		if (platform === 'windows') {
			rejects((value) => {
				delete value.evidence[0].native_startup;
			});
			for (const [field, replacement] of [
				['exit_code', 1],
				['exit_code', null],
				['log_files', 0],
				['logged_errors', ['ERROR during boot']],
				['nonce', 'd'.repeat(32)],
				['pid', 43],
				['executable', 'C:\\foreign\\ErgoptiPlus.exe'],
				['launched_sha256', 'd'.repeat(64)]
			])
				rejects((value) => {
					value.evidence[0].native_startup[field] = replacement;
				});
			for (const [field, replacement] of [
				['compiled', false],
				['build_commit', 'd'.repeat(40)],
				['bundle_identity', 'old\n' + 'd'.repeat(40)],
				['phase', 'input-init'],
				['driver_ready', false],
				['menu_ready', false],
				['logs_flushed', false],
				['nonce', 'd'.repeat(32)],
				['pid', 43],
				['executable', 'C:\\foreign\\ErgoptiPlus.exe']
			])
				rejects((value) => {
					value.evidence[0].native_startup.receipt[field] = replacement;
				});
			for (const field of Object.keys(windowsStartup().receipt))
				rejects((value) => {
					delete value.evidence[0].native_startup.receipt[field];
				});
			rejects((value) => {
				value.evidence[0].marker_seen = false;
			});
			rejects((value) => {
				value.evidence[0].crashed_early = true;
			});
		} else {
			for (const [field, replacement] of [
				['complete', false],
				['variant_count', 7],
				['manipulator_count', 0],
				['publication_scope', 'runtime-active'],
				['lease_initialized', true],
				['private_source_restored', false],
				['codec_independent', false],
				['native_equal_values_shared', false],
				['preference_restored', false],
				['nonce', ''],
				['pid', 0],
				['executable', '/foreign/Hammerspoon']
			])
				rejects((value) => {
					value.evidence.find(
						(record) => record.scenario === 'karabiner_config'
					).native_karabiner_config[field] = replacement;
				});
			for (const field of Object.keys(karabinerSummary()))
				rejects((value) => {
					delete value.evidence.find((record) => record.scenario === 'karabiner_config')
						.native_karabiner_config[field];
				});
			rejects((value) => {
				delete value.evidence.find((record) => record.scenario === 'karabiner_config')
					.native_karabiner_config;
			});
			for (const [field, replacement] of [
				['complete', false],
				['checks', 0],
				['preference_restored', false],
				['nonce', ''],
				['pid', 0],
				['version', '0.0.0'],
				['runtime', 'stubbed Hammerspoon'],
				['executable', '/other/Hammerspoon']
			])
				rejects((value) => {
					value.evidence[0].native_delayed_timer[field] = replacement;
				});
			for (const field of Object.keys(timerSummary())) {
				rejects((value) => {
					delete value.evidence[0].native_delayed_timer[field];
				});
			}
			rejects((value) => {
				delete value.evidence[0].native_delayed_timer;
			});
			rejects((value) => {
				value.evidence[0].package_sha256 = 'c'.repeat(64);
			});
		}
	}
}

const timerEvidenceRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-native-timer-evidence-'));
try {
	const resultFile = path.join(timerEvidenceRoot, 'result.json');
	const archive = path.join(timerEvidenceRoot, 'archive.zip');
	const output = path.join(timerEvidenceRoot, 'evidence.json');
	fs.writeFileSync(archive, 'owned archive fixture');
	for (const summary of [undefined, {}, { ...timerSummary(), complete: false }]) {
		fs.writeFileSync(
			resultFile,
			JSON.stringify({ scenario: 'clean', failures: [], native_delayed_timer: summary })
		);
		assert.throws(
			() => recordMac(resultFile, archive, output),
			'recording may not admit an incomplete native probe'
		);
		assert.equal(fs.existsSync(output), false, 'a refused record must publish no evidence');
	}
	fs.writeFileSync(
		resultFile,
		JSON.stringify({ scenario: 'clean', failures: [], native_delayed_timer: timerSummary() })
	);
	recordMac(resultFile, archive, output);
	assert.deepEqual(
		JSON.parse(fs.readFileSync(output, 'utf8')).native_delayed_timer,
		timerSummary(),
		'the aggregate judge must retain the exact admitted native summary'
	);
} finally {
	fs.rmSync(timerEvidenceRoot, { recursive: true, force: true });
}

const karabinerEvidenceRoot = fs.mkdtempSync(
	path.join(os.tmpdir(), 'ergopti-native-karabiner-evidence-')
);
try {
	const resultFile = path.join(karabinerEvidenceRoot, 'result.json');
	const archive = path.join(karabinerEvidenceRoot, 'archive.zip');
	const output = path.join(karabinerEvidenceRoot, 'evidence.json');
	fs.writeFileSync(archive, 'owned archive fixture');
	for (const summary of [undefined, {}, { ...karabinerSummary(), lease_initialized: true }]) {
		fs.writeFileSync(
			resultFile,
			JSON.stringify({
				scenario: 'karabiner_config',
				failures: [],
				native_karabiner_config: summary
			})
		);
		assert.throws(
			() => recordMac(resultFile, archive, output),
			'native graph qualification must precede evidence publication'
		);
		assert.equal(
			fs.existsSync(output),
			false,
			'refused native graph evidence must never be published'
		);
	}
	fs.writeFileSync(
		resultFile,
		JSON.stringify({
			scenario: 'karabiner_config',
			failures: [],
			native_karabiner_config: karabinerSummary()
		})
	);
	recordMac(resultFile, archive, output);
	assert.deepEqual(
		JSON.parse(fs.readFileSync(output, 'utf8')).native_karabiner_config,
		karabinerSummary()
	);
} finally {
	fs.rmSync(karabinerEvidenceRoot, { recursive: true, force: true });
}

const startupEvidenceRoot = fs.mkdtempSync(
	path.join(os.tmpdir(), 'ergopti-native-startup-evidence-')
);
const savedGithubSha = process.env.GITHUB_SHA;
try {
	process.env.GITHUB_SHA = 'a'.repeat(40);
	const executable = path.join(startupEvidenceRoot, 'ErgoptiPlus.exe');
	const bytes = 'owned packaged byte fixture';
	fs.writeFileSync(executable, bytes);
	const native = windowsStartup();
	native.executable = executable;
	native.receipt.executable = executable;
	native.launched_sha256 = crypto.createHash('sha256').update(bytes).digest('hex');
	const resultFile = path.join(startupEvidenceRoot, 'observation.json');
	const output = path.join(startupEvidenceRoot, 'evidence.json');
	const publishObservation = (observation) =>
		fs.writeFileSync(
			resultFile,
			JSON.stringify({
				marker_seen: true,
				crashed_early: false,
				marker_seconds: 1,
				native_startup: observation
			})
		);
	const foreignReceipt = structuredClone(native);
	foreignReceipt.receipt.executable = path.join(
		startupEvidenceRoot,
		'foreign sibling',
		'ErgoptiPlus.exe'
	);
	publishObservation(foreignReceipt);
	assert.throws(
		() => recordWindows(resultFile, executable, output),
		/Readiness came from another executable/
	);
	assert.equal(
		fs.existsSync(output),
		false,
		'a foreign same-basename receipt must publish no evidence'
	);
	const foreignPath = structuredClone(native);
	foreignPath.executable = path.join(startupEvidenceRoot, 'another', 'ErgoptiPlus.exe');
	foreignPath.receipt.executable = foreignPath.executable;
	publishObservation(foreignPath);
	assert.throws(() => recordWindows(resultFile, executable, output), /not the launched executable/);
	assert.equal(fs.existsSync(output), false, 'a path substitution must publish no evidence');
	publishObservation(native);
	fs.writeFileSync(executable, bytes + ' changed after launch');
	assert.throws(() => recordWindows(resultFile, executable, output), /Package bytes differ/);
	assert.equal(fs.existsSync(output), false, 'changed package bytes must publish no evidence');
	fs.writeFileSync(executable, bytes);
	recordWindows(resultFile, executable, output);
	assert.equal(
		JSON.parse(fs.readFileSync(output, 'utf8')).package_sha256,
		native.launched_sha256,
		'the successful record carries the exact launched bytes'
	);
} finally {
	if (savedGithubSha === undefined) delete process.env.GITHUB_SHA;
	else process.env.GITHUB_SHA = savedGithubSha;
	fs.rmSync(startupEvidenceRoot, { recursive: true, force: true });
}

/** Pins a fresh shallow checkout and the exact independently gated core suites. */
function checkCore(body) {
	assert.deepEqual(pipeline.needsOf(body), ['validate']);
	assert.equal(pipeline.field(body, 'if'), null);
	assert.match(body, /^      fail-fast: false$/m);
	assert.ok(
		body.includes(
			`        suite: \${{ fromJSON(github.ref == 'refs/heads/main' && '["js","properties","mutation"]' || '["js","properties"]') }}`
		)
	);
	const steps = pipeline.steps(body);
	const checkout = steps.filter(
		(step) => pipeline.stepField(step.body, 'uses') === 'actions/checkout@v4'
	);
	assert.equal(checkout.length, 1);
	assert.equal(pipeline.stepField(checkout[0].body, 'with'), null);
	assert.doesNotMatch(body, /\bgit (?:fetch|pull|clone)\b/);
	assert.equal(
		pipeline.stepField(pipeline.step(body, 'Run shared validation suite'), 'run'),
		'npm run test:${{ matrix.suite }}'
	);
	assert.ok(steps.some((step) => pipeline.stepField(step.body, 'run') === 'npm ci'));
	assert.match(
		body,
		/sudo python3 "\$GITHUB_WORKSPACE\/tools\/ci\/ubuntu_apt\.py" -y lua5\.4 lua-luv libxml2-utils/
	);
	for (const [name, command] of [
		['Install shared UI browsers', 'node tools/ci/install-playwright.cjs chromium webkit'],
		['Test shared layer editor rendering', 'npm run test:browser:layer-editor'],
		['Test shared Versions installation rendering', 'npm run test:browser:changelog-install']
	]) {
		const step = pipeline.step(body, name);
		assert.equal(pipeline.stepField(step, 'if'), "matrix.suite == 'js'");
		assert.equal(pipeline.stepField(step, 'run'), command);
		assert.equal(pipeline.stepField(step, 'continue-on-error'), null);
	}
}

const core = pipeline.job('core');
checkCore(core);
for (const [from, to] of [
	['refs/heads/main', 'refs/heads/never'],
	['"js","properties","mutation"', '"js","properties"'],
	['"js","properties"', '"js"'],
	['fail-fast: false', 'fail-fast: true'],
	['needs: [validate]', 'needs: [macos]'],
	['run: npm run test:${{ matrix.suite }}', 'run: npm run test:${{ matrix.suite }} -- --only lint'],
	['run: npm run test:browser:layer-editor', 'run: echo skipped browser gate'],
	['run: npm run test:browser:changelog-install', 'run: echo skipped Versions browser gate'],
	[
		'run: npm run test:browser:changelog-install',
		'continue-on-error: true\n        run: npm run test:browser:changelog-install'
	],
	['node tools/ci/install-playwright.cjs chromium webkit', 'npx playwright install chromium'],
	["if: matrix.suite == 'js'", "if: matrix.suite == 'never'"],
	[
		'- uses: actions/checkout@v4',
		'- uses: actions/checkout@v4\n        with:\n          fetch-depth: 0'
	]
]) {
	const changed = core.replace(from, to);
	assert.notEqual(changed, core, from + ' must actually mutate the shared gate');
	assert.throws(() => checkCore(changed), from);
}

for (const [job, platform] of [
	['macos-ok', 'macos'],
	['windows-ok', 'windows']
]) {
	assert.ok(
		pipeline.job(job).includes(`node tools/test/desktop-ci-evidence.cjs verify ${platform}`)
	);
}
/** Requires actual native Ollama inputs and receiving before Brew can fail. */
function checkManagedOllamaNative(body) {
	assert.equal(pipeline.field(body, 'needs'), null);
	assert.equal(pipeline.field(body, 'if'), null);
	assert.equal(pipeline.field(body, 'continue-on-error'), null);
	assert.equal(pipeline.field(body, 'runs-on'), '${{ matrix.runner }}');
	assert.match(body, /fail-fast: false/);
	assert.match(body, /runner: macos-15\n\s+architecture: arm64/);
	assert.match(body, /runner: macos-15-intel\n\s+architecture: amd64/);
	assert.match(body, /ERGOPTI_RELEASE_TAG: \$\{\{ inputs\.tag \}\}/);
	assert.match(body, /GOTOOLCHAIN: local/);
	const acquire = pipeline.step(body, 'Acquire and verify genuine pinned upstream inputs');
	assert.match(
		acquire,
		/git -C "\$ERGOPTI_OLLAMA_SOURCE" fetch --depth=1 --no-tags origin "\$ERGOPTI_OLLAMA_SOURCE_COMMIT"/
	);
	assert.match(acquire, /actual == identity\['sha256'\]/);
	assert.match(acquire, /archive\.stat\(\)\.st_size == identity\['bytes'\]/);
	const build = pipeline.step(body, 'Build and admit the actual native source asset');
	for (const command of [
		'tools/build/build-macos-managed-ollama.py',
		'tools/test/macos_managed_ollama_catalogue_test.py --native',
		'tools/build/stage-macos-managed-ollama-catalogue.py'
	])
		assert.ok(build.includes(command));
	assert.match(build, /--release "\$ERGOPTI_RELEASE" --release-tag "\$ERGOPTI_RELEASE_TAG"/);
	const listener = pipeline.step(
		body,
		'Qualify actual SDK accepted-owner and deadline XCTest controls'
	);
	assert.match(listener, /--filter 'ManagedOllamaAPIWorkerTests\|ManagedPTYWorkerTests'/);
	assert.match(listener, /Executed 12 tests, with 0 failures/);
	assert.match(listener, /Executed 11 tests, with 0 failures/);
	assert.match(listener, /ManagedPTYWorkerTests/);
	assert.equal(pipeline.stepField(listener, 'continue-on-error'), null);
	const receive = pipeline.step(
		body,
		'Receive actual native model create, pull, inference and retirement'
	);
	assert.match(receive, /for profile in pac-inline pac-url explicit-proxy/);
	assert.match(receive, /tools\/diagnostics\/macos_managed_ollama_receiving\.py/);
	assert.match(
		receive,
		/--archive "\$ERGOPTI_OLLAMA_ASSET" --catalogue "\$ERGOPTI_OLLAMA_CATALOGUE"/
	);
	assert.equal(pipeline.stepField(receive, 'continue-on-error'), null);
	assert.doesNotMatch(body, /gh release|softprops\/action-gh-release|createRelease|--cross/);
}
const managedOllamaNative = pipeline.job('managed-ollama-native');
checkManagedOllamaNative(managedOllamaNative);
assert.deepEqual(
	pipeline.needsOf(pipeline.job('macos-ok')).sort(),
	[
		'test-hs',
		'e2e-hs',
		'package-macos',
		'launch',
		'tooltip-canvas',
		'managed-ollama-native',
		'cold-bootstrap-native'
	].sort()
);
assert.ok(pipeline.job('macos').includes('tag: ${{ needs.validate.outputs.tag }}'));
for (const [from, to] of [
	['runs-on: ${{ matrix.runner }}', 'runs-on: ubuntu-latest'],
	['fail-fast: false', 'fail-fast: true'],
	['runner: macos-15-intel', 'runner: macos-15'],
	['architecture: amd64', 'architecture: arm64'],
	['GOTOOLCHAIN: local', 'GOTOOLCHAIN: auto'],
	['fetch --depth=1 --no-tags origin', 'fetch --depth=1 --no-tags other'],
	["actual == identity['sha256']", 'actual == actual'],
	['macos_managed_ollama_catalogue_test.py --native', 'macos_managed_ollama_catalogue_test.py'],
	['for profile in pac-inline pac-url explicit-proxy', 'for profile in pac-inline'],
	['Executed 12 tests, with 0 failures', 'Executed 0 tests, with 0 failures'],
	[
		"    name: 'Managed Ollama native",
		"    needs: package-macos\n    name: 'Managed Ollama native"
	],
	["    name: 'Managed Ollama native", "    if: inputs.release\n    name: 'Managed Ollama native"],
	[
		"    name: 'Managed Ollama native",
		"    continue-on-error: true\n    name: 'Managed Ollama native"
	]
]) {
	const changed = managedOllamaNative.replace(from, to);
	assert.notEqual(changed, managedOllamaNative, from);
	assert.throws(() => checkManagedOllamaNative(changed), from);
}

for (const [job, name] of [
	['launch', 'Retain launch evidence'],
	['launch-windows', 'Upload mandatory launch evidence']
]) {
	const upload = pipeline.step(pipeline.job(job), name);
	assert.match(upload, /overwrite: true/);
	assert.doesNotMatch(upload, /github\.run_attempt/);
}
const launch = pipeline.job('launch-windows');
/** Requires native refusal probes to run on Windows before package admission. */
function checkWindowsAdmission(body) {
	const admission = pipeline.step(body, 'Test native compiled startup admission');
	assert.equal(
		pipeline.stepField(admission, 'run'),
		'node tools/test/test-desktop-ci-evidence.cjs'
	);
	assert.equal(pipeline.stepField(admission, 'shell'), 'pwsh');
	assert.equal(pipeline.stepField(admission, 'if'), null);
	assert.equal(pipeline.stepField(admission, 'continue-on-error'), null);
	assert.ok(body.indexOf(admission) < body.indexOf('name: Smoke test compiled ErgoptiPlus.exe'));
}
checkWindowsAdmission(launch);

/** A fresh-clone boot must be an unconditional native Windows gate. */
function checkFreshSourceBoot(body) {
	const step = pipeline.step(body, 'Test fresh Git clone bootstrap and warm startup');
	assert.equal(pipeline.stepField(step, 'shell'), 'pwsh');
	assert.equal(pipeline.stepField(step, 'if'), null);
	assert.equal(pipeline.stepField(step, 'continue-on-error'), null);
	const run = pipeline.runOf(step).join('\n');
	assert.match(run, /\$env:ERGOPTI_AHK_EXE = \$ahk/);
	assert.match(run, /node tools\/test\/test-ahk-fresh-clone-startup\.cjs/);
	assert.match(run, /if \(\$LASTEXITCODE -ne 0\) \{ exit \$LASTEXITCODE \}/);
}
const sourceBoot = pipeline.job('test-ahk');
checkFreshSourceBoot(sourceBoot);

/** Requires bounded refusal facts without changing source admission authority. */
function checkSourceOwnerEvidence(source) {
	const body = source.match(/^function Get-SourceOwnerEvidence \{([\s\S]*?)^\}/m)?.[1];
	assert.ok(body, 'the actual native source-owner evidence producer must exist');
	const record = body.match(/return \[ordered\]@\{([\s\S]*?)\n {4}\}/)?.[1];
	assert.ok(record, 'the native evidence must have one closed record');
	assert.deepEqual(
		[...record.matchAll(/^ {8}([a-z_]+) =/gm)].map((match) => match[1]),
		[
			'schema_version',
			'native_present',
			'image_present',
			'image_exact',
			'command_present',
			'script_argument_exact'
		],
		'no process command, pathname or unrelated identity belongs in refusal evidence'
	);
	for (const predicate of [
		'schema_version = 1',
		'native_present = [bool]$nativePresent',
		'image_present = [bool]$imagePresent',
		'image_exact = [bool]($imagePresent -and $Native.ExecutablePath -ieq $Interpreter)',
		'command_present = [bool]$commandPresent',
		'script_argument_exact = [bool]($commandPresent -and\n' +
			'            [SourceBootProcess]::HasExactEntry($Native.CommandLine, $Entry))'
	])
		assert.ok(record.includes(predicate), 'the actual predicate must produce ' + predicate);
	assert.doesNotMatch(body, /OpenProcess|TerminateProcess|Get-AdmittedSourceHandle/);
	const refusal = source.match(
		/if \(\$null -eq \$native -or \$native\.ExecutablePath -ine \$Ahk -or\n {8}!\[SourceBootProcess\]::HasExactEntry\(\$native\.CommandLine, \$Entry\)\) \{([\s\S]*?)\n {4}\}/
	)?.[1];
	assert.ok(refusal, 'exact CIM image and first-script-argument admission must remain unchanged');
	assert.match(
		refusal,
		/Get-SourceOwnerEvidence -Native \$native -Interpreter \$Ahk -Entry \$Entry/
	);
	assert.match(refusal, /throw \('[^']*source-owner-evidence=' \+/);
	assert.match(refusal, /\$ownerEvidence \| ConvertTo-Json -Compress/);
}
const sourceObserver = fs.readFileSync(
	path.join(__dirname, 'fixtures/observe_ahk_source_boot.ps1'),
	'utf8'
);
/** Requires native path normalization before any source process starts. */
function checkCanonicalSourceEntry(source) {
	const canonical = source.match(
		/public static string CanonicalEntry\(string entry\) \{([\s\S]*?)^    \}/m
	)?.[1];
	assert.ok(canonical, 'the existing-file native canonical constructor must exist');
	for (const required of [
		'!Path.IsPathFullyQualified(entry) || !File.Exists(entry)',
		'string full = Path.GetFullPath(entry);',
		'GetLongPathName(full, canonical, (uint)canonical.Capacity)',
		'size == 0 || size >= canonical.Capacity || !File.Exists(canonical.ToString())',
		'return canonical.ToString();'
	])
		assert.ok(
			canonical.includes(required),
			'native canonical construction must retain ' + required
		);
	const normalize = '$Entry = [SourceBootProcess]::CanonicalEntry($Entry)';
	assert.equal(source.split(normalize).length - 1, 1, 'normalize the selected entry exactly once');
	assert.ok(source.indexOf('if ($LibraryOnly) { return }') < source.indexOf(normalize));
	assert.ok(source.indexOf(normalize) < source.indexOf('$initial = Start-Process'));
	assert.ok(source.includes('entry = $requestedEntry;'), 'observations preserve caller spelling');
	assert.ok(
		source.includes('[SourceBootProcess]::HasExactEntry($native.CommandLine, $requestedEntry)')
	);
	assert.ok(source.includes('[SourceBootProcess]::HasExactEntry($native.CommandLine, $Entry)'));
	assert.doesNotMatch(canonical, /GetFileInformationByHandle|Contains|EndsWith|GetFileName/);
}
checkCanonicalSourceEntry(sourceObserver);
for (const [from, to] of [
	['$Entry = [SourceBootProcess]::CanonicalEntry($Entry)', '$Entry = $Entry'],
	[
		'GetLongPathName(full, canonical, (uint)canonical.Capacity)',
		'GetLongPathName(entry, canonical, (uint)canonical.Capacity)'
	],
	['!Path.IsPathFullyQualified(entry) || !File.Exists(entry)', '!Path.IsPathFullyQualified(entry)'],
	['entry = $requestedEntry;', 'entry = $Entry;']
]) {
	assert.ok(
		sourceObserver.includes(from),
		'native normalization mutation must modify actual source'
	);
	assert.throws(() => checkCanonicalSourceEntry(sourceObserver.replaceAll(from, to)), from);
}
checkSourceOwnerEvidence(sourceObserver);
for (const [from, to] of [
	['function Get-SourceOwnerEvidence {', 'function MissingEvidenceProducer {'],
	['native_present = [bool]$nativePresent', 'raw_command = $Native.CommandLine'],
	[
		'image_exact = [bool]($imagePresent -and $Native.ExecutablePath -ieq $Interpreter)',
		'image_exact = [bool]$nativePresent'
	],
	[
		'[SourceBootProcess]::HasExactEntry($Native.CommandLine, $Entry))',
		'[SourceBootProcess]::HasExactEntry($Native.CommandLine, $Interpreter))'
	],
	['($ownerEvidence | ConvertTo-Json -Compress)', '($native | ConvertTo-Json -Compress)']
]) {
	assert.ok(
		sourceObserver.includes(from),
		'the source-owner mutation must modify an actual producer'
	);
	assert.throws(() => checkSourceOwnerEvidence(sourceObserver.replaceAll(from, to)), from);
}
/** Requires every isolated LLM runner, including deferred pointer dismissal, to gate CI. */
function checkIsolatedLlmSuites(body) {
	const step = pipeline.step(body, 'Run isolated AHK LLM suites');
	assert.equal(pipeline.stepField(step, 'shell'), 'pwsh');
	assert.equal(pipeline.stepField(step, 'if'), null);
	assert.equal(pipeline.stepField(step, 'continue-on-error'), null);
	const lines = pipeline.runOf(step);
	const block = pipeline.scriptBlock(lines, 'foreach ($name in @(');
	assert.match(block[0], /^foreach /, 'the suite loop must execute outside conditional wrappers');
	const names = [...block[0].matchAll(/"(run_[a-z_]+\.ahk)"/g)].map((match) => match[1]);
	assert.equal(new Set(names).size, names.length, 'each isolated suite runs once');
	for (const name of [
		'run_llm_model_browser.ahk',
		'run_llm_model_menu_disabled.ahk',
		'run_llm_pointer_dismiss.ahk'
	])
		assert.ok(names.includes(name), name + ' must be a mandatory native suite');
	const nativeBody = block.filter((line) => !line.trimStart().startsWith('#')).join('\n');
	assert.doesNotMatch(
		nativeBody,
		/\b(?:continue|break|return)\b/,
		'selected suites cannot be skipped'
	);
	assert.match(nativeBody, /\$runner = Join-Path \$tests \$name/);
	assert.match(
		nativeBody,
		/\$proc = Start-Process -FilePath \$ahk -ArgumentList @\("\/ErrorStdOut", \$runner\)/
	);
	assert.match(nativeBody, /-Wait -PassThru/);
	assert.match(nativeBody, /if \(\$proc\.ExitCode -ne 0\) \{ \$failed \+= 1 \}/);
	assert.match(nativeBody, /validate-ahk-suite-manifest\.cjs/);
	assert.match(nativeBody, /--input \$env:ERGOPTI_AHK_RESULTS_FILE --json \$manifestFile/);
	assert.match(nativeBody, /if \(\$LASTEXITCODE -ne 0\) \{ \$failed \+= 1 \}/);
	assert.ok(pipeline.blockExits(pipeline.scriptBlock(lines, 'if ($failed -gt 0) {'), '1'));
}
checkIsolatedLlmSuites(sourceBoot);
for (const [from, to] of [
	[', "run_llm_pointer_dismiss.ahk"', ''],
	['- name: Run isolated AHK LLM suites', '- name: Run isolated AHK LLM suites\n        if: false'],
	[
		'- name: Run isolated AHK LLM suites',
		'- name: Run isolated AHK LLM suites\n        continue-on-error: true'
	],
	['$runner = Join-Path $tests $name', '$runner = Join-Path $tests "run_llm_model_browser.ahk"'],
	[
		'$runner = Join-Path $tests $name',
		'if ($name -eq "run_llm_pointer_dismiss.ahk") { continue }\n              $runner = Join-Path $tests $name'
	],
	['$proc = Start-Process -FilePath $ahk', '$proc = Write-Output -FilePath $ahk'],
	['if ($proc.ExitCode -ne 0) { $failed += 1 }', 'if ($proc.ExitCode -ne 0) { $failed += 0 }'],
	[
		'--input $env:ERGOPTI_AHK_RESULTS_FILE --json $manifestFile',
		'--input $env:UNUSED_RESULTS_FILE --json $manifestFile'
	],
	['if ($LASTEXITCODE -ne 0) { $failed += 1 }', 'if ($LASTEXITCODE -ne 0) { $failed += 0 }'],
	[
		'if ($failed -gt 0) { Write-Error "$failed isolated LLM suite(s) failed."; exit 1 }',
		'if ($failed -gt 0) { Write-Error "$failed isolated LLM suite(s) failed."; exit 0 }'
	]
]) {
	const originalStep = pipeline.step(sourceBoot, 'Run isolated AHK LLM suites');
	const mutatedStep = originalStep.replace(from, to);
	assert.notEqual(
		mutatedStep,
		originalStep,
		'the isolated-suite mutant must change its real subject'
	);
	const mutated = sourceBoot.replace(originalStep, mutatedStep);
	assert.throws(() => checkIsolatedLlmSuites(mutated), from);
}

for (const [from, to] of [
	['node tools/test/test-ahk-fresh-clone-startup.cjs', 'echo skipped source boot'],
	['$env:ERGOPTI_AHK_EXE = $ahk', '$env:UNUSED_AHK_EXE = $ahk'],
	[
		'- name: Test fresh Git clone bootstrap and warm startup',
		'- name: Test fresh Git clone bootstrap and warm startup\n        if: false'
	],
	[
		'- name: Test fresh Git clone bootstrap and warm startup',
		'- name: Test fresh Git clone bootstrap and warm startup\n        continue-on-error: true'
	]
])
	assert.throws(() => checkFreshSourceBoot(sourceBoot.replaceAll(from, to)), from);
for (const replacement of [
	'run: echo skipped native probes',
	'if: false\n        run: node tools/test/test-desktop-ci-evidence.cjs',
	'continue-on-error: true\n        run: node tools/test/test-desktop-ci-evidence.cjs'
])
	assert.throws(() =>
		checkWindowsAdmission(
			launch.replace('run: node tools/test/test-desktop-ci-evidence.cjs', replacement)
		)
	);
assert.match(launch, /name: assets-windows/);
assert.match(launch, /\$env:RUNNER_TEMP\\package\\ergopti_plus\\windows\\ErgoptiPlus\.exe/);
assert.doesNotMatch(launch, /build_static_bundle|Ahk2Exe/);
const profile = "${{ inputs.release && 'release' || 'ci' }}";
assert.ok(
	pipeline
		.step(pipeline.job('launch'), 'Retain launch evidence')
		.includes(`name: launch-gate-${profile}-`)
);
assert.ok(pipeline.job('macos-ok').includes(`pattern: launch-gate-${profile}-*`));
console.log(
	'[OK] Desktop verdicts reject incomplete launches; shared core gates run independently.'
);

/** Requires the actual zero-status assertion, excluding quoted and commented decoys. */
function checkNativeIdentityStatusAssertion(runtime) {
	const code = runtime.replace(
		/\/\/[^\r\n]*|\/\*[\s\S]*?\*\/|\/(?![/*])(?:\\[^\r\n]|\[(?:\\[^\r\n]|[^\]\\])*\]|[^/\\\r\n])+\/[dgimsuvy]*|'(?:\\[\s\S]|[^'\\])*'|"(?:\\[\s\S]|[^"\\])*"|`(?:\\[\s\S]|[^`\\])*`/g,
		(literal) => literal.replace(/[^\r\n]/g, ' ')
	);
	assert.match(
		code,
		/^[\t ]*assert\s*\.\s*equal\s*\(\s*identity\s*\.\s*status\s*,\s*0\s*[,)]/m,
		'the native own-image status must be asserted equal to integer zero'
	);
}

for (const actual of [
	"assert.equal(identity.status, 0, 'native own-image status');",
	"assert.equal(\n\tidentity.status,\n\t0,\n\t'native own-image status'\n);"
])
	checkNativeIdentityStatusAssertion(actual);
for (const decoy of [
	'assert.equal(result.status, 0);',
	'assert.equal(identity.status, 1);',
	'assert.equal(identity.status, 0.5);',
	"assert.equal(identity.status, '0');",
	'assert.ok(identity.status === 0);',
	'assert.notEqual(identity.status, 0);',
	'other.assert.equal(identity.status, 0);',
	'// assert.equal(identity.status, 0);',
	'/*\nassert.equal(identity.status, 0);\n*/',
	"const text = 'assert.equal(identity.status, 0);';",
	'const text = `\nassert.equal(identity.status, 0);\n`;'
])
	assert.throws(() => checkNativeIdentityStatusAssertion(decoy), decoy);

/** The native fixture must report its own canonical image without relaxing admission. */
function checkCompiledFixtureNormalization(source, runtime) {
	checkNativeIdentityStatusAssertion(runtime);
	for (const token of [
		'if (args.Length != 0 && args[0].StartsWith("--", StringComparison.Ordinal))',
		'CanonicalExistingFile(Process.GetCurrentProcess().MainModule.FileName)',
		'{ "executable", OwnExecutable() }',
		'!Path.IsPathRooted(path)',
		'Path.GetPathRoot(path).Length < 3',
		'piece == "." || piece == ".."',
		'!String.Equals(Path.GetFullPath(path), canonical, StringComparison.OrdinalIgnoreCase)',
		'!SamePhysicalFile(path, canonical)',
		'!File.Exists(path) || Directory.Exists(path)',
		'GetLongPathNameW(path, result, (uint)result.Capacity)',
		'size == 0 || size >= result.Capacity || size != result.Length',
		'!File.Exists(canonical) || Directory.Exists(canonical)',
		'SamePhysicalFile(alias, expected)',
		'shortSize > 0 && shortSize < shortBuffer.Capacity && shortSize == shortBuffer.Length',
		'var launchPath = forceNoShortAlias ? expected : alias;',
		'var aliasObserved = !String.Equals(launchPath, expected, StringComparison.OrdinalIgnoreCase);',
		'new ProcessStartInfo(launchPath, "--own-image")',
		'SamePhysicalFile(invalid, expected)',
		'Environment.CurrentDirectory = priorDirectory;',
		'new string[] { driveRelative, rootRelative, dotted, parentDotted }',
		'An existing malformed native module spelling was admitted.',
		'!SamePhysicalFile(expected, foreign)',
		'GetFileInformationByHandle(first, out a)',
		'GetFileInformationByHandle(second, out b)',
		'a.Volume == b.Volume && a.IndexHigh == b.IndexHigh && a.IndexLow == b.IndexLow',
		'SamePhysicalFile(module, canonical)',
		'(bool)receipt["same_file"] && (bool)receipt["alias_observed"] == aliasObserved',
		'String.Equals((string)receipt["canonical"], expected, StringComparison.OrdinalIgnoreCase)',
		'using (var child = Process.Start(start)) {\n            try {\n                var handle = child.Handle;',
		'if (!child.HasExited)',
		'child.Kill();',
		'child.WaitForExit(5000)',
		'receipt["executable"] = CanonicalExistingFile(foreign);'
	])
		assert.ok(source.includes(token), 'the native own-image contract must retain ' + token);
	assert.doesNotMatch(
		source,
		/IsPathFullyQualified|GetEnvironmentVariable\("(?:EXPECTED|ERGOPTI_EXPECTED)/
	);
	assert.doesNotMatch(
		source,
		/Path\.GetFullPath\(path\), path,/,
		'Framework alias expansion cannot be refused before native canonical admission'
	);
	for (const scenario of [
		'ready',
		'marker-only',
		'early-exit',
		'receipt-then-error-exit',
		'missing-logs',
		'logged-error',
		'foreign-nonce',
		'foreign-executable'
	])
		assert.ok(runtime.includes("'" + scenario + "'"), 'native admission must execute ' + scenario);
	for (const token of [
		'script.includes(\'-ArgumentList "/ErrorStdOut"\')',
		' --identity-controls ',
		' --identity-controls-no-short-alias ',
		'assert.equal(noShortAlias.status, 0',
		"assert.equal(noShortAlias.stderr, ''",
		"assert.equal(noShortAlias.stdout.trim(), identityMessage + 'unavailable (forced control).')",
		' --unknown; exit $LASTEXITCODE',
		"assert.equal(identity.stderr, ''",
		'assert.notEqual(unknownMode.status, 0',
		'assert.notEqual(result.status, 0',
		'failure.failures.length > 0',
		'assert.equal(result.status, 0',
		'receipt.compiled, true',
		'native_startup.exit_code, 0'
	])
		assert.ok(
			runtime.includes(token),
			'native compilation/admission controls must retain ' + token
		);
}
const compiledFixture = fs.readFileSync(
	path.join(__dirname, 'fixtures/windows_launch_child.cs'),
	'utf8'
);
const compiledRuntime = fs.readFileSync(
	path.join(__dirname, 'support/windows-launch-runtime.cjs'),
	'utf8'
);
checkCompiledFixtureNormalization(compiledFixture, compiledRuntime);
for (const [from, to] of [
	[
		'if (args.Length != 0 && args[0].StartsWith("--", StringComparison.Ordinal))',
		'if (args.Length != 0)'
	],
	[
		'CanonicalExistingFile(Process.GetCurrentProcess().MainModule.FileName)',
		'Process.GetCurrentProcess().MainModule.FileName'
	],
	['!Path.IsPathRooted(path)', 'false'],
	['Path.GetPathRoot(path).Length < 3', 'false'],
	['piece == "." || piece == ".."', 'false'],
	[
		'!String.Equals(Path.GetFullPath(path), canonical, StringComparison.OrdinalIgnoreCase)',
		'false'
	],
	['!SamePhysicalFile(path, canonical)', 'false'],
	['SamePhysicalFile(invalid, expected)', 'true'],
	['Environment.CurrentDirectory = priorDirectory;', '// restoration omitted'],
	['size == 0 || size >= result.Capacity || size != result.Length', 'size == 0'],
	['SamePhysicalFile(alias, expected)', 'true'],
	['shortSize > 0 && shortSize < shortBuffer.Capacity && shortSize == shortBuffer.Length', 'true'],
	['var launchPath = forceNoShortAlias ? expected : alias;', 'var launchPath = alias;'],
	[
		'var aliasObserved = !String.Equals(launchPath, expected, StringComparison.OrdinalIgnoreCase);',
		'var aliasObserved = true;'
	],
	['new ProcessStartInfo(launchPath, "--own-image")', 'new ProcessStartInfo(expected, "--unused")'],
	['!SamePhysicalFile(expected, foreign)', 'true'],
	[
		'(bool)receipt["same_file"] && (bool)receipt["alias_observed"] == aliasObserved',
		'(bool)receipt["same_file"]'
	],
	[
		'using (var child = Process.Start(start)) {\n            try {\n                var handle = child.Handle;',
		'using (var child = Process.Start(start)) {\n            var handle = child.Handle;\n            try {'
	],
	['child.WaitForExit(5000)', 'true']
]) {
	assert.ok(compiledFixture.includes(from), 'the mutation must alter the actual native producer');
	assert.throws(
		() => checkCompiledFixtureNormalization(compiledFixture.replaceAll(from, to), compiledRuntime),
		from
	);
}
for (const [from, to] of [
	['identity.status,\n\t\t\t0,', 'result.status,\n\t\t\t0,'],
	['identity.status,\n\t\t\t0,', 'identity.status,\n\t\t\t1,'],
	['assert.equal(\n\t\t\tidentity.status,', 'assert.notEqual(\n\t\t\tidentity.status,'],
	["'foreign-executable'", "'ready'"],
	[' --identity-controls ', ' --unused '],
	[' --identity-controls-no-short-alias ', ' --unused '],
	['assert.equal(noShortAlias.status, 0', 'assert.equal(noShortAlias.status, 1'],
	["assert.equal(noShortAlias.stderr, ''", "assert.ok(noShortAlias.stderr === ''"],
	[
		"assert.equal(noShortAlias.stdout.trim(), identityMessage + 'unavailable (forced control).')",
		"assert.equal(noShortAlias.stdout.trim(), identityMessage + 'observed.')"
	],
	["assert.equal(identity.stderr, ''", "assert.ok(identity.stderr === ''"]
]) {
	assert.ok(compiledRuntime.includes(from), 'the mutation must alter the actual native control');
	assert.throws(
		() => checkCompiledFixtureNormalization(compiledFixture, compiledRuntime.replaceAll(from, to)),
		from
	);
}
// Native stderr is diagnostic input only; it cannot supply success or raw payload.
{
	const describe = require('./support/windows-launch-runtime.cjs').describeNativeIdentityFailure;
	assert.equal(
		typeof describe,
		'function',
		'the actual native status owner must expose its closed classifier'
	);
	const known = 'The native alias does not resolve to the exact controlled module.';
	const raw = 'private-error-payload-marker';
	const native = {
		stderr:
			'Unhandled Exception: System.InvalidOperationException: ' +
			known +
			'\r\n' +
			'   at WindowsLaunchChild.IdentityControls(String[] args) in C:\\' +
			raw +
			':line 1\r\n',
		stdout: raw
	};
	const closed = JSON.parse(describe(native, compiledFixture));
	assert.equal(closed.exception_type, 'System.InvalidOperationException');
	assert.equal(closed.fixture_refusal, known);
	assert.equal(
		JSON.parse(
			describe(
				{ stderr: 'native.exe : Unhandled Exception: System.InvalidOperationException: ' + known },
				compiledFixture
			)
		).fixture_refusal,
		known
	);
	assert.deepEqual(closed.fixture_frames, ['IdentityControls']);
	assert.equal(closed.stderr_characters, native.stderr.length);
	assert.equal(closed.stdout_characters, raw.length);
	assert(!describe(native, compiledFixture).includes(raw));
	assert.equal(
		JSON.parse(
			describe(
				{ stderr: 'Unhandled Exception: System.InvalidOperationException: ' + raw },
				compiledFixture
			)
		).fixture_refusal,
		'unobserved'
	);
	assert.equal(
		JSON.parse(
			describe(
				{ stderr: 'Unhandled Exception: System.InvalidOperationException: ' + known + raw },
				compiledFixture
			)
		).fixture_refusal,
		'unobserved'
	);
	assert.equal(
		JSON.parse(describe({ stderr: 'System.Private' + raw + ': ' + raw }, compiledFixture))
			.exception_type,
		'unobserved'
	);
	assert.equal(
		JSON.parse(
			describe(
				{ stderr: 'Unhandled Exception: System.ComponentModel.Win32Exception: ' + raw },
				compiledFixture
			)
		).exception_type,
		'System.ComponentModel.Win32Exception'
	);
	assert.equal(
		JSON.parse(
			describe(
				{ stderr: 'Unhandled Exception: System.ComponentModel.Win32Exception: ' + raw },
				compiledFixture
			)
		).fixture_refusal,
		'unobserved'
	);
	assert.deepEqual(
		JSON.parse(describe({ stderr: 'at Private.' + raw + '()' }, compiledFixture)).fixture_frames,
		[]
	);
	assert.deepEqual(JSON.parse(describe({ stderr: { raw }, stdout: { raw } }, compiledFixture)), {
		exception_type: 'unobserved',
		fixture_refusal: 'unobserved',
		fixture_frames: [],
		stderr_characters: 0,
		stdout_characters: 0
	});
	assert(
		compiledRuntime.includes('describeNativeIdentityFailure(identity, fixtureSource)'),
		'the actual status assertion must consume the closed native stderr classifier'
	);
}

// The fixture must supply the canonical package location without relaxing recordWindows.
{
	const canonicalDirectory =
		require('./support/windows-launch-runtime.cjs').canonicalFixtureDirectory;
	assert.equal(
		typeof canonicalDirectory,
		'function',
		'the actual native owner must expose its directory admission'
	);
	const owned = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-canonical-fixture-root-'));
	try {
		const target = path.join(owned, 'actual');
		const alias = path.join(owned, 'alias');
		fs.mkdirSync(target);
		fs.symlinkSync(target, alias, process.platform === 'win32' ? 'junction' : 'dir');
		const canonical = canonicalDirectory(alias);
		assert.equal(
			canonical,
			fs.realpathSync.native(target),
			'an actual alias must resolve through the native owner'
		);
		assert.notEqual(
			alias,
			canonical,
			'the positive control must have independently different spellings'
		);
		const originalIdentity = fs.statSync(alias, { bigint: true });
		const canonicalIdentity = fs.statSync(canonical, { bigint: true });
		assert.equal(originalIdentity.dev, canonicalIdentity.dev);
		assert.equal(
			originalIdentity.ino,
			canonicalIdentity.ino,
			'the canonical image must be the same physical directory'
		);
		const packageBytes = 'independent canonical package fixture';
		const canonicalPackage = path.join(canonical, 'ErgoptiPlus.exe');
		const requestedPackage = path.join(alias, 'ErgoptiPlus.exe');
		fs.writeFileSync(canonicalPackage, packageBytes);
		const native = windowsStartup();
		native.executable = canonicalPackage;
		native.receipt.executable = canonicalPackage;
		native.launched_sha256 = crypto.createHash('sha256').update(packageBytes).digest('hex');
		const observation = path.join(owned, 'observation.json');
		const output = path.join(owned, 'recorded.json');
		fs.writeFileSync(
			observation,
			JSON.stringify({
				marker_seen: true,
				crashed_early: false,
				marker_seconds: 1,
				native_startup: native
			})
		);
		const oldSha = process.env.GITHUB_SHA;
		try {
			process.env.GITHUB_SHA = 'a'.repeat(40);
			assert.throws(
				() => recordWindows(observation, requestedPackage, output),
				/not the launched executable/,
				'the old requested-spelling policy must fail the unchanged strict product validator'
			);
			assert.equal(fs.existsSync(output), false, 'an alias mismatch must publish no evidence');
			recordWindows(observation, canonicalPackage, output);
			assert.equal(
				JSON.parse(fs.readFileSync(output, 'utf8')).package_sha256,
				native.launched_sha256,
				'the native canonical fixture must record actual same-file package bytes'
			);
		} finally {
			if (oldSha === undefined) delete process.env.GITHUB_SHA;
			else process.env.GITHUB_SHA = oldSha;
		}
		const foreign = path.join(owned, 'foreign');
		fs.mkdirSync(foreign);
		const foreignPort = { statSync: fs.statSync, realpathSync: { native: () => foreign } };
		assert.throws(
			() => canonicalDirectory(alias, foreignPort),
			/another file/,
			'a native image of a foreign directory must not replace the actual owned directory'
		);
		let physicalReads = 0;
		const foreignDevice = {
			statSync: () => ({
				isDirectory: () => true,
				dev: originalIdentity.dev + (physicalReads++ === 0 ? 0n : 1n),
				ino: originalIdentity.ino
			}),
			realpathSync: { native: () => target }
		};
		assert.throws(
			() => canonicalDirectory(alias, foreignDevice),
			/another device/,
			'equal file indices on another device do not establish physical ownership'
		);
		assert.throws(
			() =>
				canonicalDirectory(alias, {
					statSync: fs.statSync,
					realpathSync: { native: () => 'relative-directory' }
				}),
			/actual absolute native directory/
		);
		const file = path.join(owned, 'regular-file');
		fs.writeFileSync(file, 'actual regular file');
		assert.throws(() => canonicalDirectory(file), /must be directories/);
		const unknownIdentity = {
			statSync: () => ({ isDirectory: () => true, dev: 0n, ino: 0n }),
			realpathSync: { native: () => target }
		};
		assert.throws(() => canonicalDirectory(alias, unknownIdentity), /independent file identities/);
		const textualIdentity = {
			statSync: () => ({ isDirectory: () => true, dev: '1', ino: '1' }),
			realpathSync: { native: () => target }
		};
		assert.throws(() => canonicalDirectory(alias, textualIdentity), /independent file identities/);
		assert.equal(
			fs.existsSync(target),
			true,
			'refused projections must not retire the actual fixture'
		);
		assert.equal(
			fs.existsSync(foreign),
			true,
			'foreign identity refusal must not delete a sibling'
		);
	} finally {
		fs.rmSync(owned, { recursive: true, force: true });
	}
	assert.ok(
		compiledRuntime.includes('const temporary = canonicalFixtureDirectory(acquiredDirectory);')
	);
	assert.ok(
		compiledRuntime.includes('fs.rmSync(acquiredDirectory, { recursive: true, force: true });')
	);
}

// The launch job has no npm install: every native control must load with builtins only.
{
	const childProcess = require('node:child_process');
	const runtimePath = require.resolve('./support/windows-startup-log-runtime.cjs');
	const result = childProcess.spawnSync(
		process.execPath,
		[
			'-e',
			`
		const Module = require('node:module');
		const originalLoad = Module._load;
		Module._load = function(request, parent, isMain) {
			if (!Module.isBuiltin(request) && !request.startsWith('.') && !require('node:path').isAbsolute(request))
				throw new Error('Third-party modules are unavailable in the native launch job');
			return originalLoad.call(this, request, parent, isMain);
		};
		const runtime = require(process.argv[1]);
		if (typeof runtime !== 'function' || typeof runtime.readStartupLogCatalog !== 'function')
			throw new Error('The actual native catalogue owner was not loaded');
	`,
			runtimePath
		],
		{ encoding: 'utf8', timeout: 10000, windowsHide: true }
	);
	assert.ok(
		!result.error && result.status === 0,
		'the actual native runtime must load without third-party modules'
	);
	assert.equal(result.stderr, '');
	const readCatalog = require(runtimePath).readStartupLogCatalog;
	const recipe = pipeline.runOf(
		pipeline.step(
			pipeline.job('launch-windows'),
			'Smoke test compiled ErgoptiPlus.exe (crash-on-launch guard)'
		)
	);
	const actual = readCatalog(recipe);
	assert.ok(
		actual.segments.length > 0,
		'the real canonical TOML catalogue must be admitted by its native workflow reader'
	);
	const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-native-log-catalog-'));
	try {
		const catalogPath = path.join(directory, 'catalog.toml');
		const command = recipe.find((line) => line.includes('$catalogJson = & python -c '));
		const fixtureRecipe = [
			command.replace(
				/"\$env:GITHUB_WORKSPACE\\[^"\r\n]+"/,
				'"$env:GITHUB_WORKSPACE\\catalog.toml"'
			)
		];
		fs.writeFileSync(
			catalogPath,
			'[app]\nfolder_name="owned-name"\n[logs.windows]\nbase="PRIVATE_ROOT"\nsegments=["{app}","trace"]\n[logs.files]\nunified_prefix="daily_"\nextension=".txt"\n'
		);
		assert.deepEqual(
			readCatalog(fixtureRecipe, directory),
			{
				base: 'PRIVATE_ROOT',
				segments: ['owned-name', 'trace'],
				prefix: 'daily_',
				extension: '.txt'
			},
			'the existing Python source command must resolve independent TOML fields and the application placeholder'
		);
		fs.writeFileSync(catalogPath, '[app\nPRIVATE_CATALOG_ERROR');
		assert.throws(
			() => readCatalog(fixtureRecipe, directory),
			/native log catalogue reader refused/
		);
	} finally {
		fs.rmSync(directory, { recursive: true, force: true });
	}
	const valid = { status: 0, stdout: JSON.stringify(actual), stderr: '' };
	for (const response of [
		{ ...valid, status: null, signal: 'SIGTERM' },
		{ ...valid, status: 1 },
		{ ...valid, error: new Error('PRIVATE_CATALOG_ERROR') },
		{ ...valid, stdout: 'PRIVATE_CATALOG_ERROR' },
		{ ...valid, stderr: 'PRIVATE_CATALOG_ERROR' },
		{ ...valid, stdout: '{}' },
		{ ...valid, stdout: JSON.stringify({ ...actual, segments: ['..'] }) },
		{ ...valid, stdout: JSON.stringify({ ...actual, prefix: false }) }
	]) {
		assert.throws(
			() => readCatalog(recipe, pipeline.ROOT, () => response),
			(error) => !/PRIVATE_CATALOG_ERROR/.test(error.message),
			'native reader refusal must not project private streams'
		);
	}

	// Independent closed receipts distinguish native refusal without projecting private data.
	const refusalPrefix = 'the actual native log catalogue reader refused';
	const closedRefusals = [
		[
			'timeout',
			{ error: { code: 'ETIMEDOUT' }, status: null, signal: 'SIGTERM' },
			'present; status=null; error=ETIMEDOUT; signal=SIGTERM'
		],
		[
			'missing-program',
			{ error: { code: 'ENOENT' }, status: null, signal: null },
			'present; status=null; error=ENOENT; signal=NONE'
		],
		[
			'access-refused',
			{ error: { code: 'EACCES' }, status: null },
			'present; status=null; error=EACCES; signal=NONE'
		],
		[
			'buffer-refused',
			{ error: { code: 'ENOBUFS' }, status: null },
			'present; status=null; error=ENOBUFS; signal=NONE'
		],
		['nonzero', { status: 7, signal: null }, 'present; status=7; error=NONE; signal=NONE'],
		['null-status', { status: null }, 'present; status=null; error=NONE; signal=NONE'],
		['absent-result', undefined, 'absent; status=null; error=NONE; signal=NONE'],
		['null-result', null, 'absent; status=null; error=NONE; signal=NONE'],
		[
			'private-code',
			{
				error: { code: 'PRIVATE_CATALOG_ERROR', message: 'PRIVATE_CATALOG_ERROR' },
				status: -2,
				signal: 'PRIVATE_CATALOG_ERROR'
			},
			'present; status=-2; error=OTHER; signal=OTHER'
		],
		[
			'string-error',
			{ error: 'PRIVATE_CATALOG_ERROR', status: null },
			'present; status=null; error=OTHER; signal=NONE'
		],
		[
			'integer-error',
			{ error: 17, status: null },
			'present; status=null; error=OTHER; signal=NONE'
		],
		[
			'invalid-status',
			{ error: true, status: 'PRIVATE_CATALOG_ERROR', signal: 17 },
			'present; status=null; error=OTHER; signal=OTHER'
		],
		[
			'private-code-getter',
			{
				error: {
					get code() {
						throw 'PRIVATE_CATALOG_ERROR';
					}
				},
				status: null
			},
			'present; status=null; error=OTHER; signal=NONE'
		],
		[
			'private-signal-getter',
			{
				error: true,
				status: null,
				get signal() {
					throw 'PRIVATE_CATALOG_ERROR';
				}
			},
			'present; status=null; error=OTHER; signal=OTHER'
		]
	];
	for (const [name, response, fields] of closedRefusals) {
		let observed;
		assert.throws(
			() => readCatalog(recipe, pipeline.ROOT, () => response),
			(error) => {
				observed = error;
				return error instanceof assert.AssertionError;
			},
			`${name}: the original native result predicate must still refuse`
		);
		assert.equal(
			observed.message,
			`${refusalPrefix} [result=${fields}]`,
			`${name}: the exact closed refusal receipt must remain observable`
		);
		assert.doesNotMatch(
			observed.message,
			/PRIVATE_CATALOG_ERROR/,
			`${name}: no private result field may escape`
		);
	}
	// The existing execute boundary propagates thrown values by exact identity.
	for (const thrown of ['PRIVATE_CATALOG_ERROR', 17, null, new Error('PRIVATE_CATALOG_ERROR')]) {
		let caught = false;
		try {
			readCatalog(recipe, pipeline.ROOT, () => {
				throw thrown;
			});
		} catch (error) {
			caught = true;
			assert.equal(error, thrown, 'execute exceptions retain their original identity');
		}
		assert.equal(caught, true, 'the original execute exception must propagate');
	}
	assert.deepEqual(
		readCatalog(recipe, pipeline.ROOT, (program, arguments_, options) => {
			assert.equal(program, 'python', 'the original workflow command remains the executable');
			assert.equal(arguments_[0], '-c', 'the original catalogue script invocation is unchanged');
			assert.equal(options.timeout, 5000, 'diagnostics never relax the native read deadline');
			assert.equal(options.maxBuffer, 65536, 'diagnostics never relax the native stream bound');
			return valid;
		}),
		actual,
		'the original valid native result is still admitted unchanged'
	);

	assert.throws(() => readCatalog([]), /one actual owner/);
	const command = recipe.find((line) => line.includes('$catalogJson = & python -c '));
	assert.throws(() => readCatalog([command, command]), /one actual owner/);
	assert.throws(
		() =>
			readCatalog([
				command.replace(
					/"\$env:GITHUB_WORKSPACE\\[^"\r\n]+"/,
					'"$env:GITHUB_WORKSPACE\\..\\catalog.toml"'
				)
			]),
		/inside its repository/
	);
}

// Exercise the actual Windows consumer after the catalogue reader returns its flat packet.
{
	const vm = require('node:vm');
	const runtimePath = require.resolve('./support/windows-startup-log-runtime.cjs');
	const module = { exports: {} };
	const cases = [];
	const ownedRoots = new Set();
	let catalogueCalls = 0;
	const catalog = {
		base: 'ERGOPTI_TEST_LOG_ROOT',
		segments: ['independent-app', 'trace'],
		prefix: 'independent_daily_',
		extension: '.txt'
	};
	function nativeSpawn(program, arguments_, options) {
		if (program === 'python') {
			catalogueCalls++;
			assert.equal(arguments_[0], '-c');
			assert.equal(options.timeout, 5000);
			return { status: 0, stdout: JSON.stringify(catalog), stderr: '' };
		}
		assert.equal(program, 'pwsh.exe', 'only the actual native collector boundary is replaced');
		assert.deepEqual(Array.from(arguments_.slice(0, 3)), [
			'-NoProfile',
			'-NonInteractive',
			'-File'
		]);
		assert.equal(options.timeout, 30000, 'the existing native collector keeps its deadline');
		const defaultRoot = options.env.ERGOPTI_TEST_LOG_ROOT;
		assert.equal(
			typeof defaultRoot,
			'string',
			'the flat catalogue base owns the native environment'
		);
		assert.equal(path.basename(defaultRoot), 'private-local-app-data');
		assert.equal(options.env.GITHUB_WORKSPACE, pipeline.ROOT);
		const scenario = path.dirname(defaultRoot);
		ownedRoots.add(path.dirname(scenario));
		const smoke = options.env.ERGOPTI_STARTUP_SMOKE_DIR !== '';
		const selected = smoke ? options.env.ERGOPTI_STARTUP_SMOKE_DIR : defaultRoot;
		assert.equal(path.dirname(selected), scenario);
		const observer = fs.readFileSync(arguments_[3], 'utf8');
		assert.ok(observer.includes('Write-StartupOwnershipEvidence $proc'));
		const bootstrap = path.join(selected, 'independent-app', 'trace', 'bootstrap.log');
		const present = fs.existsSync(bootstrap);
		cases.push(`${smoke ? 'smoke' : 'normal'}-${present ? 'present' : 'absent'}`);
		const logs = ['bootstrap.log', 'independent_daily_2026-10-04.txt'];
		const rows = logs.map((log) => {
			if (!present)
				return {
					log,
					status: 'unavailable',
					cause: 'Owned fixture log is absent.'
				};
			const bytes = fs.readFileSync(bootstrap);
			return {
				log,
				status: 'observed',
				size_bytes: bytes.length,
				read_bytes: 4096,
				truncated: true,
				tail: bytes.subarray(bytes.length - 4096).toString('utf8')
			};
		});
		return {
			status: 0,
			stdout: rows.map((row) => JSON.stringify(row)).join('\n'),
			stderr: ''
		};
	}
	vm.runInNewContext(
		fs.readFileSync(runtimePath, 'utf8'),
		{
			module,
			exports: module.exports,
			process: { platform: 'win32', env: {} },
			Buffer,
			console: { log() {} },
			require(name) {
				if (name === 'node:child_process') return { spawnSync: nativeSpawn };
				if (name === '../ci-pipeline.cjs') return pipeline;
				return require(name);
			}
		},
		{ filename: runtimePath, timeout: 10000 }
	);
	assert.equal(typeof module.exports, 'function');
	module.exports();
	assert.equal(catalogueCalls, 1, 'the real consumer acquires one strict catalogue packet');
	assert.deepEqual(cases, ['smoke-present', 'smoke-absent', 'normal-present', 'normal-absent']);
	assert.equal(ownedRoots.size, 1, 'all four actual scenarios share one acquired fixture owner');
	for (const directory of ownedRoots)
		assert.equal(fs.existsSync(directory), false, 'the actual consumer retires its fixture');
}

require('./support/windows-launch-runtime.cjs')();

require('./support/windows-startup-log-runtime.cjs')();

// CI_INSTALLED_ARCHIVE_EVIDENCE_BEGIN
{
	const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ci-installed-archive-evidence-'));
	try {
		const observation = path.join(root, 'result.json');
		fs.writeFileSync(observation, JSON.stringify({ scenario: 'upgraded', failures: [] }));
		const previousSha = process.env.GITHUB_SHA,
			previousRunner = process.env.MATRIX_RUNNER;
		try {
			process.env.GITHUB_SHA = 'a'.repeat(40);
			process.env.MATRIX_RUNNER = 'macos-15';
			for (const extension of ['tar.xz', 'zip']) {
				const selected = path.join(root, 'installed.' + extension);
				const unselected = path.join(root, 'other-' + extension);
				const output = path.join(root, 'evidence-' + extension + '.json');
				fs.writeFileSync(selected, 'Actual installed immutable bytes: ' + extension);
				fs.writeFileSync(unselected, 'Another valid archive, never installed');
				recordMac(observation, selected, output);
				const actual = JSON.parse(fs.readFileSync(output));
				assert.equal(
					actual.package_sha256,
					crypto.createHash('sha256').update(fs.readFileSync(selected)).digest('hex')
				);
				assert.notEqual(
					actual.package_sha256,
					crypto.createHash('sha256').update(fs.readFileSync(unselected)).digest('hex')
				);
				assert.equal(actual.scenario, 'upgraded');
				assert.deepEqual(actual.failures, []);
			}
		} finally {
			if (previousSha === undefined) delete process.env.GITHUB_SHA;
			else process.env.GITHUB_SHA = previousSha;
			if (previousRunner === undefined) delete process.env.MATRIX_RUNNER;
			else process.env.MATRIX_RUNNER = previousRunner;
		}
	} finally {
		fs.rmSync(root, { recursive: true });
	}
	console.log('Actual installed-archive evidence controls: 2');
}
// CI_INSTALLED_ARCHIVE_EVIDENCE_END

// The cold proof supplements all existing job/launch assertions.
const {
	verifyColdBootstrapRecords,
	recordColdMac,
	readColdBootstrapEvidence
} = require('./desktop-ci-evidence.cjs');
verifyColdBootstrapRecords([coldBootstrapRecord()], 'a'.repeat(40));
let coldRejections = 0;
function rejectCold(mutate) {
	const records = [coldBootstrapRecord()];
	mutate(records);
	assert.throws(() => verifyColdBootstrapRecords(records, 'a'.repeat(40)));
	coldRejections += 1;
}
rejectCold((records) => records.pop());
rejectCold((records) => records.push(structuredClone(records[0])));
for (const field of Object.keys(coldBootstrapRecord()))
	rejectCold((records) => {
		delete records[0][field];
	});
for (const [field, value] of [
	['sha', 'b'.repeat(40)],
	['build_commit', 'b'.repeat(40)],
	['status', 'failed'],
	['architecture', 'x86_64'],
	['platform', 'linux'],
	['runtime_environment', 'stock host physically missing Python'],
	['signature_verified', false],
	['cleanup', false],
	['helpers_retired', false],
	['managed_runtime_isolated_exec', false],
	['imports', 'skipped'],
	['uv', 'uv 0.12.20'],
	['python', '3.11.15'],
	['fingerprint', 'foreign']
])
	rejectCold((records) => {
		records[0].receipt[field] = value;
	});
for (const field of Object.keys(coldBootstrapRecord().receipt))
	rejectCold((records) => {
		delete records[0].receipt[field];
	});
for (const field of [
	'group_retired',
	'guardian_reaped',
	'pty_eof',
	'handles_closed',
	'status_valid',
	'source_admitted'
])
	for (const value of [false, null, 1, 'true'])
		rejectCold((records) => {
			records[0].receipt.caller.physical_receipt[field] = value;
		});
for (const [field, value] of [
	['tasks', true],
	['tasks', 2],
	['worker_status', false],
	['worker_status', 74],
	['worker_pid', 0],
	['python_resolver', 'forced missing Python test adapter'],
	['python_state', 'ready'],
	['native_python_candidates_count', true],
	['native_python_candidates_count', 1],
	['receipt_removed', false],
	['receipt_retired', false],
	['nonce', 'foreign'],
	['native_cli', ['--managed-pty-worker', '600000']],
	['source_sha256', '0'.repeat(64)]
])
	rejectCold((records) => {
		records[0].receipt.caller[field] = value;
	});
for (const field of Object.keys(coldBootstrapRecord().receipt.caller))
	rejectCold((records) => {
		delete records[0].receipt.caller[field];
	});
rejectCold((records) => {
	records[0].receipt.sources['macos/modules/llm/ensure-mlx-deps.sh'] = '0'.repeat(64);
});
rejectCold((records) => {
	delete records[0].receipt.sources['macos/adapters/python_interpreter.lua'];
});
rejectCold((records) => {
	records[0].receipt.diagnostics['tools/diagnostics/macos_cold_bootstrap.lua'] = '0'.repeat(64);
});
rejectCold((records) => {
	records[0].receipt.official_hammerspoon.sha256 = '0'.repeat(64);
});
rejectCold((records) => {
	records[0].receipt.official_hammerspoon.bytes = 9704558;
});
for (const [field, value] of [
	['read_denied', false],
	['read_denied', 1],
	['exec_denied', false],
	['exec_denied', 1],
	['native', 1],
	['inode', 0],
	['device', null],
	['bytes', 0],
	['sha256', ''],
	['path', '/foreign/python']
])
	rejectCold((records) => {
		records[0].receipt.isolation.observations[0][field] = value;
	});
rejectCold((records) => {
	records[0].receipt.isolation.observations = [];
});
rejectCold((records) => {
	records[0].receipt.isolation.observations.push(records[0].receipt.isolation.observations[0]);
});
rejectCold((records) => {
	records[0].receipt.isolation.host_files_preserved = false;
});
rejectCold((records) => {
	records[0].receipt.isolation.paths.pop();
});
rejectCold((records) => {
	records[0].receipt.isolation.paths.push('/usr/bin/python3');
});
rejectCold((records) => {
	records[0].receipt.isolation.profile_sha256 = '0'.repeat(64);
});
rejectCold((records) => {
	records[0].receipt.caller.denied_runtime_paths = [];
});

/** Pins a native arm64 full application job without unrelated dependencies or publication. */
function checkColdJob(body) {
	assert.equal(pipeline.field(body, 'needs'), null);
	assert.equal(pipeline.field(body, 'runs-on'), 'macos-15');
	assert.equal(pipeline.field(body, 'if'), null);
	assert.equal(pipeline.field(body, 'continue-on-error'), null);
	assert.ok(Number(pipeline.field(body, 'timeout-minutes')) >= 40);
	const prerequisites = pipeline.step(body, 'Require actual arm64 cold runtime prerequisites');
	assert.match(prerequisites, /test -x \/usr\/bin\/sandbox-exec/);
	assert.match(prerequisites, /test \"\$\(uname -m\)\" = arm64/);
	const build = pipeline.step(body, 'Build independent signed cold application');
	const receive = pipeline.step(body, 'Receive actual isolated cold native MLX bootstrap');
	for (const step of [prerequisites, build, receive]) {
		assert.equal(pipeline.stepField(step, 'if'), null);
		assert.equal(pipeline.stepField(step, 'continue-on-error'), null);
		assert.equal(pipeline.stepField(step, 'shell'), 'bash');
	}
	assert.match(build, /ERGOPTI_BUILD_COMMIT: \$\{\{ github.sha \}\}/);
	assert.match(build, /ERGOPTI_RELEASE: 'false'/);
	assert.match(build, /HAMMERSPOON_VERSION: '1\.1\.1'/);
	assert.match(build, /bash tools\/build\/build_macos_app.sh/);
	assert.match(build, /codesign --verify --deep --strict build\/macos\/ErgoptiPlus.app/);
	assert.doesNotMatch(
		body,
		/--native-helper-only|brew install|gh release|TCC\.db|tccutil|continue-on-error|sudo rm|rm -rf.*(?:uv|python)/
	);
	assert.match(receive, /python3 tools\/diagnostics\/macos_cold_bootstrap.py/);
	assert.match(receive, /--app "\$PWD\/build\/macos\/ErgoptiPlus.app"/);
	assert.match(receive, /record-cold-macos/);
	const officialUpload = pipeline.step(body, 'Retain official cold Ollama receipt only');
	assert.equal(pipeline.stepField(officialUpload, 'if'), 'always()');
	assert.match(officialUpload, /if-no-files-found: error/);
	assert.match(officialUpload, /overwrite: true/);
	assert.match(
		officialUpload,
		/path: \$\{\{ runner.temp \}\}\/native-cold-ollama-bootstrap\/receipt.json$/m
	);
	const upload = pipeline.step(body, 'Retain native cold bootstrap evidence');
	assert.equal(pipeline.stepField(upload, 'if'), 'always()');
	assert.match(upload, /if-no-files-found: error/);
	assert.match(upload, /overwrite: true/);
	assert.match(upload, /cold-bootstrap-evidence\.json/);
}
const coldJob = pipeline.job('cold-bootstrap-native');
checkColdJob(coldJob);
for (const [from, to] of [
	['runs-on: macos-15', 'runs-on: ubuntu-latest'],
	['timeout-minutes: 90', 'timeout-minutes: 5'],
	['runs-on: macos-15', 'needs: package-macos\n    runs-on: macos-15'],
	["ERGOPTI_RELEASE: 'false'", "ERGOPTI_RELEASE: 'true'"],
	[
		'bash tools/build/build_macos_app.sh',
		'bash tools/build/build_macos_app.sh --native-helper-only'
	],
	['python3 tools/diagnostics/macos_cold_bootstrap.py', 'echo skipped cold receiving'],
	['record-cold-macos', 'record-macos'],
	['if-no-files-found: error', 'if-no-files-found: warn'],
	['if: always()', 'if: success()'],
	['shell: bash', 'if: false\n        shell: bash']
]) {
	const changed = coldJob.replace(from, to);
	assert.notEqual(changed, coldJob);
	assert.throws(() => checkColdJob(changed), from);
}
assert.ok(pipeline.needsOf(pipeline.job('macos-ok')).includes('cold-bootstrap-native'));
assert.match(
	pipeline.step(pipeline.job('macos-ok'), 'Download native cold bootstrap evidence'),
	/cold-bootstrap-native-/
);
console.log(
	`[OK] Cold native verdict retained existing launch/job assertions and rejected ${coldRejections} independent receipt mutations plus 10 workflow mutations.`
);

// A compiler failure must retain its actual transcript before unrelated tests.
for (const [job, buildName, uploadName, transcript] of [
	[
		'package-macos',
		'Build release launcher',
		'Retain launcher build diagnostics',
		'macos-release-launcher-build.log'
	],
	[
		'package-macos',
		'Build ErgoptiPlus.app',
		'Retain application build diagnostics',
		'macos-application-build.log'
	],
	[
		'cold-bootstrap-native',
		'Build independent signed cold application',
		'Retain native cold bootstrap evidence',
		'cold-bootstrap-application-build.log'
	],
	[
		'managed-ollama-native',
		'Build the actual launcher native transport roles',
		'Retain actual native producer, catalogue and receiving evidence',
		'managed-ollama-launcher-build.log'
	],
	[
		'managed-ollama-native',
		'Build and admit the actual native source asset',
		'Retain actual native producer, catalogue and receiving evidence',
		'managed-ollama-producer-build.log'
	]
]) {
	const body = pipeline.job(job);
	const build = pipeline.step(body, buildName);
	const upload = pipeline.step(body, uploadName);
	const check = (step, artifact) => {
		assert.match(step, /set -euo pipefail/);
		assert.ok(step.includes('2>&1 | tee "$RUNNER_TEMP/' + transcript + '"'));
		assert.equal(pipeline.stepField(artifact, 'if'), 'always()');
		assert.ok(artifact.includes('${{ runner.temp }}/' + transcript));
	};
	check(build, upload);
	assert.throws(() => check(build.replace('2>&1 | tee', '| tee'), upload));
	assert.throws(() => check(build.replace('set -euo pipefail', 'set -eu'), upload));
	assert.throws(() => check(build, upload.replace('if: always()', 'if: success()')));
	assert.throws(() =>
		check(
			build,
			upload.replace('${{ runner.temp }}/' + transcript, '${{ runner.temp }}/missing.log')
		)
	);
}
assert.ok(
	pipeline
		.step(managedOllamaNative, 'Retain actual native producer, catalogue and receiving evidence')
		.includes('receiving/*/native-receiving.json')
);
assert.doesNotMatch(
	pipeline.step(
		managedOllamaNative,
		'Retain actual native producer, catalogue and receiving evidence'
	),
	/include-hidden-files: true/
);
console.log(
	'[OK] Five actual native compiler/build transcripts remain available on failure; 20 independent retention mutations rejected.'
);

// Exercise actual record/read admission functions with portable literal data.
{
	const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-cold-verdict-'));
	const previousSha = process.env.GITHUB_SHA;
	try {
		process.env.GITHUB_SHA = 'a'.repeat(40);
		const source = path.join(directory, 'receipt.json');
		const output = path.join(directory, 'cold-bootstrap-evidence.json');
		const rejected = coldBootstrapRecord().receipt;
		rejected.caller.python_resolver = 'forced missing Python adapter';
		fs.writeFileSync(source, JSON.stringify(rejected));
		assert.throws(() => recordColdMac(source, output));
		assert.equal(
			fs.existsSync(output),
			false,
			'A fake missing-Python selection must publish no evidence'
		);
		fs.writeFileSync(source, JSON.stringify(coldBootstrapRecord().receipt));
		recordColdMac(source, output);
		assert.deepEqual(readColdBootstrapEvidence(directory), [coldBootstrapRecord()]);
		assert.deepEqual(require('./desktop-ci-evidence.cjs').readEvidence(directory), []);
		const duplicate = path.join(directory, 'other-artifact');
		fs.mkdirSync(duplicate);
		fs.copyFileSync(output, path.join(duplicate, 'cold-bootstrap-evidence.json'));
		assert.throws(() =>
			verifyColdBootstrapRecords(readColdBootstrapEvidence(directory), 'a'.repeat(40))
		);
	} finally {
		if (previousSha === undefined) delete process.env.GITHUB_SHA;
		else process.env.GITHUB_SHA = previousSha;
		fs.rmSync(directory, { recursive: true, force: true });
	}
}

// Surface actual SDK compiler/test refusal before fetching and building Go.
{
	const body = pipeline.job('managed-ollama-native');
	const compile = pipeline.step(body, 'Build the actual launcher native transport roles');
	const listener = pipeline.step(
		body,
		'Qualify actual SDK accepted-owner and deadline XCTest controls'
	);
	const producer = pipeline.step(body, 'Build and admit the actual native source asset');
	assert.ok(body.indexOf(compile) < body.indexOf(listener));
	assert.ok(body.indexOf(listener) < body.indexOf(producer));
	assert.match(listener, /tests\? skipped/);
	for (const name of [
		'Retain independent native launcher compiler diagnostics',
		'Retain independent native SDK XCTest diagnostics'
	]) {
		const upload = pipeline.step(body, name);
		assert.equal(pipeline.stepField(upload, 'if'), 'always()');
		assert.ok(body.indexOf(upload) < body.indexOf(producer));
	}
}
