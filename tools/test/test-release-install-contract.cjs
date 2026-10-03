// tools/test/test-release-install-contract.cjs

/**
 * ==============================================================================
 * MODULE: Release Install Contract (three drivers)
 * DESCRIPTION:
 * Pins the parts of the one-click release install, and of the notify-only
 * update rule, that no single driver suite can see.
 *
 * ROOT CAUSE ENCODED:
 * The maintainer's rule is that ErgoptiPlus tells about an update and never
 * installs one by itself, and the Versions window now installs any release.
 * An install entry point called from a scheduler, or a second copy of the
 * install reasons that drifts from the page's, would each pass every driver's
 * own tests.
 *
 * FEATURES & RATIONALE:
 * 1. Only clicks install: every caller of each driver's install entry points
 *    is on an exact allowlist of click handlers, and the background check and
 *    scheduler bodies never reach one. A new caller fails here until it is
 *    reviewed and listed.
 * 2. One set of reasons: the shared Lua sequence and its Windows port name the
 *    same page keys, each exists in en.json, and each matches the family the
 *    page accepts from a host.
 * 3. Backup first on Windows: in ReleaseInstall_Start the backup port is
 *    called before the asset and install ports (the Lua order is proven by the
 *    shared contract in both Lua suites; AutoHotkey does not run in this gate).
 * 4. No modal box hides the window's failure: Updater_DownloadAndInstall routes
 *    every failure through _Updater_ReportInstallFailure.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS = path.join(ROOT, 'static', 'ergopti_plus');
const EN = JSON.parse(
	fs.readFileSync(path.join(DRIVERS, '_shared', 'data', 'locales', 'en.json'), 'utf8')
);

const failures = [];
let checks = 0;

function expect(condition, message) {
	checks += 1;
	if (!condition) failures.push(message);
}

// ==========================================
// ==========================================
// ======= 1/ Source Helpers ================
// ==========================================
// ==========================================

/** Every source file of a driver with an extension, tests excluded. */
function sources(driver, extension) {
	const out = [];
	const walk = (dir) => {
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			const full = path.join(dir, entry.name);
			if (entry.isDirectory()) {
				if (['tests', 'launcher', 'vendor', '_generated', 'node_modules'].includes(entry.name))
					continue;
				walk(full);
			} else if (entry.name.endsWith(extension)) out.push(full);
		}
	};
	walk(path.join(DRIVERS, driver));
	return out;
}

/** The AHK functions whose bodies contain a call, as "file:function". */
function ahkCallers(callee) {
	const found = new Set();
	const definition = /^([A-Za-z_][A-Za-z0-9_]*)\(.*\)\s*\{\s*$/;
	for (const file of sources('windows', '.ahk')) {
		let current = null;
		for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
			const match = line.match(definition);
			if (match) current = match[1];
			if (/^\s*;/.test(line) || match) continue;
			if (line.includes(callee + '(') && current) found.add(current);
		}
	}
	return [...found].sort();
}

/** The Lua files (relative to the driver) calling a function name. */
function luaCallers(driver, pattern) {
	const found = new Set();
	for (const file of sources(driver, '.lua')) {
		const text = fs.readFileSync(file, 'utf8');
		for (const line of text.split('\n')) {
			if (/^\s*--/.test(line)) continue;
			if (pattern.test(line))
				found.add(path.relative(path.join(DRIVERS, driver), file).replaceAll('\\', '/'));
		}
	}
	return [...found].sort();
}

/** The body of an AHK function, from its definition to the closing brace. */
function ahkBody(file, name) {
	const text = fs.readFileSync(path.join(DRIVERS, 'windows', file), 'utf8');
	const start = text.search(new RegExp('^' + name + '\\(.*\\)\\s*\\{\\s*$', 'm'));
	if (start < 0) return '';
	const end = text.indexOf('\n}\n', start);
	return text.slice(start, end < 0 ? undefined : end);
}

/** The body of a Lua local or module function, to the next top-level `end`. */
function luaBody(driver, file, name) {
	const text = fs.readFileSync(path.join(DRIVERS, driver, file), 'utf8');
	const start = text.search(
		new RegExp('^(local function |function M\\.|' + name + ' = function)' + name, 'm')
	);
	const alt = start < 0 ? text.search(new RegExp('^' + name + ' = function', 'm')) : start;
	if (alt < 0) return '';
	const end = text.indexOf('\nend\n', alt);
	return text.slice(alt, end < 0 ? undefined : end);
}

