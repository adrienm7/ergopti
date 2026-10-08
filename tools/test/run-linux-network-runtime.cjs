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

/** Qualifies exact completed child receipts or explicitly defers on another OS. */
function run({
	platform = process.platform,
	spawn = spawnSync,
	log = console.log,
	error = console.error
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
			encoding: 'utf8',
			maxBuffer: 65536,
			...(phase.timeout ? { timeout: phase.timeout } : {})
		});
		if (result.error || result.signal || result.status !== 0 || result.stdout !== phase.receipt) {
			// Native streams stay private; status and a fixed phase identify refusal.
			error(`[FAIL] Linux network runtime ${phase.name}: completed execution receipt refused.`);
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
