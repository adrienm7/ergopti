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
        `Lifecycle: ${f} exposes M.stop(...)`,
        f,
        /function M\.stop\([^)]*\)/
    );
});

// --- Controlled teardown / native shutdown audit ---
// Controlled reload/exit owns the retryable module teardown transaction. The
// native Hammerspoon callback deliberately leaves local consumers live until
// process exit while its asynchronous exact-lease fence and launcher EOF remain
// armed; requiring direct stop calls from that callback would reintroduce the
// missing-output window guarded by the Lua lifecycle tests.
check(
    'Controlled teardown: calls keymap, gestures, and shortcuts stop in order',
    'static/ergopti_plus/macos/init.lua',
    /return keymap\.stop\(true\)[\s\S]*return gestures\.stop\(\)[\s\S]*return shortcuts\.stop\(\)/
);

check(
    'Controlled teardown: drains owners before the dependent timer finalizer',
    'static/ergopti_plus/macos/init.lua',
    /name\s*=\s*["']timer-scheduler["'][\s\S]*TeardownTransaction\.run_with_finalizer\([\s\S]*_local_teardown_state,[\s\S]*steps,[\s\S]*timer_finalizer/
);

check(
    'Termination coordinator: owns the controlled teardown callback',
    'static/ergopti_plus/macos/init.lua',
    /TerminationCoordinator\.init\([\s\S]*teardown\s*=\s*teardown_all_resources/
);

check(
    'Native shutdown: exact-lease handoff remains armed',
    'static/ergopti_plus/macos/init.lua',
    /hs\.shutdownCallback\s*=\s*shutdown_all_resources/
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
