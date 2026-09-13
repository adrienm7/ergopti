// tools/test/test-verify-change-ahk-launch.cjs

/**
 * Native gate parse failures must reach the terminal without a blocking dialog.
 * Exercise both production launch branches before replaying their arguments
 * against small native scripts; never launch the bad fixture without the flag.
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const { spawnSync } = require('node:child_process');

const source = path.join(__dirname, 'verify-change.cjs');
const originalRequire = createRequire(source);
const calls = [];
const output = [];
let status = 2;
const context = vm.createContext({
	module: { exports: {} }, __dirname, process,
	console: { log: (line) => output.push(line), error: (line) => output.push(line) },
	require(name) {
		if (name === 'node:fs') return {
			...fs, existsSync: () => true,
			readFileSync: () => { throw new Error('No manifest after fixture parse failure.'); },
			rmSync: () => {},
		};
		if (name === 'node:child_process') return {
			spawnSync: (command, args, options) => {
				calls.push({ command, args: Array.from(args), options });
				return { status };
			},
		};
		return originalRequire(name);
	},
});
vm.runInContext(fs.readFileSync(source, 'utf8'), context, { filename: source });
for (const gate of ['ahk-suite', 'ahk-e2e']) {
	assert.equal(context.runGate(gate).status, 2, 'native parse failure must remain a gate failure');
	const call = calls.at(-1);
	assert.deepEqual(call.args, ['/ErrorStdOut', gate === 'ahk-suite' ? 'run_all.ahk' : 'e2e/run_e2e.ahk'],
		`${gate} must redirect parser diagnostics before the script argument`);
	assert.equal(call.options.windowsHide, true, `${gate} must launch hidden`);
	assert.equal(call.options.stdio, 'inherit', 'native diagnostics must reach the gate receipt');
}
status = 0;
assert.equal(context.runGate('ahk-suite').status, 1, 'a zero exit without a manifest must still fail');
assert.equal(context.runGate('ahk-e2e').status, 0, 'normal E2E completion must remain successful');

const nativeCalls = calls.slice(0, 2);
if (process.platform === 'win32' && fs.existsSync(nativeCalls[0].command)) {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-ahk-launch-'));
	try {
		for (const [name, body, expected] of [
			['valid.ahk', '#Requires AutoHotkey v2.0\nExitApp(0)\n', 0],
			['invalid.ahk', '#Requires AutoHotkey v2.0\nCase := 1\n', 2],
		]) {
			const script = path.join(root, name);
			fs.writeFileSync(script, '\uFEFF' + body, 'utf8');
			for (const call of nativeCalls) {
				const result = spawnSync(call.command, [...call.args.slice(0, -1), script], {
					...call.options, stdio: 'pipe', encoding: 'utf8', timeout: 5000,
				});
				assert.equal(result.error, undefined, 'a parse failure must exit without waiting for user input');
				assert.equal(result.status, expected, result.stdout + result.stderr);
				if (expected) assert.match(result.stdout + result.stderr, /reserved word/i);
			}
		}
	} finally {
		fs.rmSync(root, { recursive: true, force: true });
	}
} else {
	console.log('Native AHK launch replay unavailable; launch and failure contracts exercised with receipts.');
}
console.log('verify-change AHK launch: hidden parser failure and normal completion passed.');
