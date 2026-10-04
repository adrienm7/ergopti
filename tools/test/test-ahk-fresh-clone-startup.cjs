// tools/test/test-ahk-fresh-clone-startup.cjs

/**
 * ==============================================================================
 * MODULE: Fresh AutoHotkey Clone Bootstrap Regression
 * DESCRIPTION:
 * Boots an actual shallow local Git clone without generated personal includes,
 * dependency junctions or developer caches. The first process must really Reload;
 * its successor proves readiness and a clean native exit before a warm boot.
 * Current tracked working bytes are projected for pre-commit verification; a
 * clean CI checkout projects exactly the same committed bytes as its clone.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '../..');
if (process.platform !== 'win32') {
	console.log('[SKIP] Fresh AHK clone startup requires native Windows.');
	process.exit(0);
}
const ahk = process.env.ERGOPTI_AHK_EXE || 'C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe';
assert.ok(fs.existsSync(ahk), 'fresh clone startup requires an actual AutoHotkey v2 interpreter');
const interpreter = path.resolve(ahk);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-fresh-clone-'));
const clone = path.join(temporary, 'repo');
const probe = path.join(temporary, 'probe');
fs.mkdirSync(probe);

/** Runs one private fixture command and retains its complete diagnostics. */
function run(command, args, cwd = root, timeout = 30000) {
	const result = spawnSync(command, args, {
		cwd,
		encoding: 'utf8',
		windowsHide: true,
		// Cover readiness, terminal waits and owned-process cleanup before the
		// outer supervisor can terminate its observer.
		timeout,
		maxBuffer: 16 * 1024 * 1024
	});
	assert.ifError(result.error);
	if (result.status !== 0) {
		for (const name of ['stdout.txt', 'stderr.txt']) {
			const file = path.join(probe, name);
			if (fs.existsSync(file))
				console.error(name + ':\n' + fs.readFileSync(file, 'utf8').slice(-12000));
		}
		function showLogs(directory) {
			for (const item of fs.readdirSync(directory, { withFileTypes: true })) {
				const file = path.join(directory, item.name);
				if (item.isDirectory()) showLogs(file);
				else if (item.name.endsWith('.log'))
					console.error(
						path.relative(probe, file) +
							':\n' +
							fs.readFileSync(file, 'utf8').split(/\r?\n/).slice(-40).join('\n')
					);
			}
		}
		showLogs(probe);
	}
	assert.equal(result.status, 0, result.stdout + result.stderr);
	return result.stdout;
}

let primaryFailure;
try {
	require('./support/source-boot-runtime.cjs')(root, temporary);
	run('pwsh.exe', [
		'-NoProfile',
		'-NonInteractive',
		'-File',
		path.join(root, 'tools/test/fixtures/test_source_boot_ownership.ps1'),
		'-Observer',
		path.join(root, 'tools/test/fixtures/observe_ahk_source_boot.ps1'),
		'-Ahk',
		interpreter,
		'-Root',
		temporary
	]);
	run(
		'git',
		['clone', '--quiet', '--no-local', '--no-hardlinks', '--depth=1', root, clone],
		root,
		180000
	);
	assert.equal(
		run('git', ['rev-parse', 'HEAD'], clone).trim(),
		run('git', ['rev-parse', 'HEAD']).trim(),
		'the clone must start at the tested commit'
	);
	const tracked = run('git', ['ls-files', '-z', '--', 'static']).split('\0').filter(Boolean);
	assert.ok(tracked.length > 100, 'the fixture must copy the full tracked driver dependencies');
	for (const relative of tracked) {
		const source = path.join(root, relative);
		assert.ok(fs.lstatSync(source).isFile(), 'tracked fixture assets must have their own bytes');
		const destination = path.join(clone, relative);
		fs.mkdirSync(path.dirname(destination), { recursive: true });
		fs.copyFileSync(source, destination);
	}
	const windows = path.join(clone, 'static/ergopti_plus/windows');
	const entry = path.join(windows, 'ErgoptiPlus.ahk');
	const forwarder = path.join(windows, '_generated/personal_shortcuts.ahk');
	const personal = path.join(probe, 'config/autohotkey/personal_shortcuts.ahk');
	assert.equal(
		fs.existsSync(forwarder),
		false,
		'a fresh clone must not pre-seed its generated include'
	);
	assert.equal(fs.existsSync(personal), false, 'a fresh user must not pre-seed personal shortcuts');
	assert.equal(
		fs.existsSync(path.join(windows, 'build/static_bundle.zip')),
		false,
		'a source clone must not depend on a development bundle cache'
	);
	for (const reloaded of [true, false]) {
		const nonce = crypto.randomBytes(16).toString('hex');
		const args = [
			'-NoProfile',
			'-NonInteractive',
			'-File',
			path.join(root, 'tools/test/fixtures/observe_ahk_source_boot.ps1'),
			'-Entry',
			entry,
			'-Ahk',
			interpreter,
			'-Root',
			probe,
			'-Nonce',
			nonce
		];
		if (reloaded) args.push('-ExpectReload');
		run('pwsh.exe', args, root, 270000);
		const observation = JSON.parse(fs.readFileSync(path.join(probe, 'observation.json'), 'utf8'));
		assert.equal(observation.receipt.nonce, nonce);
		assert.equal(
			observation.entry,
			entry,
			'the observation keeps the caller-selected entry spelling'
		);
		assert.equal(observation.source_owner.script_argument_canonical_exact, true);
		assert.equal(observation.reloaded, reloaded);
		assert.equal(observation.ready_pid !== observation.initial_pid, reloaded);
		assert.equal(observation.initial_exit_code, 0);
		assert.equal(observation.exit_code, 0);
		assert.ok(observation.log_files > 0);
		for (const file of [forwarder, personal]) {
			const bytes = fs.readFileSync(file);
			assert.deepEqual(
				[...bytes.subarray(0, 3)],
				[239, 187, 191],
				'boot-generated AHK keeps its BOM'
			);
			assert.equal(bytes.includes(13), false, 'boot-generated AHK keeps LF');
		}
		assert.ok(fs.readFileSync(forwarder, 'utf8').includes('#Include *i ' + personal));
		fs.unlinkSync(path.join(probe, 'ready.json'));
		fs.unlinkSync(path.join(probe, 'ack.txt'));
	}
	console.log(
		'[OK] Fresh cloned source really reloads, reaches readiness and exits cleanly; warm boot keeps its process.'
	);
} catch (error) {
	primaryFailure = error;
} finally {
	// This tree is exclusively owned by this test and contains no dependency links.
	try {
		fs.rmSync(temporary, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
	} catch (cleanupFailure) {
		if (primaryFailure)
			throw new AggregateError(
				[primaryFailure, cleanupFailure],
				'Source bootstrap and fixture cleanup failed.'
			);
		throw cleanupFailure;
	}
}
if (primaryFailure) throw primaryFailure;
