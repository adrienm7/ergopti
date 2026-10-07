// tools/test/test-ahk-full-startup-smoke.cjs

/**
 * ==============================================================================
 * MODULE: Full AutoHotkey Startup Smoke
 * DESCRIPTION:
 * Executes the real ErgoptiPlus.ahk auto-execute path in a separate process,
 * with a unique wrapper identity and isolated configuration directory. The
 * driver exits itself only after publishing ready, so any load-order/runtime
 * startup exception becomes this test's non-zero child exit.
 *
 * FEATURES & RATIONALE:
 * 1. hardening-a-startup-zero-error: a boot that reaches ready may still have
 *    logged an ERROR, which opens the error window for the user. Every boot's
 *    logs must hold no ERROR or FATAL line and no suppressed error window.
 * 2. User states: a fresh folder, the neutral defaults the wizard writes, and
 *    config.toml files older releases wrote (the shared migration corpus).
 * 3. CI runs it in the Windows unit job with ERGOPTI_AHK_EXE set, which turns
 *    a missing interpreter into a failure instead of a skip.
 * 4. script-chords-switch-2026-09-30: after ready, every script chord of
 *    ScriptAltGrChordPlan exists under its criterion, and its slot runs an
 *    action in every configuration that does not switch it off: the four
 *    AltGr chords start on, a stored "none" keeps one off and the submenu's
 *    switch off leaves them all to the system.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync, spawn } = require('child_process');
const {
	launchNaturalExit,
	naturalExitReceiptProblem
} = require('./lib/ahk-startup-natural-exit.cjs');
const crypto = require('node:crypto');
const {
	createStartupCodeFixture,
	prepareStartupPersonalInclude
} = require('./lib/ahk-startup-fixture.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const WINDOWS = path.join(ROOT, 'static', 'ergopti_plus', 'windows');
const ENTRY = path.join(WINDOWS, 'ErgoptiPlus.ahk');
const CORPUS = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'tests',
	'corpus',
	'config_migrations'
);
// config.toml files seeded before the boot: the wizard's neutral defaults, and
// every file an older Windows release wrote (the shipped cases of the shared
// migration corpus, found by name so a new case boots without an edit here).
const SEEDED_CONFIGS = {
	'neutral-defaults': path.join(WINDOWS, '_generated', 'config_template.toml')
};
for (const name of fs.readdirSync(CORPUS).sort()) {
	if (/^shipped_.+_on_windows(_and_linux)?$/.test(name)) {
		SEEDED_CONFIGS[`older-release-${name}`] = path.join(CORPUS, name, 'input.toml');
	}
}
// config.toml files that change the script chords, and the slots each leaves
// running (every other fixture runs all four: they start with their preset).
const SCRIPT_CHORD_SLOTS = [
	'script_altgr_enter',
	'script_altgr_backspace',
	'script_altgr_delete',
	'script_altgr_escape'
];
const CHORD_CONFIGS = {
	'script-chords-off': {
		toml: '[shortcuts.script_control]\nchords_enabled = false\n',
		running: []
	},
	'script-chord-none': {
		toml: '[shortcuts.script_control]\nscript_altgr_enter = "none"\n',
		running: SCRIPT_CHORD_SLOTS.filter((slot) => slot !== 'script_altgr_enter')
	}
};
if (Object.keys(SEEDED_CONFIGS).length < 4) {
	throw new Error(
		'full AHK startup smoke: the migration corpus holds fewer than three Windows releases'
	);
}
const AHK_CANDIDATES = [
	'C:\\Program Files\\AutoHotkey\\v2\\AutoHotkey64.exe',
	'C:\\Program Files\\AutoHotkey\\v2\\AutoHotkey.exe',
	'C:\\Program Files (x86)\\AutoHotkey\\v2\\AutoHotkey.exe'
];

function fail(message) {
	console.error(`\x1b[31m[ERROR] full AHK startup smoke: ${message}\x1b[0m`);
	return 1;
}

/**
 * Every line of a boot's logs a user would have been shown as an error.
 * @param {string} configRoot
 * @returns {string[]}
 */
