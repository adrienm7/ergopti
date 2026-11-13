// tools/test/test-windows-diagnostic-progress-reader.cjs
/**
 * The Windows diagnostic worker commits its archive while the host reads its
 * progress (2026-10-28 audit, remaining finding 6).
 *
 * The host polls progress.json every 100 ms with FileRead and tolerates the
 * worker's exclusive rewrite (collection.ahk, Tick). The worker did not
 * tolerate the host: a rewrite that met an open host read failed with a sharing
 * violation, the failure escaped its finally block before the ZIP, and the host
 * saw no acknowledgement. Native CI run 40709098135 failed that way once.
 *
 * The real worker runs its cancelled path, which opens no window, under a host
 * reader opened with the share mode of AutoHotkey's FileRead. A brief read must
 * not cost the archive; a read that never ends must still fail within a bound.
 */

'use strict';

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const DRIVER_ROOT = path.join(REPO_ROOT, 'static', 'ergopti_plus');
const WORKER = path.join(DRIVER_ROOT, 'windows', 'vendor', 'ergopti_diagnostics.ps1');
const CONTRACT = path.join(DRIVER_ROOT, '_shared', 'diagnostics', 'data', 'collection.json');
const WORKER_EXIT_BOUND_MS = 60000;
const BRIEF_HOLD_MS = 300;

// The seam precedes the worker's acquisition of the stream it rewrites, so the
// reader below is open exactly when the worker asks for exclusive access.
const SEAM = '$taskPrior = $taskEvidenceReceipts[$Name]';
const INJECTION = `
if ($Name -ceq 'progress.json' -and !(Test-Path -LiteralPath (Join-Path $taskRoot 'hold-request'))) {
	[IO.File]::WriteAllText((Join-Path $taskRoot 'hold-request'), 'hold')
	$taskHoldWatch = [Diagnostics.Stopwatch]::StartNew()
	while (!(Test-Path -LiteralPath (Join-Path $taskRoot 'held')) -and $taskHoldWatch.ElapsedMilliseconds -lt 20000) { Start-Sleep -Milliseconds 5 }
	if (!(Test-Path -LiteralPath (Join-Path $taskRoot 'held'))) { throw 'The host reader never opened progress.json.' }
}`;

/**
 * Runs the real worker on a cancelled session while a host reader holds
 * progress.json from the worker's first rewrite.
 * @param {string} scratch Private directory of this case.
 * @param {number|null} holdMs Reader lifetime: 0 opens no reader, null holds until the worker exits.
 * @returns {Promise<object>} The worker outcome and its session paths.
 */
async function runWorker(scratch, holdMs) {
	const source = fs.readFileSync(WORKER, 'utf8');
	assert.equal(source.split(SEAM).length, 2, 'the worker keeps one exclusive rewrite seam');
	const worker = path.join(scratch, 'worker.ps1');
	fs.writeFileSync(worker, source.replace(SEAM, SEAM + INJECTION));
	const id = 'ergopti-diagnostic-' + crypto.randomBytes(16).toString('hex');
	const session = path.join(scratch, id);
	fs.mkdirSync(session);
	const vendor = path.join(DRIVER_ROOT, 'windows', 'vendor');
	const request = {
		schema_version: 1,
		redaction_verified: true,
		compiled: 0,
		evidence_origin: 'worker_control',
		version: 'local',
		source_sha: 'unknown',
		architecture: 'x64',
		runtime: '2.0.0',
		contract_path: CONTRACT,
		components: [
			{ id: 'driver', path: path.join(DRIVER_ROOT, 'windows', 'ErgoptiPlus.ahk') },
			{ id: 'runtime', path: process.execPath },
			{ id: 'native_owner', path: path.join(vendor, 'ergopti_nav_owner.dll') },
			{ id: 'native_manifest', path: path.join(vendor, 'ergopti_nav_owner.manifest.json') },
			{ id: 'collector', path: worker },
			{ id: 'contract', path: CONTRACT }
		]
	};
	fs.writeFileSync(path.join(session, 'request.json'), JSON.stringify(request));
	// A cancelled session skips the synthetic window: no focus or input is touched.
	fs.writeFileSync(path.join(session, 'cancel'), 'cancel');

	const powershell = path.join(
		process.env.SystemRoot,
		'System32',
		'WindowsPowerShell',
		'v1.0',
		'powershell.exe'
	);
	const child = spawn(
		powershell,
		[
			'-NoLogo',
			'-NoProfile',
			'-NonInteractive',
			'-ExecutionPolicy',
			'Bypass',
			'-File',
			worker,
			'-SessionDirectory',
			session
		],
		{ windowsHide: true }
	);
	let stdout = '';
	let stderr = '';
	child.stdout.on('data', (chunk) => (stdout += chunk));
	child.stderr.on('data', (chunk) => (stderr += chunk));
	let reader = null;
	let held = false;
	const release = () => {
		if (reader === null) return;
		fs.closeSync(reader);
		reader = null;
	};
	const poll = setInterval(() => {
		if (held || !fs.existsSync(path.join(session, 'hold-request'))) return;
		held = true;
		// Node opens with FILE_SHARE_READ | WRITE | DELETE, as FileRead does.
		if (holdMs !== 0) reader = fs.openSync(path.join(session, 'progress.json'), 'r');
		fs.writeFileSync(path.join(session, 'held'), 'held');
		if (holdMs !== null && holdMs !== 0) setTimeout(release, holdMs);
	}, 2);
	const timeout = setTimeout(() => child.kill(), WORKER_EXIT_BOUND_MS);
	const exitCode = await new Promise((resolve, reject) => {
		child.on('error', reject);
		child.on('close', resolve);
	});
	clearTimeout(timeout);
	clearInterval(poll);
	release();
	return { exitCode, stdout, stderr, held, id, session, archive: session + '.zip' };
}

