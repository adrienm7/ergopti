// Source-only parent protocol models. No native child or cleanup proof.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const { phaseReceipt, ownPhase } = require(process.argv[2]);
let passed = 0;
const golden = {
	schema: 1,
	phase: 'command',
	pid: 12345,
	state: 'closed',
	status: 0,
	cancelled: false
};
assert.equal(phaseReceipt(golden, 12345, 'command', 0), true);
passed++;
for (const invalid of [
	{ ...golden, extra: true },
	{ ...golden, schema: 2 },
	{ ...golden, pid: 12346 },
	{ ...golden, pid: '12345' },
	{ ...golden, phase: 'public30' },
	{ ...golden, state: 'retained' },
	{ ...golden, status: 1 },
	{ ...golden, status: 0.5 },
	{ ...golden, cancelled: 'false' },
	{ ...golden, cancelled: undefined },
	{ ...golden, cancelled: true }
]) {
	assert.equal(phaseReceipt(invalid, 12345, 'command', 0), false);
	passed++;
}

// Only the modeled child receipt receives POSIX facts on Windows. Actual file
// kind, size, links and descriptor lifetime stay native; this is not ACL proof.
function modelReceiptFacts(work) {
	if (process.platform !== 'win32') return () => {};
	const originalStat = fs.lstatSync;
	const originalUid = Object.getOwnPropertyDescriptor(process, 'getuid');
	const receipt = path.resolve(work, '01.owner/closed.json');
	const uid = originalStat(work, { bigint: true }).uid;
	Object.defineProperty(process, 'getuid', {
		value: () => Number(uid),
		configurable: true,
		writable: true
	});
	fs.lstatSync = function (filename, options) {
		const fact = originalStat.call(fs, filename, options);
		if (
			typeof filename !== 'string' ||
			path.resolve(filename) !== receipt ||
			options?.bigint !== true
		)
			return fact;
		const modeled = Object.create(fact);
		Object.defineProperties(modeled, {
			uid: { value: uid },
			mode: { value: (fact.mode & ~511n) | 384n }
		});
		return modeled;
	};
	return () => {
		fs.lstatSync = originalStat;
		if (originalUid) Object.defineProperty(process, 'getuid', originalUid);
		else delete process.getuid;
	};
}

async function model(name, action) {
	const work = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-phase-protocol-model-'));
	fs.chmodSync(work, 0o700);
	const restoreFacts = modelReceiptFacts(work);
	try {
		let native,
			options,
			now = 0n,
			kills = 0;
		const spawnChild = (command, args, config) => {
			assert.equal(command, 'python3');
			options = config;
			native = new EventEmitter();
			native.pid = 12345;
			native.exitCode = null;
			native.signalCode = null;
			native.kill = (signal) => {
				assert.equal(signal, 'SIGTERM');
				kills++;
				return true;
			};
			setImmediate(() => native.emit('spawn'));
			return native;
		};
		const started = ownPhase({
			command: '/MODELED/cc',
			args: [],
			env: {},
			cwd: work,
			work,
			label: '01',
			worker: '/MODELED/worker.py',
			owner: '/MODELED/owner.py',
			ownerSha: '0'.repeat(64),
			kind: 'command',
			budgetMs: 30,
			gateDeadline: 1000000000n,
			clock: () => now,
			graceMs: 5,
			spawnChild
		});
		await new Promise(setImmediate);
		function finish(status, receipt = { ...golden, status }) {
			if (receipt)
				fs.writeFileSync(path.join(work, '01.owner/closed.json'), JSON.stringify(receipt), {
					flag: 'wx',
					mode: 0o600
				});
			native.exitCode = status;
			native.emit('close', status, null);
		}
		await action({
			started,
			finish,
			setTime: (value) => {
				now = value;
			},
			kills: () => kills,
			fds: () => options.stdio.slice(1)
		});
		fs.rmSync(work, { recursive: true }); // Models have acknowledged their exact fake child/real sink closure.
		passed++;
		console.log('MODEL PASS ' + name);
	} finally {
		restoreFacts();
	}
}

(async () => {
	await model(
		'healthy closed receipt requires actual parent sink close',
		async ({ started, finish, fds }) => {
			const held = fds();
			finish(0);
			const value = await started;
			assert.equal(value.status, 0);
			assert.equal(value.error, null);
			for (const fd of held) assert.throws(() => fs.fstatSync(fd), { code: 'EBADF' });
		}
	);
	await model(
		'absent native closure fails despite child exit zero',
		async ({ started, finish }) => {
			finish(0, null);
			const value = await started;
			assert.equal(value.status, 0);
			assert.equal(value.error, 'closure_receipt_refused');
		}
	);
	await model(
		'late close cannot beat original deadline monitor',
		async ({ started, finish, setTime }) => {
			setTime(30000001n);
			finish(0);
			const value = await started;
			assert.equal(value.error, 'deadline');
		}
	);
	await model(
		'grace refusal retains one-TERM owner until later exact close',
		async ({ started, finish, setTime, kills, fds }) => {
			const held = fds();
			setTime(30000001n);
			const value = await started;
			assert.equal(value.error, 'owned_cleanup_pending');
			assert.equal(kills(), 1);
			for (const fd of held) assert.equal(fs.fstatSync(fd).isFile(), true);
			finish(1, { ...golden, status: 1, cancelled: true });
			assert.equal(value.error, 'owned_cleanup_pending');
			assert.equal(kills(), 1);
			for (const fd of held) assert.throws(() => fs.fstatSync(fd), { code: 'EBADF' });
		}
	);
	console.log('Owned phase protocol models: ' + passed + ' passed; native execution UNRUN.');
})().catch(() => {
	console.error('Owned phase protocol model refused.');
	process.exitCode = 1;
});
