// tools/test/test-windows-dev-script.cjs

/**
 * ==============================================================================
 * MODULE: Windows Developer Driver Runner Tests
 * DESCRIPTION:
 * tools/dev/run-windows-dev.ps1 starts ErgoptiPlus.ahk from this clone with
 * AutoHotkey v2 and names the clone in the shared developer variable, which
 * infra/dev_source.ahk checks. This host has no PowerShell, so the contract is
 * read from the script: the variable comes from identifiers.json and never as a
 * literal, the entry point and the x64 interpreter are the built exe's, and a
 * running ErgoptiPlus is asked to close, never killed. When pwsh is on PATH
 * the script is also parsed.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const SCRIPT = path.join(ROOT, 'tools/dev/run-windows-dev.ps1');
const IDENTIFIERS = JSON.parse(
	fs.readFileSync(path.join(ROOT, 'static/ergopti_plus/_shared/data/identifiers.json'), 'utf8')
);
const source = fs.readFileSync(SCRIPT, 'utf8');
let checks = 0;

function check(name, body) {
	body();
	checks++;
	console.log(`PASS ${name}`);
}

check('reads the developer variable from the shared identifiers', () => {
	assert.match(source, /_shared\\data\\identifiers\.json/);
	assert.match(source, /\$Identifiers\.dev_source\.environment/);
	assert.ok(
		!source.includes(IDENTIFIERS.dev_source.environment),
		'the variable name must not be a second literal'
	);
});

check("starts the clone's ErgoptiPlus.ahk with AutoHotkey v2 x64", () => {
	assert.match(source, /'static\\ergopti_plus\\windows'/);
	assert.match(source, /Join-Path \$DriverDir \$Identifiers\.app\.ahk/);
	assert.match(source, /AutoHotkey\\v2\\AutoHotkey64\.exe/);
	assert.match(source, /Start-Process -FilePath \$Interpreter/);
});

check('asks a running ErgoptiPlus to close and never forces it', () => {
	assert.match(source, /taskkill\.exe \/IM \$Identifiers\.app\.exe/);
	assert.doesNotMatch(source, /taskkill[^\n]*\/F\b/i);
	assert.doesNotMatch(source, /Stop-Process/);
});

check('the driver reads the same variable name it is handed', () => {
	const driver = fs.readFileSync(
		path.join(ROOT, 'static/ergopti_plus/windows/infra/dev_source.ahk'),
		'utf8'
	);
	assert.match(driver, /Data\["dev_source"\]\["environment"\]/);
});

const pwsh = spawnSync('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major'], {
	encoding: 'utf8'
});
if (pwsh.status === 0) {
	check('parses under PowerShell', () => {
		const parsed = spawnSync(
			'pwsh',
			[
				'-NoProfile',
				'-Command',
				`$t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile('${SCRIPT}',[ref]$t,[ref]$e);exit $e.Count`
			],
			{ encoding: 'utf8' }
		);
		assert.equal(parsed.status, 0, parsed.stdout + parsed.stderr);
	});
} else {
	console.log('[SKIP] PowerShell parse: pwsh is not on PATH.');
}
console.log(`[OK] Windows developer driver runner (${checks} checks).`);
