// tools/test/fixtures/macos-opaque-exec-argv.cjs
/** Receives an original-owner shell wrapper; the only leaf port is exec argv. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../../lib/git-bash.cjs');
assert.equal(process.argv.length, 3, 'one exact owner-emitted wrapper file is required');
const source = fs.readFileSync(process.argv[2], 'utf8');
assert.ok(
	source.length > 0 && Buffer.byteLength(source) <= 262144,
	'bounded complete wrapper source required'
);
const env = { ...process.env };
for (const key of [
	'https_proxy',
	'HTTPS_PROXY',
	'http_proxy',
	'HTTP_PROXY',
	'all_proxy',
	'ALL_PROXY',
	'NO_PROXY',
	'no_proxy',
	'UV_SYSTEM_CERTS',
	'SSL_CERT_FILE',
	'REQUESTS_CA_BUNDLE'
])
	delete env[key];
env.HTTPS_PROXY = 'http://receiver.invalid:3128';
const leaf = `_ergopti_exec_count=0; exec() { _ergopti_exec_count=$((_ergopti_exec_count + 1)); [ "$_ergopti_exec_count" -eq 1 ] || return 75; printf '%s\\0' __ERGOPTI_EXEC_ARGV_V1__ "$@"; }; `;
const received = spawnSync(bashExecutable(), ['-c', leaf + source], {
	env,
	encoding: 'utf8',
	timeout: 10000,
	maxBuffer: 1048576
});
assert.ifError(received.error);
assert.equal(received.signal, null, 'receiving child must physically exit');
assert.equal(received.status, 0, received.stderr || received.stdout);
assert.equal(
	received.stderr,
	'__ERGOPTI_OPAQUE_ADMISSION_V1__:accepted\n',
	'the genuine pre-child opaque phase must admit the executed leaf'
);
assert.ok(received.stdout.endsWith('\0'), 'leaf argv must have its exact terminating delimiter');
const values = received.stdout.split('\0');
assert.equal(values.pop(), '');
assert.equal(
	values.shift(),
	'__ERGOPTI_EXEC_ARGV_V1__',
	'exact receiver-owned exec frame required'
);
assert.equal(
	values[0],
	'/opt/homebrew/bin/ollama',
	'the original fixture CLI executable is preserved'
);
process.stdout.write(JSON.stringify({ executable: values[0], args: values.slice(1) }));
