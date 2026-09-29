// tools/test/test-ui-focus-fix.cjs

/**
 * ==============================================================================
 * MODULE: Windows Are Focused, Never Kept On Top
 * DESCRIPTION:
 * Maintainer rule (2026-09-29): an ErgoptiPlus window is shown, raised and
 * given focus when it is opened or re-opened, and nothing more. No window may
 * hold a z-order or level that keeps it above the user's other applications:
 * the diagnostics window floated at the macOS floating level (and at the
 * screen-saver level through the focus fallback), so opening another
 * application's window left it underneath.
 *
 * FEATURES & RATIONALE:
 * 1. One gate for the three drivers. Every always-on-top mechanism of each
 *    platform is scanned in the shipped sources (comments stripped): macOS
 *    window levels and bringToFront, which SETS a level rather than raising
 *    the window; Windows AlwaysOnTop, WS_EX_TOPMOST, HWND_TOPMOST and the
 *    topmost MsgBox options; Linux keep-above, floating type hints and
 *    override-redirect popups. A new window, on any branch, is caught the
 *    moment it lands.
 * 2. An explicit allowlist names the overlay surfaces that must stay above
 *    other applications because they are not windows the user works in. An
 *    entry that no longer matches anything fails, so the list cannot rot.
 * 3. The detectors are proven on fixtures of every pattern, so the scan cannot
 *    turn green by matching nothing.
 * 4. The macOS focus helper keeps its owned retry and its application
 *    activation, and no dialog path bypasses the shared dialog wrapper.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const PASS_SYMBOL = '✓';
const FAIL_SYMBOL = '✗';

const REPO_ROOT = path.resolve(__dirname, '../..');
const DRIVERS_ROOT = path.join(REPO_ROOT, 'static', 'ergopti_plus');

// Directories that never ship as driver windows: test doubles and targets,
// third-party code, generated output of other tools.
const SKIPPED_DIRS = new Set(['tests', 'Tests', 'vendor', 'node_modules', '.build']);

// The walk must reach at least this many files per driver, or it is broken.
const MIN_FILES_PER_DRIVER = 100;

let total_pass = 0;
let total_fail = 0;

/**
 * Records one check.
 * @param {string} label What the check proves.
 * @param {boolean} ok Outcome.
 * @param {string[]} [details] Lines printed under a failure.
 */
function record(label, ok, details = []) {
	if (ok) {
		total_pass++;
		console.log(`  ${PASS_SYMBOL}  ${label}`);
		return;
	}
	total_fail++;
	console.log(`  ${FAIL_SYMBOL}  ${label}`);
	for (const line of details) console.log(`       ${line}`);
}

// ============================================================
// ============================================================
// ======= 1/ Overlay surfaces allowed to stay on top =======
// ============================================================
// ============================================================

// Each entry is a file (relative to static/ergopti_plus) and the pattern kinds
// it may use. These surfaces are not windows: they never take focus, most are
// click-through, and they are useless unless they stay above the application
// the user is typing in. Anything else that reaches for a level or a topmost
// flag is a window and must only be focused.
const ALLOWLIST = [
	{
		file: 'macos/ui/tooltip/renderer.lua',
		kinds: ['mac.level'],
		reason: 'hotstring preview and LLM prediction tooltip canvases at the caret'
	},
	{
		file: 'macos/ui/wpm/wpm_widget.lua',
		kinds: ['mac.level'],
		reason: 'WPM widget: a click-through HUD canvas, never focused'
	},
	{
		file: 'macos/adapters/graphics_renderer.lua',
		kinds: ['mac.level'],
		reason: 'overlay canvas adapter behind the WPM widget and feedback overlays'
	},
	{
		file: 'macos/modules/shortcuts/actions/system_mouse.lua',
		kinds: ['mac.level'],
		reason: 'mouse spotlight: a transient locator overlay dismissed on mouse move'
	},
	{
		file: 'windows/ui/tooltip/helpers.ahk',
		kinds: ['win.alwaysOnTop'],
		reason: 'hotstring preview tooltip surfaces (content and border), never activated'
	},
	{
		file: 'windows/ui/tooltip/llm.ahk',
		kinds: ['win.alwaysOnTop'],
		reason: 'LLM prediction panel, click-through and never activated'
	},
	{
		file: 'windows/ui/wpm/wpm_widget.ahk',
		kinds: ['win.alwaysOnTop'],
		reason: 'WPM widget and its graph: layered HUD windows, never focused'
	},
	{
		file: 'windows/adapters/graphics_renderer.ahk',
		kinds: ['win.alwaysOnTop', 'win.exTopmost'],
		reason: 'layered overlay adapter (spotlight and feedback overlays)'
	},
	{
		file: 'windows/ui/spotlight/init.ahk',
		kinds: ['win.alwaysOnTop'],
		reason: 'mouse spotlight: a click-through locator overlay dismissed on mouse move'
	},
	{
		file: 'linux/adapters/graphics_renderer.lua',
		kinds: ['linux.keepAbove', 'linux.popup'],
		reason: 'hotstring preview tooltip: an undecorated click-through popup'
	},
	{
		file: 'linux/adapters/wpm_surface.lua',
		kinds: ['linux.keepAbove', 'linux.popup'],
		reason: 'WPM widget surface: an undecorated popup that never takes focus'
	}
];