const same = (actual, expected) => JSON.stringify(actual) === JSON.stringify(expected);

// ==========================================
// ==========================================
// ======= 2/ Only Clicks Install ===========
// ==========================================
// ==========================================

function checkWindowsInstallCallers() {
	const install = ahkCallers('Updater_DownloadAndInstall');
	expect(
		same(install, [
			'_CLW_StartUpdatePath',
			'_Updater_ActivateCachedRelease',
			'_Updater_InstallPromptRelease',
			'_Updater_StartObservedInstall'
		]),
		`Windows: Updater_DownloadAndInstall has an unreviewed caller: ${install.join(', ')}`
	);
	const cached = ahkCallers('_Updater_ActivateCachedRelease');
	expect(
		same(cached, ['Updater_OneClickUpdate', '_UpdateCheck_Install']),
		`Windows: the cached update is installed from an unreviewed place: ${cached.join(', ')}`
	);
	const chosen = ahkCallers('ReleaseInstall_Start');
	expect(
		same(chosen, ['_CLW_OnWebMessage', '_Updater_InstallChosenRelease']),
		`Windows: a chosen release is installed from an unreviewed place: ${chosen.join(', ')}`
	);
	for (const [file, name] of [
		['modules/updater/self_update.ahk', '_Updater_HandleBackgroundResult'],
		['modules/updater/self_update.ahk', 'Updater_BackgroundTick']
	]) {
		const body = ahkBody(file, name);
		expect(body !== '', `Windows: ${name} not found`);
		for (const forbidden of [
			'Updater_DownloadAndInstall(',
			'_Updater_ActivateCachedRelease(',
			'_Updater_StartStagingWorker(',
			'ReleaseInstall_Start('
		]) {
			expect(
				!body.includes(forbidden),
				`Windows: ${name} must only announce, it calls ${forbidden}`
			);
		}
	}
}

