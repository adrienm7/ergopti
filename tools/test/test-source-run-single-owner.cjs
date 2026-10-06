// tools/test/test-source-run-single-owner.cjs

/**
 * ==============================================================================
 * MODULE: One Installed-Build-Or-Source-Run Owner Per Driver
 * DESCRIPTION:
 * « Désinstaller Ergopti » stayed live on a local version run from source, and
 * the drivers answered « installed build or source run? » in several places
 * each: Windows read A_IsCompiled in its uninstall, update and login-startup
 * code next to Updater_IsLocalSource; Linux matched the install layout in the
 * uninstall action and read the build stamp in the Versions window and the
 * layout catalogue. Each driver now has one owner, and this gate keeps the
 * question from being answered anywhere else.
 *
 * FEATURES & RATIONALE:
 * 1. Windows: Updater_IsLocalSource is the owner. A_IsCompiled appears in no
 *    other function of core.ahk, and elsewhere only in the files listed with
 *    the launch mechanics they choose (which executable, where its files are).
 * 2. macOS: Updater.is_local_source is the owner; the packaged app's bundle id
 *    is compared nowhere else.
 * 3. Linux: infra/installation.lua is the owner; no other module matches an
 *    install layout or compares the build-stamp source.
 * 4. The Uninstall row: the manifest greys it through the installed_build
 *    getter, each driver answers that getter from its owner, and each uninstall
 *    action refuses a source run through the owner before any dialog.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS = path.join(ROOT, 'static', 'ergopti_plus');
const MANIFEST = path.join(DRIVERS, '_shared', 'modules', 'menu', 'menu_manifest.json');

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

/** Every source file of a driver with an extension, relative to the driver. */
function sources(driver, extension) {
	const base = path.join(DRIVERS, driver);
	const out = [];
	const walk = (dir) => {
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			const full = path.join(dir, entry.name);
			if (entry.isDirectory()) {
				if (['tests', 'vendor', '_generated', 'node_modules'].includes(entry.name)) continue;
				walk(full);
			} else if (entry.name.endsWith(extension)) out.push(path.relative(base, full));
		}
	};
	walk(base);
	return out;
}

/** A driver file's text without its comment lines. */
function code(driver, file, comment) {
	return fs
		.readFileSync(path.join(DRIVERS, driver, file), 'utf8')
		.split('\n')
		.filter((line) => !comment.test(line))
		.join('\n');
}

/** The body of an AHK function, from its definition to the closing brace. */
function ahkBody(file, name) {
	const text = fs.readFileSync(path.join(DRIVERS, 'windows', file), 'utf8');
	const start = text.search(new RegExp('^' + name + '\\(.*\\)\\s*\\{\\s*$', 'm'));
	if (start < 0) return '';
	const end = text.indexOf('\n}\n', start);
	return text.slice(start, end < 0 ? undefined : end);
}

// ==========================================
// ==========================================
// ======= 2/ Windows =======================
// ==========================================
// ==========================================

// The files that read A_IsCompiled to choose launch mechanics, not to decide
// what an installed build may do. Every product decision asks the owner.
const WINDOWS_MECHANICS = {
	'ErgoptiPlus.ahk': 'the compiled exe extracts and recovers its bundle',
	'infra/boot.ahk': 'where each launch mode keeps paths.toml',
	'infra/bundle.ahk': 'only the exe carries an embedded bundle',
	'infra/config_registry_cache.ahk': 'fingerprint the executable when parser sources are embedded',
	'infra/lifecycle.ahk': 'which executable a reload relaunches',
	'infra/toml/toml_helpers.ahk': "the compiled exe's former paths.toml location",
	'infra/diagnostic_snapshot.ahk': 'the snapshot reports the flag itself',
	'infra/startup_smoke.ahk':
		'the native readiness receipt identifies its executable and reports the compiled flag',
	'modules/keymap/uia_selection_worker.ahk': 'how a worker process is spawned',
	'modules/keylogger/keylogger_prefetch.ahk': 'how a worker process is spawned',
	'modules/dynamic_hotstrings/user_code.ahk':
		'launch an owned personal-code worker with the bundled interpreter /script mode',
	'adapters/program_providers.ahk':
		'admit A_AhkPath as an interpreter only when the current runtime is interpreted',
	'modules/updater/core.ahk': 'the owner, Updater_IsLocalSource'
};

