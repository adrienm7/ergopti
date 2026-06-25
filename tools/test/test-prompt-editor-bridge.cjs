// tools/test/test-prompt-editor-bridge.cjs

/**
 * ==============================================================================
 * MODULE: Prompt Editor Shared-Frontend Bridge Contract Guard
 * DESCRIPTION:
 * Guards the port of the LLM prompt-profile editor to a shared WebView2 /
 * WKWebView frontend at _shared/ui/prompt_editor/. The single frontend must
 * drive BOTH drivers, so several contracts have to hold or the Windows editor
 * silently breaks:
 *
 * 1. Host-agnostic post — script.js must probe window.chrome.webview (Windows
 *    WebView2, which takes a JSON string) BEFORE window.webkit (macOS WKWebView,
 *    which takes an object). A regression to the macOS-only postMessage leaves
 *    the Windows editor unable to save or cancel.
 * 2. Action parity — every {action} the page posts (save / cancel) must be
 *    handled by the Windows host (_PromptEdWeb_OnWebMessage).
 * 3. Field mapping — the Windows profile uses system_single, not raw_prompt, so
 *    the host must map the webview's prompt field onto system_single on save and
 *    feed system_single back into the init payload.
 * 4. Native fallback preserved — the InputBox wizard must remain (gated behind
 *    the webview TryOpen) so a machine without the WebView2 runtime still works.
 *
 * FEATURES & RATIONALE:
 *   Actions are extracted from script.js so the test tracks the UI as it
 *   evolves rather than hardcoding a list that can drift.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const PASS_SYMBOL = '✓';
const FAIL_SYMBOL = '✗';

const REPO_ROOT = path.resolve(__dirname, '../..');
const FRONT_DIR = 'static/ergopti_plus/_shared/ui/prompt_editor';
const SCRIPT = `${FRONT_DIR}/script.js`;
const INDEX = `${FRONT_DIR}/index.html`;
const WIN_HOST = 'static/ergopti_plus/windows/ui/prompt_editor/init.ahk';
const WIN_MENU = 'static/ergopti_plus/windows/ui/menu/menu_llm/menu_profiles.ahk';

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

console.log('\n=== Prompt Editor Shared-Frontend Bridge ===');

let script = '';
let index = '';
let host = '';
let menu = '';
try { script = read(SCRIPT); } catch (err) { check('script.js readable at shared path', false, err.message); }
try { index = read(INDEX); } catch (err) { check('index.html readable at shared path', false, err.message); }
try { host = read(WIN_HOST); } catch (err) { check('Windows host readable', false, err.message); }
try { menu = read(WIN_MENU); } catch (err) { check('Windows menu_profiles readable', false, err.message); }

// 1. Host-agnostic post(): chrome.webview probed before webkit.
const chromeIdx = script.indexOf('window.chrome.webview');
const webkitIdx = script.indexOf('window.webkit');
check(
	'script.js probes window.chrome.webview (Windows channel present)',
	chromeIdx !== -1,
	'The Windows WebView2 branch is missing — the editor cannot post to AHK.'
);
check(
	'script.js still supports window.webkit (macOS channel present)',
	webkitIdx !== -1,
	'The macOS WKWebView branch was dropped.'
);
check(
	'script.js posts a JSON string to the WebView2 channel',
	/chrome\.webview\.postMessage\(\s*JSON\.stringify\(/.test(script),
	'WebView2 requires a string payload — JSON.stringify is missing.'
);
check(
	'chrome.webview is probed before webkit',
	chromeIdx !== -1 && webkitIdx !== -1 && chromeIdx < webkitIdx,
	'On Windows both objects may exist; the WebView2 branch must win.'
);

// 2. index.html references the shared i18n.js one level up (../i18n.js).
check(
	'index.html loads ../i18n.js (shared loader, correct depth)',
	/src=["']\.\.\/i18n\.js["']/.test(index) && !/\.\.\/\.\.\//.test(index),
	'After the move to _shared/ui/<name>/, i18n.js sits at ../i18n.js.'
);

// 3. Action parity — every action the page posts is handled by the Windows host.
const actions = new Set();
const actionRe = /action:\s*'([a-z_]+)'/g;
let m;
while ((m = actionRe.exec(script)) !== null) actions.add(m[1]);
check(
	'script.js posts save + cancel',
	actions.has('save') && actions.has('cancel'),
	`Found: ${[...actions].join(', ')}`
);
for (const action of [...actions].sort()) {
	check(
		`Windows host handles action "${action}"`,
		host.includes(`"${action}"`),
		`_PromptEdWeb_OnWebMessage has no branch for "${action}".`
	);
}

// 4. Field mapping — host maps the webview prompt onto the Windows system_single.
check(
	'Windows host writes system_single on save',
	/"system_single"\]\s*:=\s*Prompt/.test(host) || /"system_single",\s*Prompt/.test(host),
	'The webview prompt field must map onto the Windows profile system_single.'
);
check(
	'Windows host seeds the editor from system_single',
	host.includes('Existing["system_single"]'),
	'Editing an existing profile must pre-fill from its system_single value.'
);

// 5. init payload shape consumed by the frontend init(data).
for (const key of ['title', 'name', 'mode', 'prompt']) {
	check(
		`Windows host init payload carries "${key}"`,
		host.includes(`"${key}"`),
		`The frontend init(data) reads data.${key}.`
	);
}

// 6. Native InputBox fallback preserved, gated behind the webview TryOpen.
check(
	'create profile tries the webview first',
	/_PromptEdWeb_TryOpen\(0\)/.test(menu),
	'LLM_Menu_PromptCreateProfile must call _PromptEdWeb_TryOpen(0) before InputBox.'
);
check(
	'edit profile tries the webview first',
	/_PromptEdWeb_TryOpen\(profile\)/.test(menu),
	'LLM_Menu_PromptEditProfile must call _PromptEdWeb_TryOpen(profile) before InputBox.'
);
check(
	'native InputBox wizard is still present (fallback)',
	menu.includes('InputBox('),
	'The native InputBox wizard must remain as a fallback when WebView2 is absent.'
);

console.log(`\nResults: ${total_pass} passed, ${total_fail} failed.`);

if (total_fail > 0) {
	process.exit(1);
}