function checkLinuxInstallCallers() {
	// The manager defines them; its own bodies are checked below.
	const installs = luaCallers(
		'linux',
		/\.(download_update|download_release|install_update|install_release_archive)\(/
	).filter((file) => file !== 'modules/updater/manager.lua');
	expect(
		same(
			installs,
			['ui/menu/menu_builder.lua', 'ui/update_check/bridge.lua', 'ui/changelog/bridge.lua'].sort()
		),
		`Linux: an update is downloaded or installed from an unreviewed file: ${installs.join(', ')}`
	);
	for (const name of ['_complete_background_check', '_evaluate_schedule']) {
		const body = luaBody('linux', 'modules/updater/manager.lua', name);
		expect(body !== '', `Linux: ${name} not found`);
		expect(
			!/download_update|download_release|install_update|install_release_archive|start_download/.test(
				body
			),
			`Linux: ${name} must only announce a release`
		);
	}
}

function checkMacosInstallCallers() {
	const sparkle = luaCallers('macos', /UpdateLauncher\.request_check\(/);
	expect(
		same(
			sparkle,
			[
				'modules/updater/auto_check.lua',
				'ui/menu/menu_about.lua',
				'ui/update_check/init.lua'
			].sort()
		),
		`macOS: Sparkle is asked for an update from an unreviewed file: ${sparkle.join(', ')}`
	);
	const autoCheck = fs.readFileSync(
		path.join(DRIVERS, 'macos', 'modules/updater/auto_check.lua'),
		'utf8'
	);
	const requests = autoCheck
		.split('\n')
		.filter((line) => line.includes('UpdateLauncher.request_check('));
	expect(
		requests.length === 1 &&
			/function\(\) UpdateLauncher\.request_check\(release\.channel\) end\)/.test(requests[0]),
		'macOS: the automatic check may reach Sparkle only from the notification click handler'
	);
	const staged = luaCallers('macos', /installer\.(stage|arm_swap)\(/);
	expect(
		same(staged, ['ui/changelog/init.lua']),
		`macOS: a chosen release is staged or swapped from an unreviewed file: ${staged.join(', ')}`
	);
}

// ==========================================
// ==========================================
// ======= 3/ One Set of Reasons ============
// ==========================================
// ==========================================

function checkReasonKeys() {
	const lua = fs.readFileSync(
		path.join(DRIVERS, '_shared/lua/updater/release_install.lua'),
		'utf8'
	);
	const luaBlock = lua.slice(
		lua.indexOf('M.REASON = {'),
		lua.indexOf('}', lua.indexOf('M.REASON = {'))
	);
	const luaMap = Object.fromEntries(
		[...luaBlock.matchAll(/^\s*([a-z_]+) = "([^"]+)",/gm)].map((m) => [m[1], m[2]])
	);
	const ahk = fs.readFileSync(
		path.join(DRIVERS, 'windows/modules/updater/release_install.ahk'),
		'utf8'
	);
	const ahkBlock = ahk.slice(
		ahk.indexOf('RELEASE_INSTALL_REASONS := Map('),
		ahk.indexOf(')\n', ahk.indexOf('RELEASE_INSTALL_REASONS := Map('))
	);
	const ahkMap = Object.fromEntries(
		[...ahkBlock.matchAll(/"([a-z_]+)",\s*"([^"]+)"/g)].map((m) => [m[1], m[2]])
	);
	expect(Object.keys(luaMap).length >= 9, 'the Lua reasons could not be read');
	expect(
		same(Object.entries(luaMap).sort(), Object.entries(ahkMap).sort()),
		`the Windows install reasons drifted from the shared ones: ${JSON.stringify(ahkMap)}`
	);
	const page = fs.readFileSync(path.join(DRIVERS, '_shared/ui/changelog/script.js'), 'utf8');
	const family = /var INSTALL_REASON_KEY = \/(.+)\/;/.exec(page);
	expect(family !== null, 'the page install reason family could not be read');
	const accepted = family ? new RegExp(family[1]) : /$^/;
	for (const key of Object.values(luaMap)) {
		expect(typeof EN[key] === 'string' && EN[key] !== '', `${key} is missing from en.json`);
		expect(accepted.test(key), `the page refuses the host reason ${key}`);
	}
	for (const key of [
		'changelog_window.install_blocked_source',
		'changelog_window.install_blocked_package',
		'changelog_window.restore_error_backup',
		'changelog_window.restore_error_missing',
		'changelog_window.restore_error_unexpected'
	]) {
		expect(typeof EN[key] === 'string' && EN[key] !== '', `${key} is missing from en.json`);
	}
}

// ==========================================
// ==========================================
// ======= 4/ Windows Order and Failures ====
// ==========================================
// ==========================================

function checkWindowsSequence() {
	const body = ahkBody('modules/updater/release_install.ahk', 'ReleaseInstall_Start');
	expect(body !== '', 'ReleaseInstall_Start not found');
	const at = (needle) => body.indexOf(needle);
	expect(at('Deps["backup"].Call(') > 0, 'Windows: the sequence has no backup');
	expect(
		at('Deps["backup"].Call(') < at('Deps["asset"].Call(') &&
			at('Deps["asset"].Call(') < at('Deps["install"].Call('),
		'Windows: the backup must precede the asset lookup and the update path'
	);
	const install = ahkBody('modules/updater/self_update.ahk', 'Updater_DownloadAndInstall');
	expect(install !== '', 'Updater_DownloadAndInstall not found');
	expect(
		!/^\s*MsgBox\(/m.test(install),
		'Windows: a failure of the update path must reach the Versions window, not only a modal box'
	);
	const poll = ahkBody('modules/updater/self_update.ahk', '_Updater_PollDownloadAsync');
	expect(
		poll.includes('_Updater_NotifyInstallPhase("installing")') &&
			poll.includes('_Updater_NotifyInstallPhase("restarting")'),
		'Windows: the verified download and the swap must reach the Versions window'
	);
}

// ==========================================
// ==========================================
// ======= 5/ Report =======================
// ==========================================
// ==========================================

checkWindowsInstallCallers();
checkLinuxInstallCallers();
checkMacosInstallCallers();
checkReasonKeys();
checkWindowsSequence();

if (failures.length > 0) {
	console.error(`\x1b[31m[FAIL] release install contract (${failures.length}/${checks}):\x1b[0m`);
	for (const failure of failures) console.error('  - ' + failure);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] only clicks install, on every driver; one set of install reasons (${checks} checks).\x1b[0m`
);
