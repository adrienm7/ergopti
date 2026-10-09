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

/** Mac launch/verdict jobs remain dependency-free; only Windows loads TOML. */
function verifyUpgrade(...args) {
	return require('./compiled-upgrade-contract.cjs').verifyUpgrade(...args);
}

/** Reads the version from the same canonical registry the compiled owner ships. */
function currentSchemaVersion() {
	const { parse: parseToml } = require('smol-toml');
	return parseToml(
		fs.readFileSync(
			path.join(__dirname, '../../static/ergopti_plus/_shared/core/config_schema/migrations.toml'),
			'utf8'
		)
	).registry.current_version;
}

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
function verify({
	platform,
	needs,
	evidence,
	sha,
	scenarios,
	release,
	qualificationContext = null,
	qualificationNow = new Date()
}) {
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
			verifyUpgrade(
				record.compiled_upgrade,
				sha,
				record.package_sha256,
				verifyWindowsStartup,
				currentSchemaVersion()
			);
			assert.equal(
				new Set([
					record.native_startup.nonce,
					...record.compiled_upgrade.launches.map((launch) => launch.native_startup.nonce)
				]).size,
				3,
				'Upgrade borrowed the fresh-startup nonce'
			);
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

/** Adds only admitted actual prior-package upgrade and installed warm observations. */
function recordWindowsUpgrade(resultFile, archive, output) {
	const summary = JSON.parse(fs.readFileSync(resultFile, 'utf8'));
	const existing = JSON.parse(fs.readFileSync(output, 'utf8'));
	const sha = process.env.GITHUB_SHA;
	assert.match(sha, /^[a-f0-9]{40}$/, 'Invalid commit');
	const digest = crypto.createHash('sha256').update(fs.readFileSync(archive)).digest('hex');
	assert.equal(existing.sha, sha, 'Fresh startup evidence belongs to another commit');
	assert.equal(existing.package_sha256, digest, 'Upgrade uses a different packaged executable');
	assert.deepEqual(existing.failures, []);
	verifyWindowsStartup(existing.native_startup, sha, digest);
	assert.equal(
		path.win32.normalize(path.resolve(archive)).toLowerCase(),
		path.win32.normalize(existing.native_startup.executable).toLowerCase(),
		'The upgrade package was not the admitted executable'
	);
	verifyUpgrade(summary, sha, digest, verifyWindowsStartup, currentSchemaVersion());
	const nonces = new Set([
		existing.native_startup.nonce,
		...summary.launches.map((launch) => launch.native_startup.nonce)
	]);
	assert.equal(nonces.size, 3, 'Upgrade borrowed the fresh-startup nonce');
	assert.equal(existing.compiled_upgrade, undefined, 'Compiled upgrade evidence is already owned');
	// Retain the distinct native old-output and externally edited installed-input
	// observations. A prior boot receipt alone never attributes comment preservation
	// or the explicit offline user edit to the historical executable.
	assert.ok(
		summary.prior_install.native_profile_before_edit,
		'Missing native installed profile observation'
	);
	assert.ok(
		summary.prior_install.installed_user_edit,
		'Missing installed-user boundary observation'
	);
	fs.writeFileSync(output, JSON.stringify({ ...existing, compiled_upgrade: summary }) + '\n');
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
	if (command === 'record-windows-upgrade') {
		assert.equal(args.length, 3);
		recordWindowsUpgrade(...args);
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
	recordWindowsUpgrade
};