// ===================================================
// ===================================================
// ======= 2/ Comment stripping, lines preserved =======
// ===================================================
// ===================================================

/**
 * Blanks Lua comments while keeping strings and every newline, so a mention in
 * prose neither creates nor hides a finding and line numbers stay exact.
 * @param {string} src Lua source.
 * @returns {string}
 */
function stripLuaComments(src) {
	let out = '';
	let i = 0;
	const blank = (text) => text.replace(/[^\n]/g, ' ');
	while (i < src.length) {
		const c = src[i];
		if (c === '-' && src[i + 1] === '-') {
			const long = /^--\[(=*)\[/.exec(src.slice(i, i + 64));
			if (long) {
				const close = `]${long[1]}]`;
				const end = src.indexOf(close, i + long[0].length);
				const stop = end < 0 ? src.length : end + close.length;
				out += blank(src.slice(i, stop));
				i = stop;
				continue;
			}
			const nl = src.indexOf('\n', i);
			const stop = nl < 0 ? src.length : nl;
			out += blank(src.slice(i, stop));
			i = stop;
			continue;
		}
		if (c === '"' || c === "'") {
			let j = i + 1;
			while (j < src.length && src[j] !== c && src[j] !== '\n') j += src[j] === '\\' ? 2 : 1;
			out += src.slice(i, j + 1);
			i = j + 1;
			continue;
		}
		const longString = c === '[' ? /^\[(=*)\[/.exec(src.slice(i, i + 64)) : null;
		if (longString) {
			const close = `]${longString[1]}]`;
			const end = src.indexOf(close, i + longString[0].length);
			const stop = end < 0 ? src.length : end + close.length;
			out += src.slice(i, stop);
			i = stop;
			continue;
		}
		out += c;
		i++;
	}
	return out;
}

/**
 * Blanks AHK comments (a `;` at line start or after whitespace, outside a
 * string, and `/* *\/` blocks opened at line start), keeping every newline.
 * @param {string} src AutoHotkey source.
 * @returns {string}
 */
function stripAhkComments(src) {
	const lines = src.split('\n');
	let inBlock = false;
	return lines
		.map((line) => {
			if (inBlock) {
				if (/\*\/\s*$/.test(line) || /^\s*\*\//.test(line)) inBlock = false;
				return '';
			}
			if (/^\s*\/\*/.test(line)) {
				if (!/\*\/\s*$/.test(line)) inBlock = true;
				return '';
			}
			let quote = null;
			for (let k = 0; k < line.length; k++) {
				const c = line[k];
				if (quote) {
					if (c === '`') k++;
					else if (c === quote) quote = null;
					continue;
				}
				if (c === '"' || c === "'") quote = c;
				else if (c === ';' && (k === 0 || /\s/.test(line[k - 1]))) return line.slice(0, k);
			}
			return line;
		})
		.join('\n');
}

/**
 * Blanks Swift `//` and block comments, keeping strings and newlines.
 * @param {string} src Swift source.
 * @returns {string}
 */
function stripSwiftComments(src) {
	return src
		.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
		.replace(/(^|[^:"])\/\/[^\n]*/g, (m, lead) => lead);
}

// ======================================================
// ======================================================
// ======= 3/ Always-on-top detectors per driver =======
// ======================================================
// ======================================================

// macOS levels that sit above normal windows. Only `normal` is a window level.
const MAC_RAISED_LEVELS =
	'floating|tornOffMenu|modalPanel|utility|dock|mainMenu|status|popUpMenu|overlay|help|dragging|screenSaver|assistiveTechHigh|cursor|desktopIcon';

// Linux type hints a window manager stacks above ordinary windows.
const LINUX_FLOATING_HINTS =
	'DOCK|NOTIFICATION|UTILITY|SPLASHSCREEN|TOOLTIP|POPUP_MENU|DROPDOWN_MENU|COMBO|DND|TOOLBAR|MENU';

/**
 * Returns the argument list of the call whose `(` sits at `open`, split at
 * top-level commas, strings respected. Returns null when unbalanced.
 * @param {string} src Comment-stripped AHK source.
 * @param {number} open Index of the opening parenthesis.
 * @returns {{args: string[], end: number}|null}
 */
function ahkCallArgs(src, open) {
	const args = [];
	let depth = 0;
	let quote = null;
	let start = open + 1;
	for (let k = open; k < src.length; k++) {
		const c = src[k];
		if (quote) {
			if (c === '`') k++;
			else if (c === quote) quote = null;
			continue;
		}
		if (c === '"' || c === "'") quote = c;
		else if (c === '(' || c === '[' || c === '{') depth++;
		else if (c === ')' || c === ']' || c === '}') {
			depth--;
			if (depth === 0) {
				args.push(src.slice(start, k));
				return { args, end: k };
			}
		} else if (c === ',' && depth === 1) {
			args.push(src.slice(start, k));
			start = k + 1;
		}
	}
	return null;
}

/**
 * True when an extended-style literal (decimal or 0x hex) carries WS_EX_TOPMOST.
 * @param {string} literal
 * @returns {boolean}
 */
function hasTopmostBit(literal) {
	const value = /^0x/i.test(literal) ? parseInt(literal, 16) : parseInt(literal, 10);
	return Number.isFinite(value) && (value & 0x8) === 0x8;
}

/**
 * Lists every always-on-top finding in one comment-stripped source.
 * @param {string} driver 'macos' | 'windows' | 'linux' | 'swift'.
 * @param {string} src Comment-stripped source.
 * @returns {{kind: string, index: number, text: string}[]}
 */
function detect(driver, src) {
	const found = [];
	const scan = (kind, regex, accept = () => true) => {
		for (const m of src.matchAll(regex)) {
			if (accept(m)) found.push({ kind, index: m.index, text: m[0] });
		}
	};
	if (driver === 'macos') {
		// hs.webview / hs.drawing / hs.canvas bringToFront SETS the window level
		// (floating, or screen saver with `true`); it does not raise a window.
		scan('mac.bringToFront', /:bringToFront\s*\(/g);
		scan(
			'mac.level',
			new RegExp(`windowLevels\\s*(?:\\.\\s*|\\[\\s*["'])(?:${MAC_RAISED_LEVELS})\\b`, 'g')
		);
		scan('mac.level', /:level\s*\(\s*(?!0\s*\))\d+/g);
		scan(
			'mac.level',
			/\bNS\w*WindowLevel\b|kCG\w*WindowLevel\w*/g,
			(m) => !/NSNormalWindowLevel/.test(m[0])
		);
	} else if (driver === 'swift') {
		scan('mac.level', /\.level\s*=\s*([^\n]+)/g, (m) => !/^\.normal\b/.test(m[1].trim()));
		scan('mac.level', /\bisFloatingPanel\s*=\s*true\b/g);
	} else if (driver === 'windows') {
		scan('win.alwaysOnTop', /AlwaysOnTop/gi);
		scan('win.topmost', /\bHWND_TOPMOST\b/g);
		scan('win.exTopmost', /\bWS_EX_TOPMOST\b/g);
		scan('win.exTopmost', /[+\s"']E(0x[0-9a-f]+|\d+)\b/gi, (m) => hasTopmostBit(m[1]));
		scan('win.exTopmost', /\b\w*ExStyle\w*\s*(?:\|=|:=)\s*(0x[0-9a-f]+|\d+)/gi, (m) =>
			hasTopmostBit(m[1])
		);
		scan('win.exTopmost', /\bWinSetExStyle\s*\(\s*["']\+?(0x[0-9a-f]+|\d+)/gi, (m) =>
			hasTopmostBit(m[1])
		);
		for (const m of src.matchAll(/\bDllCall\s*\(/g)) {
			const call = ahkCallArgs(src, m.index + m[0].length - 1);
			if (!call || !/SetWindowPos/.test(call.args[0] || '')) continue;
			if (/^\s*-1\s*$/.test(call.args[4] || '')) {
				found.push({
					kind: 'win.topmost',
					index: m.index,
					text: 'SetWindowPos(..., HWND_TOPMOST = -1, ...)'
				});
			}
		}
		// MsgBox option 262144 (0x40000) is "AlwaysOnTop"; 4096 (0x1000) is
		// "System Modal", which also makes the box topmost.
		const topmostOption = /(?:^|[^\w])(262144|0x40000|4096|0x1000)(?![\w])/i;
		for (const m of src.matchAll(/\bMsgBox\s*\(/g)) {
			const call = ahkCallArgs(src, m.index + m[0].length - 1);
			if (call && call.args.length >= 3 && topmostOption.test(call.args[2])) {
				found.push({
					kind: 'win.msgboxTopmost',
					index: m.index,
					text: `MsgBox options ${call.args[2].trim()}`
				});
			}
		}
		scan('win.msgboxTopmost', /^\s*MsgBox\s+[^\n(][^\n]*/gm, (m) => {
			const parts = m[0].split(',');
			return parts.length >= 3 && topmostOption.test(parts[2]);
		});
	} else if (driver === 'linux') {
		scan('linux.keepAbove', /\bset_keep_above\s*\(\s*(?!false\b)/g);
		scan('linux.keepAbove', /\bkeep_above\s*=\s*true\b/g);
		scan('linux.keepAbove', /_NET_WM_STATE_ABOVE|\badd,above\b|--keep-above/g);
		scan('linux.typeHint', new RegExp(`type_hint[^\\n]*\\b(?:${LINUX_FLOATING_HINTS})\\b`, 'g'));
		scan(
			'linux.typeHint',
			new RegExp(`WindowTypeHint\\s*\\.\\s*(?:${LINUX_FLOATING_HINTS})\\b`, 'g')
		);
		scan('linux.popup', /\bGTK_WINDOW_POPUP\b|WindowType\s*\.\s*POPUP\b|override_redirect/g);
	}
	return found;
}

// =============================================
// =============================================
// ======= 4/ Walking the shipped sources =======
// =============================================
// =============================================

/**
 * Lists shipped files of one driver with the given extensions.
 * @param {string} dir Absolute directory.
 * @param {string[]} exts Extensions such as '.lua'.
 * @param {string[]} out Accumulator.
 * @returns {string[]}
 */
function walk(dir, exts, out = []) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		if (entry.isDirectory()) {
			if (!SKIPPED_DIRS.has(entry.name)) walk(path.join(dir, entry.name), exts, out);
		} else if (exts.includes(path.extname(entry.name))) {
			out.push(path.join(dir, entry.name));
		}
	}
	return out;
}

/**
 * Scans one driver tree and returns its findings with file:line.
 * @param {string} driverDir Directory under static/ergopti_plus.
 * @returns {{files: number, findings: {file: string, line: number, kind: string, text: string}[]}}
 */
function scanDriver(driverDir) {
	const root = path.join(DRIVERS_ROOT, driverDir);
	const exts = driverDir === 'windows' ? ['.ahk'] : ['.lua', '.swift'];
	const files = walk(root, exts);
	const findings = [];
	for (const file of files) {
		const raw = fs.readFileSync(file, 'utf8').replace(/^﻿/, '');
		const isSwift = file.endsWith('.swift');
		const driver = isSwift ? 'swift' : driverDir;
		const src = isSwift
			? stripSwiftComments(raw)
			: driverDir === 'windows'
				? stripAhkComments(raw)
				: stripLuaComments(raw);
		for (const hit of detect(driver, src)) {
			findings.push({
				file: path.relative(DRIVERS_ROOT, file).split(path.sep).join('/'),
				line: src.slice(0, hit.index).split('\n').length,
				kind: hit.kind,
				text: hit.text.trim().slice(0, 90)
			});
		}
	}
	return { files: files.length, findings };
}

// ===========================================
// ===========================================
// ======= 5/ The detectors are not blind =======
// ===========================================
// ===========================================

console.log('\n=== Always-on-top detectors match every mechanism ===');

const FIXTURES = [
	['macos', 'wv:level(hs.drawing.windowLevels.floating)', 'mac.level'],
	['macos', 'level = hs.drawing.windowLevels["screenSaver"],', 'mac.level'],
	['macos', 'canvas:level(hs.canvas.windowLevels.overlay)', 'mac.level'],
	['macos', 'wv:bringToFront(true)', 'mac.bringToFront'],
	['macos', 'wv:bringToFront()', 'mac.bringToFront'],
	['macos', 'view:level(3)', 'mac.level'],
	['swift', 'panel.level = .floating', 'mac.level'],
	['swift', 'alert.window.level = .modalPanel', 'mac.level'],
	['windows', 'G := Gui("+Resize +AlwaysOnTop", "x")', 'win.alwaysOnTop'],
	['windows', 'try g.Opt("+AlwaysOnTop")', 'win.alwaysOnTop'],
	['windows', 'WinSetAlwaysOnTop(1, "ahk_id " . Hwnd)', 'win.alwaysOnTop'],
	['windows', 'G := Gui("-Caption +E0x8", "x")', 'win.exTopmost'],
	['windows', 'G := Gui("-Caption +E0x80008", "x")', 'win.exTopmost'],
	['windows', 'ExStyle |= 0x00000008', 'win.exTopmost'],
	[
		'windows',
		'DllCall("User32\\SetWindowPos", "Ptr", H, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 3)',
		'win.topmost'
	],
	['windows', 'MsgBox("Text", "Title", "Iconi 262144")', 'win.msgboxTopmost'],
	['windows', 'MsgBox(Msg,\n\tTitle, 0x1000 | 0x30)', 'win.msgboxTopmost'],
	['windows', 'MsgBox "Text", "Title", "4096"', 'win.msgboxTopmost'],
	['linux', 'window:set_keep_above(true)', 'linux.keepAbove'],
	['linux', 'window:set_type_hint(Gdk.WindowTypeHint.UTILITY)', 'linux.typeHint'],
	['linux', 'local w = Gtk.Window({ type = Gtk.WindowType.POPUP })', 'linux.popup']
];
for (const [driver, snippet, kind] of FIXTURES) {
	const kinds = detect(driver, snippet).map((f) => f.kind);
	record(
		`${driver} detector flags ${kind}: ${snippet.replace(/\n\s*/g, ' ')}`,
		kinds.includes(kind),
		[`found: ${JSON.stringify(kinds)}`]
	);
}

const CLEAN_FIXTURES = [
	['macos', 'wv:level(hs.drawing.windowLevels.normal)'],
	['macos', '-- wv:bringToFront(true) used to pin the window'],
	['swift', 'panel.level = .normal'],
	['windows', 'G := Gui("+Resize +MinSize640x480", "x")'],
	['windows', 'G := Gui("+Resize", "x") ; was +AlwaysOnTop'],
	['windows', 'G := Gui("-Caption +E0x20 +E0x80", "x")'],
	['windows', 'MsgBox(Msg, Title, "Iconi T2")'],
	['windows', 'MsgBox(Format("{1}", 4096), Title, "Iconi")'],
	['linux', 'window:set_keep_above(false)'],
	['linux', 'Gtk.Window({ type = Gtk.WindowType.TOPLEVEL })']
];
for (const [driver, snippet] of CLEAN_FIXTURES) {
	const src =
		driver === 'windows'
			? stripAhkComments(snippet)
			: driver === 'swift'
				? stripSwiftComments(snippet)
				: stripLuaComments(snippet);
	const kinds = detect(driver, src).map((f) => f.kind);
	record(`${driver} detector ignores a focus-only spelling: ${snippet}`, kinds.length === 0, [
		`found: ${JSON.stringify(kinds)}`
	]);
}

// ==========================================================
// ==========================================================
// ======= 6/ No window of any driver stays on top =======
// ==========================================================
// ==========================================================

console.log('\n=== No ErgoptiPlus window holds an always-on-top level ===');

const allowed = new Map(ALLOWLIST.map((entry) => [entry.file, entry]));
const usedAllowances = new Set();
for (const driverDir of ['macos', 'windows', 'linux']) {
	const { files, findings } = scanDriver(driverDir);
	record(
		`${driverDir}: the walk reaches the shipped sources (${files} files)`,
		files >= MIN_FILES_PER_DRIVER,
		[`expected at least ${MIN_FILES_PER_DRIVER} files`]
	);
	const violations = [];
	for (const finding of findings) {
		const entry = allowed.get(finding.file);
		if (entry && entry.kinds.includes(finding.kind)) {
			usedAllowances.add(`${finding.file}#${finding.kind}`);
			continue;
		}
		violations.push(`${finding.file}:${finding.line} [${finding.kind}] ${finding.text}`);
	}
	record(
		`${driverDir}: every window is only focused, never kept on top (ui-focus-not-topmost)`,
		violations.length === 0,
		[
			'Windows must be shown, raised and focused by the driver present helper; only',
			'the overlay allowlist in this file may stay above other applications:',
			...violations
		]
	);
}

const stale = [];
for (const entry of ALLOWLIST) {
	for (const kind of entry.kinds) {
		if (!usedAllowances.has(`${entry.file}#${kind}`))
			stale.push(`${entry.file} [${kind}] (${entry.reason})`);
	}
}
record(
	'every allowlisted overlay still uses its exemption (no stale entry)',
	stale.length === 0,
	stale
);

// ===============================================================
// ===============================================================
// ======= 7/ macOS focus helper and dialog wrapper contract =======
// ===============================================================
// ===============================================================

console.log('\n=== macOS focus helper and dialog wrapper ===');

/**
 * Reads a repository file, failing the check when it is missing.
 * @param {string} rel Path relative to the repository root.
 * @returns {string}
 */
function read(rel) {
	return fs.readFileSync(path.join(REPO_ROOT, rel), 'utf8');
}

const builder = stripLuaComments(read('static/ergopti_plus/macos/ui/ui_builder.lua'));
record(
	'UI Builder: focus retry mechanism (try_focus)',
	/local function try_focus\(\)/.test(builder)
);
record(
	'UI Builder: retry loop uses the lifecycle scheduler',
	/schedule\(0\.05,\s*try_focus,\s*["']webview focus retry["']\)/.test(builder)
);
record(
	'UI Builder: activates Hammerspoon so the raised window takes the keyboard',
	/hs\.focus\(true\)/.test(builder)
);
record(
	'UI Builder: every window chrome applies the normal level',
	/windowLevels\.normal[\s\S]*wv:level\(/.test(builder)
);
record(
	'Dialog Util: use hs.focus(true) with force flag',
	/hs\.focus\(true\)/.test(read('static/ergopti_plus/macos/infra/dialog_util.lua'))
);

const metricsTyping = read('static/ergopti_plus/macos/ui/metrics_typing/init.lua');
record(
	'Metrics Typing: redundant raise_now removed',
	!/local function raise_now/.test(metricsTyping)
);
record(
	'Metrics Typing: redundant poll_and_set_behavior removed',
	!/local function poll_and_set_behavior/.test(metricsTyping)
);

for (const rel of [
	'static/ergopti_plus/macos/ui/onboarding/init.lua',
	'static/ergopti_plus/macos/ui/healthcheck/core.lua',
	'static/ergopti_plus/macos/modules/diagnostics/crash_reporter.lua',
	'static/ergopti_plus/macos/platform/remap/onboarding.lua'
]) {
	record(
		`Global Audit: No raw hs.dialog.blockAlert in ${rel}`,
		!/hs\.dialog\.blockAlert/.test(read(rel))
	);
}

console.log(`\nResults: ${total_pass} passed, ${total_fail} failed.`);

if (total_fail > 0) {
	process.exit(1);
}
