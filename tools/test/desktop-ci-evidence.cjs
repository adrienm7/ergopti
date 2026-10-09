// tools/test/desktop-ci-evidence.cjs

/**
 * ==============================================================================
 * MODULE: Desktop CI Launch Evidence
 * DESCRIPTION:
 * Checks the Windows and macOS lane results and every expected packaged launch.
 * Missing matrix rows, foreign commits and duplicate records cannot pass merely
 * because the remaining GitHub jobs are green.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const qualification = require('../ci/dev-release-qualification.cjs');
const timerContract = require('../diagnostics/hs_delayed_timer_contract.json');
const karabinerContract = require('../diagnostics/hs_karabiner_config_contract.json');

/** Requires the complete measured native admission receipt on every clean Mac. */
function verifyNativeTimer(summary) {
	assert.ok(summary && typeof summary === 'object', 'Missing native delayed-timer evidence');
	assert.deepEqual(
		Object.keys(summary).sort(),
		[
			'schema_version',
			'contract',
			'runtime',
			'version',
			'complete',
			'checks',
			'nonce',
			'pid',
			'executable',
			'preference_restored'
		].sort(),
		'Malformed native delayed-timer evidence'
	);
	for (const [key, expected] of Object.entries({
		schema_version: 1,
		contract: timerContract.contract,
		runtime: 'native Hammerspoon',
		version: timerContract.runtime_version,
		complete: true,
		checks:
			Object.keys(timerContract.boolean_observations).length +
			Object.keys(timerContract.remaining_limits).length +
			Object.keys(timerContract.deliveries).length,
		preference_restored: true,
		executable:
			'/Applications/ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app/Contents/MacOS/Hammerspoon'
	}))
		assert.equal(summary[key], expected, `Incomplete native delayed-timer evidence: ${key}`);
	assert.match(summary.nonce, /^[0-9a-f]{32}$/, 'Invalid native timer nonce');
	assert.ok(Number.isSafeInteger(summary.pid) && summary.pid > 0, 'Invalid native timer PID');
}

/** Requires measured private native Karabiner graphs and acknowledged restoration. */
function verifyNativeKarabiner(summary) {
	assert.ok(summary && typeof summary === 'object', 'Missing native Karabiner evidence');
	assert.deepEqual(
		Object.keys(summary).sort(),
		[
			...Object.keys(karabinerContract.summary_fixed),
			'version',
			'nonce',
			'pid',
			'executable',
			'variant_count',
			'manipulator_count',
			'preference_restored'
		].sort(),
		'Malformed native Karabiner evidence'
	);
	const variants = karabinerContract.presets.length * karabinerContract.switches.length ** 2;
	for (const [key, value] of Object.entries({
		...karabinerContract.summary_fixed,
		version: timerContract.runtime_version,
		variant_count: variants,
		preference_restored: true
	}))
		assert.equal(summary[key], value, `Incomplete native Karabiner evidence: ${key}`);
	assert.match(summary.nonce, /^[0-9a-f]{32}$/, 'Invalid native Karabiner nonce');
	assert.ok(Number.isSafeInteger(summary.pid) && summary.pid > 0, 'Invalid native Karabiner PID');
	assert.ok(
		Number.isSafeInteger(summary.manipulator_count) &&
			summary.manipulator_count >= variants * karabinerContract.minimum_manipulators,
		'Missing native Karabiner condition measurements'
	);
	assert.equal(
		summary.executable,
		'/Applications/ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app/Contents/MacOS/Hammerspoon'
	);
}

