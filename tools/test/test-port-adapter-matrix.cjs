// tools/test/test-port-adapter-matrix.cjs

/**
 * ==============================================================================
 * MODULE: Port × Driver Adapter Matrix
 * DESCRIPTION:
 * Which ports each driver ships an adapter for is a pure filesystem fact that
 * spans all three trees, and nothing measured it. Each driver's own compliance
 * test loads its adapters and inspects the real method table — that is the right
 * check and it stays where it is, because only a runtime check catches an adapter
 * that fails to LOAD. But a per-driver test cannot see that a port present on two
 * drivers vanished from the third, because from inside one tree that is not an
 * event.
 *
 * This is the cross-tree half, and only that half. It reads directory entries; it
 * asserts nothing about behaviour.
 *
 * WHAT IS FROZEN:
 * 1. The matrix itself. 21 ports; Windows and macOS ship all 21, Linux 13. A port
 *    losing an adapter fails here, in the direction that matters — silently
 *    dropping one is how a capability becomes a claim.
 * 2. Every absence carries a reason. ADR-008 settled that a port is a contract
 *    for the drivers that need the capability, not a checklist — which makes an
 *    unexplained absence and a deliberate one look identical. They do not look
 *    identical here.
 * 3. No port is absent everywhere. A contract no driver implements is a contract
 *    describing nothing, and `contracts.json` would still report it as covered.
 *
 * WHY THE ABSENCES ARE WHAT THEY ARE: nine of Linux's were adapters DELETED under
 * ADR-008 because they had zero production callers — a `notifier.lua` nothing
 * called made the tree answer "does Linux notify?" wrongly by inspection. The
 * gate records that, so re-adding one without a caller is a decision rather than
 * an accident.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS = path.join(ROOT, 'static/ergopti_plus');
const CONTRACTS = path.join(DRIVERS, '_shared/core/ports/contracts.json');

const EXT = { windows: '.ahk', macos: '.lua', linux: '.lua' };

// Every port a driver does NOT ship an adapter for, with the reason. An entry
// here is a decision; an unlisted absence is a finding.
const DECLARED_ABSENT = {
	linux: {
		AppLauncher: 'deleted under ADR-008 — zero production callers; the daemon launches nothing',
		HotkeyRegistrar:
			'no global keyboard-grab API in userland; the evdev keyboard hook and its in-daemon tap-hold engine own the key path',
		KeyState: 'deleted under ADR-008 — zero production callers',
		MouseControl: 'deleted under ADR-008 — zero production callers; no gesture layer',
		NetworkInfo: 'deleted under ADR-008 — zero production callers',
		TextSender:
			'deleted under ADR-008 — zero production callers; the transactional injector owns Linux output',
		TooltipRenderer:
			'ui/tooltip uses the live GraphicsRenderer adapter for both preview families; no second rendering port',
		WindowManager: 'deleted under ADR-008 — zero production callers'
	},
	windows: {},
	macos: {}
};

// Where each shipped adapter lives, by repository path: the structure plan
// moves adapters out of adapters/ into the feature they serve, often under
// another name, and these paths follow each move.
const ADAPTER_FILES = {
	windows: {
		AppLauncher: 'static/ergopti_plus/windows/adapters/app_launcher.ahk',
		Clipboard: 'static/ergopti_plus/windows/adapters/clipboard.ahk',
		Crypto: 'static/ergopti_plus/windows/adapters/crypto.ahk',
		FileSystem: 'static/ergopti_plus/windows/adapters/file_system.ahk',
		GraphicsRenderer: 'static/ergopti_plus/windows/adapters/graphics_renderer.ahk',
		HotkeyRegistrar: 'static/ergopti_plus/windows/adapters/hotkey_registrar.ahk',
		HttpClient: 'static/ergopti_plus/windows/adapters/http_client.ahk',
		KeyState: 'static/ergopti_plus/windows/adapters/key_state.ahk',
		KeyboardHook: 'static/ergopti_plus/windows/adapters/keyboard_hook.ahk',
		MouseControl: 'static/ergopti_plus/windows/adapters/mouse_control.ahk',
		NetworkInfo: 'static/ergopti_plus/windows/adapters/network_info.ahk',
		Notifier: 'static/ergopti_plus/windows/adapters/notifier.ahk',
		ProcessLifecycle: 'static/ergopti_plus/windows/adapters/process_lifecycle.ahk',
		SecureFieldDetector: 'static/ergopti_plus/windows/adapters/secure_field_detector.ahk',
		Storage: 'static/ergopti_plus/windows/adapters/storage.ahk',
		TextSender: 'static/ergopti_plus/windows/adapters/text_sender.ahk',
		TimerScheduler: 'static/ergopti_plus/windows/adapters/timer_scheduler.ahk',
		TooltipRenderer: 'static/ergopti_plus/windows/adapters/tooltip_renderer.ahk',
		TrayMenu: 'static/ergopti_plus/windows/adapters/tray_menu.ahk',
		WindowInfo: 'static/ergopti_plus/windows/adapters/window_info.ahk',
		WindowManager: 'static/ergopti_plus/windows/adapters/window_manager.ahk'
	},
	macos: {
		AppLauncher: 'static/ergopti_plus/macos/adapters/app_launcher.lua',
		Clipboard: 'static/ergopti_plus/macos/adapters/clipboard.lua',
		Crypto: 'static/ergopti_plus/macos/adapters/crypto.lua',
		FileSystem: 'static/ergopti_plus/macos/adapters/file_system.lua',
		GraphicsRenderer: 'static/ergopti_plus/macos/adapters/graphics_renderer.lua',
		HotkeyRegistrar: 'static/ergopti_plus/macos/adapters/hotkey_registrar.lua',
		HttpClient: 'static/ergopti_plus/macos/adapters/http_client.lua',
		KeyState: 'static/ergopti_plus/macos/adapters/key_state.lua',
		KeyboardHook: 'static/ergopti_plus/macos/adapters/keyboard_hook.lua',
		MouseControl: 'static/ergopti_plus/macos/adapters/mouse_control.lua',
		NetworkInfo: 'static/ergopti_plus/macos/adapters/network_info.lua',
		Notifier: 'static/ergopti_plus/macos/adapters/notifier.lua',
		ProcessLifecycle: 'static/ergopti_plus/macos/adapters/process_lifecycle.lua',
		SecureFieldDetector: 'static/ergopti_plus/macos/adapters/secure_field_detector.lua',
		Storage: 'static/ergopti_plus/macos/adapters/storage.lua',
		TextSender: 'static/ergopti_plus/macos/adapters/text_sender.lua',
		TimerScheduler: 'static/ergopti_plus/macos/adapters/timer_scheduler.lua',
		TooltipRenderer: 'static/ergopti_plus/macos/adapters/tooltip_renderer.lua',
		TrayMenu: 'static/ergopti_plus/macos/adapters/tray_menu.lua',
		WindowInfo: 'static/ergopti_plus/macos/adapters/window_info.lua',
		WindowManager: 'static/ergopti_plus/macos/adapters/window_manager.lua'
	},
	linux: {
		Clipboard: 'static/ergopti_plus/linux/adapters/clipboard.lua',
		Crypto: 'static/ergopti_plus/linux/adapters/crypto.lua',
		FileSystem: 'static/ergopti_plus/linux/adapters/file_system.lua',
		GraphicsRenderer: 'static/ergopti_plus/linux/adapters/graphics_renderer.lua',
		HttpClient: 'static/ergopti_plus/linux/adapters/http_client.lua',
		KeyboardHook: 'static/ergopti_plus/linux/adapters/keyboard_hook.lua',
		Notifier: 'static/ergopti_plus/linux/adapters/notifier.lua',
		ProcessLifecycle: 'static/ergopti_plus/linux/adapters/process_lifecycle.lua',
		SecureFieldDetector: 'static/ergopti_plus/linux/adapters/secure_field_detector.lua',
		Storage: 'static/ergopti_plus/linux/adapters/storage.lua',
		TimerScheduler: 'static/ergopti_plus/linux/adapters/timer_scheduler.lua',
		TrayMenu: 'static/ergopti_plus/linux/adapters/tray_menu.lua',
		WindowInfo: 'static/ergopti_plus/linux/adapters/window_info.lua'
	}
};

const errors = [];

/** PascalCase port name → the adapter file stem. */
function stemOf(port) {
	return port
		.replace(/([a-z0-9])([A-Z])/g, '$1_$2')
		.replace(/([A-Z]+)([A-Z][a-z])/g, '$1_$2')
		.toLowerCase();
}

