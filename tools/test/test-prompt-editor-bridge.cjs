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
 * 5. Immutable context — init must carry an edit id + epoch that every deferred
 *    save/cancel echoes, and both the page and host must reject stale epochs.
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
const HOST_BRIDGE = 'static/ergopti_plus/_shared/ui/host_bridge.js';
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
let bridge = '';
let index = '';
let host = '';
let menu = '';
try { script = read(SCRIPT); } catch (err) { check('script.js readable at shared path', false, err.message); }
try { bridge = read(HOST_BRIDGE); } catch (err) { check('host_bridge.js readable', false, err.message); }
try { index = read(INDEX); } catch (err) { check('index.html readable at shared path', false, err.message); }
try { host = read(WIN_HOST); } catch (err) { check('Windows host readable', false, err.message); }
try { menu = read(WIN_MENU); } catch (err) { check('Windows menu_profiles readable', false, err.message); }

// 1. Host-agnostic post(): chrome.webview probed before webkit.
// Bridge patterns now live in host_bridge.js (shared across all webview apps).
const chromeIdx = bridge.indexOf('window.chrome.webview');
const webkitIdx = bridge.indexOf('window.webkit');
check(
	'host_bridge.js probes window.chrome.webview (Windows channel present)',
	chromeIdx !== -1,
	'The Windows WebView2 branch is missing from host_bridge.js — the editor cannot post to AHK.'
);
check(
	'host_bridge.js still supports window.webkit (macOS channel present)',
	webkitIdx !== -1,
	'The macOS WKWebView branch was dropped from host_bridge.js.'
);
check(
	'host_bridge.js posts a JSON string to the WebView2 channel',
	/chrome\.webview\.postMessage\(/.test(bridge) && /JSON\.stringify\(/.test(bridge),
	'WebView2 requires a string payload — JSON.stringify is missing from host_bridge.js.'
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
check(
	'index.html loads host_bridge.js (../host_bridge.js)',
	/src=["']\.\.\/host_bridge\.js["']/.test(index),
	'host_bridge.js must be loaded before script.js in index.html.'
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
for (const key of ['edit_id', 'epoch', 'title', 'name', 'mode', 'prompt']) {
	check(
		`Windows host init payload carries "${key}"`,
		host.includes(`"${key}"`),
		`The frontend init(data) reads data.${key}.`
	);
}

// 6. The page and host must carry the same immutable context through deferral.
check(
	'frontend freezes the active prompt context',
	/Object\.freeze\(\{\s*edit_id:/.test(script),
	'The page must snapshot edit_id + epoch instead of reading mutable host state at Save time.'
);
check(
	'frontend rejects an init older than the displayed epoch',
	/nextContext\.epoch\s*<\s*activePromptContext\.epoch/.test(script),
	'An older fire-and-forget init may otherwise repaint a newer singleton context.'
);
check(
	'save and cancel both echo the displayed edit id',
	(script.match(/edit_id:\s*activePromptContext\.edit_id/g) || []).length === 2,
	'Every page action that can mutate or close the host must carry the displayed edit id.'
);
check(
	'save and cancel both echo the displayed epoch',
	(script.match(/epoch:\s*activePromptContext\.epoch/g) || []).length === 2,
	'Every page action that can mutate or close the host must carry the displayed epoch.'
);
check(
	'Windows host binds context scalars into deferred save',
	/_PromptEdWeb_Save\.Bind\(EditId,\s*Epoch,/.test(host),
	'The timer callback must own edit_id + epoch instead of reading _PromptEdWeb_EditId after yielding.'
);
check(
	'Windows host fences every deferred context action',
	host.includes('_PromptEdWeb_IsCurrentContext(EditId, Epoch)'),
	'Save, close and init continuations must reject callbacks from an older display context.'
);

// 7. Native InputBox fallback preserved, gated behind the webview TryOpen.
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