/** Admits only readiness bound to the launched process, build and package bytes. */
function verifyWindowsStartup(summary, sha, packageDigest) {
	assert.ok(summary && typeof summary === 'object', 'Missing native Windows readiness evidence');
	assert.deepEqual(
		Object.keys(summary).sort(),
		[
			'nonce',
			'pid',
			'executable',
			'launched_sha256',
			'exit_code',
			'log_files',
			'logged_errors',
			'receipt'
		].sort(),
		'Malformed native Windows startup observation'
	);
	assert.match(summary.nonce, /^[0-9a-f]{32}$/, 'Invalid startup nonce');
	assert.ok(Number.isSafeInteger(summary.pid) && summary.pid > 0, 'Invalid native startup PID');
	assert.ok(
		typeof summary.executable === 'string' && path.win32.isAbsolute(summary.executable),
		'The exact launched executable path is required'
	);
	assert.equal(path.win32.basename(summary.executable).toLowerCase(), 'ergoptiplus.exe');
	assert.match(summary.launched_sha256, /^[a-f0-9]{64}$/, 'Missing launched package digest');
	assert.equal(
		summary.launched_sha256,
		packageDigest,
		'Package bytes differ from the launched executable'
	);
	assert.equal(summary.exit_code, 0, 'The compiled readiness probe did not exit successfully');
	assert.ok(
		Number.isSafeInteger(summary.log_files) && summary.log_files > 0,
		'Startup logs are missing'
	);
	assert.deepEqual(summary.logged_errors, [], 'Startup logged an error');
	const receipt = summary.receipt;
	assert.ok(
		receipt && typeof receipt === 'object',
		'The compiled process published no readiness receipt'
	);
	assert.deepEqual(
		Object.keys(receipt).sort(),
		[
			'schema_version',
			'nonce',
			'pid',
			'executable',
			'compiled',
			'build_commit',
			'bundle_identity',
			'phase',
			'driver_ready',
			'menu_ready',
			'logs_flushed'
		].sort(),
		'Malformed compiled readiness receipt'
	);
	for (const [field, expected] of Object.entries({
		schema_version: 1,
		nonce: summary.nonce,
		pid: summary.pid,
		compiled: true,
		build_commit: sha,
		phase: 'ready',
		driver_ready: true,
		menu_ready: true,
		logs_flushed: true
	}))
		assert.equal(receipt[field], expected, `Incomplete or foreign compiled readiness: ${field}`);
	assert.equal(typeof receipt.executable, 'string');
	assert.equal(
		path.win32.normalize(receipt.executable).toLowerCase(),
		path.win32.normalize(summary.executable).toLowerCase(),
		'Readiness came from another executable'
	);
	assert.match(
		receipt.bundle_identity,
		new RegExp(`^(?!__BUNDLE_VERSION__)[^\\r\\n]+\\n${sha}$`),
		"Readiness does not identify this build's runtime bundle"
	);
}

// Require actual native closure and an independently qualified isolated runtime.
const COLD_SOURCE_PATHS = [
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
];

