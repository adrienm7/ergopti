// tools/test/test-macos-release-stage-native-receiving.cjs
/**
 * Exercise the unchanged native receiver's rejection boundaries in controlled
 * Node children. No guardian, Darwin ABI, Python corpus, signal syscall or
 * routing/package behavior is executed by these portable controls.
 */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { EventEmitter } = require('node:events');
const Module = require('node:module');
const root = path.resolve(__dirname, '../..');
const wrapper = path.join(root, 'tools/diagnostics/macos_release_stage_native_receiving.cjs');
const sha = (bytes) => createHash('sha256').update(bytes).digest('hex');
const scenarioNames = [
	'envelope-only',
	'missing-platform',
	'missing-interpreter',
	'missing-native-capability',
	'missing-receipt',
	'foreign-guardian',
	'foreign-group',
	'unclosed-receipt',
	'unknown-receipt-field',
	'wrong-exit-status',
	'weak-receipt-mode',
	'linked-receipt',
	'symlink-receipt',
	'missing-ready',
	'missing-sent',
	'foreign-sent-guardian',
	'foreign-sent-helper',
	'unsent-signal',
	'wrong-signal-name',
	'foreign-ready-worker',
	'unknown-ready-field',
	'close-refusal',
	'close-then-error',
	'late-after-close',
	'outer-interruption'
];
const expectedHash = 'bf8a362993f6dde3fa2f0f06266267fb334f2fd568d3d791192e6c2deb67a99c';

