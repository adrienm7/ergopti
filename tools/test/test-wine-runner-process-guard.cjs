// tools/test/test-wine-runner-process-guard.cjs

/** Exercise the actual Wine admission guard against private NUL-delimited process records. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

assert.equal(process.platform, 'linux', 'The /proc Wine admission guard requires Linux.');
const source = fs.readFileSync(path.join(__dirname, 'run-ahk-under-wine.sh'), 'utf8');
const start = source.indexOf('for proc in /proc/[0-9]*; do');
const end = source.indexOf('\nif [ -z "$results" ]; then', start);
assert.ok(start >= 0 && end > start, 'the real process admission must be present');
const guard = source.slice(start, end);
assert.match(guard, /AutoHotkey already runs/, 'the extracted guard must include the refusal');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-wine-guard-'));
try {
	const proc = path.join(root, 'proc');
	const bin = path.join(root, 'bin');
	fs.mkdirSync(bin);
	const trace = path.join(root, 'external-calls');
	for (const name of ['tr', 'head', 'sed']) {
		fs.writeFileSync(
			path.join(bin, name),
			`#!/bin/bash\nprintf '%s\\n' '${name}' >> "$GUARD_TRACE"\nexec /usr/bin/${name} "$@"\n`,
			{ mode: 0o755 }
		);
	}
	function run(records, prefix = '/owned/prefix') {
		fs.rmSync(proc, { force: true, recursive: true });
		fs.mkdirSync(proc);
		fs.writeFileSync(trace, '');
		for (const [index, record] of records.entries()) {
			const dir = path.join(proc, String(index + 100));
			fs.mkdirSync(dir);
			fs.writeFileSync(
				path.join(dir, 'cmdline'),
				record.argv.join('\0') + (record.argv.length ? '\0' : '')
			);
			fs.writeFileSync(path.join(dir, 'environ'), record.env.join('\0') + '\0');
		}
		const script =
			'set -euo pipefail\ndie() { echo "$*" >&2; exit 23; }\n' +
			'prefix="$GUARD_PREFIX"\n' +
			guard.replaceAll('/proc/', proc + '/') +
			'\necho ADMITTED\n';
		const result = spawnSync('/bin/bash', ['-c', script], {
			encoding: 'utf8',
			env: {
				...process.env,
				PATH: bin + ':' + process.env.PATH,

				GUARD_PREFIX: prefix,
				GUARD_TRACE: trace
			}
		});
		assert.ifError(result.error);
		assert.notEqual(result.status, null, 'the guard must finish with an exact exit receipt');
		return {
			...result,
			external: fs.readFileSync(trace, 'utf8').trim().split('\n').filter(Boolean)
		};
	}
	const scenarios = [
		{
			argv: ['/tmp/AutoHotkey64.exe', 'runner.ahk'],
			env: ['WINEPREFIX=/owned/prefix'],
			blocked: true
		},
		{ argv: ['C:\\Tools\\aUtOhOtKeY32.ExE'], env: ['WINEPREFIX=/owned/prefix'], blocked: true },
		{ argv: ['AutoHotkey.exe'], env: [], prefix: process.env.HOME + '/.wine', blocked: true },
		{ argv: ['AutoHotkey64.exe'], env: ['WINEPREFIX=/other/prefix'], blocked: false },
		{
			argv: ['/bin/bash', '/tmp/AutoHotkey64.exe'],
			env: ['WINEPREFIX=/owned/prefix'],
			blocked: false
		},
		{ argv: ['wine', '/tmp/AutoHotkey64.exe'], env: ['WINEPREFIX=/owned/prefix'], blocked: false },
		{ argv: ['/tmp/AutoHotkey64.exe.backup'], env: ['WINEPREFIX=/owned/prefix'], blocked: false },
		{ argv: [], env: [], blocked: false }
	];
	for (const scenario of scenarios) {
		const result = run([scenario], scenario.prefix);
		assert.equal(
			result.status,
			scenario.blocked ? 23 : 0,
			JSON.stringify({ scenario, stderr: result.stderr })
		);
		assert.equal(
			result.stdout.includes('ADMITTED'),
			!scenario.blocked,
			'a blocker must never reach admission'
		);
		if (scenario.blocked) assert.match(result.stderr, /AutoHotkey already runs/);
	}
	console.log('Wine guard NUL-delimited record semantics: 8 controls passed');
	const irrelevant = Array.from({ length: 256 }, (_, index) => ({
		argv: index % 2 ? [] : ['/usr/bin/unrelated', '/tmp/AutoHotkey64.exe'],
		env: []
	}));
	const result = run(irrelevant);
	assert.equal(result.status, 0, result.stderr);
	assert.equal(
		result.external.length,
		0,
		'irrelevant or zombie processes must require no external command per PID'
	);
	console.log('Wine guard process scan resource regression: passed');
} finally {
	fs.rmSync(root, { recursive: true, force: true });
}
