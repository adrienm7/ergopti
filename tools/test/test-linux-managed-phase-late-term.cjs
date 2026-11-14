// tools/test/test-linux-managed-phase-late-term.cjs

/**
 * ==============================================================================
 * MODULE: Managed Phase Late TERM Test
 * DESCRIPTION:
 * The managed phase worker (tools/test/run-linux-managed-http-phase.py) publishes
 * its closure receipt (closed.json) and then exits with the same status. Its
 * Node owner (run-linux-managed-http-native.cjs) may still send one TERM after
 * the command ended: the capture watcher notices an oversized output on its next
 * 25 ms tick. Python resets its signal handlers to SIG_DFL while the interpreter
 * finalizes, so a TERM landing there killed the worker by signal and the owner
 * read status null beside a receipt that said 0 (test-linux-nix-native.cjs,
 * « assert 0 !== null », about one run in three). This test runs the real worker
 * on a command that succeeds, floods it with TERM from the moment its receipt
 * appears until it exits, and requires every exit to be the receipt's status.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const WORKER = path.join(ROOT, 'tools/test/run-linux-managed-http-phase.py');
const OWNER = path.join(ROOT, 'tools/build/stage-linux-network-runtime.py');
// Each attempt has a fair chance to land a TERM in the finalization window;
// before the fix nearly every run of this many attempts failed.
const ATTEMPTS = 12;

/** Resolves once a predicate holds, polling every millisecond, or rejects after a bound. */
function until(predicate, boundMs) {
	const started = Date.now();
	return new Promise((resolve, reject) => {
		(function poll() {
			if (predicate()) return resolve();
			if (Date.now() - started > boundMs) return reject(new Error('timed out'));
			setImmediate(poll);
		})();
	});
}

/** Runs the worker once and floods it with TERM after its closure receipt. */
async function attempt(directory, index, ownerSha) {
	const receipt = path.join(directory, 'receipt-' + index);
	fs.mkdirSync(receipt, { mode: 0o700 });
	const child = spawn(
		'python3',
		[
			'-B',
			WORKER,
			'--owner',
			OWNER,
			'--owner-sha256',
			ownerSha,
			'--kind',
			'command',
			'--receipt',
			receipt,
			'--budget',
			'20',
			'--',
			'/bin/true'
		],
		{ cwd: directory, env: { PATH: '/usr/bin:/bin', HOME: directory }, stdio: 'ignore' }
	);
	const exited = new Promise((resolve) =>
		child.once('exit', (code, signal) => resolve({ code, signal }))
	);
	let done = false;
	exited.then(() => (done = true));
	const closedFile = path.join(receipt, 'closed.json');
	await until(() => done || fs.existsSync(closedFile), 20000);
	// The owner's late cancel, sent as often as it can until the worker is gone.
	while (!done) {
		try {
			process.kill(child.pid, 'SIGTERM');
		} catch {
			break;
		}
		await new Promise((resolve) => setImmediate(resolve));
	}
	const { code, signal } = await exited;
	assert.ok(fs.existsSync(closedFile), `attempt ${index}: the worker published its closure`);
	const closed = JSON.parse(fs.readFileSync(closedFile, 'utf8'));
	assert.equal(
		signal,
		null,
		`attempt ${index}: a TERM after the closure receipt killed the worker`
	);
	assert.equal(code, closed.status, `attempt ${index}: the exit status is the receipt's`);
}

async function main() {
	if (process.platform !== 'linux') {
		process.stdout.write(
			'SKIP managed phase late TERM: the worker owns Linux subreaper state only.\n'
		);
		return;
	}
	const ownerSha = crypto.createHash('sha256').update(fs.readFileSync(OWNER)).digest('hex');
	const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-phase-term-'));
	try {
		fs.chmodSync(directory, 0o700);
		for (let index = 1; index <= ATTEMPTS; index++) await attempt(directory, index, ownerSha);
	} finally {
		fs.rmSync(directory, { recursive: true, force: true });
	}
	process.stdout.write(
		`PASS managed phase late TERM: ${ATTEMPTS} closures kept their published status under a TERM flood.\n`
	);
}

main().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
