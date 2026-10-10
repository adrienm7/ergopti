// tools/diagnostics/macos_release_stage_native_receiving.cjs
/** Receive the frozen shell corpus and actual Darwin guardian cancellation. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { spawn } = require('node:child_process');
const { pythonExecutable } = require('../lib/python.cjs');
const root = path.resolve(__dirname, '../..');
const sha = (bytes) => createHash('sha256').update(bytes).digest('hex');
// Fixed stimuli create two real inherited-PGID members. Only the original
// guardian sends cleanup signals/reaps; the helper sends the named interruption.
const WORKER = `# Authored Darwin cancellation stimulus; no replacement process owner.
import os
from pathlib import Path
import signal
import subprocess
import sys
import macos_owned_process as owner

mode, directory, value = sys.argv[1:]
directory = Path(directory)
if mode == 'worker':
    child = subprocess.Popen([sys.executable, '-B', __file__, 'helper', str(directory), value + ':' + str(os.getppid())], stdin=subprocess.DEVNULL)
    while True:
        signal.pause()
elif mode == 'helper':
    name, guardian = value.split(':')
    signum = {'TERM': signal.SIGTERM, 'INT': signal.SIGINT}[name]
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    owner.exclusive_receipt(directory / 'ready.json', {
        'version': 1, 'signal': name, 'guardian_pid': int(guardian),
        'worker_pid': os.getppid(), 'helper_pid': os.getpid(), 'group_id': os.getpgid(0),
    })
    os.kill(int(guardian), signum)
    owner.exclusive_receipt(directory / 'sent.json', {'version': 1, 'signal': name, 'guardian_pid': int(guardian), 'helper_pid': os.getpid(), 'native_kill_returned': True})
    while True:
        signal.pause()
else:
    raise RuntimeError('Unknown fixed cancellation stimulus')
`;

async function receive() {
	assert.equal(process.platform, 'darwin', 'actual Darwin guardian capability required');
	assert.equal(process.argv.length, 4);
	assert.equal(process.argv[2], '--output');
	const output = path.resolve(process.argv[3]);
	fs.mkdirSync(output, { mode: 0o700 }); // Existing/colliding evidence is refused.
	const sources = new Map();
	function capture(relative) {
		const filename = path.join(root, relative);
		const fact = fs.lstatSync(filename, { bigint: true });
		assert.ok(fact.isFile() && !fact.isSymbolicLink() && fact.size <= 1024 * 1024);
		const bytes = fs.readFileSync(filename);
		sources.set(relative, { filename, fact, bytes, sha256: sha(bytes) });
		return bytes;
	}
	const ownerRelative = 'tools/diagnostics/macos_owned_process.py';
	const corpusRelative = 'tools/diagnostics/macos_release_stage_route_test.py';
	const stageRelative = 'static/ergopti_plus/macos/adapters/release_stage.sh';
	capture(ownerRelative);
	capture(corpusRelative);
	capture(stageRelative);
	capture('tools/lib/python.cjs');
	capture('tools/diagnostics/macos_release_stage_native_receiving.cjs');
	const interpreter = pythonExecutable();
	const sourceDirectory = path.join(output, 'source');
	fs.mkdirSync(sourceDirectory, { mode: 0o700 });
	for (const relative of [ownerRelative, corpusRelative]) {
		fs.writeFileSync(
			path.join(sourceDirectory, path.basename(relative)),
			sources.get(relative).bytes,
			{ flag: 'wx', mode: 0o600 }
		);
	}
	const worker = path.join(sourceDirectory, 'cancellation_worker.py');
	fs.writeFileSync(worker, WORKER, { flag: 'wx', mode: 0o600 });
	const deadline = process.hrtime.bigint() + 120000000000n;
	let active = null;
	let cancelled = false;
	const cancel = () => {
		cancelled = true;
		if (active && active.exitCode === null && active.signalCode === null) {
			try {
				active.kill('SIGTERM');
			} catch {
				/* Cancellation remains refusal. */
			}
		}
	};
	process.on('SIGTERM', cancel);
	process.on('SIGINT', cancel);
	const observed = [];
	try {
		for (const name of ['corpus', 'TERM', 'INT']) {
			assert.equal(cancelled, false);
			const remaining = Number(deadline - process.hrtime.bigint()) / 1e9;
			assert.ok(remaining > 0 && remaining <= 120, 'same original receiving deadline');
			const directory = path.join(output, name);
			fs.mkdirSync(directory, { mode: 0o700 });
			const sentinel = path.join(directory, 'inputs-retained');
			fs.writeFileSync(sentinel, 'original-owned-input\n', { flag: 'wx', mode: 0o600 });
			if (name === 'corpus') fs.mkdirSync(path.join(directory, 'cases'), { mode: 0o700 });
			const receiptPath = path.join(directory, 'closed.json');
			const corpusPath = path.join(directory, 'corpus.json');
			const command =
				name === 'corpus'
					? [
							interpreter,
							'-B',
							path.join(sourceDirectory, path.basename(corpusRelative)),
							path.join(root, stageRelative),
							corpusPath
						]
					: [interpreter, '-B', worker, 'worker', directory, name];
			const descriptors = [];
			let native;
			try {
				for (const stream of ['stdout', 'stderr'])
					descriptors.push({
						fd: fs.openSync(path.join(directory, stream), 'wx', 0o600),
						state: 'open'
					});
				native = await new Promise((resolve) => {
					let refused = false;
					active = spawn(
						interpreter,
						[
							'-B',
							path.join(sourceDirectory, path.basename(ownerRelative)),
							'run',
							receiptPath,
							String(remaining),
							'--',
							...command
						],
						{
							cwd: root,
							env: process.env,
							stdio: ['ignore', descriptors[0].fd, descriptors[1].fd]
						}
					);
					active.once('spawn', () => {
						if (cancelled) cancel();
					});
					active.once('error', () => {
						refused = true;
					});
					active.once('close', (status, signal) =>
						resolve({ pid: active.pid, status, signal, refused })
					);
				});
			} finally {
				for (const descriptor of descriptors) {
					descriptor.state = 'closing';
					try {
						fs.closeSync(descriptor.fd);
						descriptor.state = 'closed';
					} catch {
						descriptor.state = 'uncertain-close';
					}
				}
				assert.ok(
					descriptors.every((entry) => entry.state === 'closed'),
					'actual capture descriptor closure'
				);
			}
			assert.ok(
				process.hrtime.bigint() < deadline,
				'original deadline after native close and capture closure'
			);
			assert.equal(native.refused, false);
			assert.equal(native.signal, null);
			assert.equal(native.status, name === 'corpus' ? 0 : 124);
			assert.equal(cancelled, false);
			const fact = fs.lstatSync(receiptPath);
			assert.ok(fact.isFile() && !fact.isSymbolicLink() && fact.nlink === 1 && fact.size <= 1024);
			assert.equal(fact.mode & 0o777, 0o600);
			assert.equal(fact.uid, process.getuid());
			const closed = JSON.parse(fs.readFileSync(receiptPath, 'utf8'));
			assert.deepEqual(Object.keys(closed).sort(), [
				'closed',
				'exit_status',
				'group_id',
				'guardian_pid',
				'schema',
				'worker_pid'
			]);
			assert.equal(closed.schema, 1);
			assert.equal(closed.guardian_pid, native.pid);
			assert.ok(Number.isSafeInteger(closed.worker_pid) && closed.worker_pid > 0);
			assert.equal(closed.group_id, closed.worker_pid);
			assert.equal(closed.closed, true);
			assert.equal(closed.exit_status, native.status);
			assert.ok(
				process.hrtime.bigint() < deadline,
				'original deadline after native closed receipt admission'
			);
			assert.equal(fs.readFileSync(sentinel, 'utf8'), 'original-owned-input\n');
			if (name === 'corpus') {
				const corpusFact = fs.lstatSync(corpusPath);
				assert.ok(
					corpusFact.isFile() &&
						!corpusFact.isSymbolicLink() &&
						corpusFact.nlink === 1 &&
						corpusFact.size <= 1024 * 1024
				);
				const result = JSON.parse(fs.readFileSync(corpusPath, 'utf8'));
				assert.deepEqual(Object.keys(result).sort(), [
					'failures',
					'kind',
					'no_genuine_native_qualification',
					'observations',
					'script',
					'script_sha256',
					'version'
				]);
				assert.equal(result.version, 1);
				assert.equal(result.kind, 'portable-authored-shell-only');
				assert.equal(result.no_genuine_native_qualification, true);
				assert.equal(result.script, fs.realpathSync(path.join(root, stageRelative)));
				assert.equal(result.script_sha256, sources.get(stageRelative).sha256);
				assert.deepEqual(result.failures, []);
				assert.equal(result.observations.length, 50);
				assert.equal(new Set(result.observations.map((entry) => entry.name)).size, 50);
				for (const row of result.observations) {
					assert.deepEqual(Object.keys(row).sort(), [
						'actual_calls',
						'actual_rows',
						'actual_status',
						'errors',
						'expected_calls',
						'expected_status',
						'name',
						'stderr_hex',
						'stdout_hex'
					]);
					assert.equal(typeof row.name, 'string');
					assert.ok(row.name.length > 0);
					assert.ok([0, 10, 21, 22, 25, 26, 27].includes(row.expected_status));
					assert.equal(row.actual_status, row.expected_status);
					assert.deepEqual(row.actual_calls, row.expected_calls);
					assert.deepEqual(row.errors, []);
				}
			} else {
				for (const packet of ['ready.json', 'sent.json']) {
					const packetFact = fs.lstatSync(path.join(directory, packet));
					assert.ok(
						packetFact.isFile() &&
							!packetFact.isSymbolicLink() &&
							packetFact.nlink === 1 &&
							packetFact.size <= 1024
					);
					assert.equal(packetFact.mode & 0o777, 0o600);
					assert.equal(packetFact.uid, process.getuid());
				}
				const ready = JSON.parse(fs.readFileSync(path.join(directory, 'ready.json'), 'utf8'));
				const sent = JSON.parse(fs.readFileSync(path.join(directory, 'sent.json'), 'utf8'));
				assert.deepEqual(Object.keys(sent).sort(), [
					'guardian_pid',
					'helper_pid',
					'native_kill_returned',
					'signal',
					'version'
				]);
				assert.deepEqual(sent, {
					version: 1,
					signal: name,
					guardian_pid: native.pid,
					helper_pid: ready.helper_pid,
					native_kill_returned: true
				});
				assert.deepEqual(Object.keys(ready).sort(), [
					'group_id',
					'guardian_pid',
					'helper_pid',
					'signal',
					'version',
					'worker_pid'
				]);
				assert.equal(ready.version, 1);
				assert.equal(ready.signal, name);
				assert.equal(ready.guardian_pid, native.pid);
				assert.equal(ready.worker_pid, closed.worker_pid);
				assert.equal(ready.group_id, closed.group_id);
				assert.ok(
					Number.isSafeInteger(ready.helper_pid) &&
						ready.helper_pid > 0 &&
						ready.helper_pid !== ready.worker_pid
				);
			}
			observed.push({
				name,
				native,
				closed,
				capture_descriptors_closed: descriptors.every((entry) => entry.state === 'closed'),
				inputs_retained: true
			});
			active = null;
		}
		for (const held of sources.values()) {
			const fact = fs.lstatSync(held.filename, { bigint: true });
			assert.ok(fact.isFile() && !fact.isSymbolicLink());
			assert.equal(fact.dev, held.fact.dev);
			assert.equal(fact.ino, held.fact.ino);
			assert.equal(sha(fs.readFileSync(held.filename)), held.sha256);
		}
		assert.equal(sha(fs.readFileSync(worker)), sha(Buffer.from(WORKER)));
		for (const relative of [ownerRelative, corpusRelative])
			assert.equal(
				sha(fs.readFileSync(path.join(sourceDirectory, path.basename(relative)))),
				sources.get(relative).sha256
			);
		assert.ok(process.hrtime.bigint() < deadline, 'original deadline before success publication');
		fs.writeFileSync(
			path.join(output, 'receipt.json'),
			JSON.stringify({
				version: 1,
				platform: process.platform,
				corpus_cases: 50,
				skipped_cases: 0,
				cancellation_signals: ['TERM', 'INT'],
				observations: observed,
				source_sha256: Object.fromEntries([...sources].map(([key, value]) => [key, value.sha256])),
				native_owner_retirement_only: true,
				genuine_routing_or_package_acceptance: false,
				escaped_sessions_managed: false,
				inputs_retained: true
			}) + '\n',
			{ flag: 'wx', mode: 0o600 }
		);
		assert.ok(process.hrtime.bigint() < deadline, 'original deadline before final PASS');
		console.log(
			'PASS - Darwin-owned frozen50 corpus and actual TERM/INT guardian retirement; no routing/package acceptance credit'
		);
	} finally {
		process.removeListener('SIGTERM', cancel);
		process.removeListener('SIGINT', cancel);
		// Success and refusal both retain all inputs/captures for artifact handover.
	}
}
receive().catch(() => {
	console.error(
		'FAIL - Darwin selected-release receiving or native retirement refused; inputs retained'
	);
	process.exitCode = 1;
});