/** Install explicit stand-ins only in a fresh controlled child process. */
function controlledChild() {
	const scenario = process.env.ERGOPTI_RECEIVER_CONTROL_SCENARIO;
	assert.ok(scenarioNames.includes(scenario));
	assert.equal(sha(fs.readFileSync(wrapper)), expectedHash, 'unchanged original wrapper');
	const recordPath = process.env.ERGOPTI_RECEIVER_CONTROL_RECORD;
	assert.ok(path.isAbsolute(recordPath));
	const record = {
		scope: 'controlled portable rejection only',
		scenario,
		acquisitions: [],
		closes: [],
		guardian_executed: false,
		native_signal_syscall: false
	};
	const publishRecord = () =>
		fs.writeFileSync(recordPath, JSON.stringify(record) + '\n', { mode: 0o600 });
	process.once('exit', publishRecord);
	Object.defineProperty(process, 'platform', {
		value: scenario === 'missing-platform' ? 'linux' : 'darwin'
	});
	const originalLoad = Module._load;
	const originalClose = fs.closeSync;
	const captures = new Map();
	let closeFaultInjected = false;
	let replacement = null;
	fs.closeSync = function closeExactCapture(fd) {
		if (!captures.has(fd)) return originalClose(fd);
		const entry = captures.get(fd);
		// A numeric descriptor stops identifying this capture before any close
		// attempt. Its immutable observation never follows a reused number.
		captures.delete(fd);
		let outcome = 'uncertain-close';
		try {
			if (
				!closeFaultInjected &&
				entry.name === 'TERM' &&
				['close-refusal', 'close-then-error'].includes(scenario)
			) {
				closeFaultInjected = true;
				if (scenario === 'close-then-error') {
					originalClose(fd);
					const replacementFD = fs.openSync(
						path.join(path.dirname(recordPath), 'replacement-after-close'),
						'wx',
						0o600
					);
					replacement = { fd: replacementFD, reused: replacementFD === fd };
				}
				throw new Error('Controlled capture close failure');
			}
			originalClose(fd);
			outcome = 'closed';
		} finally {
			record.closes.push(
				Object.freeze({
					capture_id: entry.id,
					operation: entry.name,
					stream: entry.stream,
					attempt: 1,
					numeric_binding_retired: true,
					outcome
				})
			);
		}
	};
	process.once('beforeExit', () => {
		if (replacement === null) return;
		const before = record.closes.length;
		assert.equal(captures.has(replacement.fd), false, 'no stale numeric capture binding');
		assert.ok(fs.fstatSync(replacement.fd).isFile(), 'replacement remains physically open');
		fs.closeSync(replacement.fd);
		record.replacement = Object.freeze({
			reused: replacement.reused,
			closed: true,
			added_capture_close_rows: record.closes.length - before
		});
		replacement = null;
	});
	if (scenario === 'late-after-close') {
		let firstClock = true;
		process.hrtime.bigint = () => {
			if (firstClock) {
				firstClock = false;
				return 1000000000n;
			}
			return record.acquisitions.length > 0 ? 121000000000n : 1000000000n;
		};
	}
	function publishPackets(args, native, directory, name) {
		const closed = {
			schema: 1,
			guardian_pid: native.pid,
			worker_pid: native.pid + 1,
			group_id: native.pid + 1,
			closed: true,
			exit_status: name === 'corpus' ? 0 : 124
		};
		const selected = name === 'TERM';
		if (selected && scenario === 'foreign-guardian') closed.guardian_pid += 10;
		if (selected && scenario === 'foreign-group') closed.group_id += 10;
		if (selected && scenario === 'unclosed-receipt') closed.closed = false;
		if (selected && scenario === 'unknown-receipt-field') closed.foreign = true;
		if (selected && scenario === 'wrong-exit-status') closed.exit_status = 0;
		if (!(selected && scenario === 'missing-receipt') && scenario !== 'missing-native-capability') {
			const receiptPath = args[3];
			if (selected && scenario === 'symlink-receipt') {
				const target = path.join(directory, 'foreign.json');
				fs.writeFileSync(target, JSON.stringify(closed), { flag: 'wx', mode: 0o600 });
				fs.symlinkSync(target, receiptPath);
			} else {
				fs.writeFileSync(receiptPath, JSON.stringify(closed), { flag: 'wx', mode: 0o600 });
				if (selected && scenario === 'weak-receipt-mode') fs.chmodSync(receiptPath, 0o644);
				if (selected && scenario === 'linked-receipt')
					fs.linkSync(receiptPath, path.join(directory, 'foreign-hardlink.json'));
			}
		}
		if (name === 'corpus') {
			const script = path.join(root, 'static/ergopti_plus/macos/adapters/release_stage.sh');
			// Synthetic envelope rows exercise only receiving. The independent literal
			// corpus is copied byte-exact and never executed or regenerated here.
			const observations = Array.from({ length: 50 }, (_, index) => ({
				name: `controlled-envelope-${index}`,
				actual_calls: [],
				actual_rows: [],
				actual_status: 0,
				expected_calls: [],
				expected_status: 0,
				errors: [],
				stderr_hex: '',
				stdout_hex: ''
			}));
			const corpus = {
				version: 1,
				kind: 'portable-authored-shell-only',
				no_genuine_native_qualification: true,
				observations,
				script: fs.realpathSync(script),
				script_sha256: sha(fs.readFileSync(script)),
				failures: []
			};
			fs.writeFileSync(path.join(directory, 'corpus.json'), JSON.stringify(corpus), {
				flag: 'wx',
				mode: 0o600
			});
			return;
		}
		const ready = {
			version: 1,
			signal: name,
			guardian_pid: native.pid,
			worker_pid: native.pid + 1,
			helper_pid: native.pid + 2,
			group_id: native.pid + 1
		};
		const sent = {
			version: 1,
			signal: name,
			guardian_pid: native.pid,
			helper_pid: native.pid + 2,
			native_kill_returned: true
		};
		if (selected && scenario === 'foreign-sent-guardian') sent.guardian_pid += 10;
		if (selected && scenario === 'foreign-sent-helper') sent.helper_pid += 10;
		if (selected && scenario === 'unsent-signal') sent.native_kill_returned = false;
		if (selected && scenario === 'wrong-signal-name') sent.signal = 'INT';
		if (selected && scenario === 'foreign-ready-worker') ready.worker_pid += 10;
		if (selected && scenario === 'unknown-ready-field') ready.foreign = true;
		if (!(selected && scenario === 'missing-ready'))
			fs.writeFileSync(path.join(directory, 'ready.json'), JSON.stringify(ready), {
				flag: 'wx',
				mode: 0o600
			});
		if (!(selected && scenario === 'missing-sent'))
			fs.writeFileSync(path.join(directory, 'sent.json'), JSON.stringify(sent), {
				flag: 'wx',
				mode: 0o600
			});
	}
	function spawnControlledGuardian(interpreter, args, options) {
		assert.equal(interpreter, '/controlled/CPython');
		assert.equal(args[0], '-B');
		assert.equal(path.basename(args[1]), 'macos_owned_process.py');
		assert.equal(args[2], 'run');
		assert.equal(args[5], '--');
		assert.equal(args[6], interpreter);
		assert.equal(args[7], '-B');
		assert.equal(options.cwd, root);
		assert.equal(options.stdio[0], 'ignore');
		assert.ok(Number(args[4]) > 0 && Number(args[4]) <= 120);
		const directory = path.dirname(args[3]);
		const name = path.basename(directory);
		assert.equal(args[3], path.join(directory, 'closed.json'));
		assert.equal(name, ['corpus', 'TERM', 'INT'][record.acquisitions.length]);
		if (name === 'corpus') {
			assert.equal(path.basename(args[8]), 'macos_release_stage_route_test.py');
			assert.equal(args[9], path.join(root, 'static/ergopti_plus/macos/adapters/release_stage.sh'));
			assert.equal(args[10], path.join(directory, 'corpus.json'));
		} else {
			assert.equal(path.basename(args[8]), 'cancellation_worker.py');
			assert.deepEqual(args.slice(9), ['worker', directory, name]);
		}
		const native = new EventEmitter();
		native.pid = 31000 + record.acquisitions.length * 10;
		native.exitCode = null;
		native.signalCode = null;
		native.kill = (signal) => {
			record.outer_signal = signal;
			return true;
		};
		for (const [index, stream] of ['stdout', 'stderr'].entries()) {
			const fd = options.stdio[index + 1];
			assert.ok(fs.fstatSync(fd).isFile());
			captures.set(
				fd,
				Object.freeze({ id: `${record.acquisitions.length}:${stream}`, name, stream })
			);
		}
		record.acquisitions.push({ name, pid: native.pid, command_contract_checked: true });
		setImmediate(() => {
			native.emit('spawn');
			publishPackets(args, native, directory, name);
			if (scenario === 'outer-interruption' && name === 'TERM') process.emit('SIGTERM');
			native.exitCode = scenario === 'missing-native-capability' ? 1 : name === 'corpus' ? 0 : 124;
			native.emit('close', native.exitCode, null);
		});
		return native;
	}
	Module._load = function loadControlledBoundary(request, parent, isMain) {
		if (request === 'node:child_process') return { spawn: spawnControlledGuardian };
		if (request === '../lib/python.cjs' && parent && parent.filename === wrapper)
			return {
				pythonExecutable: () => {
					if (scenario === 'missing-interpreter')
						throw new Error('Controlled interpreter capability missing');
					return '/controlled/CPython';
				}
			};
		return originalLoad.call(this, request, parent, isMain);
	};
}

