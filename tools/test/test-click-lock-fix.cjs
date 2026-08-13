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

console.log('\n=== Click Lock Fix Structural Validation ===');

// Check AHK Fixes
//
// The watcher is a NON-CONSUMING ("V") Level-3 InputHook: keys pass through to the
// focused app instead of being swallowed and re-sent. This replaced the earlier
// block-then-SendLevel(3)-resend design; asserting "V L3" locks the current root
// cause so a regression back to a consuming hook (which would drop the keystroke
// that releases the hold) fails here.
check(
    'AHK: keyboard watcher is a non-consuming Level-3 InputHook ("V L3")',
    'static/ergopti_plus/windows/modules/gestures/click.ahk',
    /GestureKeyboardHook := InputHook\("V L3"\)[\s\S]*\.KeyOpt\("\{All\}", "N"\)/
);

check(
    'AHK: GestureOnKeyDown stops the hook and releases both held buttons (suspend-aware)',
    'static/ergopti_plus/windows/modules/gestures/click.ahk',
    /GestureOnKeyDown\(ih, vk, sc\) \{[\s\S]*A_IsSuspended[\s\S]*ih\.Stop\(\)[\s\S]*GestureReleaseLeftClick\(\)[\s\S]*GestureReleaseRightClick\(\)[\s\S]*\}/
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
