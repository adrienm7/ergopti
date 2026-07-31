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
const HOST_BRIDGE = 'static/ergopti_plus/_shared/ui/host_bridge.js';
const WIN_HOST = 'static/ergopti_plus/windows/ui/action_picker_webview.ahk';
const WIN_NATIVE = 'static/ergopti_plus/windows/ui/action_picker/init.ahk';
const MAC_HOST = 'static/ergopti_plus/macos/ui/action_picker/init.lua';
const MAC_MENU = 'static/ergopti_plus/macos/ui/menu/menu_gestures.lua';
const LINUX_HOST = 'static/ergopti_plus/linux/modules/ui/bridge_handlers/action_picker_bridge.lua';
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
const bridge = read(HOST_BRIDGE);
const index = read(INDEX);
const winHost = read(WIN_HOST);
const winNative = read(WIN_NATIVE);
const macHost = read(MAC_HOST);
const macMenu = read(MAC_MENU);
const linuxHost = read(LINUX_HOST);
const enLocale = read(EN_LOCALE);

// 1. Host-agnostic post().
// Bridge patterns now live in host_bridge.js (shared across all webview apps).
const chromeIdx = bridge.indexOf('window.chrome.webview');
const webkitIdx = bridge.indexOf('window.webkit');
check('host_bridge.js probes window.chrome.webview (Windows channel)', chromeIdx !== -1);
check('host_bridge.js still supports window.webkit (macOS channel)', webkitIdx !== -1);
check('host_bridge.js JSON-stringifies the WebView2 payload',
	/chrome\.webview\.postMessage\(/.test(bridge) && /JSON\.stringify\(/.test(bridge));
check('chrome.webview is probed before webkit',
	chromeIdx !== -1 && webkitIdx !== -1 && chromeIdx < webkitIdx);

// 2. index.html loads the shared i18n.js at the right depth and host_bridge.js.
check('index.html loads ../i18n.js',
	/src=["']\.\.\/i18n\.js["']/.test(index) && !/\.\.\/\.\.\//.test(index));
check('index.html loads ../host_bridge.js',
	/src=["']\.\.\/host_bridge\.js["']/.test(index));

// 3. Action parity across both hosts.
const actions = new Set();
const re = /action:\s*'([a-z_]+)'/g;
let m;
while ((m = re.exec(script)) !== null) actions.add(m[1]);
check('script.js posts ready + confirm + cancel',
	actions.has('ready') && actions.has('confirm') && actions.has('cancel'),
	`Found: ${[...actions].join(', ')}`);
// Three hosts, not two. Linux was absent from this list, and its bridge had
// drifted into a protocol of its own — execute/search, which the page has never
// posted — so the picker did nothing there while both ends looked implemented.
for (const a of [...actions].sort()) {
	check(`Windows host handles "${a}"`, winHost.includes(`"${a}"`));
	check(`macOS host handles "${a}"`, macHost.includes(`"${a}"`));
	check(`Linux host handles "${a}"`, linuxHost.includes(`"${a}"`));
}

// And no host may answer a message the page never sends. A handler branch for an
// invented action is indistinguishable from a working feature until someone tries
// it — which is what the Linux bridge was made of.
for (const invented of ['execute', 'search']) {
	check(
		`Linux host does NOT answer the invented "${invented}"`,
		!new RegExp(`action\\s*==\\s*"${invented}"`).test(linuxHost),
		`the page posts only ${[...actions].sort().join(' / ')}`
	);
}

// 4. initData-shape parity — both hosts emit every field the page reads.
const FIELDS = ['title', 'label', 'current', 'allowNative', 'nativeLabel', 'noneLabel',
	'searchPlaceholder', 'noResults', 'cancelLabel', 'items'];
for (const f of FIELDS) {
	check(`page reads data.${f}`, script.includes(`data.${f}`) || script.includes(`.${f}`));
	check(`Windows host emits "${f}"`, winHost.includes(`"${f}"`));
	check(`macOS host emits ${f}`, new RegExp(`\\b${f}\\b`).test(macHost));
	check(`Linux host emits ${f}`, new RegExp(`\\b${f}\\b`).test(linuxHost));
}

// 4b. Ordered-item shape — headings ({type,level,text}) + actions ({type,id,label}).
for (const k of ['type', 'level', 'text', 'id', 'label']) {
	check(`page reads item.${k}`, new RegExp(`it\\.${k}|\\.${k}\\b`).test(script));
}
for (const tok of ['"heading"', '"action"', '"level"', '"text"']) {
	check(`Windows host serializes ${tok}`, winHost.includes(tok));
}
check('macOS host builds heading/action items',
	/type\s*=\s*"heading"/.test(macMenu) && /type\s*=\s*"action"/.test(macMenu) && /level\s*=/.test(macMenu));

// 4c. Hierarchy / fold / TOC features present in the frontend.
check('frontend folds headings (toggleFold)', /function toggleFold/.test(script) && /collapsed/.test(script));
check('frontend renders heading levels', /lvl/.test(script) && /level/.test(script));
check('frontend has a table of contents (toggleToc + buildToc)',
	/function toggleToc/.test(script) && /function buildToc/.test(script));
check('index.html exposes the TOC button + drawer',
	/id="toc-btn"/.test(index) && /id="toc"/.test(index));

// 4d. Catalogue is now multi-level (at least one "##" sub-header in sg_order).
const catalogue = read('static/ergopti_plus/_shared/modules/gestures/actions.toml');
check('actions.toml sg_order has h1 group parents (grp_*) + h2 sub-headers (##)',
	/"#grp_/.test(catalogue) && /"##/.test(catalogue));

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
for (const key of ['dialog.action_picker.search', 'dialog.action_picker.no_results',
	'sg_actions.sg_order.header.grp_input', 'sg_actions.sg_order.header.grp_system']) {
	check(`locale has "${key}"`, typeof locale[key] === 'string' && locale[key].length > 0);
}

console.log(`\nResults: ${total_pass} passed, ${total_fail} failed.`);

if (total_fail > 0) {
	process.exit(1);
}