/** Run bounded fresh children; returned green means portable contracts only. */
function main() {
	assert.equal(sha(fs.readFileSync(wrapper)), expectedHash, 'immutable native wrapper preimage');
	const held = fs.readFileSync(
		path.join(root, 'tools/diagnostics/macos_release_stage_route_test.py')
	);
	assert.equal(sha(held), '0b739b76604a464d86d8e94eb7e5fc37df1834633250f7aac6dd7a6a04e38fc9');
	const directory = fs.mkdtempSync(
		path.join(process.env.TMPDIR || require('node:os').tmpdir(), 'darwin50-controlled-refusals-')
	);
	const results = [];
	for (const scenario of scenarioNames) {
		const own = path.join(directory, scenario);
		fs.mkdirSync(own, { mode: 0o700 });
		const output = path.join(own, 'evidence');
		const recordPath = path.join(own, 'control-record.json');
		const result = spawnSync(
			process.execPath,
			['--require', __filename, wrapper, '--output', output],
			{
				cwd: root,
				encoding: 'utf8',
				timeout: 10000,
				env: {
					...process.env,
					ERGOPTI_RECEIVER_CONTROL_PRELOAD: '1',
					ERGOPTI_RECEIVER_CONTROL_SCENARIO: scenario,
					ERGOPTI_RECEIVER_CONTROL_RECORD: recordPath
				}
			}
		);
		assert.ifError(result.error);
		assert.equal(result.signal, null, 'actual controlled child physically completed');
		const record = JSON.parse(fs.readFileSync(recordPath));
		assert.equal(record.guardian_executed, false);
		assert.equal(record.native_signal_syscall, false);
		if (scenario === 'envelope-only') {
			assert.equal(result.status, 0);
			const receipt = JSON.parse(fs.readFileSync(path.join(output, 'receipt.json')));
			assert.equal(receipt.genuine_routing_or_package_acceptance, false);
			assert.deepEqual(
				record.acquisitions.map((entry) => entry.name),
				['corpus', 'TERM', 'INT']
			);
		} else {
			assert.equal(result.status, 1, `original wrapper must refuse ${scenario}`);
			assert.equal(result.stdout, '', 'refusal cannot publish PASS');
			assert.equal(
				result.stderr.trim(),
				'FAIL - Darwin selected-release receiving or native retirement refused; inputs retained'
			);
			assert.equal(fs.existsSync(path.join(output, 'receipt.json')), false);
			const expectedAcquisitions = ['missing-platform', 'missing-interpreter'].includes(scenario)
				? 0
				: ['missing-native-capability', 'late-after-close'].includes(scenario)
					? 1
					: 2;
			assert.equal(record.acquisitions.length, expectedAcquisitions, 'no successor after refusal');
			if (expectedAcquisitions) {
				assert.equal(
					fs.readFileSync(path.join(output, 'corpus/inputs-retained'), 'utf8'),
					'original-owned-input\n'
				);
				assert.ok(fs.existsSync(path.join(output, 'source/cancellation_worker.py')));
			}
			if (scenario.startsWith('close-')) {
				const termCloses = record.closes.filter((entry) => entry.operation === 'TERM');
				assert.equal(termCloses.length, 2, 'one retained observation per original capture');
				assert.deepEqual(
					termCloses.map((entry) => entry.attempt),
					[1, 1]
				);
				assert.equal(
					termCloses.every((entry) => entry.numeric_binding_retired),
					true
				);
				assert.deepEqual(
					termCloses.map((entry) => entry.outcome),
					['uncertain-close', 'closed']
				);
			}
			if (scenario === 'close-then-error') {
				assert.deepEqual(record.replacement, {
					reused: true,
					closed: true,
					added_capture_close_rows: 0
				});
			}
			if (scenario === 'outer-interruption')
				assert.equal(
					record.outer_signal,
					'SIGTERM',
					'controlled active child cancellation requested'
				);
		}
		results.push({
			scenario,
			actual_child_exit: result.status,
			child_completed: true,
			portable_contract_only: true
		});
	}
	assert.equal(sha(fs.readFileSync(wrapper)), expectedHash);
	assert.equal(
		sha(fs.readFileSync(path.join(root, 'tools/diagnostics/macos_release_stage_route_test.py'))),
		sha(held)
	);
	fs.writeFileSync(
		path.join(directory, 'RECEIVING.json'),
		JSON.stringify(
			{
				schema: 1,
				scope: 'controlled portable rejection only',
				actual_Darwin: 'UNEXECUTED',
				original_wrapper_sha256: expectedHash,
				original_corpus_sha256: sha(held),
				results
			},
			null,
			2
		) + '\n',
		{ flag: 'wx', mode: 0o600 }
	);
	console.log(
		`PASS - ${results.length} controlled receiver contracts; actual Darwin retirement, signals and literal50 corpus UNEXECUTED`
	);
}
if (process.env.ERGOPTI_RECEIVER_CONTROL_PRELOAD === '1') controlledChild();
else if (require.main === module) main();
module.exports = { main };
