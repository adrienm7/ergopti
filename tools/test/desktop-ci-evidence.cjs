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

/** Checks mandatory job results and the exact set of successful launch records. */
function verify({ platform, needs, evidence, sha, scenarios, release }) {
	assert.ok(['windows', 'macos'].includes(platform), 'Unknown desktop platform');
	const jobs =
		platform === 'windows'
			? ['test-ahk', 'e2e-ahk', 'package-windows', 'launch-windows']
			: ['test-hs', 'e2e-hs', 'package-macos', 'launch', 'tooltip-canvas'];
	assert.deepEqual(Object.keys(needs).sort(), jobs.sort(), 'Mandatory jobs differ');
	for (const job of jobs) assert.equal(needs[job].result, 'success', `${job} did not succeed`);
	assert.match(sha, /^[a-f0-9]{40}$/, 'Invalid commit');
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
function recordMac(resultFile, archive, output) {
	const result = JSON.parse(fs.readFileSync(resultFile, 'utf8'));
	assert.deepEqual(result.failures, [], 'Launch reported failures');
	assert.equal(typeof result.scenario, 'string', 'Missing scenario');
	if (result.scenario === 'clean') verifyNativeTimer(result.native_delayed_timer);
	if (result.scenario === 'karabiner_config') verifyNativeKarabiner(result.native_karabiner_config);
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
			...(result.scenario === 'clean' ? { native_delayed_timer: result.native_delayed_timer } : {}),
			...(result.scenario === 'karabiner_config'
				? { native_karabiner_config: result.native_karabiner_config }
				: {})
		}) + '\n'
	);
}

if (require.main === module) {
	const [command, ...args] = process.argv.slice(2);
	if (command === 'record-macos' || command === 'record-windows') {
		assert.equal(args.length, 3);
		(command === 'record-macos' ? recordMac : recordWindows)(...args);
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
			sha: process.env.GITHUB_SHA,
			scenarios,
			release
		});
		console.log(`${platform}: all mandatory jobs and packaged launch scenarios passed.`);
	}
}

module.exports = { verify, verifyWindowsStartup, readEvidence, recordMac, recordWindows };