/** Requires a source-qualified, physically closed cold installation on real arm64 macOS. */
function verifyColdBootstrap(report, sha) {
	assert.ok(report && typeof report === 'object', 'Missing native cold bootstrap receipt');
	for (const [key, expected] of Object.entries({
		version: 1,
		status: 'passed',
		sha,
		build_commit: sha,
		platform: 'darwin',
		architecture: 'arm64',
		runtime_environment: 'controlled isolated cold environment',
		signature_verified: true,
		uv: 'uv 0.12.21',
		python: '3.11.16',
		imports: 'passed',
		helpers_retired: true,
		cleanup: true,
		managed_runtime_isolated_exec: true
	}))
		assert.equal(report[key], expected, `Native cold bootstrap differs: ${key}`);
	assert.match(sha, /^[a-f0-9]{40}$/);
	assert.match(report.launcher_sha256, /^[a-f0-9]{64}$/);
	assert.match(report.hammerspoon_sha256, /^[a-f0-9]{64}$/);
	assert.deepEqual(report.official_hammerspoon, {
		version: '1.1.1',
		sha256: '11bb1c90faf5427f37c7bd4fe7eab9774ae43e1d5cb020c5b3088dac32849efa',
		bytes: 9704557
	});
	const root = path.resolve(__dirname, '../..');
	const fingerprint = (relative) =>
		crypto
			.createHash('sha256')
			.update(fs.readFileSync(path.join(root, relative)))
			.digest('hex');
	assert.deepEqual(
		Object.keys(report.sources).sort(),
		[...COLD_SOURCE_PATHS].sort(),
		'Cold bundled source census differs'
	);
	for (const relative of COLD_SOURCE_PATHS)
		assert.equal(
			report.sources[relative],
			fingerprint('static/ergopti_plus/' + relative),
			'Stale cold bundled source: ' + relative
		);
	assert.deepEqual(
		Object.keys(report.diagnostics).sort(),
		['tools/diagnostics/macos_cold_bootstrap.lua', 'tools/diagnostics/macos_cold_bootstrap.py'],
		'Cold diagnostic source census differs'
	);
	for (const [relative, digest] of Object.entries(report.diagnostics))
		assert.equal(digest, fingerprint(relative), 'Stale cold diagnostic source');
	assert.equal(
		report.fingerprint,
		report.sources['macos/pyproject.toml'] + ':' + report.sources['macos/uv.lock']
	);
	const isolation = report.isolation;
	assert.deepEqual(Object.keys(isolation).sort(), [
		'host_files_preserved',
		'observations',
		'paths',
		'profile_sha256'
	]);
	assert.equal(isolation.host_files_preserved, true, 'Host runtimes were not preserved');
	assert.ok(Array.isArray(isolation.paths) && isolation.paths.length >= 7);
	assert.deepEqual(
		isolation.paths,
		[...new Set(isolation.paths)].sort(),
		'Runtime denial paths differ or duplicate'
	);
	for (const literal of [
		'/usr/bin/python3',
		'/opt/homebrew/bin/python3',
		'/usr/local/bin/python3',
		'/Library/Frameworks/Python.framework/Versions/Current/bin/python3',
		'/opt/homebrew/bin/uv',
		'/usr/local/bin/uv',
		'/usr/bin/uv'
	])
		assert.ok(isolation.paths.includes(literal), 'Missing fixed native runtime denial');
	for (const literal of isolation.paths) {
		assert.equal(typeof literal, 'string');
		assert.ok(literal.startsWith('/') && !/[\r\n\0]/.test(literal), 'Invalid denial path');
	}
	const profile =
		'(version 1)\n(allow default)\n(deny file-read* process-exec\n' +
		isolation.paths.map((literal) => '  (literal ' + JSON.stringify(literal) + ')\n').join('') +
		')\n';
	assert.equal(
		isolation.profile_sha256,
		crypto.createHash('sha256').update(profile).digest('hex'),
		'Native sandbox profile differs'
	);
	assert.ok(
		Array.isArray(isolation.observations) && isolation.observations.length > 0,
		'No genuine runtime denial probes'
	);
	const observed = new Set();
	for (const item of isolation.observations) {
		assert.deepEqual(Object.keys(item).sort(), [
			'bytes',
			'device',
			'exec_denied',
			'inode',
			'native',
			'path',
			'read_denied',
			'sha256'
		]);
		assert.ok(
			isolation.paths.includes(item.path) && !observed.has(item.path),
			'Unknown or duplicated stock runtime'
		);
		observed.add(item.path);
		assert.match(item.sha256, /^[a-f0-9]{64}$/);
		assert.ok(
			Number.isSafeInteger(item.bytes) && item.bytes > 0,
			'Missing physical stock runtime identity'
		);
		// APFS identities can exceed JavaScript's exact integer range. Admit only
		// canonical decimal strings, then bound their exact BigInt values.
		for (const field of ['device', 'inode']) {
			assert.equal(typeof item[field], 'string', 'Physical identity must be exact decimal text');
			assert.match(item[field], /^[1-9][0-9]{0,19}$/, 'Noncanonical physical identity');
			const identity = BigInt(item[field]);
			assert.equal(identity.toString(), item[field], 'Noncanonical physical identity bytes');
			assert.ok(identity <= 18446744073709551615n, 'Physical identity exceeds uint64');
		}
		assert.equal(item.read_denied, true, 'Actual stock runtime read was not denied');
		assert.equal(typeof item.native, 'boolean');
		assert.equal(item.exec_denied, item.native, 'Native stock runtime exec denial differs');
	}
	assert.ok(
		isolation.observations.some((item) => item.native && item.exec_denied),
		'No actual native stock executable denied'
	);
	const caller = report.caller;
	for (const [key, expected] of Object.entries({
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
		receipt_retired: true,
		receipt_removed: true,
		worker_status: 0
	}))
		assert.equal(caller[key], expected, `Incomplete cold native caller: ${key}`);
	assert.ok(!caller.error && !caller.ui_failure, 'Cold caller reported an error');
	assert.deepEqual(
		caller.denied_runtime_paths,
		isolation.paths,
		'Hammerspoon inherited another sandbox'
	);
	assert.equal(caller.source_sha256, report.sources['macos/modules/llm/ensure-mlx-deps.sh']);
	assert.deepEqual(caller.native_cli, ['--managed-pty-worker', '1800000']);
	assert.ok(Number.isSafeInteger(caller.worker_pid) && caller.worker_pid > 0);
	assert.equal(typeof caller.receipt_path, 'string');
	assert.ok(caller.receipt_path.startsWith('/') && !/[\r\n\0]/.test(caller.receipt_path));
	assert.match(
		caller.nonce,
		/^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$/
	);
	assert.deepEqual(
		caller.physical_receipt,
		{
			version: 1,
			nonce: caller.nonce,
			state: 'retired',
			group_retired: true,
			guardian_reaped: true,
			pty_eof: true,
			handles_closed: true,
			status_valid: true,
			exit_status: 0,
			worker_status: 0,
			source_admitted: true
		},
		'Cold native PTY physical closure is incomplete'
	);
}

