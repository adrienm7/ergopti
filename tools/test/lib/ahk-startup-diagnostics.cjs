// tools/test/lib/ahk-startup-diagnostics.cjs

/** Retain isolated startup observations without granting native qualification. */
'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

// These are capture policy limits, not a claim about the driver's log capacity.
const MAX_MEMBER_BYTES = 16 * 1024 * 1024;
const MAX_TOTAL_BYTES = 64 * 1024 * 1024;
const MAX_LOG_MEMBERS = 16;
const MAX_SOURCE_BYTES = 128 * 1024 * 1024;
const RECEIPTS = [
	'ready.json',
	'full-save.json',
	'startup-pump.txt',
	'tray-shell.txt',
	'extension-receipt.txt',
	'script-chords.txt'
];
const digest = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');

/** Read one bounded regular member, joining the acquired descriptor to its path. */
function readDiagnosticMember(file, anchor, limit = MAX_MEMBER_BYTES) {
	const relative = path.relative(anchor, file);
	assert.ok(relative && !relative.startsWith('..') && !path.isAbsolute(relative));
	let current = anchor;
	for (const part of relative.split(path.sep)) {
		current = path.join(current, part);
		assert.equal(fs.lstatSync(current).isSymbolicLink(), false, 'diagnostic links refused');
	}
	assert.equal(fs.realpathSync(file), path.resolve(file), 'diagnostic redirection refused');
	const before = fs.lstatSync(file, { bigint: true });
	assert.ok(before.isFile(), 'diagnostic member must be a regular file');
	assert.ok(before.size <= BigInt(limit), 'diagnostic member exceeds capture policy');
	const identity = (stat) => [stat.dev, stat.ino, stat.size, stat.mtimeNs, stat.ctimeNs];
	const fd = fs.openSync(file, 'r');
	try {
		assert.deepEqual(identity(fs.fstatSync(fd, { bigint: true })), identity(before));
		const bytes = Buffer.alloc(Number(before.size));
		let offset = 0;
		while (offset < bytes.length) {
			const count = fs.readSync(fd, bytes, offset, bytes.length - offset, offset);
			assert.ok(count > 0, 'diagnostic member shrank during capture');
			offset += count;
		}
		assert.deepEqual(identity(fs.fstatSync(fd, { bigint: true })), identity(before));
		assert.deepEqual(identity(fs.lstatSync(file, { bigint: true })), identity(before));
		assert.equal(fs.realpathSync(file), path.resolve(file), 'diagnostic redirection changed');
		return bytes;
	} finally {
		fs.closeSync(fd);
	}
}

