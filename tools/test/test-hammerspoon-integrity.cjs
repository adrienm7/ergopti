// tools/test/test-hammerspoon-integrity.cjs

/**
 * ==============================================================================
 * MODULE: Hammerspoon Integrity Validation
 * DESCRIPTION:
 * Proactively verifies that the Hammerspoon codebase adheres to quality
 * standards: no global leaks in key modules, all modules expose M.stop(),
 * and critical initialization calls are present.
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

function checkNegative(label, file, pattern) {
    const filePath = path.join(REPO_ROOT, file);
    try {
        const content = fs.readFileSync(filePath, 'utf8');
        if (!pattern.test(content)) {
            total_pass++;
            console.log(`  ${PASS_SYMBOL}  ${label}`);
        } else {
            total_fail++;
            console.log(`  ${FAIL_SYMBOL}  ${label}`);
            console.log(`       Violation: Forbidden pattern FOUND in ${file}`);
        }
    } catch (err) {
        total_fail++;
        console.log(`  ${FAIL_SYMBOL}  ${label}`);
        console.log(`       Error: ${err.message}`);
    }
}

console.log('\n=== Hammerspoon Code Integrity Validation ===');

// --- Global Leak Audit ---
// F-L5/F-I2: the gestureInProgress flag was write-only dead state (set but never
// read — the drag-protect guard it claimed to provide was never wired). It was
// removed entirely, so it must NOT reappear in any form (local OR global leak).
checkNegative(
    'Gestures Actions: dead gestureInProgress flag stays removed',
    'static/ergopti_plus/macos/modules/gestures/actions_click.lua',
    /gestureInProgress/
);

// --- Initialization Audit ---
check(
    'Init: locale trigger provider is wired',
    'static/ergopti_plus/macos/init.lua',
    /locale_mod\.set_trigger_provider/
);

check(
    'Keymap: exposes get_trigger_char',
    'static/ergopti_plus/macos/modules/keymap/init.lua',
    /function M\.get_trigger_char\(\)/
);

// --- Resource Management Audit (M.stop) ---
const modulesWithStop = [
    'static/ergopti_plus/macos/modules/gestures/init.lua',
    'static/ergopti_plus/macos/modules/keymap/init.lua',
    'static/ergopti_plus/macos/modules/shortcuts/init.lua',
    'static/ergopti_plus/macos/modules/shortcuts/keyboard_shortcuts.lua',
    'static/ergopti_plus/macos/modules/shortcuts/script_control.lua',
    'static/ergopti_plus/macos/modules/dynamic_hotstrings/init.lua',
];

modulesWithStop.forEach(f => {
    check(
        `Lifecycle: ${f} exposes M.stop()`,
        f,
        /function M\.stop\(\)/
    );
});

// --- Shutdown Hook Audit ---
check(
    'Shutdown: calls modules stop()',
    'static/ergopti_plus/macos/init.lua',
    /keymap\.stop\(\)[\s\S]*gestures\.stop\(\)[\s\S]*shortcuts\.stop\(\)/
);

// --- Code Quality Audit ---
check(
    'Gestures: uses Logger.pcall for frame processing',
    'static/ergopti_plus/macos/modules/gestures/init.lua',
    /Logger\.pcall\(LOG, Engine\.process_frame/
);

console.log(`\nResults: ${total_pass} passed, ${total_fail} failed.`);

if (total_fail > 0) {
    process.exit(1);
}