function loggedErrors(configRoot) {
	const logs = path.join(configRoot, 'ergopti_plus', 'logs');
	if (!fs.existsSync(logs)) return [];
	const found = [];
	for (const name of fs.readdirSync(logs)) {
		const file = path.join(logs, name);
		// ErgoptiPlus_errors_*.log repeats every WARNING and ERROR of the main log.
		if (!name.endsWith('.log') || name.includes('errors_') || !fs.statSync(file).isFile()) continue;
		for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
			if (/\[(ERROR|FATAL)\]/.test(line) || line.includes('the error window for')) {
				found.push(`${name}: ${line.trim()}`);
			}
		}
	}
	return found;
}

/**
 * Fails a boot that reached ready with an error logged (hardening-a).
 * @param {string} label
 * @param {string} configRoot
 * @returns {number|null} exit code, or null when the logs are clean
 */
function failOnLoggedErrors(label, configRoot) {
	const errors = loggedErrors(configRoot);
	if (errors.length === 0) return null;
	return fail(
		`${label} reached ready with ${errors.length} error line(s):\n${errors.slice(0, 12).join('\n')}`
	);
}

/**
 * Checks the script-chord receipt a ready boot wrote: every hotkey of the plan
 * exists under its criterion, and exactly the expected slots run an action.
 * @param {string} configRoot
 * @param {string[]|null} running Slots expected to run, or null to skip that part.
 * @returns {string|null} The problem, or null when the receipt holds.
 */
function scriptChordReceiptProblem(configRoot, running) {
	const receipt = path.join(configRoot, 'script-chords.txt');
	if (!fs.existsSync(receipt)) return 'the boot wrote no script-chord receipt';
	const rows = fs
		.readFileSync(receipt, 'utf8')
		.replace(/^\uFEFF/, '')
		.split(/\r?\n/)
		.filter(Boolean)
		.map((line) => line.split('|'));
	if (rows.length !== 3 * SCRIPT_CHORD_SLOTS.length)
		return `expected ${3 * SCRIPT_CHORD_SLOTS.length} script chord hotkeys, the plan registered ${rows.length}`;
	const missing = rows.filter((row) => row[2] !== '1');
	if (missing.length > 0)
		return `script chords not registered: ${missing.map((r) => r.join('|')).join(', ')}`;
	if (running === null) return null;
	for (const [hotkey, slot, , runs] of rows) {
		const expected = running.includes(slot) ? '1' : '0';
		if (runs !== expected)
			return `${hotkey} (${slot}) runs=${runs}, expected ${expected}: the chord ${expected === '1' ? 'must run its preset' : 'must stay with the system'}`;
	}
	return null;
}

/**
 * Checks the existing native startup publisher's fresh source-process receipt.
 * @param {string} configRoot Exclusive smoke directory.
 * @param {number} pid Native PID returned by the synchronous launcher.
 * @param {string} nonce Current launch's private nonce.
 * @param {string} ahk Selected interpreter.
 * @returns {string|null} Refusal reason, or null for complete source readiness.
 */