/** Admits exactly one actual cold bootstrap observation for this source SHA. */
function verifyColdBootstrapRecords(records, sha) {
	assert.ok(
		Array.isArray(records) && records.length === 1,
		'Missing, duplicate or unexpected cold bootstrap evidence'
	);
	const record = records[0];
	assert.deepEqual(Object.keys(record).sort(), [
		'contract',
		'receipt',
		'runner',
		'schema_version',
		'sha'
	]);
	assert.equal(record.schema_version, 1);
	assert.equal(record.contract, 'macos-native-cold-bootstrap-v1');
	assert.equal(record.runner, 'macos-15');
	assert.equal(record.sha, sha);
	verifyColdBootstrap(record.receipt, sha);
}

/** Records only a source-admitted actual cold native receipt. */
function recordColdMac(receiptFile, output) {
	const sha = process.env.GITHUB_SHA;
	const receipt = JSON.parse(fs.readFileSync(receiptFile, 'utf8'));
	verifyColdBootstrap(receipt, sha);
	fs.writeFileSync(
		output,
		JSON.stringify({
			schema_version: 1,
			contract: 'macos-native-cold-bootstrap-v1',
			runner: 'macos-15',
			sha,
			receipt
		}) + '\n'
	);
}

/** Keeps cold evidence separate from packaged-launch and other native records. */
function readColdBootstrapEvidence(directory) {
	return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
		const file = path.join(directory, entry.name);
		if (entry.isDirectory()) return readColdBootstrapEvidence(file);
		return entry.name === 'cold-bootstrap-evidence.json'
			? [JSON.parse(fs.readFileSync(file, 'utf8'))]
			: [];
	});
}