const contracts = JSON.parse(fs.readFileSync(CONTRACTS, 'utf8')).ports;
const ports = Object.keys(contracts);

// Floor: an empty or truncated contracts.json would make every loop below run
// zero times and report success over nothing.
if (ports.length < 15) {
	errors.push(
		`contracts.json declares ${ports.length} port(s) — expected at least 15; the file is truncated or the parse is wrong`
	);
}

// ==================================================
// ==================================================
// ======= 1/ Build The Matrix ======================
// ==================================================
// ==================================================

const present = {};
for (const driver of Object.keys(EXT)) {
	present[driver] = new Set();
	for (const [port, file] of Object.entries(ADAPTER_FILES[driver])) {
		if (!ports.includes(port)) {
			errors.push(
				`${driver} lists an adapter for "${port}", which is not a port in contracts.json`
			);
			continue;
		}
		if (!fs.existsSync(path.join(ROOT, file))) {
			errors.push(
				`${driver}'s ${port} adapter ${file} does not exist — a move left the table behind`
			);
			continue;
		}
		present[driver].add(port);
	}
	// A new adapter in the legacy folder counts too, while that folder exists:
	// an absence recorded above would otherwise go stale unseen.
	const legacy = path.join(DRIVERS, driver, 'adapters');
	for (const port of ports)
		if (fs.existsSync(path.join(legacy, stemOf(port) + EXT[driver]))) present[driver].add(port);
	if (present[driver].size === 0) {
		errors.push(
			`${driver} ships an adapter for none of the ${ports.length} ports — the table drifted`
		);
	}
}