function startupReceiptProblem(configRoot, pid, nonce, ahk) {
	const file = path.join(configRoot, 'ready.json');
	if (!fs.existsSync(file)) return 'the boot published no fresh readiness receipt';
	let receipt;
	try {
		receipt = JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
	} catch (error) {
		return 'the readiness receipt cannot be read: ' + error.message;
	}
	if (
		!receipt ||
		typeof receipt !== 'object' ||
		Array.isArray(receipt) ||
		Object.keys(receipt).sort().join('|') !==
			[
				'schema_version',
				'nonce',
				'pid',
				'executable',
				'compiled',
				'build_commit',
				'bundle_identity',
				'phase',
				'driver_ready',
				'menu_ready',
				'logs_flushed'
			]
				.sort()
				.join('|') ||
		receipt.schema_version !== 1 ||
		receipt.nonce !== nonce ||
		!Number.isSafeInteger(pid) ||
		pid <= 0 ||
		receipt.pid !== pid ||
		receipt.compiled !== false ||
		receipt.phase !== 'ready' ||
		receipt.driver_ready !== true ||
		receipt.menu_ready !== true ||
		receipt.logs_flushed !== true ||
		typeof receipt.executable !== 'string' ||
		path.win32.normalize(receipt.executable).toLowerCase() !==
			path.win32.normalize(path.resolve(ahk)).toLowerCase()
	)
		return 'the readiness receipt is foreign or incomplete';
	return null;
}

/**
 * Requires a committed existing full-save generation from this exact launch.
 * @param {string} configRoot Exclusive smoke directory.
 * @param {number} pid Launched native PID.
 * @param {string} nonce Current launch nonce, including warm reloads.
 * @returns {string|null} Refusal reason, or null for a committed generation.
 */
function fullSaveReceiptProblem(configRoot, pid, nonce) {
	const file = path.join(configRoot, 'full-save.json');
	if (!fs.existsSync(file)) return 'the boot published no fresh full-save receipt';
	let receipt;
	try {
		receipt = JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
	} catch (error) {
		return 'the full-save receipt cannot be read: ' + error.message;
	}
	if (
		!receipt ||
		typeof receipt !== 'object' ||
		Array.isArray(receipt) ||
		Object.keys(receipt).sort().join('|') !==
			['schema_version', 'nonce', 'pid', 'requested', 'committed', 'settled', 'pending']
				.sort()
				.join('|') ||
		receipt.schema_version !== 1 ||
		!/^[0-9a-f]{32}$/.test(nonce) ||
		receipt.nonce !== nonce ||
		!Number.isSafeInteger(pid) ||
		pid <= 0 ||
		receipt.pid !== pid ||
		!Number.isSafeInteger(receipt.requested) ||
		receipt.requested <= 0 ||
		!Number.isSafeInteger(receipt.committed) ||
		receipt.committed < receipt.requested ||
		!Number.isSafeInteger(receipt.settled) ||
		receipt.settled < receipt.requested ||
		receipt.pending !== false
	)
		return 'the full-save receipt is foreign or its generation is not committed';
	return null;
}

function logTail(configRoot) {
	// Under the smoke, boot puts the default logs folder at
	// <smoke dir>\<AppDirsWindowsLogsRelative()>.
	const logs = path.join(configRoot, 'ergopti_plus', 'logs');
	if (!fs.existsSync(logs)) return '';
	const files = fs
		.readdirSync(logs)
		.filter((name) => name.includes('errors_') || /^ErgoptiPlus_\d/.test(name))
		.map((name) => path.join(logs, name));
	return files
		.map((file) => {
			const lines = fs.readFileSync(file, 'utf8').trim().split(/\r?\n/).slice(-12);
			return `${path.basename(file)}:\n${lines.join('\n')}`;
		})
		.join('\n');
}