const ahkComment = /^\s*;/;
for (const file of sources('windows', '.ahk')) {
	if (!code('windows', file, ahkComment).includes('A_IsCompiled')) continue;
	expect(
		Object.prototype.hasOwnProperty.call(WINDOWS_MECHANICS, file.split(path.sep).join('/')),
		`windows/${file} reads A_IsCompiled: ask Updater_IsLocalSource() for an installed-build ` +
			'decision, or list the file here with the launch mechanics it chooses.'
	);
}
const readinessPublisher = ahkBody('infra/startup_smoke.ahk', 'StartupSmokePublishReady');
const programInventory = code('windows', 'adapters/program_providers.ahk', ahkComment);
expect(
	programInventory.split('A_IsCompiled').length === 2 &&
		programInventory.split('A_AhkPath').length === 3 &&
		/if !A_IsCompiled && ProviderId == "autohotkey" \{\s*Info := this\.Identity\(A_AhkPath\)\s*if Info\["kind"\] == "file" && Info\["executable"\]\s*return Map\("executable", A_AhkPath, "token", Info\["token"\]\)\s*\}/.test(
			programInventory
		),
	'the provider uses the compiled flag only to refuse its executable as an AHK interpreter'
);
expect(readinessPublisher !== '', 'the native readiness publisher must exist');
expect(
	readinessPublisher.split('A_IsCompiled').length === 3 &&
		code('windows', 'infra/startup_smoke.ahk', ahkComment).split('A_IsCompiled').length === 3,
	'the readiness owner reports runtime identity only; product decisions still ask Updater_IsLocalSource'
);
const owner = ahkBody('modules/updater/core.ahk', 'Updater_IsLocalSource');
expect(/return !A_IsCompiled/.test(owner), 'Updater_IsLocalSource must stay the Windows owner');
expect(
	code('windows', 'modules/updater/core.ahk', ahkComment).split('A_IsCompiled').length === 2,
	'core.ahk reads A_IsCompiled in Updater_IsLocalSource only'
);
for (const [file, name] of [
	['infra/uninstall.ahk', 'ShowUninstallErgopti'],
	['infra/start_at_login.ahk', 'StartAtLoginEnabled'],
	['infra/start_at_login.ahk', 'ToggleStartAtLogin'],
	['modules/updater/self_update.ahk', 'Updater_DownloadAndInstall'],
	['ui/changelog/init.ahk', '_CLW_InstallBlocked']
]) {
	expect(
		ahkBody(file, name).includes('Updater_IsLocalSource()'),
		`${name} must ask Updater_IsLocalSource()`
	);
}
const uninstall = ahkBody('infra/uninstall.ahk', 'ShowUninstallErgopti');
const refusal = uninstall.indexOf('Updater_IsLocalSource()');
expect(
	refusal >= 0 &&
		!uninstall.slice(0, uninstall.indexOf('return false', refusal)).includes('MsgBox'),
	'a source run must leave ShowUninstallErgopti before any dialog'
);
expect(
	/"installed_build",\s*\(\)\s*=>\s*!Updater_IsLocalSource\(\)/.test(
		ahkBody('ui/menu/menu_init.ahk', '_MI_BuildAboutMenu')
	),
	'the Windows About menu must answer installed_build from Updater_IsLocalSource'
);

// ==========================================
// ==========================================
// ======= 3/ macOS =========================
// ==========================================
// ==========================================

const luaComment = /^\s*--/;
const BUNDLED_ID = 'com.ergoptiplus.app.hammerspoon';
for (const file of sources('macos', '.lua')) {
	if (file === path.join('modules', 'updater', 'init.lua')) continue;
	expect(
		!code('macos', file, luaComment).includes(BUNDLED_ID),
		`macos/${file} compares the packaged bundle id: ask Updater.is_local_source() instead`
	);
}
expect(
	/function M\.is_local_source\(\)/.test(code('macos', 'modules/updater/init.lua', luaComment)),
	'Updater.is_local_source must stay the macOS owner'
);
expect(
	/installed_build"\]\s*=\s*function\(\)\s*return not is_local_source\(\)/.test(
		code('macos', 'ui/menu/menu_about.lua', luaComment)
	),
	'the macOS About menu must answer installed_build from Updater.is_local_source'
);
const macUninstall = code('macos', 'ui/menu/uninstall.lua', luaComment);
expect(
	macUninstall.indexOf('is_local_source()') >= 0 &&
		macUninstall.indexOf('is_local_source()') < macUninstall.indexOf('block_alert'),
	'the macOS uninstall action must refuse a source run before any dialog'
);

// ==========================================
// ==========================================
// ======= 4/ Linux =========================
// ==========================================
// ==========================================

const LINUX_OWNER = path.join('infra', 'installation.lua');
// Where the updater decides who may REPLACE the files (system package,
// bundle, standalone install): a different question, with its own tests.
const LINUX_REPLACEMENT = path.join('modules', 'updater', 'installer.lua');
for (const file of sources('linux', '.lua')) {
	if (file === LINUX_OWNER || file === LINUX_REPLACEMENT) continue;
	const text = code('linux', file, luaComment);
	expect(
		!/lib\/ergopti/.test(text),
		`linux/${file} matches an install layout: ask infra/installation.lua instead`
	);
	expect(
		!/SOURCE_LOCAL|Version\.LOCAL\b/.test(text) || file === path.join('infra', 'version.lua'),
		`linux/${file} reads the build-stamp source: ask Installation.is_source_run() instead`
	);
}
for (const file of [
	'ui/menu/uninstall.lua',
	'ui/menu/menu_builder.lua',
	'ui/changelog/bridge.lua',
	'ui/update_check/bridge.lua',
	'modules/keymap/layout_registry.lua'
]) {
	expect(
		code('linux', file, luaComment).includes('is_source_run('),
		`linux/${file} must ask Installation.is_source_run()`
	);
}
expect(
	/installed_build"\]\s*=\s*function\(\)\s*return not Installation\.is_source_run\(\)/.test(
		code('linux', 'ui/menu/menu_builder.lua', luaComment)
	),
	'the Linux About menu must answer installed_build from Installation.is_source_run'
);

// ==========================================
// ==========================================
// ======= 5/ The Uninstall Row =============
// ==========================================
// ==========================================

const about = JSON.parse(fs.readFileSync(MANIFEST, 'utf8')).about_menu || [];
const row = about.find((entry) => entry && entry.id === 'uninstall');
expect(
	row && Array.isArray(row.disabled_when) && row.disabled_when.join() === 'installed_build',
	'the Uninstall row must be greyed by installed_build'
);
expect(
	row && row.disabled_reason_key === 'menu.about.source_run_reason',
	'the greyed Uninstall row must name why'
);

if (failures.length > 0) {
	console.error(`[FAIL] installed-build-or-source-run owners (${failures.length}/${checks}):`);
	for (const failure of failures) console.error('  - ' + failure);
	process.exit(1);
}
console.log(
	`[OK] one installed-build-or-source-run owner per driver; Uninstall greyed on a source run (${checks} checks).`
);
