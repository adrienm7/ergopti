// tools/test/support/file-backed-native-runner.cjs

/** Own native output files until the synchronous child has returned. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function runFileBackedNative(executable, args, directory, options) {
	assert.ok(
		fs.lstatSync(directory).isDirectory(),
		'native capture requires its acquired directory'
	);
	const captures = {
		stdout: path.join(directory, 'native.stdout.log'),
		stderr: path.join(directory, 'native.stderr.log')
	};
	let stdoutFd;
	let stderrFd;
	try {
		stdoutFd = fs.openSync(captures.stdout, 'wx');
		stderrFd = fs.openSync(captures.stderr, 'wx');
		const result = spawnSync(executable, args, {
			...options,
			stdio: ['ignore', stdoutFd, stderrFd]
		});
		return { result, captures };
	} finally {
		try {
			if (stderrFd !== undefined) fs.closeSync(stderrFd);
		} finally {
			if (stdoutFd !== undefined) fs.closeSync(stdoutFd);
		}
	}
}

// Full bytes stay in the acquired file. This is explicitly only a bounded tail.
function describeNativeCapture(file) {
	let fd;
	try {
		fd = fs.openSync(file, 'r');
		const bytes = fs.fstatSync(fd).size;
		const limit = 4096;
		const tail = Buffer.alloc(Math.min(bytes, limit));
		const tailBytes = fs.readSync(fd, tail, 0, tail.length, Math.max(0, bytes - limit));
		return {
			file,
			bytes,
			tail_limit_bytes: limit,
			tail_bytes: tailBytes,
			tail_utf8: tail.subarray(0, tailBytes).toString('utf8')
		};
	} catch (error) {
		return { file, observation_error: String(error.code || error.message) };
	} finally {
		if (fd !== undefined) fs.closeSync(fd);
	}
}

module.exports = { runFileBackedNative, describeNativeCapture };