/** Checks mandatory job results and the exact set of successful launch records. */
function verify({
	platform,
	needs,
	evidence,
	sha,
	scenarios,
	release,
	coldBootstrap,
	qualificationContext = null,
	qualificationNow = new Date()
}) {
	assert.ok(['windows', 'macos'].includes(platform), 'Unknown desktop platform');
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
	assert.deepEqual(Object.keys(needs).sort(), jobs.sort(), 'Mandatory jobs differ');
	for (const job of jobs) assert.equal(needs[job].result, 'success', `${job} did not succeed`);
	assert.match(sha, /^[a-f0-9]{40}$/, 'Invalid commit');
	if (platform === 'macos') verifyColdBootstrapRecords(coldBootstrap, sha);
	const runners = release ? ['macos-15', 'macos-15-intel'] : ['macos-15'];
	const expected =
		platform === 'windows'
			? ['windows-latest/startup']
			: runners.flatMap((runner) => scenarios.map((scenario) => `${runner}/${scenario}`));
	assert.ok(expected.length > 0, 'No expected launch scenarios');
	assert.deepEqual(
		evidence.map((record) => `${record.runner}/${record.scenario}`).sort(),
		expected.sort(),
		'Missing, duplicate or unexpected launch evidence'
	);
	const hashes = new Set();
	for (const record of evidence) {
		assert.equal(record.schema_version, 1, 'Unknown evidence schema');
		assert.equal(record.platform, platform, 'Foreign platform');
		assert.equal(record.sha, sha, 'Foreign commit');
		assert.match(record.package_sha256, /^[a-f0-9]{64}$/, 'Invalid package digest');
		hashes.add(record.package_sha256);
		assert.deepEqual(record.failures, [], 'Launch reported failures');
		if (platform === 'windows') {
			assert.equal(record.marker_seen, true, 'Bundle was not extracted');
			assert.equal(record.crashed_early, false, 'Application exited early');
			verifyWindowsStartup(record.native_startup, sha, record.package_sha256);
		} else if (record.qualification) {
			assert.ok(qualificationContext, 'Explicit launch qualification context required');
			assert.equal(record.native_qualified, false, 'Deferred native proof cannot become qualified');
			assert.ok(
				qualification.validateLaunchQualificationReceipt(
					record.qualification,
					record.scenario,
					record.runner,
					sha,
					qualificationContext,
					qualificationNow
				)
			);
			assert.equal(
				record.native_delayed_timer,
				undefined,
				'Deferred record cannot publish native timer proof'
			);
			assert.equal(
				record.native_karabiner_config,
				undefined,
				'Deferred record cannot publish native Karabiner proof'
			);
		} else if (record.scenario === 'clean') {
			verifyNativeTimer(record.native_delayed_timer);
		} else if (record.scenario === 'karabiner_config') {
			verifyNativeKarabiner(record.native_karabiner_config);
		}
	}
	assert.equal(hashes.size, 1, 'Scenarios launched different packages');
}

/** Records only an admitted process-bound launch of the downloaded Windows EXE. */
function recordWindows(resultFile, archive, output) {
	const result = JSON.parse(fs.readFileSync(resultFile, 'utf8'));
	const sha = process.env.GITHUB_SHA;
	assert.match(sha, /^[a-f0-9]{40}$/, 'Invalid commit');
	assert.equal(result.marker_seen, true, 'Bundle was not extracted');
	assert.equal(result.crashed_early, false, 'Startup failed before readiness');
	const packageDigest = crypto.createHash('sha256').update(fs.readFileSync(archive)).digest('hex');
	verifyWindowsStartup(result.native_startup, sha, packageDigest);
	assert.equal(
		path.win32.normalize(path.resolve(archive)).toLowerCase(),
		path.win32.normalize(result.native_startup.executable).toLowerCase(),
		'The recorded package was not the launched executable'
	);
	fs.writeFileSync(
		output,
		JSON.stringify({
			schema_version: 1,
			platform: 'windows',
			sha,
			runner: 'windows-latest',
			scenario: 'startup',
			package_sha256: packageDigest,
			marker_seen: true,
			crashed_early: false,
			marker_seconds: result.marker_seconds,
			failures: [],
			native_startup: result.native_startup
		}) + '\n'
	);
}

/** Reads records without merging identically named files from matrix artifacts. */
function readEvidence(directory) {
	return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
		const file = path.join(directory, entry.name);
		if (entry.isDirectory()) return readEvidence(file);
		return entry.name === 'evidence.json' ? [JSON.parse(fs.readFileSync(file, 'utf8'))] : [];
	});
}