/** Acquire an invocation-owned staging directory before fallible fixture setup. */
function createStartupDiagnostics(parent, context, sources, execution = null) {
	assert.ok(path.isAbsolute(parent), 'startup diagnostics require an absolute root');
	assert.ok(['local', 'github'].includes(context), 'startup diagnostics context refused');
	if (context === 'github') {
		assert.ok(
			execution && Object.keys(execution).sort().join(',') === 'job,run_attempt,run_id,source_sha'
		);
		assert.match(execution.source_sha, /^[a-f0-9]{40}$/);
		assert.match(execution.run_id, /^[1-9][0-9]*$/);
		assert.match(execution.run_attempt, /^[1-9][0-9]*$/);
		assert.match(execution.job, /^[A-Za-z0-9_-]+$/);
	} else assert.equal(execution, null);
	const directory = fs.mkdtempSync(path.join(parent, 'ergopti-startup-diagnostics-'));
	const anchor = fs.realpathSync(directory);
	const directoryIdentity = fs.lstatSync(directory, { bigint: true });
	function requireDirectory() {
		const current = fs.lstatSync(directory, { bigint: true });
		assert.ok(current.isDirectory() && !current.isSymbolicLink(), 'startup staging root refused');
		assert.deepEqual(
			[current.dev, current.ino],
			[directoryIdentity.dev, directoryIdentity.ino],
			'startup staging identity changed'
		);
		assert.equal(fs.realpathSync(directory), anchor, 'startup diagnostics root changed');
	}
	const record = {
		schema_version: 1,
		qualified: false,
		context,
		execution_observed: execution === null ? null : { ...execution },
		capture_policy: {
			max_member_bytes: MAX_MEMBER_BYTES,
			max_total_bytes: MAX_TOTAL_BYTES,
			max_log_members: MAX_LOG_MEMBERS,
			max_source_bytes: MAX_SOURCE_BYTES
		},
		identity_scope: 'node-stat-path-descriptor-observations; native-reparse-tags-unobserved',
		transitive_source_closure: 'unreceived',
		descendant_retirement: 'unobserved',
		sources: [],
		invocations: [],
		capture_errors: []
	};
	let total = 0;
	let finished = false;
	function write(name, bytes) {
		requireDirectory();
		assert.ok(
			bytes.length <= MAX_MEMBER_BYTES && total + bytes.length <= MAX_TOTAL_BYTES,
			'startup diagnostics exceed capture policy'
		);
		fs.writeFileSync(path.join(directory, name), bytes, { flag: 'wx', mode: 0o600 });
		total += bytes.length;
		return { file: name, bytes: bytes.length, sha256: digest(bytes) };
	}
	function recordError(stage, error) {
		record.capture_errors.push({ stage, name: String(error.name), code: error.code || null });
	}
	try {
		for (const [role, file] of Object.entries(sources)) {
			const bytes = readDiagnosticMember(file, path.dirname(file), MAX_SOURCE_BYTES);
			record.sources.push({ role, sha256: digest(bytes), bytes: bytes.length });
		}
	} catch (error) {
		recordError('source-binding', error);
		record.outcome = 'FAIL_OR_INCOMPLETE';
		record.last_stage = 'source-binding';
		record.cleanup_complete = false;
		try {
			fs.writeFileSync(
				path.join(directory, 'receipt.json'),
				JSON.stringify(record, null, 2) + '\n',
				{ flag: 'wx', mode: 0o600 }
			);
			error.retainedStartupDiagnostics = directory;
		} catch {
			error.startupDiagnosticsUnavailable = true;
		}
		throw error;
	}
	return {
		directory,
		capture(fixture, phase, configRoot, nonce, result) {
			assert.equal(finished, false, 'startup diagnostics already finalized');
			requireDirectory();
			assert.match(fixture, /^[a-z0-9_-]+$/);
			assert.ok(['cold', 'warm'].includes(phase));
			assert.match(nonce, /^[a-f0-9]{32}$/);
			assert.ok(
				!record.invocations.some((row) => row.fixture === fixture && row.phase === phase),
				'duplicate startup invocation refused'
			);
			const frame = {
				fixture,
				phase,
				nonce,
				pid: result.pid ?? null,
				status: result.status ?? null,
				signal: result.signal ?? null,
				error_code: result.error?.code ?? null,
				direct_child_return_observed: true,
				child_output_completeness: 'unknown',
				members: [],
				missing: []
			};
			record.invocations.push(frame);
			try {
				for (const stream of ['stdout', 'stderr']) {
					const value = result[stream];
					if (value === null || value === undefined) {
						frame.missing.push(stream);
						continue;
					}
					assert.ok(Buffer.isBuffer(value), 'startup diagnostics require returned raw bytes');
					frame.members.push(write(`${record.invocations.length}-${stream}.bin`, value));
				}
				const root = fs.realpathSync(configRoot);
				assert.equal(root, path.resolve(configRoot), 'startup fixture redirection refused');
				const files = RECEIPTS.map((name) => ({ name, file: path.join(root, name) }));
				const logs = path.join(root, 'ergopti_plus/logs');
				if (fs.existsSync(logs)) {
					assert.equal(fs.lstatSync(path.join(root, 'ergopti_plus')).isSymbolicLink(), false);
					assert.equal(fs.lstatSync(logs).isSymbolicLink(), false);
					assert.ok(fs.lstatSync(logs).isDirectory(), 'startup logs require their owned directory');
					assert.equal(fs.realpathSync(logs), path.resolve(logs));
					const names = fs
						.readdirSync(logs)
						.filter((name) => name.endsWith('.log'))
						.sort();
					assert.ok(names.length <= MAX_LOG_MEMBERS, 'startup log census exceeds capture policy');
					for (const name of names)
						files.push({ name: `logs/${name}`, file: path.join(logs, name) });
				}
				for (const { name, file } of files) {
					if (!fs.existsSync(file)) {
						frame.missing.push(name);
						continue;
					}
					const bytes = readDiagnosticMember(file, root);
					frame.members.push({
						...write(`${record.invocations.length}-${frame.members.length}.bin`, bytes),
						source_member: name
					});
				}
			} catch (error) {
				recordError(`${fixture}/${phase}`, error);
				throw error;
			}
		},
		finish(passed, cleanupComplete, stage) {
			assert.equal(finished, false, 'startup diagnostics finalized twice');
			finished = true;
			requireDirectory();
			if (passed && cleanupComplete && record.capture_errors.length === 0) {
				fs.rmSync(directory, { recursive: true });
				return null;
			}
			record.outcome = 'FAIL_OR_INCOMPLETE';
			record.last_stage = stage;
			record.cleanup_complete = cleanupComplete;
			record.observed_bytes = total;
			fs.writeFileSync(
				path.join(directory, 'receipt.json'),
				JSON.stringify(record, null, 2) + '\n',
				{ flag: 'wx', mode: 0o600 }
			);
			return directory;
		}
	};
}

module.exports = {
	createStartupDiagnostics,
	readDiagnosticMember,
	MAX_MEMBER_BYTES,
	MAX_TOTAL_BYTES,
	MAX_LOG_MEMBERS
};
