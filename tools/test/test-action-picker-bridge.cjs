// tools/test/test-action-picker-bridge.cjs

/**
 * ==============================================================================
 * MODULE: Action Picker Shared-Frontend Bridge Contract Guard
 * DESCRIPTION:
 * Guards the new cross-driver action picker at _shared/ui/action_picker/. A single
 * frontend drives BOTH drivers (AHK WebView2 + macOS WKWebView), so several
 * contracts have to hold or one platform silently breaks:
 *
 * 1. Host-agnostic post — script.js probes window.chrome.webview (Windows
 *    WebView2, JSON string) BEFORE window.webkit (macOS WKWebView, object).
 * 2. Action parity — every {action} the page posts (ready / confirm / cancel)
 *    is handled by BOTH hosts.
 * 3. initData-shape parity — both hosts emit every field the page reads, so the
 *    list renders identically (title, label, current, allowNative, nativeLabel,
 *    noneLabel, searchPlaceholder, noResults, cancelLabel, actions).
 * 4. Wiring + fallback — Windows ShowActionPicker tries the webview first and
 *    keeps the native ListBox fallback; macOS open_action_chooser routes through
 *    the shared picker.
 * 5. Locale — the two new keys the picker needs exist in the reference locale.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const PASS_SYMBOL = '✓';
const FAIL_SYMBOL = '✗';

const REPO_ROOT = path.resolve(__dirname, '../..');
const FRONT = 'static/ergopti_plus/_shared/ui/action_picker';
const SCRIPT = `${FRONT}/script.js`;
const INDEX = `${FRONT}/index.html`;
const WIN_HOST = 'static/ergopti_plus/windows/ui/action_picker_webview.ahk';
const WIN_NATIVE = 'static/ergopti_plus/windows/ui/action_picker.ahk';
const MAC_HOST = 'static/ergopti_plus/macos/ui/action_picker/init.lua';
const MAC_MENU = 'static/ergopti_plus/macos/ui/menu/menu_gestures.lua';
const EN_LOCALE = 'static/ergopti_plus/_shared/data/locales/en.json';

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
	try {
		return fs.readFileSync(path.join(REPO_ROOT, rel), 'utf8').replace(/^﻿/, '');
	} catch (err) {
		check(`${rel} readable`, false, err.message);
		return '';
	}
}

console.log('\n=== Action Picker Shared-Frontend Bridge ===');

const script = read(SCRIPT);
const index = read(INDEX);
const winHost = read(WIN_HOST);
const winNative = read(WIN_NATIVE);
const macHost = read(MAC_HOST);
const macMenu = read(MAC_MENU);
const enLocale = read(EN_LOCALE);

// 1. Host-agnostic post().
const chromeIdx = script.indexOf('window.chrome.webview');
const webkitIdx = script.indexOf('window.webkit');
check('script.js probes window.chrome.webview (Windows channel)', chromeIdx !== -1);
check('script.js still supports window.webkit (macOS channel)', webkitIdx !== -1);
check('script.js JSON-stringifies the WebView2 payload',
	/chrome\.webview\.postMessage\(\s*JSON\.stringify\(/.test(script));
check('chrome.webview is probed before webkit',
	chromeIdx !== -1 && webkitIdx !== -1 && chromeIdx < webkitIdx);

// 2. index.html loads the shared i18n.js at the right depth.
check('index.html loads ../i18n.js',
	/src=["']\.\.\/i18n\.js["']/.test(index) && !/\.\.\/\.\.\//.test(index));

// 3. Action parity across both hosts.
const actions = new Set();
const re = /action:\s*'([a-z_]+)'/g;
let m;
while ((m = re.exec(script)) !== null) actions.add(m[1]);
check('script.js posts ready + confirm + cancel',
	actions.has('ready') && actions.has('confirm') && actions.has('cancel'),
	`Found: ${[...actions].join(', ')}`);
for (const a of [...actions].sort()) {
	check(`Windows host handles "${a}"`, winHost.includes(`"${a}"`));
	check(`macOS host handles "${a}"`, macHost.includes(`"${a}"`));
}

// 4. initData-shape parity — both hosts emit every field the page reads.
const FIELDS = ['title', 'label', 'current', 'allowNative', 'nativeLabel', 'noneLabel',
	'searchPlaceholder', 'noResults', 'cancelLabel', 'actions'];
for (const f of FIELDS) {
	check(`page reads data.${f}`, script.includes(`data.${f}`) || script.includes(`.${f}`));
	check(`Windows host emits "${f}"`, winHost.includes(`"${f}"`));
	check(`macOS host emits ${f}`, new RegExp(`\\b${f}\\b`).test(macHost));
}
// Per-action keys.
for (const k of ['id', 'label', 'category']) {
	check(`page reads action.${k}`, new RegExp(`a\\.${k}|\\.${k}\\b`).test(script));
}

// 5. Wiring + native fallback preserved.
check('Windows ShowActionPicker tries the webview first',
	/_ActPickWeb_TryOpen\(/.test(winNative));
check('Windows keeps the native ListBox fallback',
	winNative.includes('ListBox'));
check('macOS open_action_chooser routes through the shared picker',
	macMenu.includes('ActionPicker.open(') && /require\(["']ui\.action_picker["']\)/.test(macMenu));

// 6. Locale keys present.
let locale = {};
try { locale = JSON.parse(enLocale); } catch (err) { check('en.json parses', false, err.message); }
for (const key of ['dialog.action_picker.search', 'dialog.action_picker.no_results']) {
	check(`locale has "${key}"`, typeof locale[key] === 'string' && locale[key].length > 0);
}

console.log(`\nResults: ${total_pass} passed, ${total_fail} failed.`);

if (total_fail > 0) {
	process.exit(1);
}
