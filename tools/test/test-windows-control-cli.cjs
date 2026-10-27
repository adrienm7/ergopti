// tools/test/test-windows-control-cli.cjs

/**
 * MODULE: Windows Control CLI Admission Tests
 * DESCRIPTION:
 * Executes the real session reader and public result receiver with private
 * data and a genuinely absent process. Windows uses its actual PowerShell 5.1; other hosts verify portable
 * PowerShell semantics without qualifying Windows messages or live reloads.
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const SOURCE = path.join(ROOT, 'tools/control/request_driver_reload.ps1');
const CHILD_TIMEOUT_MS = 30000;
const argumentsByName = new Map();
for (const argument of process.argv.slice(2)) {
	const match = /^--(phase|receipt)=(.+)$/.exec(argument);
	assert.ok(match && !argumentsByName.has(match[1]), 'expected unique --phase/--receipt arguments');
	argumentsByName.set(match[1], match[2]);
}
const phase = argumentsByName.get('phase');
assert.ok(
	['session', 'result'].includes(phase),
	'a known admission phase must be selected explicitly'
);
const runtime =
	process.platform === 'win32'
		? path.join(process.env.SystemRoot, 'System32/WindowsPowerShell/v1.0/powershell.exe')
		: 'pwsh';
const invoke = (arguments_, environment = process.env) => {
	const child = spawnSync(runtime, ['-NoProfile', '-NonInteractive', ...arguments_], {
		cwd: ROOT,
		env: environment,
		encoding: 'utf8',
		windowsHide: true,
		timeout: CHILD_TIMEOUT_MS
	});
	return {
		exit: child.status,
		signal: child.signal,
		error: child.error?.message || '',
		stdout: child.stdout || '',
		stderr: child.stderr || ''
	};
};
const version = invoke(['-Command', '$PSVersionTable.PSVersion.ToString()']);
assert.equal(version.exit, 0, `the actual PowerShell host must run: ${JSON.stringify(version)}`);
const runtimeVersion = version.stdout.trim();
assert.match(
	runtimeVersion,
	process.platform === 'win32' ? /^5\.1\./ : /^7\./,
	'the required actual PowerShell host must report its version; an empty native shim cannot qualify it'
);
const spec = JSON.parse(
	fs.readFileSync(
		path.join(ROOT, 'static/ergopti_plus/_shared/modules/control/driver_control.json'),
		'utf8'
	)
);
if (phase === 'result') {
	require('./support/windows-control-cli-result.cjs').runResult({
		root: ROOT,
		source: SOURCE,
		spec,
		invoke,
		runtimeVersion,
		receiptPath: argumentsByName.get('receipt')
	});
	process.exit(0);
}
const folders = fs.readFileSync(
	path.join(ROOT, 'static/ergopti_plus/_shared/modules/paths/app_dirs.toml'),
	'utf8'
);
const folderNames = [...folders.matchAll(/^folder_name = "([^"]+)"$/gm)];
assert.equal(folderNames.length, 1, 'the actual application folder declaration must be unique');
const sourceHash = () => createHash('sha256').update(fs.readFileSync(SOURCE)).digest('hex');
const originalHash = sourceHash();
const token = 'a'.repeat(spec.token_hex_length);
const baseline = { schema: spec.schema, driver: 'windows', pid: 2147483647, token };
const cases = [
	{ name: 'valid', allow: true },
	{ name: 'schema-float', change: { schema: 1.0 }, allow: true },
	{ name: 'schema-exponent', change: { schema: 1.0 }, exponent: true, allow: true },
	{
		name: 'pid-integral-float',
		change: { pid: 2147483647.0 },
		integralPidFloat: true,
		allow: true
	},
	{ name: 'schema-true', change: { schema: true } },
	{ name: 'schema-string', change: { schema: '1' } },
	{ name: 'schema-array', change: { schema: [1] } },
	{ name: 'schema-empty-array', change: { schema: [] } },
	{ name: 'driver-array', change: { driver: ['windows'] } },
	{ name: 'driver-uppercase', change: { driver: 'WINDOWS' } },
	{ name: 'token-final-LF', change: { token: token + '\n' } },
	{ name: 'token-uppercase', change: { token: token.toUpperCase() } },
	{ name: 'token-array', change: { token: [token] } },
	{ name: 'pid-string', change: { pid: String(baseline.pid) } },
	{ name: 'pid-fraction', change: { pid: 2147483646.5 } },
	{ name: 'schema-key-uppercase', uppercaseSchema: true },
	{ name: 'root-array', arrayRoot: true },
	{ name: 'wrong-driver', change: { driver: 'linux' } },
	{ name: 'short-token', change: { token: token.slice(1) } },
	{ name: 'wrong-schema', change: { schema: 0 } }
];
assert.equal(cases.length, 20, 'all authored session controls must execute');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-control-cli-'));
const controls = [];
const failures = [];
const replaceFixtureToken = (text, from, to) => {
	assert.equal(
		text.split(from).length,
		2,
		'the numeric spelling control must replace exactly one real token'
	);
	return text.replace(from, to);
};
const plain = (text) => text.replace(/\x1b\[[0-9;]*m/g, '').replace(/\s+/g, ' ');
try {
	for (const fixture of cases) {
		const base = path.join(scratch, fixture.name + " O'Brien é [1]");
		const folder = spec.folders.windows.segments.reduce(
			(parent, segment) => path.join(parent, segment === '{app}' ? folderNames[0][1] : segment),
			base
		);
		fs.mkdirSync(folder, { recursive: true });
		const record = { ...baseline, ...fixture.change };
		if (fixture.uppercaseSchema) {
			record.SCHEMA = record.schema;
			delete record.schema;
		}
		let text = JSON.stringify(fixture.arrayRoot ? [record] : record);
		if (fixture.name === 'schema-float')
			text = replaceFixtureToken(text, '"schema":1,', '"schema":1.0,');
		if (fixture.exponent) text = replaceFixtureToken(text, '"schema":1,', '"schema":1e0,');
		if (fixture.integralPidFloat)
			text = replaceFixtureToken(text, '"pid":2147483647,', '"pid":2147483647.0,');
		fs.writeFileSync(path.join(folder, spec.files.session), text + '\n', 'utf8');
		const actual = invoke(['-File', SOURCE, '-TimeoutMs', '1000'], {
			...process.env,
			[spec.folders.windows.base]: base
		});
		let passed = false;
		if (fixture.allow) {
			try {
				const outcome = JSON.parse(actual.stdout.trim());
				passed =
					actual.exit === 3 &&
					outcome.state === 'unreachable' &&
					outcome.detail === 'the published driver process is gone';
			} catch {
				passed = false;
			}
		} else {
			passed =
				actual.exit === 1 && plain(actual.stderr).includes('The driver session is malformed.');
		}
		controls.push({ name: fixture.name, allow: fixture.allow === true, passed, ...actual });
		if (!passed)
			failures.push(
				`${fixture.name}: expected ${fixture.allow ? 'the genuine absent-process outcome' : 'malformed-session refusal'}, exit=${actual.exit}, out=${actual.stdout.trim()}`
			);
	}
	assert.equal(
		sourceHash(),
		originalHash,
		'the actual CLI source must remain stable across every control'
	);
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
	if (argumentsByName.has('receipt')) {
		fs.writeFileSync(
			argumentsByName.get('receipt'),
			JSON.stringify(
				{
					phase: 'session',
					runtime: runtimeVersion,
					source_sha256: originalHash,
					qualification:
						'Real CLI session admission; no Windows messages, COM or live reload receiving.',
					controls
				},
				null,
				2
			) + '\n'
		);
	}
}
assert.equal(
	controls.length,
	cases.length,
	'every session control must produce an actual child receipt'
);
assert.deepEqual(failures, [], failures.join('\n'));
console.log('[OK] Windows control CLI session admission controls passed.');
console.log(`PowerShell ${runtimeVersion}; Windows message and live reload receiving UNRUN.`);
