// tools/test/test-ahk-smoke-input-quarantine.cjs

/**
 * ==============================================================================
 * MODULE: Startup Smoke Input Quarantine
 * DESCRIPTION:
 * Boots the real entry in smoke mode, off CI, and reads its input state: no key
 * is sent. A suspended hotkey lets its key through, and the native hook, which
 * ignores Suspend, must not start. A smoke that kept the session's keyboard beside
 * the maintainer's resident driver doubled everything he typed. A second boot
 * throws after ready and must end the process: that error once left a hooked
 * driver resident for two minutes.
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { app } = require('../lib/identifiers.cjs');
const {
	createStartupCodeFixture,
	prepareStartupPersonalInclude
} = require('./lib/ahk-startup-fixture.cjs');

const WINDOWS = path.resolve(__dirname, '../../static/ergopti_plus/windows');
const AHK = process.env.ERGOPTI_AHK_EXE || 'C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe';
const BOOT_TIMEOUT_MS = 120000;

const INSPECT = [
	'_QuarantineInspect(*) {',
	'\tglobal _DriverSmokeInputQuarantined, _LLM_NavEventOwnerStarted',
	'\tFileAppend("suspended=" . A_IsSuspended . " quarantined=" . _DriverSmokeInputQuarantined',
	'\t\t. " native_hook=" . _LLM_NavEventOwnerStarted,',
	'\t\tEnvGet("ERGOPTI_STARTUP_SMOKE_DIR") . "\\receipt.txt", "UTF-8-RAW")',
	'}',
	''
].join('\n');

const THROW = '_QuarantineThrow(*) {\n\tthrow Error("post-ready probe failure")\n}\n';

/**
 * Boots the entry once under a wrapper.
 * @param {string} base Private folder of this boot.
 * @param {string} hook Name of the ready hook.
 * @param {string} body Source of the hook.
 * @returns {{status: number|null, error: Error|undefined, stderr: string, root: string}}
 */
function boot(base, hook, body) {
	const code = createStartupCodeFixture(path.join(base, 'code'), WINDOWS);
	const root = path.join(base, 'cfg');
	const config = path.join(root, 'config');
	fs.mkdirSync(path.join(config, 'autohotkey'), { recursive: true });
	fs.copyFileSync(
		path.join(WINDOWS, '_generated/config_template.toml'),
		path.join(config, 'autohotkey/config.toml')
	);
	prepareStartupPersonalInclude(code.windows, config);
	fs.writeFileSync(
		path.join(root, 'paths.toml'),
		`ConfigDirPath = "${config.replace(/\\/g, '/')}"\n`
	);
	const wrapper = path.join(code.windows, `.ergopti_quarantine_${process.pid}.ahk`);
	fs.writeFileSync(
		wrapper,
		`\uFEFF#Requires AutoHotkey v2.0+\n_DriverStartupSmokeInspect := ${hook}\n#Include ${app.ahk}\n${body}`
	);
	try {
		const result = spawnSync(AHK, ['/ErrorStdOut', wrapper], {
			cwd: code.windows,
			windowsHide: true,
			encoding: 'utf8',
			timeout: BOOT_TIMEOUT_MS,
			env: {
				...process.env,
				CI: '',
				ERGOPTI_STARTUP_SMOKE_LIVE_INPUT: '',
				LOCALAPPDATA: root,
				ERGOPTI_STARTUP_SMOKE_DIR: root
			}
		});
		return { status: result.status, error: result.error, stderr: result.stderr, root };
	} finally {
		code.close();
	}
}

if (process.platform !== 'win32' || !fs.existsSync(AHK)) {
	console.log('Smoke input quarantine: skipped, this needs AutoHotkey on Windows.');
	process.exit(0);
}

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-quarantine-'));
try {
	const ready = boot(path.join(scratch, 'ready'), '_QuarantineInspect', INSPECT);
	assert.equal(ready.status, 0, `the quarantined smoke must boot to ready: ${ready.stderr}`);
	assert.equal(
		fs.readFileSync(path.join(ready.root, 'receipt.txt'), 'utf8'),
		'suspended=1 quarantined=1 native_hook=0',
		'an interactive smoke must own no input'
	);

	const failing = boot(path.join(scratch, 'failing'), '_QuarantineThrow', THROW);
	assert.equal(
		failing.error,
		undefined,
		'an error after ready must end the smoke, not leave it resident'
	);
	assert.equal(failing.status, 1, 'an error after ready must fail the smoke');
	console.log('Smoke input quarantine: passed.');
} finally {
	fs.rmSync(scratch, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
}
