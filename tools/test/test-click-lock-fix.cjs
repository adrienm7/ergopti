// tools/test/test-click-lock-fix.cjs

/**
 * ==============================================================================
 * MODULE: Click Lock Fix Structural Validation
 * DESCRIPTION:
 * Ensures that the click lock deactivation fixes are present in the source files.
 * Since functional testing of touchpad gestures is not feasible in a headless
 * environment, this test prevents accidental reverts of the fix.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const PASS_SYMBOL = '✓';
const FAIL_SYMBOL = '✗';

const REPO_ROOT = path.resolve(__dirname, '../..');

let total_pass = 0;
let total_fail = 0;

function check(label, file, pattern) {
    const filePath = path.join(REPO_ROOT, file);
    try {
        const content = fs.readFileSync(filePath, 'utf8');
        if (pattern.test(content)) {
            total_pass++;
            console.log(`  ${PASS_SYMBOL}  ${label}`);
        } else {
            total_fail++;
            console.log(`  ${FAIL_SYMBOL}  ${label}`);
            console.log(`       Violation: Pattern not found in ${file}`);
        }
    } catch (err) {
        total_fail++;
        console.log(`  ${FAIL_SYMBOL}  ${label}`);
        console.log(`       Error: ${err.message}`);
    }
}

function read(file) {
	return fs.readFileSync(path.join(REPO_ROOT, file), 'utf8').replace(/^\uFEFF/, '');
}

function ahkFunctionBody(source, name) {
	const uncommented = source.replace(/^\s*;.*$/gm, '');
	const signature = new RegExp(`(?:^|\\n)${name}\\s*\\([^\\n]*\\)\\s*\\{`, 'm');
	const match = signature.exec(uncommented);
	if (!match) return '';
	const open = uncommented.indexOf('{', match.index);
	let depth = 0;
	let quoted = false;
	for (let i = open; i < uncommented.length; i++) {
		const char = uncommented[i];
		if (char === '`' && quoted) {
			i++;
			continue;
		}
		if (char === '"') {
			quoted = !quoted;
			continue;
		}
		if (quoted) continue;
		if (char === '{') depth++;
		if (char === '}' && --depth === 0) return uncommented.slice(open + 1, i);
	}
	return '';
}

function checkSource(label, source, predicate, violation) {
	if (predicate(source)) {
		total_pass++;
		console.log(`  ${PASS_SYMBOL}  ${label}`);
		return;
	}
	total_fail++;
	console.log(`  ${FAIL_SYMBOL}  ${label}`);
	console.log(`       Violation: ${violation}`);
}

console.log('\n=== Click Lock Fix Structural Validation ===');

// Check AHK Fixes
//
const clickSource = read('static/ergopti_plus/windows/modules/gestures/click.ahk');
const startWatcherBody = ahkFunctionBody(clickSource, 'GestureStartKeyboardWatcher');
const onKeyDownBody = ahkFunctionBody(clickSource, 'GestureOnKeyDown');

// The watcher is non-consuming, publishes its exact cleanup owner before native
// admission, and lets the release transactions retire it only after Button Up.
checkSource(
	'AHK: keyboard watcher is a non-consuming Level-3 InputHook ("V L3")',
	startWatcherBody,
	(body) => /Hook\s*:=\s*InputHook\("V L3"\)/.test(body)
		&& /Hook\.KeyOpt\("\{All\}", "N"\)/.test(body),
	'GestureStartKeyboardWatcher must construct InputHook("V L3") and subscribe to every key'
);

checkSource(
	'AHK: keyboard watcher publishes exact ownership before native Start',
	startWatcherBody,
	(body) => {
		const construct = body.indexOf('Hook := InputHook("V L3")');
		const publish = body.indexOf('GestureKeyboardHook := Hook');
		const start = body.indexOf('Hook.Start()');
		return construct >= 0 && publish > construct && start > publish;
	},
	'watcher construction, publication, and Start must remain in that order'
);

checkSource(
	'AHK: GestureOnKeyDown keeps release ownership on normal and suspended paths',
	onKeyDownBody,
	(body) => body.includes('A_IsSuspended')
		&& (body.match(/GestureReleaseLeftClick\(\)/g) || []).length === 2
		&& (body.match(/GestureReleaseRightClick\(\)/g) || []).length === 2
		&& !/\bih\.Stop\(\)/.test(body),
	'keypress handling must delegate both release transactions on both paths without stopping their retry owner first'
);

// Check Hammerspoon Fixes
check(
	'HS: click_key_watcher includes flagsChanged through its event-types alias',
	'static/ergopti_plus/macos/modules/gestures/actions_click.lua',
	/local function construct_click_key_watcher\([\s\S]*local ev_types = hs\.eventtap\.event\.types[\s\S]*construct_eventtap\(\{\s*ev_types\.keyDown\s*,\s*ev_types\.flagsChanged\s*\}/
);

console.log(`\nResults: ${total_pass} passed, ${total_fail} failed.`);

if (total_fail > 0) {
    process.exit(1);
}
