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
const vm = require('vm');

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

// --- Shared Healthcheck Frontend Checks ---
const SHARED_UI_DIR = 'static/ergopti_plus/_shared/ui/healthcheck';
const SHARED_SCRIPT = SHARED_UI_DIR + '/script.js';

check(
    'Shared: script.js defines window.renderHealthcheck',
    SHARED_SCRIPT,
    /window\.renderHealthcheck\s*=\s*function/
);

check(
    'Shared: style.css exists with .ok / .fail classes',
    SHARED_UI_DIR + '/style.css',
    /\.ok\{/
);

check(
    'Shared: index.html exists and loads script.js',
    SHARED_UI_DIR + '/index.html',
    /script\.js/
);

/**
 * Executes the shared renderer against the macOS-only telemetry shape.
 * A source grep would pass if the label lived in dead code or read the wrong
 * field, so this assertion observes the HTML the user actually sees.
 */
function checkNativeTapTelemetryRender() {
	const content = { innerHTML: '' };
	const sandbox = {
		window: {},
		document: {
			getElementById: () => content,
		},
		escapeHtml: value => String(value),
	};
	const script = fs.readFileSync(path.join(REPO_ROOT, SHARED_SCRIPT), 'utf8');
	vm.runInNewContext(script, sandbox, { filename: SHARED_SCRIPT });
	sandbox.window.renderHealthcheck({
		version: 'test',
		uptime_sec: 0,
		sys: { hs_version: '1.1.1' },
		event_tap_timeout_telemetry: {
			available: false,
			summary: 'unavailable — native contract marker',
		},
	});

	if (content.innerHTML.includes('Native tap timeout telemetry')
		&& content.innerHTML.includes('unavailable — native contract marker')) {
		total_pass++;
		console.log(`  ${PASS_SYMBOL}  Shared: macOS native tap telemetry status is rendered`);
		return;
	}

	total_fail++;
	console.log(`  ${FAIL_SYMBOL}  Shared: macOS native tap telemetry status is rendered`);
	console.log('       Violation: rendered HTML omitted the explicit unavailable status');
}

checkNativeTapTelemetryRender();

/**
 * Executes the shared renderer against a packaged-build snapshot. The report
 * used to label the app bundle "Config dir" and to show a bare "unknown"
 * commit; the configuration folder, the script folder and the commit's origin
 * must each reach the page under their own label.
 */
function checkCommitAndDirectoriesRender() {
	const content = { innerHTML: '' };
	const sandbox = {
		window: {},
		document: {
			getElementById: () => content,
		},
		escapeHtml: value => String(value),
	};
	const script = fs.readFileSync(path.join(REPO_ROOT, SHARED_SCRIPT), 'utf8');
	vm.runInNewContext(script, sandbox, { filename: SHARED_SCRIPT });
	sandbox.window.renderHealthcheck({
		version: 'test',
		uptime_sec: 0,
		sys: {
			hs_version: '1.1.1',
			git_hash: 'f58d15798',
			commit_source: 'build',
			config_dir: '/Volumes/Fixture/alice/Chosen/ergopti_plus/',
			script_dir: '/Applications/ErgoptiPlus.app/Contents/Resources/static/ergopti_plus/macos',
		},
	});
	const html = content.innerHTML;
	const ok = html.includes('<td>Last git commit</td><td>f58d15798 (build)</td>')
		&& html.includes('<td>Config dir</td><td><code>/Volumes/Fixture/alice/Chosen/ergopti_plus/</code></td>')
		&& html.includes('<td>Script dir</td><td><code>/Applications/ErgoptiPlus.app/Contents/Resources/static/ergopti_plus/macos</code></td>');
	if (ok) {
		total_pass++;
		console.log(`  ${PASS_SYMBOL}  Shared: commit origin, config dir and script dir render under their own labels`);
		return;
	}
	total_fail++;
	console.log(`  ${FAIL_SYMBOL}  Shared: commit origin, config dir and script dir render under their own labels`);
	console.log('       Violation: rendered HTML lacks one of the three rows');
}

checkCommitAndDirectoriesRender();

/**
 * Executes the shared renderer against a macOS snapshot whose runtime lacks
 * Screen Recording. A packaged app in that state left Ctrl+H screenshots off
 * the clipboard with no diagnostic saying why, so the state must reach the page
 * and a missing grant must be marked as a failure.
 */
function checkPermissionsRender() {
	const content = { innerHTML: '' };
	const sandbox = {
		window: {},
		document: {
			getElementById: () => content,
		},
		escapeHtml: value => String(value),
	};
	const script = fs.readFileSync(path.join(REPO_ROOT, SHARED_SCRIPT), 'utf8');
	vm.runInNewContext(script, sandbox, { filename: SHARED_SCRIPT });
	sandbox.window.renderHealthcheck({
		version: 'test',
		uptime_sec: 0,
		sys: { hs_version: '1.1.1' },
		permissions: { accessibility: 'granted', screen_recording: 'missing' },
	});
	const html = content.innerHTML;
	const ok = html.includes('<td>Screen Recording</td><td><span class="fail">missing</span></td>')
		&& html.includes('<td>Accessibility</td><td><span class="ok">granted</span></td>');
	if (ok) {
		total_pass++;
		console.log(`  ${PASS_SYMBOL}  Shared: macOS permission states render, a missing grant as a failure`);
		return;
	}
	total_fail++;
	console.log(`  ${FAIL_SYMBOL}  Shared: macOS permission states render, a missing grant as a failure`);
	console.log('       Violation: rendered HTML lacks the permission rows or their status class');
}

checkPermissionsRender();

/**
 * Executes the Linux bridge bootstrap and feeds its native callback a snapshot.
 * This catches the original empty-window failure: a passive renderer can pass
 * every shape assertion while never requesting or receiving production data.
 */
function checkLinuxHealthcheckBridge() {
	const content = { innerHTML: '' };
	const posted = [];
	const sandbox = {
		document: {
			getElementById: () => content,
		},
		escapeHtml: value => String(value),
		makeHostBridge: name => payload => posted.push({ name, payload }),
		decodeHostBridgeResponse: (_isBase64, payload) => JSON.parse(payload),
	};
	sandbox.window = sandbox;
	sandbox.__ergopti_host = 'linux';
	const script = fs.readFileSync(path.join(REPO_ROOT, SHARED_SCRIPT), 'utf8');
	vm.runInNewContext(script, sandbox, { filename: SHARED_SCRIPT });

	const requested = posted.length === 1
		&& posted[0].name === 'healthcheck'
		&& posted[0].payload === 'ready';
	sandbox.__hostBridgeResponse('healthcheck', false, JSON.stringify({
		version: 'linux-contract-marker',
		uptime_sec: 1,
		sys: {},
		ports_validated: [],
		failed_adapters: [],
	}));
	const rendered = content.innerHTML.includes('linux-contract-marker');

	if (requested && rendered) {
		total_pass++;
		console.log(`  ${PASS_SYMBOL}  Linux: page requests and renders its native healthcheck snapshot`);
		return;
	}

	total_fail++;
	console.log(`  ${FAIL_SYMBOL}  Linux: page requests and renders its native healthcheck snapshot`);
	console.log(`       Violation: requested=${requested}, rendered=${rendered}`);
}

checkLinuxHealthcheckBridge();

// --- Hammerspoon (macOS) Checks ---
// The HTML rendering now lives in _shared/ui/healthcheck/; helpers.lua
// has only the state-gathering probes + format_uptime. core.lua loads the
// shared frontend via ui_builder.build_injected_html() and injects the
// snapshot as JSON.
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
    'HS: core wires the sys_info probe (H.sys_info)',
    HS_CORE,
    /H\.sys_info/
);

