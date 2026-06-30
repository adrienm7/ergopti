// tools/test/test-hotstrings-config-window-bridge.cjs

/**
 * ==============================================================================
 * MODULE: Hotstrings Config Window Shared-Frontend Bridge Contract Guard
 * DESCRIPTION:
 * Guards the conversion of the hotstrings configuration window to a shared
 * WebView2 / WKWebView frontend. The single frontend at
 * _shared/ui/hotstrings_config_window/ must drive BOTH drivers, so three
 * contracts have to hold or the Windows window silently breaks:
 *
 * 1. Host-agnostic post — script.js must probe window.chrome.webview (Windows
 *    WebView2, which takes a JSON string) BEFORE window.webkit (macOS WKWebView,
 *    which takes an object). A regression to the macOS-only send() leaves the
 *    Windows window unable to talk back to AHK.
 * 2. Action parity — every {action} the page can post must be handled by the
 *    Windows host dispatcher (_HCWWeb_Dispatch); an unhandled action is a dead
 *    control on Windows.
 * 3. State-shape parity — the Windows host must emit every field key script.js
 *    reads when rendering, so the tree renders identically to macOS.
 *
 * FEATURES & RATIONALE:
 *   Each contract is derived from the shared frontend itself (the actions and
 *   field names are extracted from script.js), so the test tracks the UI as it
 *   evolves rather than hardcoding a list that can drift.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const PASS_SYMBOL = '✓';
const FAIL_SYMBOL = '✗';

const REPO_ROOT = path.resolve(__dirname, '../..');
const FRONT_DIR = 'static/ergopti_plus/_shared/ui/hotstrings_config_window';
const SCRIPT = `${FRONT_DIR}/script.js`;
const INDEX = `${FRONT_DIR}/index.html`;
const HOST_BRIDGE = 'static/ergopti_plus/_shared/ui/host_bridge.js';
const WIN_HOST = 'static/ergopti_plus/windows/ui/hotstrings_config_window/webview.ahk';

let total_pass = 0;
let total_fail = 0;

function check(label, cond, detail) {
	if (cond) {
		total_pass++;
		console.log(`  ${PASS_SYMBOL}  ${label}`);
	} else {
		total_fail++;
		console.log(`  ${FAIL_SYMBOL}  ${label}`);
		if (detail) console.log(`       ${detail}`);
	}
}

function read(rel) {
	return fs.readFileSync(path.join(REPO_ROOT, rel), 'utf8').replace(/^﻿/, '');
}

console.log('\n=== Hotstrings Config Window Shared-Frontend Bridge ===');

let script = '';
let bridge = '';
let index = '';
let host = '';
try {
	script = read(SCRIPT);
} catch (err) {
	check('script.js readable at shared path', false, err.message);
}
try {
	bridge = read(HOST_BRIDGE);
} catch (err) {
	check('host_bridge.js readable', false, err.message);
}
try {
	index = read(INDEX);
} catch (err) {
	check('index.html readable at shared path', false, err.message);
}
try {
	host = read(WIN_HOST);
} catch (err) {
	check('Windows host readable', false, err.message);
}

// 1. Host-agnostic send(): chrome.webview probed before webkit.
// Bridge patterns now live in host_bridge.js (shared across all webview apps).
const bridgeSource = bridge;
const chromeIdx = bridgeSource.indexOf('window.chrome.webview');
const webkitIdx = bridgeSource.indexOf('window.webkit');
check(
	'host_bridge.js probes window.chrome.webview (Windows channel present)',
	chromeIdx !== -1,
	'The Windows WebView2 branch is missing from host_bridge.js — the page cannot post to AHK.'
);
check(
	'host_bridge.js still supports window.webkit (macOS channel present)',
	webkitIdx !== -1,
	'The macOS WKWebView branch was dropped from host_bridge.js.'
);
check(
	'host_bridge.js posts a JSON string to the WebView2 channel',
	/chrome\.webview\.postMessage\(/.test(bridgeSource) && /JSON\.stringify\(/.test(bridgeSource),
	'WebView2 requires a string payload — JSON.stringify is missing from host_bridge.js.'
);
check(
	'chrome.webview is probed before webkit',
	chromeIdx !== -1 && webkitIdx !== -1 && chromeIdx < webkitIdx,
	'On Windows both objects may exist; the WebView2 branch must win.'
);
check(
	'index.html loads host_bridge.js (../host_bridge.js)',
	/src=["']\.\.\/host_bridge\.js["']/.test(index),
	'host_bridge.js must be loaded before script.js in index.html.'
);

// 2. index.html references the shared i18n.js one level up (../i18n.js).
check(
	'index.html loads ../i18n.js (shared loader, correct depth)',
	/src=["']\.\.\/i18n\.js["']/.test(index) && !/\.\.\/\.\.\/i18n\.js/.test(index),
	'After the move to _shared/ui/<name>/, i18n.js sits at ../i18n.js, not ../../.'
);

// 3. Action parity — every action the page posts is handled by the Windows host.
const actions = new Set();
const actionRe = /action:\s*'([a-z_]+)'/g;
let m;
while ((m = actionRe.exec(script)) !== null) actions.add(m[1]);
check(
	'script.js posts a non-trivial set of actions',
	actions.size >= 8,
	`Only found: ${[...actions].join(', ')} — extraction regex may have drifted.`
);
for (const action of [...actions].sort()) {
	check(
		`Windows host handles action "${action}"`,
		host.includes(`"${action}"`),
		`_HCWWeb_Dispatch has no branch for "${action}" — that control is dead on Windows.`
	);
}

// 4. State-shape parity — the Windows host emits every field key the page reads.
const FIELD_KEYS = [
	'categories', 'groups', 'presets', 'global_default_delay_ms',
	'name', 'group', 'title', 'sections',
	'delay_ms', 'delay_default_ms', 'delay_overridden',
	'color', 'color_default', 'color_overridden',
	'show_tooltip', 'show_tooltip_overridden',
	'priority', 'priority_default', 'priority_overridden'
];
for (const key of FIELD_KEYS) {
	check(
		`Windows host state emits "${key}"`,
		host.includes(`"${key}"`),
		`_HCWWeb_BuildStateJson omits "${key}" — the shared renderer expects it.`
	);
}

console.log(`\nResults: ${total_pass} passed, ${total_fail} failed.`);

if (total_fail > 0) {
	process.exit(1);
}
