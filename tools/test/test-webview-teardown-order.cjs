// tools/test/test-webview-teardown-order.cjs

/**
 * ==============================================================================
 * MODULE: WebView2 Host Teardown-Order Regression Guard
 * DESCRIPTION:
 * Encodes the root cause of a crash where closing a WebView2 host window (the
 * personal hotstring editor, or the onboarding wizard) also terminated the whole
 * Ergopti+ AHK script.
 *
 * The thqby WebView2 binding returns a subscription object from
 * WebMessageReceived()/NavigationCompleted(); its __Delete unsubscribes by
 * calling remove_X on the controller. If the subscription handle is dropped
 * (`:= unset`) AFTER Controller.Close(), that remove_X hits a dead COM object and
 * throws — and an uncaught exception raised inside a GUI Close-event thread
 * terminates the entire AHK process. The fix is to release the subscription
 * handles FIRST, while the controller is still alive, then Close() the controller.
 *
 * FEATURES & RATIONALE:
 * 1. Asserts, for every WebView2 host that stores subscription handles, that each
 *    `<sub> := unset` line precedes the matching `Controller.Close()` line inside
 *    its reset/teardown routine. A regression that reorders them (or appends a new
 *    stored subscription after Close) fails here instead of in a user's face.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const PASS_SYMBOL = '✓';
const FAIL_SYMBOL = '✗';

const REPO_ROOT = path.resolve(__dirname, '../..');

// Each host: the file, the Controller.Close() marker, and the subscription
// handle releases that MUST appear before it.
const HOSTS = [
	{
		label: 'hotstring editor host',
		file: 'static/ergopti_plus/windows/ui/personal_toml_editor_webview.ahk',
		close: '_HsEdWeb_Controller.Close()',
		subs: ['_HsEdWeb_MsgSub     := unset', '_HsEdWeb_NavSub     := unset']
	},
	{
		label: 'onboarding wizard host',
		file: 'static/ergopti_plus/windows/ui/onboarding/webview.ahk',
		close: '_OnbWeb_Controller.Close()',
		subs: ['_OnbWeb_MsgSub := unset']
	},
	{
		label: 'paths editor host',
		file: 'static/ergopti_plus/windows/ui/paths_editor/init.ahk',
		close: '_PathsEdWeb_Controller.Close()',
		subs: ['_PathsEdWeb_MsgSub := unset', '_PathsEdWeb_NavSub := unset']
	},
	{
		label: 'personal info editor host',
		file: 'static/ergopti_plus/windows/ui/personal_info_editor/init.ahk',
		close: '_PiEdWeb_Controller.Close()',
		subs: ['_PiEdWeb_MsgSub := unset', '_PiEdWeb_NavSub := unset']
	},
	{
		label: 'hotstrings config window host',
		file: 'static/ergopti_plus/windows/ui/hotstrings_config_window/webview.ahk',
		close: '_HCWWeb_Controller.Close()',
		subs: ['_HCWWeb_MsgSub     := unset', '_HCWWeb_NavSub     := unset']
	}
];

let total_pass = 0;
let total_fail = 0;

function fail(label, detail) {
	total_fail++;
	console.log(`  ${FAIL_SYMBOL}  ${label}`);
	console.log(`       ${detail}`);
}

function pass(label) {
	total_pass++;
	console.log(`  ${PASS_SYMBOL}  ${label}`);
}

console.log('\n=== WebView2 Host Teardown Order ===');

for (const host of HOSTS) {
	let content;
	try {
		content = fs.readFileSync(path.join(REPO_ROOT, host.file), 'utf8');
	} catch (err) {
		fail(host.label, `Error reading ${host.file}: ${err.message}`);
		continue;
	}

	const closeIdx = content.indexOf(host.close);
	if (closeIdx === -1) {
		fail(host.label, `Marker not found: ${host.close} in ${host.file}`);
		continue;
	}

	for (const sub of host.subs) {
		const subIdx = content.indexOf(sub);
		if (subIdx === -1) {
			fail(`${host.label} — releases "${sub.trim()}"`, `Line not found in ${host.file}`);
		} else if (subIdx > closeIdx) {
			fail(
				`${host.label} — "${sub.trim()}" before Controller.Close()`,
				`Subscription is dropped AFTER Controller.Close() — closing the window will crash AHK.`
			);
		} else {
			pass(`${host.label} — "${sub.trim()}" released before Controller.Close()`);
		}
	}
}

console.log(`\nResults: ${total_pass} passed, ${total_fail} failed.`);

if (total_fail > 0) {
	process.exit(1);
}