check(
    'HS: core uses shared healthcheck frontend (ui/healthcheck)',
    HS_CORE,
    /ui\/healthcheck/
);

checkNegative(
    'HS: snapshot_to_html renderer is REMOVED from helpers',
    HS_HELPERS,
    /function H\.snapshot_to_html\(/
);

checkNegative(
    'HS: H.he HTML escaper is REMOVED from helpers',
    HS_HELPERS,
    /function H\.he\(/
);

// --- AutoHotkey (Windows) Checks ---
const AHK_FILE = 'static/ergopti_plus/windows/ui/healthcheck/core.ahk';
const AHK_HELPERS = 'static/ergopti_plus/windows/ui/healthcheck/helpers.ahk';

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

check(
    'AHK: navigates to shared healthcheck frontend via vhost',
    AHK_FILE,
    /ui\/healthcheck\/index\.html/
);

checkNegative(
    'AHK: _HealthCheck_SnapshotToHtml is REMOVED from helpers',
    AHK_HELPERS,
    /_HealthCheck_SnapshotToHtml\(/
);

checkNegative(
    'AHK: _HealthCheck_HE is REMOVED from helpers',
    AHK_HELPERS,
    /_HealthCheck_HE\(/
);

checkNegative(
    'AHK: _HealthCheck_Code is REMOVED from helpers',
    AHK_HELPERS,
    /_HealthCheck_Code\(/
);

console.log(`\nResults: ${total_pass} passed, ${total_fail} failed.`);

if (total_fail > 0) {
    process.exit(1);
}
