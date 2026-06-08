// tools/test/test-diagnostic-ui-integrity.cjs

/**
 * ==============================================================================
 * MODULE: Diagnostic UI Integrity Validation
 * DESCRIPTION:
 * Ensures that the diagnostic (healthcheck) UIs on both Windows and macOS
 * are structurally sound and free from known scoping regressions.
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

console.log('\n=== Diagnostic UI Integrity Validation ===');

// --- Hammerspoon (macOS) Checks ---
const HS_FILE = 'static/ergopti_plus/macos/lib/healthcheck.lua';

check(
    'HS: has M.show_window export',
    HS_FILE,
    /function M\.show_window\(\)/
);

check(
    'HS: has forward declarations for internal helpers',
    HS_FILE,
    /local _sys_info[\s\S]*local _snapshot_to_html/
);

checkNegative(
    'HS: NO shadowed implementation for _sys_info',
    HS_FILE,
    /local function _sys_info\(\)/
);

checkNegative(
    'HS: NO shadowed implementation for _snapshot_to_html',
    HS_FILE,
    /local function _snapshot_to_html\(/
);

check(
    'HS: correct assignment for _sys_info',
    HS_FILE,
    /_sys_info = function\(\)/
);

check(
    'HS: correct assignment for _snapshot_to_html',
    HS_FILE,
    /_snapshot_to_html = function\(/
);

// --- AutoHotkey (Windows) Checks ---
const AHK_FILE = 'static/ergopti_plus/windows/lib/healthcheck.ahk';

check(
    'AHK: has HealthCheck_ShowWindow export',
    AHK_FILE,
    /HealthCheck_ShowWindow\(\)/
);

check(
    'AHK: calls HealthCheck_Run',
    AHK_FILE,
    /Snapshot\s*:=\s*HealthCheck_Run\(\)/
);

check(
    'AHK: uses WebView2 for the UI',
    AHK_FILE,
    /WebView2\.create/
);

check(
    'AHK: has fallback to native Edit control',
    AHK_FILE,
    /_HealthCheck_AddFallbackEdit/
);

console.log(`\nResults: ${total_pass} passed, ${total_fail} failed.`);

if (total_fail > 0) {
    process.exit(1);
}