/** Asserts the worker's stdout acknowledges exactly the committed archive. */
function assertAcknowledged(outcome, label) {
	assert.equal(outcome.held, true, `${label}: the host reader overlapped a rewrite`);
	assert.equal(outcome.exitCode, 0, `${label}: the worker succeeded; stderr: ${outcome.stderr}`);
	assert.ok(fs.existsSync(outcome.archive), `${label}: the archive was committed`);
	const ack = JSON.parse(outcome.stdout.trim());
	const bytes = fs.readFileSync(outcome.archive);
	assert.equal(ack.session_id, outcome.id, `${label}: the acknowledgement names its session`);
	assert.equal(ack.archive_committed, true, `${label}: the acknowledgement commits the archive`);
	assert.equal(ack.bytes, bytes.length, `${label}: the acknowledgement binds the archive size`);
	assert.equal(
		ack.sha256,
		crypto.createHash('sha256').update(bytes).digest('hex'),
		`${label}: the acknowledgement binds the archive digest`
	);
	const progress = JSON.parse(fs.readFileSync(path.join(outcome.session, 'progress.json'), 'utf8'));
	assert.equal(progress.phase, 'completed', `${label}: the terminal progress completed`);
	assert.equal(progress.archive_created, true, `${label}: the terminal progress names the archive`);
}

async function main() {
	if (process.platform !== 'win32') {
		console.log('[SKIP] The diagnostic worker and its sharing modes exist only on Windows.');
		return;
	}
	const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-diag-reader-')));
	try {
		const cases = [
			['no host read', 0],
			['brief host read', BRIEF_HOLD_MS]
		];
		for (const [label, holdMs] of cases) {
			const directory = path.join(scratch, label.replace(/ /g, '-'));
			fs.mkdirSync(directory);
			// The zero hold opens no reader: this control passes before and after the correction.
			assertAcknowledged(await runWorker(directory, holdMs), label);
			console.log(`[OK] ${label}: the archive is acknowledged.`);
		}
		const directory = path.join(scratch, 'endless-host-read');
		fs.mkdirSync(directory);
		const started = Date.now();
		const endless = await runWorker(directory, null);
		assert.equal(endless.held, true, 'endless read: the host reader overlapped a rewrite');
		assert.ok(
			Date.now() - started < WORKER_EXIT_BOUND_MS,
			'endless read: the worker gave up within its bound'
		);
		assert.notEqual(endless.exitCode, 0, 'endless read: the worker reports the refusal');
		assert.equal(
			fs.existsSync(endless.archive),
			false,
			'endless read: no archive claims the refused rewrite'
		);
		console.log('[OK] endless host read: the worker fails within its bound.');
	} finally {
		fs.rmSync(scratch, { recursive: true, force: true });
	}
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
