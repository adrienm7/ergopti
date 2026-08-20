// tools/test/test-ahk-full-startup-smoke.cjs

/**
 * ==============================================================================
 * MODULE: Full AutoHotkey Startup Smoke
 * DESCRIPTION:
 * Executes the real ErgoptiPlus.ahk auto-execute path in a separate process,
 * with a unique wrapper identity and isolated configuration directory. The
 * driver exits itself only after publishing ready, so any load-order/runtime
 * startup exception becomes this test's non-zero child exit.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const WINDOWS = path.join(ROOT, 'static', 'ergopti_plus', 'windows');
const ENTRY = path.join(WINDOWS, 'ErgoptiPlus.ahk');
const AHK_CANDIDATES = [
	'C:\\Program Files\\AutoHotkey\\v2\\AutoHotkey64.exe',
	'C:\\Program Files\\AutoHotkey\\v2\\AutoHotkey.exe',
	'C:\\Program Files (x86)\\AutoHotkey\\v2\\AutoHotkey.exe',
];

function fail(message) {
	console.error(`\x1b[31m[ERROR] full AHK startup smoke: ${message}\x1b[0m`);
	return 1;
}

function logTail(configRoot) {
	const logs = path.join(configRoot, 'config', 'autohotkey', 'logs');
	if (!fs.existsSync(logs)) return '';
	const files = fs.readdirSync(logs)
		.filter((name) => name.includes('errors_') || /^ErgoptiPlus_\d/.test(name))
		.map((name) => path.join(logs, name));
	return files.map((file) => {
		const lines = fs.readFileSync(file, 'utf8').trim().split(/\r?\n/).slice(-12);
		return `${path.basename(file)}:\n${lines.join('\n')}`;
	}).join('\n');
}

function main() {
	if (process.platform !== 'win32') {
		console.log('\x1b[33m[SKIP] full AHK startup smoke — AutoHotkey is Windows-only.\x1b[0m');
		return 0;
	}
	const ahk = AHK_CANDIDATES.find((candidate) => fs.existsSync(candidate));
	if (!ahk) {
		console.log('\x1b[33m[SKIP] full AHK startup smoke — AutoHotkey v2 is not installed.\x1b[0m');
		return 0;
	}
	if (!fs.existsSync(ENTRY)) return fail(`entry point missing: ${ENTRY}`);

	const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-full-startup-'));
	const wrapper = path.join(WINDOWS, `.ergopti_startup_smoke_${process.pid}.ahk`);
	try {
		// Keeping the wrapper beside ErgoptiPlus.ahk preserves A_ScriptDir and every
		// relative #Include, while its unique filename prevents #SingleInstance Force
		// from replacing a maintainer's live driver.
		fs.writeFileSync(wrapper,
			'\uFEFF#Requires AutoHotkey v2.0+\n#Include ErgoptiPlus.ahk\n', 'utf8');
		for (const fixture of ['fresh-config', 'existing-config']) {
			const configRoot = path.join(scratch, fixture);
			fs.mkdirSync(configRoot, { recursive: true });
			const result = spawnSync(ahk, ['/ErrorStdOut', wrapper], {
				cwd: WINDOWS,
				encoding: 'utf8',
				timeout: 120000,
				env: { ...process.env, ERGOPTI_STARTUP_SMOKE_DIR: configRoot },
			});
			if (result.error) return fail(`${fixture}: ${result.error.message}`);
			if (result.status !== 0) {
				const output = `${result.stdout || ''}${result.stderr || ''}`.trim();
				const logs = logTail(configRoot);
				return fail(`${fixture} exited ${result.status}.${output ? `\n${output}` : ''}${logs ? `\n${logs}` : ''}`);
			}
			// Reuse the first fixture once so the no-bootstrap path is exercised too.
			if (fixture === 'fresh-config') {
				const second = spawnSync(ahk, ['/ErrorStdOut', wrapper], {
					cwd: WINDOWS,
					encoding: 'utf8',
					timeout: 120000,
					env: { ...process.env, ERGOPTI_STARTUP_SMOKE_DIR: configRoot },
				});
				if (second.error || second.status !== 0) {
					const output = `${second.stdout || ''}${second.stderr || ''}`.trim();
					const logs = logTail(configRoot);
					return fail(`reloaded-config exited ${second.status}.${output ? `\n${output}` : ''}${logs ? `\n${logs}` : ''}`);
				}
			}
		}
		console.log('\x1b[32m[OK] full AHK startup smoke: fresh, reloaded, and independent config boots reached ready.\x1b[0m');
		return 0;
	} finally {
		fs.rmSync(wrapper, { force: true });
		fs.rmSync(scratch, { recursive: true, force: true });
	}
}

process.exit(main());
