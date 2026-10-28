// tools/test/test-windows-dev-script.cjs

/**
 * ==============================================================================
 * MODULE: Windows Developer Driver Runner Tests
 * DESCRIPTION:
 * tools/dev/run-windows-dev.ps1 starts ErgoptiPlus.ahk from this clone with
 * AutoHotkey v2 and names the clone in the shared developer variable, which
 * infra/dev_source.ahk checks. Actual PowerShell AST selection runs against real
 * private files on every host. Entry-body controls observe only process effects;
 * non-Windows hosts omit the unique platform guard in a private copy. Windows
 * executes the complete unmodified entry with Windows PowerShell 5.1. No installed
 * app is closed or launched, and explicit choices must never fall back.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
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

const interpreter =
	process.platform === 'win32'
		? path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
		: 'pwsh';
const fixture = path.join(ROOT, 'tools/test/fixtures/windows_dev_interpreter_controls.ps1');
const version = spawnSync(
	interpreter,
	['-NoProfile', '-NonInteractive', '-Command', '$PSVersionTable.PSVersion.ToString()'],
	{ encoding: 'utf8', timeout: 10000, windowsHide: true }
);
assert.ifError(version.error);
assert.equal(version.status, 0, version.stdout + version.stderr);
const versionText = version.stdout.trim();
assert.match(
	versionText,
	/^\d+\.\d+\.\d+(?:\.\d+)?$/,
	'an actual PowerShell must answer its full version'
);
assert.ok(Number.parseInt(versionText, 10) >= 5, 'the fixture needs a supported PowerShell parser');
if (process.platform === 'win32')
	assert.match(versionText, /^5\.1\./, 'native entry controls qualify Windows PowerShell 5.1');
console.log(`[runtime] PowerShell ${versionText}`);
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-windows-dev-runner-'));
let nativeEntryCases = 0;
let hostEntryBodyCases = 0;

/** Execute the actual checked script against one private filesystem. */
function runFixture(mode, directory, scenario = '') {
	fs.mkdirSync(directory, { recursive: true });
	const result = spawnSync(
		interpreter,
		[
			'-NoProfile',
			'-NonInteractive',
			'-ExecutionPolicy',
			'Bypass',
			'-File',
			fixture,
			'-Mode',
			mode,
			'-Launcher',
			SCRIPT,
			'-Scratch',
			directory,
			'-Case',
			scenario
		],
		{ encoding: 'utf8', timeout: 30000, windowsHide: true }
	);
	assert.ifError(result.error);
	assert.equal(result.signal, null, 'the actual child must settle within its bound');
	return result;
}

try {
	const selectionDirectory = path.join(scratch, 'selection');
	const selected = runFixture('selection', selectionDirectory);
	assert.equal(selected.status, 0, selected.stdout + selected.stderr);
	const rows = JSON.parse(fs.readFileSync(path.join(selectionDirectory, 'selection.json'), 'utf8'));
	assert.deepEqual(
		rows.map((row) => row.name),
		[
			'default-machine',
			'default-user',
			'explicit-existing',
			'explicit-missing',
			'explicit-directory'
		],
		'every real candidate-selection case must execute in order'
	);
	for (const row of rows)
		check(`actual interpreter selection: ${row.name}`, () => {
			assert.equal(row.passed, true, JSON.stringify(rows));
			assert.equal(row.refused, row.expected_refusal, JSON.stringify(row));
			assert.equal(row.selected, row.expected_refusal ? null : row.expected, JSON.stringify(row));
		});
	{
		for (const scenario of [
			'default-machine',
			'default-user',
			'explicit-existing',
			'explicit-missing',
			'explicit-directory',
			'environment-existing',
			'environment-missing',
			'default-none'
		])
			check(
				`${process.platform === 'win32' ? 'native complete' : 'host body'} developer launcher: ${scenario}`,
				() => {
					const directory = path.join(scratch, scenario);
					const result = runFixture(
						process.platform === 'win32' ? 'entry' : 'host-entry',
						directory,
						scenario
					);
					const refused = [
						'explicit-missing',
						'explicit-directory',
						'environment-missing',
						'default-none'
					].includes(scenario);
					assert.equal(result.status, refused ? 1 : 0, result.stdout + result.stderr);
					const receiptPath = path.join(directory, 'launch.json');
					const effectsPath = path.join(directory, 'effects.txt');
					if (refused) {
						assert.equal(fs.existsSync(receiptPath), false, 'refusal precedes any process launch');
						assert.equal(
							fs.existsSync(effectsPath),
							false,
							'refusal precedes discovery of running apps'
						);
						assert.match(result.stderr, /AutoHotkey v2 .*not found/);
					} else {
						const receipt = JSON.parse(fs.readFileSync(receiptPath, 'utf8'));
						const clone = path.join(directory, 'clone space é');
						const driver = path.join(clone, 'static/ergopti_plus/windows');
						const expected = ['explicit-existing', 'environment-existing'].includes(scenario)
							? path.join(directory, 'requested interpreter.exe')
							: scenario === 'default-user'
								? path.join(directory, 'local-appdata/Programs/AutoHotkey/v2/AutoHotkey64.exe')
								: path.join(directory, 'program-files/AutoHotkey/v2/AutoHotkey64.exe');
						assert.equal(receipt.interpreter, expected);
						assert.equal(receipt.working_directory, driver);
						assert.equal(receipt.developer_root, clone);
						assert.deepEqual(receipt.arguments, [`"${path.join(driver, IDENTIFIERS.app.ahk)}"`]);
						assert.equal(
							fs.readFileSync(effectsPath, 'utf8'),
							`observe:${IDENTIFIERS.app.name}${process.platform === 'win32' ? '\r\n' : '\n'}`
						);
					}
					if (process.platform === 'win32') nativeEntryCases++;
					else hostEntryBodyCases++;
				}
			);
	}
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}
console.log(
	`[OK] Windows developer driver runner (${checks} checks; native_entry_cases=${nativeEntryCases}; host_entry_body_cases=${hostEntryBodyCases}).`
);
