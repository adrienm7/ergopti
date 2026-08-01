// tools/test/test-ui-focus-fix.cjs

/**
 * ==============================================================================
 * MODULE: Hammerspoon UI Focus Fix Structural Validation
 * DESCRIPTION:
 * Ensures that the focus and Z-order fixes are present in the Hammerspoon
 * UI modules and the central builder.
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

console.log('\n=== Hammerspoon UI Focus Fix Structural Validation ===');

// Check ui_builder.lua fixes
check(
    'UI Builder: focus retry mechanism (try_focus)',
    'static/ergopti_plus/macos/ui/ui_builder.lua',
    /local function try_focus\(\)/
);

check(
    'UI Builder: retry loop calls hs.timer.doAfter',
    'static/ergopti_plus/macos/ui/ui_builder.lua',
    /hs\.timer\.doAfter\(0\.05, try_focus\)/
);

check(
    'UI Builder: aggressive app activation (hs.focus(true))',
    'static/ergopti_plus/macos/ui/ui_builder.lua',
    /hs\.focus\(true\)/
);

check(
    'UI Builder: default level is floating',
    'static/ergopti_plus/macos/ui/ui_builder.lua',
    /wv:level\(opts\.level or hs\.drawing\.windowLevels\.floating\)/
);

// Check Changelog Fix
check(
    'Changelog: explicitly set level to floating',
    'static/ergopti_plus/macos/ui/changelog/init.lua',
    /level\s*=\s*hs\.drawing\.windowLevels\.floating/
);

// Check Dialog Util Fix
check(
    'Dialog Util: use hs.focus(true) with force flag',
    'static/ergopti_plus/macos/infra/dialog_util.lua',
    /hs\.focus\(true\)/
);

// Check Metrics Typing Cleanup
checkNegative(
    'Metrics Typing: redundant raise_now removed',
    'static/ergopti_plus/macos/ui/metrics_typing/init.lua',
    /local function raise_now/
);

checkNegative(
    'Metrics Typing: redundant poll_and_set_behavior removed',
    'static/ergopti_plus/macos/ui/metrics_typing/init.lua',
    /local function poll_and_set_behavior/
);

// Global Regression: No raw hs.dialog.blockAlert in UI/lib (should use dialog_util)
// We exclude dialog_util itself from this check.
const filesToAudit = [
    'static/ergopti_plus/macos/ui/onboarding/init.lua',
    'static/ergopti_plus/macos/ui/healthcheck/core.lua',
    'static/ergopti_plus/macos/modules/diagnostics/crash_reporter.lua',
    'static/ergopti_plus/macos/modules/karabiner/onboarding.lua'
];

filesToAudit.forEach(f => {
    checkNegative(
        `Global Audit: No raw hs.dialog.blockAlert in ${f}`,
        f,
        /hs\.dialog\.blockAlert/
    );
});

console.log(`\nResults: ${total_pass} passed, ${total_fail} failed.`);

if (total_fail > 0) {
    process.exit(1);
}