async function main() {
	if (process.platform !== 'win32') {
		console.log('\x1b[33m[SKIP] full AHK startup smoke — AutoHotkey is Windows-only.\x1b[0m');
		return 0;
	}
	// CI names its interpreter: a missing one there is a failure, not a skip.
	const named = process.env.ERGOPTI_AHK_EXE || '';
	if (named && !fs.existsSync(named))
		return fail(`ERGOPTI_AHK_EXE names a missing interpreter: ${named}`);
	const ahk = named || AHK_CANDIDATES.find((candidate) => fs.existsSync(candidate));
	if (!ahk) {
		console.log('\x1b[33m[SKIP] full AHK startup smoke — AutoHotkey v2 is not installed.\x1b[0m');
		return 0;
	}
	if (!fs.existsSync(ENTRY)) return fail(`entry point missing: ${ENTRY}`);

	const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-full-startup-'));
	const productionForwarder = path.join(WINDOWS, '_generated/personal_shortcuts.ahk');
	const originalForwarder = fs.existsSync(productionForwarder)
		? fs.readFileSync(productionForwarder)
		: null;
	const code = createStartupCodeFixture(path.join(scratch, 'code'), WINDOWS);
	const wrapper = path.join(code.windows, `.ergopti_startup_smoke_${process.pid}.ahk`);
	let startupSucceeded = false;
	try {
		// The private entry preserves relative includes without sharing writable
		// generated code. Its identity cannot replace the maintainer's live driver.
		fs.writeFileSync(
			wrapper,
			'\uFEFF#Requires AutoHotkey v2.0+\n_DriverStartupSmokeInspect := _StartupSmokeReceipts\n_DriverStartupSmokeInspectShell := _StartupSmokeShellReceipt\n_DriverStartupSmokeInspectAdmission := _StartupSmokeAdmissionReceipt\n_DriverStartupSmokeInspectBootstrap := _StartupSmokeEarlyClick\n#Include ErgoptiPlus.ahk\n' +
				'_StartupSmokeEarlyClick(*) {\n\tglobal _TrayStartupClick\n\t_TrayStartupClick.PopupFn := (*) => SetTimer(_StartupSmokePumpReceipt, -1)\n\tPostMessage(0x404, 0, 0x205, , A_ScriptHwnd)\n}\n' +
				'_StartupSmokePumpReceipt(*) {\n\tglobal _TrayStartupClick, _DriverReady\n\tif !_TrayStartupClick.Pending || (IsSet(_DriverReady) && _DriverReady) || _TrayStartupClick.MenuLoopOpen\n\t\tthrow Error("the retained probe must leave bootstrap and timers running")\n\tFileAppend("pumped", EnvGet("ERGOPTI_STARTUP_SMOKE_DIR") . "\\startup-pump.txt", "UTF-8")\n}\n' +
				'_StartupSmokeReceipts(*) {\n\t_StartupSmokeFullSaveReceipt()\n\t_ScriptChordSmokeReceipt()\n\t_LayoutExtensionSmokeReceipt()\n\tif EnvGet("ERGOPTI_STARTUP_SMOKE_NATURAL_EXIT") == "1"\n\t\t_StartupSmokeNaturalShutdown()\n}\n' +
				'_StartupSmokeShellReceipt(*) {\n\tglobal _TrayFeatureHeadLabels, _TrayRootBootDetailsPending, _TrayStartupClick, _DriverReady, _DriverMenuReady, _MenuStartupCommands\n\tif _DriverReady || !_DriverMenuReady || _TrayRootBootDetailsPending || _TrayFeatureHeadLabels.Length < 4\n\t\tthrow Error("the complete configured root must be published before input readiness")\n\tif _TrayStartupClick.RequestCount != 1\n\t\tthrow Error("the early native context request was lost")\n\tglobal _StartupSmokeSelections\n\tSelections := []\n\t_StartupSmokeSelections := Selections\n\tMenuCommandRun((*) => Selections.Push(1), [])\n\tif Selections.Length || _MenuStartupCommands.Pending.Length != 1\n\t\tthrow Error("an early feature command bypassed startup admission")\n\tRows := Map()\n\tloop TrayMenuItemCount(A_TrayMenu) {\n\t\tText := Buffer(2048, 0)\n\t\tDllCall("GetMenuStringW", "ptr", A_TrayMenu.Handle, "uint", A_Index - 1, "ptr", Text, "int", 1024, "uint", 0x400)\n\t\tRows[StrGet(Text, "UTF-16")] := DllCall("GetMenuState", "ptr", A_TrayMenu.Handle, "uint", A_Index - 1, "uint", 0x400, "uint")\n\t}\n\tif Rows.Has(t("common.loading")) || Rows.Has(t("menu.global.starting"))\n\t\tthrow Error("the usable root still advertises driver startup")\n\tfor Key in ["menu.global.suspend", "menu.global.reload", "menu.global.quit"] {\n\t\tLabel := t(Key)\n\t\tif !Rows.Has(Label) || (Rows[Label] & 3) || (Rows[Label] & 0x10)\n\t\t\tthrow Error("the configured root has no enabled command for " . Key)\n\t}\n\tFileAppend("ready", EnvGet("ERGOPTI_STARTUP_SMOKE_DIR") . "\\tray-shell.txt", "UTF-8")\n}\n' +
				'_StartupSmokeAdmissionReceipt(*) {\n\tglobal _StartupSmokeSelections\n\tExpected := EnvGet("ERGOPTI_STARTUP_SMOKE_EXPECT_SUSPENDED") == "1" ? 0 : 1\n\tStarted := A_TickCount\n\tif Expected\n\t\twhile !_StartupSmokeSelections.Length && !TickExpired(Started, 1000)\n\t\t\tSleep(10)\n\telse\n\t\tSleep(50)\n\tif _StartupSmokeSelections.Length != Expected\n\t\tthrow Error("retained startup selection did not obey restored pause or execute exactly once")\n}\n' +
				'_StartupSmokeFullSaveReceipt() {\n\tglobal DriverPid\n\t_StartupSmokeRequireFullSaveAcknowledged()\n\tSaveState := _ConfigFullSaveCoordinator()\n\tPreviousCritical := Critical("On")\n\ttry {\n\t\tRequested := SaveState.requested_generation\n\t\tCommitted := SaveState.committed_generation\n\t\tSettled := SaveState.settled_generation\n\t\tPending := _ConfigFullSaveHasPending()\n\t} finally Critical(PreviousCritical)\n\tNonce := EnvGet("ERGOPTI_STARTUP_SMOKE_NONCE")\n\tif !RegExMatch(Nonce, "^[0-9a-f]{32}$")\n\t\tthrow ValueError("Invalid startup full-save nonce.")\n\tReceipt := \'{"schema_version":1,"nonce":\' . JsonStringLiteral(Nonce)\n\t\t. \',"pid":\' . DriverPid . \',"requested":\' . Requested\n\t\t. \',"committed":\' . Committed . \',"settled":\' . Settled\n\t\t. \',"pending":\' . (Pending ? "true" : "false") . \'}\' . "`n"\n\tif !FSWriteCreateDurable(EnvGet("ERGOPTI_STARTUP_SMOKE_DIR") . "\\full-save.json", Receipt)\n\t\tthrow Error("The startup full-save receipt could not be created durably.")\n}\n' +
				'_ScriptChordSmokeReceipt() {\n' +
				'\tglobal _ScriptAltGrChordRows\n' +
				'\tLines := ""\n' +
				'\tfor Row in _ScriptAltGrChordRows {\n' +
				'\t\tHotIf(Row["criterion"])\n' +
				'\t\ttry {\n\t\t\tHotkey(Row["hotkey"], "On")\n\t\t\tRegistered := 1\n' +
				'\t\t} catch as Missing {\n\t\t\tRegistered := "0 (" . Missing.Message . ")"\n\t\t}\n' +
				'\t\tHotIf()\n' +
				'\t\tLines .= Row["hotkey"] . "|" . Row["slot"] . "|" . Registered . "|" . (ScriptShortcutSlotRunsAction(Row["slot"], false) ? 1 : 0) . "`n"\n' +
				'\t}\n' +
				'\tFileAppend(Lines, EnvGet("ERGOPTI_STARTUP_SMOKE_DIR") . "\\script-chords.txt", "UTF-8")\n}\n' +
				'_LayoutExtensionSmokeReceipt(*) {\n' +
				'\tglobal Features, HSE_RegistryByGroup\n' +
				'\tif !IsSet(Features) || !IsSet(HSE_RegistryByGroup)\n\t\treturn\n' +
				'\tDesired := MasterGateDesiredFeatures(Features)["hotstrings"]\n' +
				'\tCategory := "ext:startup_probe:words"\n' +
				'\tif !Desired.Has("groups") || !Desired["groups"].Has(Category)\n\t\treturn\n' +
				'\tState := Desired["groups"][Category] . "|" . Desired["modules"][Category]["wanted"]\n' +
				'\tState .= "|" . HSE_RegistryByGroup.Has(Category . ".wanted") . "|" . HSE_RegistryByGroup.Has(Category . ".hidden")\n' +
				'\tFileAppend(State, EnvGet("ERGOPTI_STARTUP_SMOKE_DIR") . "\\extension-receipt.txt", "UTF-8")\n}\n' +
				fs
					.readFileSync(path.join(WINDOWS, 'tests/fixtures/startup_full_save_observer.ahk'), 'utf8')
					.replace(/^\uFEFF/, '') +
				fs
					.readFileSync(
						path.join(WINDOWS, 'tests/fixtures/startup_natural_shutdown_observer.ahk'),
						'utf8'
					)
					.replace(/^\uFEFF/, ''),
			'utf8'
		);
		for (const fixture of [
			'fresh-config',
			'existing-config',
			'suspend-marker',
			'extension-neutral',
			'extension-enabled',
			'extension-master-off',
			...Object.keys(CHORD_CONFIGS),
			...Object.keys(SEEDED_CONFIGS)
		]) {
			const configRoot = path.join(scratch, fixture);
			fs.mkdirSync(configRoot, { recursive: true });
			if (SEEDED_CONFIGS[fixture]) {
				const config = path.join(configRoot, 'config', 'autohotkey');
				fs.mkdirSync(config, { recursive: true });
				fs.copyFileSync(SEEDED_CONFIGS[fixture], path.join(config, 'config.toml'));
			}
			if (CHORD_CONFIGS[fixture]) {
				const config = path.join(configRoot, 'config', 'autohotkey');
				fs.mkdirSync(config, { recursive: true });
				fs.writeFileSync(path.join(config, 'config.toml'), CHORD_CONFIGS[fixture].toml);
			}
			const extensionFixture = fixture.startsWith('extension-');
			const selected = fixture !== 'extension-neutral';
			const effective = fixture === 'extension-enabled';
			if (extensionFixture) {
				const pack = path.join(configRoot, 'config', 'extensions', 'startup_probe');
				fs.mkdirSync(path.join(pack, 'hotstrings'), { recursive: true });
				fs.writeFileSync(path.join(pack, 'manifest.toml'), '[extension]\nname = "Startup probe"\n');
				fs.writeFileSync(
					path.join(pack, 'hotstrings', 'words.toml'),
					'[[wanted]]\n"ergopti_startup_probe_wanted" = "Wanted"\n[[hidden]]\n"ergopti_startup_probe_hidden" = "Hidden"\n'
				);
				const config = path.join(configRoot, 'config', 'autohotkey');
				fs.mkdirSync(config, { recursive: true });
				fs.writeFileSync(
					path.join(config, 'config.toml'),
					'[category_enabled]\nhotstrings = ' +
						effective +
						'\n' +
						(selected
							? '[hotstrings.groups]\n"ext:startup_probe:words" = true\n' +
								'[hotstrings.modules."ext:startup_probe:words"]\nwanted = true\n'
							: '')
				);
			}
			const markerBearing = fixture === 'suspend-marker';
			const marker = path.join(configRoot, 'suspend_restore.marker');
			if (markerBearing) fs.writeFileSync(marker, '1\n', 'utf8');
			prepareStartupPersonalInclude(code.windows, path.join(configRoot, 'config'));
			const nonce = crypto.randomBytes(16).toString('hex');
			const result = spawnSync(ahk, ['/ErrorStdOut', wrapper], {
				cwd: code.windows,
				encoding: 'utf8',
				timeout: 120000,
				env: {
					...process.env,
					LOCALAPPDATA: configRoot,
					ERGOPTI_STARTUP_SMOKE_DIR: configRoot,
					ERGOPTI_STARTUP_SMOKE_NONCE: nonce,
					ERGOPTI_STARTUP_SMOKE_EXPECT_SUSPENDED: markerBearing ? '1' : ''
				}
			});
			if (result.error)
				return fail(
					`${fixture}: ${result.error.message}\n${(result.stdout || '').slice(-5000)}\n${logTail(configRoot)}`
				);
			if (result.status !== 0) {
				const output = `${result.stdout || ''}${result.stderr || ''}`.trim();
				const logs = logTail(configRoot);
				return fail(
					`${fixture} exited ${result.status}.${output ? `\n${output}` : ''}${logs ? `\n${logs}` : ''}`
				);
			}
			const readiness = startupReceiptProblem(configRoot, result.pid, nonce, ahk);
			if (readiness) return fail(fixture + ': ' + readiness);
			const fullSave = fullSaveReceiptProblem(configRoot, result.pid, nonce);
			if (fullSave) return fail(fixture + ': ' + fullSave);
			if (!fs.existsSync(path.join(configRoot, 'startup-pump.txt')))
				return fail(
					`${fixture}: timers did not progress while the headless tray request was retained`
				);
			if (!fs.existsSync(path.join(configRoot, 'tray-shell.txt')))
				return fail(
					`${fixture}: no complete configured root was published before input registration`
				);
			if (extensionFixture) {
				const receipt = path.join(configRoot, 'extension-receipt.txt');
				const expected = [selected, selected, effective, false].map(Number).join('|');
				const actual = fs.existsSync(receipt)
					? fs
							.readFileSync(receipt, 'utf8')
							.replace(/^\uFEFF/, '')
							.trim()
					: '(missing)';
				if (actual !== expected)
					return fail(
						fixture + ': desired/group registration expected ' + expected + ', got ' + actual
					);
			}
			const chords = scriptChordReceiptProblem(
				configRoot,
				CHORD_CONFIGS[fixture]
					? CHORD_CONFIGS[fixture].running
					: fixture.startsWith('older-release-')
						? null
						: SCRIPT_CHORD_SLOTS
			);
			if (chords) return fail(`${fixture}: ${chords}`);
			if (markerBearing && fs.existsSync(marker)) {
				return fail(`${fixture}: startup reached ready without consuming the suspend marker.`);
			}
			const logged = failOnLoggedErrors(fixture, configRoot);
			if (logged !== null) return logged;
			// Reuse the first fixture once so the no-bootstrap path is exercised too.
			if (fixture === 'fresh-config') {
				fs.unlinkSync(path.join(configRoot, 'ready.json'));
				fs.unlinkSync(path.join(configRoot, 'full-save.json'));
				const warmNonce = crypto.randomBytes(16).toString('hex');
				const second = spawnSync(ahk, ['/ErrorStdOut', wrapper], {
					cwd: code.windows,
					encoding: 'utf8',
					timeout: 120000,
					env: {
						...process.env,
						LOCALAPPDATA: configRoot,
						ERGOPTI_STARTUP_SMOKE_DIR: configRoot,
						ERGOPTI_STARTUP_SMOKE_NONCE: warmNonce
					}
				});
				if (second.error || second.status !== 0) {
					const output = `${second.stdout || ''}${second.stderr || ''}`.trim();
					const logs = logTail(configRoot);
					return fail(
						`reloaded-config exited ${second.status}.${output ? `\n${output}` : ''}${logs ? `\n${logs}` : ''}`
					);
				}
				const warmReadiness = startupReceiptProblem(configRoot, second.pid, warmNonce, ahk);
				if (warmReadiness) return fail('reloaded-config: ' + warmReadiness);
				const warmFullSave = fullSaveReceiptProblem(configRoot, second.pid, warmNonce);
				if (warmFullSave) return fail('reloaded-config: ' + warmFullSave);
				const reloaded = failOnLoggedErrors('reloaded-config', configRoot);
				if (reloaded !== null) return reloaded;
			}
		}
		// The startup-only probes above retain their complete historical contracts.
		// This separate process proves accepted production cleanup and destruction.
		const naturalRoot = path.join(scratch, 'natural-shutdown');
		fs.mkdirSync(naturalRoot, { recursive: true });
		prepareStartupPersonalInclude(code.windows, path.join(naturalRoot, 'config'));
		const naturalNonce = crypto.randomBytes(16).toString('hex');
		const natural = await launchNaturalExit(
			spawn,
			ahk,
			['/ErrorStdOut', wrapper],
			{
				cwd: code.windows,
				env: {
					...process.env,
					LOCALAPPDATA: naturalRoot,
					ERGOPTI_STARTUP_SMOKE_DIR: naturalRoot,
					ERGOPTI_STARTUP_SMOKE_NONCE: naturalNonce,
					ERGOPTI_STARTUP_SMOKE_NATURAL_EXIT: '1',
					ERGOPTI_STARTUP_SMOKE_EXPECT_SUSPENDED: ''
				}
			},
			120000
		);
		const naturalProblem = naturalExitReceiptProblem(naturalRoot, natural, naturalNonce);
		if (naturalProblem)
			return fail(
				'natural-shutdown: ' +
					naturalProblem +
					'\n' +
					(natural.stdout || '') +
					(natural.stderr || '') +
					'\n' +
					logTail(naturalRoot)
			);
		const naturalReady = startupReceiptProblem(naturalRoot, natural.pid, naturalNonce, ahk);
		if (naturalReady) return fail('natural-shutdown: ' + naturalReady);
		const naturalSave = fullSaveReceiptProblem(naturalRoot, natural.pid, naturalNonce);
		if (naturalSave) return fail('natural-shutdown: ' + naturalSave);
		const naturalChords = scriptChordReceiptProblem(naturalRoot, SCRIPT_CHORD_SLOTS);
		if (naturalChords) return fail('natural-shutdown: ' + naturalChords);
		if (
			!fs.existsSync(path.join(naturalRoot, 'startup-pump.txt')) ||
			!fs.existsSync(path.join(naturalRoot, 'tray-shell.txt'))
		)
			return fail('natural-shutdown: the real pre-ready startup contracts are incomplete');
		const naturalLogged = failOnLoggedErrors('natural-shutdown', naturalRoot);
		if (naturalLogged !== null) return naturalLogged;
		startupSucceeded = true;
		console.log(
			'\x1b[32m[OK] full AHK startup smoke: fresh, reloaded, independent, suspend-marker, extension opt-in, ' +
				'script-chord, neutral-defaults and older-release boots reached ready with no error logged ' +
				'and every script chord registered; actual production shutdown retired naturally.\x1b[0m'
		);
		return 0;
	} finally {
		code.close();
		if (startupSucceeded) fs.rmSync(wrapper, { force: true });
		if (startupSucceeded) {
			await new Promise((resolve) => setImmediate(resolve));
			await fs.promises.rm(scratch, {
				recursive: true,
				force: true,
				maxRetries: 12,
				retryDelay: 100
			});
		} else {
			console.error('Failed startup/shutdown evidence retained: ' + scratch);
		}
		const currentForwarder = fs.existsSync(productionForwarder)
			? fs.readFileSync(productionForwarder)
			: null;
		if (
			originalForwarder === null
				? currentForwarder !== null
				: !originalForwarder.equals(currentForwarder || Buffer.alloc(0))
		)
			throw new Error('The startup smoke modified the production personal-shortcuts include.');
	}
}

main().then(
	(code) => {
		process.exitCode = code;
	},
	(error) => {
		console.error(error);
		process.exitCode = 1;
	}
);
