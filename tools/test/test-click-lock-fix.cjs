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
check(
    'AHK: InputHook level set to L3',
    'static/ergopti_plus/windows/modules/gestures.ahk',
    /InputHook\("L3"\)/
);

check(
    'AHK: GestureDispatch releases held clicks',
    'static/ergopti_plus/windows/modules/gestures.ahk',
    /if \(ActionName != "left_click_toggle" && ActionName != "right_click_toggle"\) \{[\s\S]*GestureReleaseLeftClick\(\)[\s\S]*GestureReleaseRightClick\(\)[\s\S]*\}/
);

// Check Hammerspoon Fixes
check(
    'HS: click_key_watcher includes flagsChanged',
    'static/ergopti_plus/macos/modules/gestures/actions.lua',
    /hs\.eventtap\.event\.types\.flagsChanged/
);

console.log(`\nResults: ${total_pass} passed, ${total_fail} failed.`);

if (total_fail > 0) {
    process.exit(1);
}
