// tools/test/run-linux-network-runtime.cjs

/**
 * ==============================================================================
 * MODULE: Native Linux Network Runtime Gate
 * DESCRIPTION:
 * Runs independent factory witnesses and actual installed-layout GIO admission.
 * Missing Linux prerequisites or omitted execution receipts block qualification.
 * ==============================================================================
 */
'use strict';
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { createHash } = require('node:crypto');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const DRIVER = path.join(ROOT, 'static/ergopti_plus/linux');
const FACTORY = path.join(ROOT, 'tools/test/fixtures/linux-network-runtime-factory.lua');
const NATIVE = path.join(ROOT, 'tools/test/test-linux-network-runtime.cjs');
const FACTORY_OUTPUT = 'PASS network runtime factory controls: 4 passed; 0 skipped\n';
const NATIVE_OUTPUT = [
	'PASS actual LuaJIT refuses missing luv from an unrelated installed CWD',
	'PASS actual installed GLib with dummy resolver refuses native package admission',
	'PASS actual missing compiled schema refuses helper and installer before resolver construction',
	'PASS actual installed runtime locates native and shared sources independently of CWD',
	'Linux network runtime: 4 passed; 0 skipped. Actual native probes require --native.',
	''
].join('\n');

/** Retains rejected native results without placing private child text in logs. */
function retainFailure(phase, result, evidenceRoot) {
	const directory = fs.mkdtempSync(path.join(evidenceRoot, 'ergopti-network-runtime-failure-'));
	fs.chmodSync(directory, 0o700);
	const writePrivate = (name, value) => {
		const file = path.join(directory, name);
		fs.writeFileSync(file, value, { flag: 'wx', mode: 0o600 });
		fs.chmodSync(file, 0o600);
	};
	const capture = (name) => {
		const value = result[name];
		if (value === null) return { kind: 'null' };
		if (value === undefined) return { kind: 'undefined' };
		if (!Buffer.isBuffer(value))
			throw new TypeError('Native stream capture must be a Buffer, null or undefined.');
		writePrivate(name + '.bin', value);
		return {
			kind: 'buffer',
			bytes: value.length,
			sha256: createHash('sha256').update(value).digest('hex')
		};
	};
	const metadata = {
		phase: phase.name,
		command: phase.command,
		args: phase.args,
		cwd: ROOT,
		pid: result.pid,
		status: result.status,
		signal: result.signal,
		error: result.error
			? {
					name: result.error.name,
					...Object.fromEntries(
						Object.getOwnPropertyNames(result.error).map((name) => [name, result.error[name]])
					)
				}
			: null,
		stdout: capture('stdout'),
		stderr: capture('stderr')
	};
	writePrivate('result.json', JSON.stringify(metadata, null, 2) + '\n');
	return directory;
}

/** Qualifies exact completed child receipts or explicitly defers on another OS. */
function run({
	platform = process.platform,
	spawn = spawnSync,
	log = console.log,
	error = console.error,
	evidenceRoot = os.tmpdir()
} = {}) {
	if (platform !== 'linux') {
		log('[DEFERRED] Actual Linux network runtime admission requires its Linux lane.');
		return 0;
	}
	const env = { ...process.env };
	if (env.ERGOPTI_NATIVE_LUA_CPATH) env.LUA_CPATH = env.ERGOPTI_NATIVE_LUA_CPATH;
	let failed = 0;
	for (const phase of [
		{
			name: 'factory-model',
			command: 'luajit',
			args: [FACTORY, DRIVER],
			receipt: FACTORY_OUTPUT,
			timeout: 10000
		},
		// Actual children have their own bounded synchronous waits. An outer timeout
		// must not kill this Node owner before it reaps its currently owned child.
		{
			name: 'actual-native',
			command: process.execPath,
			args: [NATIVE, '--native'],
			receipt: NATIVE_OUTPUT
		}
	]) {
		const result = spawn(phase.command, phase.args, {
			cwd: ROOT,
			env,
			maxBuffer: 65536,
			...(phase.timeout ? { timeout: phase.timeout } : {})
		});
		if (
			result.error ||
			result.signal ||
			result.status !== 0 ||
			!Buffer.isBuffer(result.stdout) ||
			!result.stdout.equals(Buffer.from(phase.receipt))
		) {
			const directory = retainFailure(phase, result, evidenceRoot);
			error(
				`[FAIL] Linux network runtime ${phase.name}: completed execution receipt refused; status=${JSON.stringify(result.status)} evidence=${JSON.stringify(directory)}`
			);
			failed = 1;
		} else {
			log(
				`[OK] Linux network runtime ${phase.name}: ${phase.name === 'factory-model' ? '4 model' : '4 actual native'} groups passed; 0 skipped.`
			);
		}
	}
	return failed;
}

if (require.main === module) process.exitCode = run();
module.exports = { run };
