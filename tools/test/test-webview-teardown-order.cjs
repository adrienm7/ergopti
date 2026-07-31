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
 * HOSTS ARE DISCOVERED, NOT LISTED:
 * This guard used to carry a hand-written list of seven hosts. Thirteen files
 * close a WebView2 controller, so six were unwatched — including the WebViewHost
 * factory in lib/webview_utils.ahk, which is the shape every future host is meant
 * to be built from. The list is now derived from the source.
 *
 * AND IT USED TO PASS FOR THE WRONG REASON:
 * The old check compared the FIRST occurrence of a handle name against the Close.
 * The first occurrence is the `global _X_MsgSub := unset` declaration at the top
 * of the file, which precedes everything — so the assertion held whether or not
 * the teardown released anything at all. Deleting the release from the teardown
 * routine would not have failed it. Declarations are now excluded: only
 * assignments after the file's first function/method definition count as
 * releases, and each handle must have one.
 *
 * It also pinned the exact internal whitespace of each line
 * ('_HsEdWeb_MsgSub     := unset'), so a reformat broke it with "line not found"
 * rather than a behaviour signal. Matching is whitespace-insensitive now.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const PASS_SYMBOL = '✓';
const FAIL_SYMBOL = '✗';

const REPO_ROOT = path.resolve(__dirname, '../..');
const WINDOWS_DIR = path.join(REPO_ROOT, 'static', 'ergopti_plus', 'windows');

// A WebView2 controller being closed. Matches both the global-variable hosts
// (`_HsEdWeb_Controller.Close()`) and the class-based factory
// (`this.Controller.Close()`).
const CLOSE_RE = /(\w+)\.Close\(\)/;
// A subscription handle being released. The name is what the thqby binding
// returns from add_WebMessageReceived / add_NavigationCompleted, so it always
// carries "Sub" — `_OnbWeb_MsgSub`, `this.NavSub`.
const RELEASE_RE = /(?:this\.)?(\w*Sub)\s*:=\s*unset/;
// A function or method definition, at any indentation: `Name(args) {`.
const FUNC_DEF_RE = /^\s*\w+\([^)]*\)\s*\{/;

/**
 * Every production .ahk file under windows/ (tests excluded — they stub these
 * very patterns and would match themselves).
 * @param {string} dir Absolute directory to walk.
 * @param {string[]} acc Accumulator.
 * @returns {string[]} Absolute paths.
 */
function walk(dir, acc = []) {
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) {
			if (e.name !== 'tests' && e.name !== '_generated') walk(p, acc);
		} else if (e.name.endsWith('.ahk')) {
			acc.push(p);
		}
	}
	return acc;
}

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

let hostsSeen = 0;

for (const abs of walk(WINDOWS_DIR)) {
	const rel = path.relative(REPO_ROOT, abs).replace(/\\/g, '/');
	const lines = fs.readFileSync(abs, 'utf8').split(/\r?\n/);

	const closes = [];
	const releases = [];
	let firstFuncLine = Infinity;

	lines.forEach((line, i) => {
		const trimmed = line.trim();
		if (trimmed.startsWith(';')) return; // prose describes this pattern at length
		if (i < firstFuncLine && FUNC_DEF_RE.test(line)) firstFuncLine = i;

		const c = trimmed.match(CLOSE_RE);
		if (c && /controller/i.test(c[1])) closes.push({ line: i, name: c[1] });

		const r = trimmed.match(RELEASE_RE);
		// Before the first function definition these are declarations, not
		// releases. Counting them is what made the old check vacuous.
		if (r && i > firstFuncLine) releases.push({ line: i, name: r[1] });
	});

	if (closes.length === 0) continue;
	hostsSeen++;

	// A host with no subscription handles has no ordering to get wrong — the
	// keylogger's abort path closes a controller it was handed and subscribes to
	// nothing.
	const declaresSubs = lines.some((l) => !l.trim().startsWith(';') && /\w*Sub\s*:=/.test(l));
	if (!declaresSubs) {
		pass(`${rel} — closes a controller, stores no subscription handle`);
		continue;
	}

	if (releases.length === 0) {
		fail(
			`${rel} — releases its subscription handles`,
			'The file stores subscription handles but its teardown releases none of them. ' +
				'Each must be dropped (:= unset) while the controller is still alive.'
		);
		continue;
	}

	for (const close of closes) {
		const late = releases.filter((r) => r.line > close.line);
		if (late.length > 0) {
			for (const r of late) {
				fail(
					`${rel}:${r.line + 1} — "${r.name} := unset" before ${close.name}.Close()`,
					`Subscription is dropped AFTER ${close.name}.Close() (line ${close.line + 1}) — ` +
						'its __Delete calls remove_X on a dead COM object, and an uncaught throw in a ' +
						'GUI Close thread terminates the whole script.'
				);
			}
		} else {
			const names = [...new Set(releases.map((r) => r.name))].join(', ');
			pass(`${rel} — ${names} released before ${close.name}.Close()`);
		}
	}
}

// A walk that finds nothing would report a clean run over an empty set. The
// count is deliberately a floor, not an equality: a new host must not have to
// edit this file.
const MIN_HOSTS = 12;
if (hostsSeen < MIN_HOSTS) {
	fail(
		'host discovery',
		`Found only ${hostsSeen} WebView2 host(s) closing a controller, expected at least ${MIN_HOSTS}. ` +
			'The walk or the Close() pattern is broken — this guard would pass over nothing.'
	);
}

console.log(`\nResults: ${total_pass} passed, ${total_fail} failed (${hostsSeen} hosts discovered).`);

if (total_fail > 0) {
	process.exit(1);
}