/** Writes the macOS observation with its commit, runner and downloaded archive. */
function recordMac(
	resultFile,
	archive,
	output,
	{ qualificationContext = null, qualificationNow = new Date() } = {}
) {
	const result = JSON.parse(fs.readFileSync(resultFile, 'utf8'));
	assert.deepEqual(result.failures, [], 'Launch reported failures');
	assert.equal(typeof result.scenario, 'string', 'Missing scenario');
	if (result.qualification) {
		assert.ok(qualificationContext, 'Explicit launch qualification context required');
		assert.equal(result.native_qualified, false, 'Deferred native proof cannot become qualified');
		assert.ok(
			qualification.validateLaunchQualificationReceipt(
				result.qualification,
				result.scenario,
				process.env.MATRIX_RUNNER,
				process.env.GITHUB_SHA,
				qualificationContext,
				qualificationNow
			)
		);
		assert.equal(
			result.native_delayed_timer,
			undefined,
			'Deferred result cannot publish native timer proof'
		);
		assert.equal(
			result.native_karabiner_config,
			undefined,
			'Deferred result cannot publish native Karabiner proof'
		);
	} else {
		if (result.scenario === 'clean') verifyNativeTimer(result.native_delayed_timer);
		if (result.scenario === 'karabiner_config')
			verifyNativeKarabiner(result.native_karabiner_config);
	}
	fs.writeFileSync(
		output,
		JSON.stringify({
			schema_version: 1,
			platform: 'macos',
			sha: process.env.GITHUB_SHA,
			runner: process.env.MATRIX_RUNNER,
			scenario: result.scenario,
			package_sha256: crypto.createHash('sha256').update(fs.readFileSync(archive)).digest('hex'),
			failures: result.failures,
			...(result.qualification
				? { qualification: result.qualification, native_qualified: false }
				: {}),
			...(!result.qualification && result.scenario === 'clean'
				? { native_delayed_timer: result.native_delayed_timer }
				: {}),
			...(!result.qualification && result.scenario === 'karabiner_config'
				? { native_karabiner_config: result.native_karabiner_config }
				: {})
		}) + '\n'
	);
}

if (require.main === module) {
	const [command, ...args] = process.argv.slice(2);
	if (command === 'record-cold-macos') {
		assert.equal(args.length, 2);
		recordColdMac(...args);
	} else if (command === 'record-macos' || command === 'record-windows') {
		assert.equal(args.length, 3);
		if (command === 'record-macos')
			recordMac(...args, { qualificationContext: qualification.environmentContext() });
		else recordWindows(...args);
	} else {
		assert.equal(command, 'verify');
		const [platform, directory] = args;
		assert.equal(args.length, 2);
		assert.ok(['true', 'false'].includes(process.env.RELEASE), 'Invalid release profile');
		const release = process.env.RELEASE === 'true';
		const scenarios =
			platform === 'macos'
				? JSON.parse(
						execFileSync(
							'python3',
							[
								'tools/diagnostics/macos_launch_gate.py',
								'--print-matrix',
								release ? 'release' : 'ci'
							],
							{ encoding: 'utf8' }
						)
							.trim()
							.replace(/^scenarios=/, '')
					)
				: [];
		verify({
			platform,
			needs: JSON.parse(process.env.NEEDS),
			evidence: readEvidence(directory),
			coldBootstrap: platform === 'macos' ? readColdBootstrapEvidence(directory) : [],
			sha: process.env.GITHUB_SHA,
			scenarios,
			release,
			qualificationContext: qualification.environmentContext()
		});
		const deferred = readEvidence(directory).filter((record) => record.qualification).length;
		console.log(
			deferred
				? `${platform}: all mandatory lifecycle checks completed; ${deferred} native/feature qualifications DEFERRED, qualified=false.`
				: `${platform}: all mandatory jobs and packaged launch scenarios passed.`
		);
	}
}

module.exports = {
	verify,
	verifyWindowsStartup,
	readEvidence,
	recordMac,
	recordWindows,
	verifyColdBootstrap,
	verifyColdBootstrapRecords,
	recordColdMac,
	readColdBootstrapEvidence
};
