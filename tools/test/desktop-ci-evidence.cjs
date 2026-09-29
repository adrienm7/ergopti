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

/** Checks mandatory job results and the exact set of successful launch records. */
function verify({ platform, needs, evidence, sha, scenarios, release }) {
	assert.ok(['windows', 'macos'].includes(platform), 'Unknown desktop platform');
	const jobs =
		platform === 'windows'
			? ['test-ahk', 'e2e-ahk', 'package-windows', 'launch-windows']
			: ['test-hs', 'e2e-hs', 'package-macos', 'launch'];
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
		}
	}
	assert.equal(hashes.size, 1, 'Scenarios launched different packages');
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
	fs.writeFileSync(
		output,
		JSON.stringify({
			schema_version: 1,
			platform: 'macos',
			sha: process.env.GITHUB_SHA,
			runner: process.env.MATRIX_RUNNER,
			scenario: result.scenario,
			package_sha256: crypto.createHash('sha256').update(fs.readFileSync(archive)).digest('hex'),
			failures: result.failures
		}) + '\n'
	);
}

if (require.main === module) {
	const [command, ...args] = process.argv.slice(2);
	if (command === 'record-macos') {
		assert.equal(args.length, 3);
		recordMac(...args);
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

module.exports = { verify, readEvidence, recordMac };
