// tools/test/test-ahk-startup-smoke-readiness.cjs

/** Proves actual full-startup admission with inert launches and owned disk receipts. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');

const ROOT = path.resolve(__dirname, '../..');
const OWNER = 'tools/test/test-ahk-full-startup-smoke.cjs';
const SLOTS = [
	'script_altgr_enter',
	'script_altgr_backspace',
	'script_altgr_delete',
	'script_altgr_escape'
];

/** Runs the complete real JS admission flow; no AHK or native process is started. */
async function observe(source, root, scenario) {
	const owned = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-startup-admission-'));
	const anchor = fs.realpathSync(owned);
	const diagnostics = [];
	let warmCalls = 0;
	let initialReceipt;
	let initialNonce;
	let launchPid = 21000;
	const ending = 'main().then(';
	assert.equal(source.split(ending).length, 2, 'the actual startup main must have one invocation');
	const executable = source.slice(0, source.indexOf(ending)) + '\nglobalThis.bootMain = main;\n';
	try {
		const context = vm.createContext({
			__dirname: path.join(root, 'tools/test'),
			process: { platform: 'win32', pid: 20000, env: { ERGOPTI_AHK_EXE: process.execPath } },
			Buffer,
			setImmediate,
			console: {
				log: (...items) => diagnostics.push(items.join(' ')),
				error: (...items) => diagnostics.push(items.join(' '))
			},
			require(name) {
				if (name === 'os') return { ...os, tmpdir: () => owned };
				if (name === './lib/ahk-startup-fixture.cjs')
					return {
						createStartupCodeFixture(container) {
							const windows = path.join(container, 'static/ergopti_plus/windows');
							fs.mkdirSync(path.join(windows, '_generated'), { recursive: true });
							return { windows, close() {} };
						},
						prepareStartupPersonalInclude(windows) {
							fs.writeFileSync(path.join(windows, '_generated/personal_shortcuts.ahk'), 'inert');
						}
					};
				if (name === 'child_process')
					return {
						spawnSync(binary, args, options) {
							assert.equal(binary, process.execPath, 'only the inert recording port is available');
							assert.equal(args[0], '/ErrorStdOut');
							assert.equal(fs.existsSync(args[1]), true, 'the actual wrapper was written');
							const probe = options.env.ERGOPTI_STARTUP_SMOKE_DIR;
							assert.equal(path.relative(anchor, fs.realpathSync(probe)).startsWith('..'), false);
							const fixture = path.basename(probe);
							const warm = fixture === 'fresh-config' && initialReceipt !== undefined;
							if (warm) warmCalls++;
							const pid = ++launchPid;
							const result = { pid, status: 0, stdout: '', stderr: '' };
							if (warm && scenario === 'early-exit') return result;
							if (warm && scenario === 'nonzero-exit') return { ...result, status: 7 };
							if (!warm && scenario === 'first-early-exit') return result;
							fs.writeFileSync(path.join(probe, 'startup-pump.txt'), 'pumped');
							fs.writeFileSync(path.join(probe, 'tray-shell.txt'), 'ready');
							let running = SLOTS;
							if (fixture === 'script-chords-off') running = [];
							if (fixture === 'script-chord-none') running = SLOTS.slice(1);
							fs.writeFileSync(
								path.join(probe, 'script-chords.txt'),
								SLOTS.flatMap((slot) =>
									[0, 1, 2].map(
										(criterion) => `${criterion}|${slot}|1|${Number(running.includes(slot))}`
									)
								).join('\n') + '\n'
							);
							if (fixture.startsWith('extension-'))
								fs.writeFileSync(
									path.join(probe, 'extension-receipt.txt'),
									[
										fixture !== 'extension-neutral',
										fixture !== 'extension-neutral',
										fixture === 'extension-enabled',
										false
									]
										.map(Number)
										.join('|')
								);
							if (fixture === 'suspend-marker')
								fs.unlinkSync(path.join(probe, 'suspend_restore.marker'));
							const logs = path.join(probe, 'ergopti_plus/logs');
							fs.mkdirSync(logs, { recursive: true });
							fs.writeFileSync(
								path.join(logs, 'ErgoptiPlus_20261004.log'),
								warm && scenario === 'logged-error'
									? '[ERROR] inert warm failure\n'
									: '[INFO] inert ready\n'
							);
							const receipt = {
								schema_version: 1,
								nonce: options.env.ERGOPTI_STARTUP_SMOKE_NONCE,
								pid,
								executable: binary,
								compiled: false,
								build_commit: '__COMMIT__',
								bundle_identity: '__VERSION__\n__COMMIT__',
								phase: 'ready',
								driver_ready: true,
								menu_ready: true,
								logs_flushed: true
							};
							if (!warm && fixture === 'fresh-config') {
								initialReceipt = { ...receipt };
								initialNonce = receipt.nonce;
							}
							if (warm && scenario === 'ready' && receipt.nonce !== undefined)
								assert.notEqual(receipt.nonce, initialNonce, 'warm startup requires its own nonce');
							if (warm && scenario === 'foreign-pid') receipt.pid = initialReceipt.pid;
							if (warm && scenario === 'foreign-nonce') receipt.nonce = 'f'.repeat(32);
							if (warm && scenario === 'incomplete') receipt.logs_flushed = false;
							if (receipt.nonce !== undefined)
								fs.writeFileSync(
									path.join(probe, 'ready.json'),
									warm && scenario === 'malformed'
										? '{'
										: JSON.stringify(warm && scenario === 'stale' ? initialReceipt : receipt),
									{ flag: 'wx' }
								);
							return result;
						}
					};
				assert.ok(['fs', 'path', 'node:crypto'].includes(name), 'unexpected dependency: ' + name);
				return require(name);
			}
		});
		vm.runInContext(executable, context, { filename: OWNER });
		const status = await context.bootMain();
		return { status, warmCalls, diagnostics };
	} finally {
		assert.equal(
			fs.realpathSync(owned),
			anchor,
			'the owned fixture root identity must remain unchanged'
		);
		fs.rmSync(owned, { recursive: true, maxRetries: 5, retryDelay: 100 });
	}
}

async function check(source, root = ROOT) {
	const observations = [];
	for (const scenario of [
		'early-exit',
		'stale',
		'foreign-pid',
		'foreign-nonce',
		'incomplete',
		'malformed',
		'logged-error',
		'nonzero-exit',
		'first-early-exit',
		'ready'
	]) {
		const result = await observe(source, root, scenario);
		observations.push({ scenario, ...result });
		assert.equal(
			result.status,
			scenario === 'ready' ? 0 : 1,
			scenario + ': the actual smoke admission must require fresh complete readiness'
		);
		assert.equal(
			result.warmCalls,
			scenario === 'first-early-exit' ? 0 : 1,
			scenario + ': the intended real runner branch must execute'
		);
		if (scenario === 'early-exit')
			assert.match(result.diagnostics.join('\n'), /reloaded-config:.*no fresh readiness/);
		if (scenario === 'logged-error')
			assert.match(result.diagnostics.join('\n'), /reloaded-config reached ready with 1 error/);
	}
	return observations;
}

if (require.main === module)
	check(fs.readFileSync(path.join(ROOT, OWNER), 'utf8')).then(
		() =>
			console.log(
				'[OK] Ten inert actual startup admission cases reject stale or incomplete warm readiness.'
			),
		(error) => {
			console.error(error);
			process.exitCode = 1;
		}
	);

module.exports = { check, observe };
