// tools/test/test-webview-host-pause-census.cjs

/**
 * ==============================================================================
 * MODULE: Windows WebViewHost Pause Census
 * DESCRIPTION:
 * A pause stops typing, not configuration (EDD-1): on macOS and Linux every
 * configuration window answers its page while the driver is paused. On
 * Windows, WebViewHost drops every page message, defers the ready and refuses
 * every script while suspended, unless the window opens with
 * `RunsWhilePaused` (LTP-03). The Studio had it; the physical shortcuts editor
 * and the configuration cleanup did not, so they stopped answering under a
 * pause (LTP-10).
 * This gate reads the Windows sources, without a driver:
 * 1. every window built on WebViewHost (a `WebViewHost.TryOpen(` call or a
 *    class that extends it) is in PAUSE_POLICY, so a new one must be placed;
 * 2. a configuration window opens with `"RunsWhilePaused", true`;
 * 3. a fenced window does not, and names why it waits for the resume.
 * Each check runs again on a mutated source and must then fail.
 * The fence itself is pinned by `(ltp-03-studio-paused)`
 * (test_script_outcomes.ahk).
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const PLUS = path.join(ROOT, 'static', 'ergopti_plus');
const HOST_FILE = 'windows/core/ui/engine/webview/utils.ahk';
const RUNS_WHILE_PAUSED = '"RunsWhilePaused", true';

// Every Windows window built on WebViewHost, by the file that opens it.
const PAUSE_POLICY = Object.freeze({
	// Ergopti Studio: saves, installs and emulates (LTP-03).
	'windows/ui/layout_manager/editor_window.ahk': { configuration: true },
	// Picks the emulated layout, a setting chosen while paused as from the tray.
	'windows/ui/emulation_picker/init.ahk': { configuration: true },
	// Edits the physical shortcuts (LTP-10).
	'windows/ui/physical_shortcuts/host.ahk': { configuration: true },
	// Removes the unused keys of config.toml (LTP-10).
	'windows/settings/ui/cleanup.ahk': { configuration: true },
	// Edits the user's workflows, as the menu would while paused (EDD-1).
	'windows/modules/shortcuts/workflows/editor_host.ahk': { configuration: true },
	// Edits the anti-sleep presets and button library, as the menu would while paused.
	'windows/modules/shortcuts/keep_awake_library_window.ahk': { configuration: true },
	// The field report progress window: it only shows a run, and the run and
	// its Stop answer under a pause as on macOS and Linux.
	'windows/diagnostics/ui/field_check/field_report.ahk': { configuration: true },
	'windows/ui/download_window/init.ahk': {
		configuration: false,
		reason:
			'a managed download failure report: its owners read the pause themselves and retry only after the resume'
	}
});

/** Every Windows driver source but the tests and vendored code, as [relative, source]. */
function windowsSources() {
	const files = [];
	const walk = (directory) => {
		for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
			const full = path.join(directory, entry.name);
			const relative = path.relative(PLUS, full).replace(/\\/g, '/');
			if (entry.isDirectory()) {
				if (!['windows/tests', 'windows/vendor'].includes(relative)) walk(full);
			} else if (entry.name.endsWith('.ahk')) files.push([relative, fs.readFileSync(full, 'utf8')]);
		}
	};
	walk(path.join(PLUS, 'windows'));
	return files;
}

/** Drops the AutoHotkey line comments, so prose never opens a window. */
function code(source) {
	return source.replace(/(^|\s);[^\n]*/g, '$1');
}

/** Whether a source opens a window on WebViewHost. */
function opensHostWindow(source) {
	const body = code(source);
	return (
		/\bWebViewHost\.TryOpen\(/.test(body) || /\bclass\s+\w+\s+extends\s+WebViewHost\b/.test(body)
	);
}

/** Problems of the census against the sources. */
function censusProblems(files, policy = PAUSE_POLICY) {
	const problems = [];
	for (const [file, source] of files) {
		if (file === HOST_FILE || !opensHostWindow(source)) continue;
		const entry = policy[file];
		if (!entry) {
			problems.push(`${file}: a WebViewHost window missing from PAUSE_POLICY`);
			continue;
		}
		const runs = code(source).includes(RUNS_WHILE_PAUSED);
		if (entry.configuration && !runs)
			problems.push(`${file}: a configuration window opened without RunsWhilePaused (EDD-1)`);
		if (!entry.configuration && runs)
			problems.push(`${file}: a fenced window opened with RunsWhilePaused`);
		if (!entry.configuration && !(typeof entry.reason === 'string' && entry.reason.length > 20))
			problems.push(`${file}: a fenced window without its reason`);
	}
	for (const file of Object.keys(policy)) {
		const found = files.find(([name]) => name === file);
		if (!found || !opensHostWindow(found[1]))
			problems.push(`${file}: listed in PAUSE_POLICY but opens no WebViewHost window`);
	}
	return problems;
}

const files = windowsSources();
const host = files.find(([file]) => file === HOST_FILE);
assert.ok(host, 'WebViewHost is read');
assert.ok(host[1].includes('"RunsWhilePaused", false'), 'WebViewHost reads RunsWhilePaused');
assert.deepEqual(censusProblems(files), []);

// Each check fails on the shape it forbids.
for (const [file, entry] of Object.entries(PAUSE_POLICY)) {
	if (!entry.configuration) continue;
	const source = files.find(([name]) => name === file)[1];
	assert.deepEqual(
		censusProblems([[file, source.replaceAll(RUNS_WHILE_PAUSED, '"NoActivate", true')]], {
			[file]: entry
		}),
		[`${file}: a configuration window opened without RunsWhilePaused (EDD-1)`],
		`${file} without RunsWhilePaused is named`
	);
}
const fenced = Object.keys(PAUSE_POLICY).find((file) => !PAUSE_POLICY[file].configuration);
const fencedSource = files.find(([name]) => name === fenced)[1];
assert.deepEqual(
	censusProblems([[fenced, `${fencedSource}\nHost.Opts := Map(${RUNS_WHILE_PAUSED})\n`]], {
		[fenced]: PAUSE_POLICY[fenced]
	}),
	[`${fenced}: a fenced window opened with RunsWhilePaused`],
	'a fenced window that runs while paused is named'
);
assert.deepEqual(
	censusProblems([[fenced, fencedSource]], { [fenced]: { configuration: false } }),
	[`${fenced}: a fenced window without its reason`],
	'a fenced window needs its reason'
);
assert.deepEqual(
	censusProblems([['windows/ui/new_window.ahk', 'class NewWindow extends WebViewHost {\n}\n']], {}),
	['windows/ui/new_window.ahk: a WebViewHost window missing from PAUSE_POLICY'],
	'a new WebViewHost window must be placed'
);
assert.deepEqual(
	censusProblems([['windows/ui/prose.ahk', '; class NewWindow extends WebViewHost\n']], {}),
	[],
	'a comment opens no window'
);
assert.deepEqual(
	censusProblems([], { 'windows/ui/gone.ahk': { configuration: true } }),
	['windows/ui/gone.ahk: listed in PAUSE_POLICY but opens no WebViewHost window'],
	'a stale entry is named'
);

console.log(
	`PASS test-webview-host-pause-census (${Object.keys(PAUSE_POLICY).length} WebViewHost windows, ${
		Object.values(PAUSE_POLICY).filter((entry) => entry.configuration).length
	} run while paused)`
);
