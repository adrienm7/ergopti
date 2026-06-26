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
// After the F2 split, healthcheck is ui/healthcheck/{init,core,helpers}.lua,
// mirroring the Windows layout. The probe + window live in core.lua; the
// state-gathering probes + HTML rendering live in helpers.lua. The former
// "forward-declare then assign" idiom (and its shadowing foot-gun) is gone by
// construction — helpers are direct table members on H, resolved at call time —
// so the integrity invariant is now "the renderer/probe are exported on H AND
// core actually wires them in", which is what these checks pin.
const HS_CORE = 'static/ergopti_plus/macos/ui/healthcheck/core.lua';
const HS_HELPERS = 'static/ergopti_plus/macos/ui/healthcheck/helpers.lua';

check(
    'HS: has M.show_window export (core)',
    HS_CORE,
    /function M\.show_window\(\)/
);

check(
    'HS: sys_info probe is defined on the helpers table',
    HS_HELPERS,
    /function H\.sys_info\(\)/
);

check(
    'HS: snapshot_to_html renderer is defined on the helpers table',
    HS_HELPERS,
    /function H\.snapshot_to_html\(/
);

check(
    'HS: core wires the sys_info probe (H.sys_info)',
    HS_CORE,
    /H\.sys_info/
);

check(
    'HS: core wires the snapshot renderer (H.snapshot_to_html)',
    HS_CORE,
    /H\.snapshot_to_html/
);

// --- AutoHotkey (Windows) Checks ---
// Windows healthcheck was moved lib/ → ui/healthcheck/{init,core,helpers}.ahk;
// the probe + window + WebView2 host live in core.ahk.
const AHK_FILE = 'static/ergopti_plus/windows/ui/healthcheck/core.ahk';

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