// ==================================================
// ==================================================
// ======= 2/ Every Absence Is Declared =============
// ==================================================
// ==================================================

for (const driver of Object.keys(EXT)) {
	const declared = DECLARED_ABSENT[driver] || {};

	for (const port of ports) {
		if (present[driver].has(port)) {
			if (declared[port]) {
				errors.push(
					`${driver} now ships an adapter for ${port}, which is recorded as absent ("${declared[port]}"). ` +
						'Remove the entry — the reason is stale, and a stale reason is worse than none.'
				);
			}
			continue;
		}
		if (!declared[port]) {
			errors.push(
				`${driver} ships no adapter for ${port} and nothing records why. ADR-008 says a port is a ` +
					'contract for the drivers that need it — which makes a deliberate absence and a dropped ' +
					'one look identical unless the deliberate one is written down.'
			);
		}
	}

	for (const port of Object.keys(declared)) {
		if (!ports.includes(port)) {
			errors.push(
				`${driver} records an absence for "${port}", which is not a port in contracts.json — the note is stale`
			);
		}
	}
}

// ==================================================
// ==================================================
// ======= 3/ No Port Is Absent Everywhere ==========
// ==================================================
// ==================================================

for (const port of ports) {
	const shipped = Object.keys(EXT).filter((d) => present[d].has(port));
	if (shipped.length === 0) {
		errors.push(
			`${port} has no adapter on any driver. A contract nothing implements describes nothing, and ` +
				'contracts.json would still report it covered.'
		);
	}
}

// ==================================================
// ==================================================
// ======= 4/ Report ================================
// ==================================================
// ==================================================

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] the port × driver adapter matrix changed:\x1b[0m');
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}

const counts = Object.keys(EXT)
	.map((d) => `${d} ${present[d].size}`)
	.join(', ');
const everywhere = ports.filter((p) => Object.keys(EXT).every((d) => present[d].has(p))).length;
console.log(
	`\x1b[32m[OK] ${ports.length} port(s): ${counts}; ${everywhere} on all three, every absence declared with ` +
		'a reason, none absent everywhere.\x1b[0m'
);
