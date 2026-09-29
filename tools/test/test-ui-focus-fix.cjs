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
 *    window levels in any spelling, bringToFront (which SETS a level rather
 *    than raising the window) and the console's on-top switch; Windows
 *    AlwaysOnTop, WS_EX_TOPMOST in any extended-style call, SetWindowPos
 *    above HWND_TOP and the topmost MsgBox bits; Linux keep-above in the GI
 *    and FFI spellings, floating type hints, popup and override-redirect
 *    windows and wmctrl above; PowerShell topmost forms. The driver trees,
 *    the shared Lua they load, the extensions and Ergopti's own vendor
 *    scripts are walked, so a new window on any branch is caught when it
 *    lands.
 * 2. An explicit allowlist names the overlay surfaces that must stay above
 *    other applications because they are not windows the user works in, and
 *    the callers of the overlay adapters, which are topmost by default. Each
 *    entry pins its exact number of sites per kind, so a new site inside an
 *    allowlisted file fails and a removed one leaves no stale exemption.
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
// generated output of other tools.
const SKIPPED_DIRS = new Set(['tests', 'Tests', 'node_modules', '.build']);

// Third-party code under a vendor directory, relative to static/ergopti_plus.
// Only these are skipped: Ergopti's own scripts shipped next to them are not.
const THIRD_PARTY = [
	'windows/vendor/UIA.ahk',
	'windows/vendor/WebView2.ahk',
	'windows/vendor/ComVar.ahk',
	'windows/vendor/Promise.ahk',
	'macos/vendor/hs_asm/',
	'_shared/ui/vendor/'
];

// Every tree that can open a window, the detectors each extension runs and
// the least number of files the walk must reach, or it is broken.
const SCAN_ROOTS = [
	{
		dir: 'macos',
		min: 100,
		detectors: { '.lua': ['macos'], '.swift': ['swift'], '.sh': ['shell'] }
	},
	{ dir: 'windows', min: 100, detectors: { '.ahk': ['windows'], '.ps1': ['powershell'] } },
	{ dir: 'linux', min: 100, detectors: { '.lua': ['linux'], '.sh': ['shell'] } },
	{
		dir: '_shared',
		min: 50,
		detectors: {
			'.lua': ['macos', 'linux'],
			'.ahk': ['windows'],
			'.sh': ['shell'],
			'.ps1': ['powershell']
		}
	},
	{ dir: 'extensions', min: 2, detectors: { '.ahk': ['windows'], '.lua': ['macos', 'linux'] } }
];

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

// Each entry is a file (relative to static/ergopti_plus) and, per pattern
// kind, the exact number of sites it holds. These surfaces are not windows:
// they never take focus, most are click-through, and they are useless unless
// they stay above the application the user is typing in. Anything else that
// reaches for a level or a topmost flag is a window and must only be focused.
// The counts are exact: an exemption covers the overlay it names, not a new
// window added next to it. The entries that are not overlays say so.
const ALLOWLIST = [
	{
		file: 'macos/ui/tooltip/renderer.lua',
		kinds: { 'mac.level': 2 },
		reason: 'hotstring preview and LLM prediction tooltip canvases at the caret'
	},
	{
		file: 'macos/ui/wpm/wpm_widget.lua',
		kinds: { 'mac.level': 1, 'overlay.adapter': 1 },
		reason: 'WPM widget: a click-through HUD canvas, never focused'
	},
	{
		file: 'macos/adapters/graphics_renderer.lua',
		kinds: { 'mac.level': 1, 'overlay.adapter': 1 },
		reason: 'overlay canvas adapter behind the WPM widget and feedback overlays'
	},
	{
		file: 'macos/ui/healthcheck/core.lua',
		kinds: { 'overlay.adapter': 1 },
		reason: 'not an overlay: names the overlay adapter in its health probe, creates nothing'
	},
	{
		file: 'macos/ui/ui_builder.lua',
		kinds: { 'mac.level': 1 },
		reason: 'not an overlay: the window chrome applies windowLevels.normal, refusing anything else'
	},
	{
		file: 'macos/modules/shortcuts/actions/system_mouse.lua',
		kinds: { 'mac.level': 1 },
		reason: 'mouse spotlight: a transient locator overlay dismissed on mouse move'
	},
	{
		file: 'windows/ui/tooltip/helpers.ahk',
		kinds: { 'win.alwaysOnTop': 2, 'win.topmost': 1 },
		reason:
			'hotstring preview tooltip surfaces (content and border), revealed topmost, never activated'
	},
	{
		file: 'windows/ui/tooltip/llm.ahk',
		kinds: { 'win.alwaysOnTop': 1 },
		reason: 'LLM prediction panel, click-through and never activated'
	},
	{
		file: 'windows/ui/wpm/wpm_widget.ahk',
		kinds: { 'win.alwaysOnTop': 2 },
		reason: 'WPM widget and its graph: layered HUD windows, never focused'
	},
	{
		file: 'windows/adapters/graphics_renderer.ahk',
		kinds: { 'win.alwaysOnTop': 4, 'win.exTopmost': 1, 'overlay.adapter': 2 },
		reason: 'layered overlay adapter (spotlight and feedback overlays)'
	},
	{
		file: 'windows/infra/ui_style.ahk',
		kinds: { 'win.alwaysOnTop': 1 },
		reason: 'not an overlay: Gui_Create names AlwaysOnTop only to refuse it for every window'
	},
	{
		file: 'windows/ui/spotlight/init.ahk',
		kinds: { 'win.alwaysOnTop': 1 },
		reason: 'mouse spotlight: a click-through locator overlay dismissed on mouse move'
	},
	{
		file: 'windows/ui/spotlight/ownership.ahk',
		kinds: { 'overlay.adapter': 1 },
		reason: 'mouse spotlight: creates its locator overlay through the overlay adapter'
	},
	{
		file: 'linux/adapters/graphics_renderer.lua',
		kinds: { 'linux.keepAbove': 1, 'linux.popup': 3, 'overlay.adapter': 1 },
		reason: 'hotstring preview tooltip: an undecorated click-through popup'
	},
	{
		file: 'linux/adapters/wpm_surface.lua',
		kinds: { 'linux.keepAbove': 1, 'linux.popup': 3, 'overlay.adapter': 1 },
		reason: 'WPM widget surface: an undecorated popup that never takes focus'
	},
	{
		file: 'linux/ui/wpm/widget.lua',
		kinds: { 'overlay.adapter': 1 },
		reason: 'WPM widget drawn on the WPM overlay surface'
	},
	{
		file: 'linux/ui/tooltip/llm.lua',
		kinds: { 'overlay.adapter': 1 },
		reason: 'LLM prediction panel drawn through the overlay adapter'
	},
	{
		file: 'linux/ui/tooltip/preview.lua',
		kinds: { 'overlay.adapter': 1 },
		reason: 'hotstring preview tooltip drawn through the overlay adapter'
	},
	{
		file: 'linux/ergopti_hotstrings.lua',
		kinds: { 'overlay.adapter': 1 },
		reason: 'not an overlay: reports whether the overlay adapter is available, creates nothing'
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

/**
 * Blanks shell and PowerShell comments: full-line `#` comments and `<# #>`
 * blocks, keeping every newline.
 * @param {string} src Shell or PowerShell source.
 * @returns {string}
 */
function stripHashComments(src) {
	return src
		.replace(/<#[\s\S]*?#>/g, (m) => m.replace(/[^\n]/g, ' '))
		.replace(/^[ \t]*#[^\n]*/gm, '');
}

/**
 * Strips the comments of one source for the detector that reads it.
 * @param {string} detector Detector name.
 * @param {string} src Raw source.
 * @returns {string}
 */
function stripFor(detector, src) {
	if (detector === 'windows') return stripAhkComments(src);
	if (detector === 'swift') return stripSwiftComments(src);
	if (detector === 'shell' || detector === 'powershell') return stripHashComments(src);
	return stripLuaComments(src);
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

// The only level argument a macOS window may take.
const MAC_NORMAL_LEVEL = /^(?:hs\.(?:drawing|canvas)\.windowLevels\.normal|0)$/;

// SetWindowPos insert-after values that never make a window topmost:
// HWND_TOP (0), HWND_BOTTOM (1) and HWND_NOTOPMOST (-2).
const WIN_PLAIN_INSERT_AFTER = /^(?:0|1|-2|HWND_TOP|HWND_BOTTOM|HWND_NOTOPMOST)$/;

// MsgBox option bits that keep the box above every window: 262144 (0x40000)
// is "AlwaysOnTop" and 4096 (0x1000) is "System Modal".
const WIN_MSGBOX_TOPMOST_BITS = 0x41000;

// WS_EX_TOPMOST.
const WS_EX_TOPMOST = 0x8;

/**
 * Returns the argument list of the call whose `(` sits at `open`, split at
 * top-level commas, strings respected. Returns null when unbalanced.
 * @param {string} src Comment-stripped source.
 * @param {number} open Index of the opening parenthesis.
 * @param {string} escape The string escape character (` in AHK, \ in Lua).
 * @returns {{args: string[], end: number}|null}
 */
function callArgs(src, open, escape) {
	const args = [];
	let depth = 0;
	let quote = null;
	let start = open + 1;
	for (let k = open; k < src.length; k++) {
		const c = src[k];
		if (quote) {
			if (c === escape) k++;
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
 * Parses one integer literal (decimal or 0x hex).
 * @param {string} literal
 * @returns {number}
 */
function parseLiteral(literal) {
	return /^0x/i.test(literal) ? parseInt(literal, 16) : parseInt(literal, 10);
}

/**
 * True when any standalone integer literal of `text` carries one of `bits`.
 * A literal after `~` is a mask being cleared, not a flag being set.
 * @param {string} text Source fragment.
 * @param {number} bits Bit mask.
 * @returns {boolean}
 */
function literalCarries(text, bits) {
	for (const m of text.matchAll(/(?<![\w.~])(0x[0-9a-f]+|\d+)(?![\w.])/gi)) {
		if ((parseLiteral(m[1]) & bits) !== 0) return true;
	}
	return false;
}

/**
 * Lists every always-on-top finding in one comment-stripped source.
 * @param {string} driver 'macos' | 'windows' | 'linux' | 'swift' | 'shell' | 'powershell'.
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
	// Overlay adapters are topmost by default: every file that loads one is a
	// caller the allowlist must name.
	if (driver === 'macos' || driver === 'linux') {
		scan('overlay.adapter', /["']adapters[./](?:graphics_renderer|wpm_surface)["']/g);
	}
	if (driver === 'macos') {
		// hs.webview / hs.drawing / hs.canvas bringToFront SETS the window level
		// (floating, or screen saver with `true`); it does not raise a window.
		scan('mac.bringToFront', /[:.]bringToFront\s*\(|\[\s*["']bringToFront["']\s*\]/g);
		scan('mac.consoleOnTop', /\bconsoleOnTop\s*\((?!\s*(?:false\b|\)))/g);
		// Any level argument but the normal level, in any spelling: a name, a
		// computed or aliased table entry, arithmetic on normal, a number.
		const levelArgs = [];
		for (const m of src.matchAll(/:level\s*\(|\bconsole\s*\.\s*level\s*\(/g)) {
			const call = callArgs(src, m.index + m[0].length - 1, '\\');
			const arg = call ? call.args.join(',').trim() : null;
			if (arg === '') continue;
			levelArgs.push([m.index, call ? call.end : src.length]);
			if (arg === null || !MAC_NORMAL_LEVEL.test(arg)) {
				found.push({ kind: 'mac.level', index: m.index, text: m[0] + (arg || '') + ')' });
			}
		}
		const outsideLevelCall = (m) => !levelArgs.some(([from, to]) => m.index > from && m.index < to);
		scan(
			'mac.level',
			new RegExp(`windowLevels\\s*(?:\\.\\s*|\\[\\s*["'])(?:${MAC_RAISED_LEVELS})\\b`, 'g'),
			outsideLevelCall
		);
		scan('mac.level', /windowLevels\s*\[\s*(?!["'])/g, outsideLevelCall);
		scan('mac.level', /windowLevels\s*\.\s*normal\s*[-+]/g, outsideLevelCall);
		scan('mac.level', /windowLevels\b(?!\s*[.[])/g, outsideLevelCall);
		scan(
			'mac.level',
			/\bNS\w*WindowLevel\b|kCG\w*WindowLevel\w*/g,
			(m) => !/NSNormalWindowLevel/.test(m[0])
		);
	} else if (driver === 'swift') {
		scan(
			'mac.level',
			/\.level\s*=\s*([^\n]+)/g,
			(m) => !/^(?:NSWindow\.Level)?\.normal\b/.test(m[1].trim())
		);
		scan('mac.level', /\bisFloatingPanel\s*=\s*true\b/g);
		// A utility panel floats above ordinary windows on its own.
		scan('mac.level', /\.utilityWindow\b/g);
		scan(
			'mac.level',
			/\bNS\w*WindowLevel\b|kCG\w*WindowLevel\w*/g,
			(m) => !/NSNormalWindowLevel/.test(m[0])
		);
	} else if (driver === 'windows') {
		scan('win.alwaysOnTop', /AlwaysOnTop/gi);
		scan('win.topmost', /\bHWND_TOPMOST\b/g);
		scan('win.exTopmost', /\bWS_EX_TOPMOST\b/g);
		scan('overlay.adapter', /\bGR_CreateWindow\b/g);
		scan('win.exTopmost', /[+\s"']E(0x[0-9a-f]+|\d+)\b/gi, (m) =>
			literalCarries(m[1], WS_EX_TOPMOST)
		);
		scan('win.exTopmost', /\b\w*ExStyle\w*\s*(?:\|=|:=)\s*(0x[0-9a-f]+|\d+)/gi, (m) =>
			literalCarries(m[1], WS_EX_TOPMOST)
		);
		// WinSetExStyle sets (no prefix), adds (+) or toggles (^) the style.
		scan('win.exTopmost', /\bWinSetExStyle\s*\(\s*["']?[+^]?(0x[0-9a-f]+|\d+)/gi, (m) =>
			literalCarries(m[1], WS_EX_TOPMOST)
		);
		for (const m of src.matchAll(/\bDllCall\s*\(/g)) {
			const call = callArgs(src, m.index + m[0].length - 1, '`');
			if (!call) continue;
			const [fn, ...rest] = call.args.map((a) => a.trim());
			if (/SetWindowPos/.test(fn || '')) {
				// Anything but a literal HWND_TOP, HWND_BOTTOM or HWND_NOTOPMOST
				// may be HWND_TOPMOST (-1), including a variable holding it.
				if (!WIN_PLAIN_INSERT_AFTER.test(rest[3] || '')) {
					found.push({
						kind: 'win.topmost',
						index: m.index,
						text: `SetWindowPos(..., ${rest[3]}, ...)`
					});
				}
			} else if (/CreateWindowEx/.test(fn || '')) {
				if (literalCarries(rest[1] || '', WS_EX_TOPMOST)) {
					found.push({
						kind: 'win.exTopmost',
						index: m.index,
						text: `CreateWindowEx(${rest[1]}, ...)`
					});
				}
			} else if (/SetWindowLong/.test(fn || '')) {
				const at = rest.findIndex((a) => a === '-20' || a === 'GWL_EXSTYLE');
				if (at >= 0 && literalCarries(rest[at + 2] || '', WS_EX_TOPMOST)) {
					found.push({
						kind: 'win.exTopmost',
						index: m.index,
						text: `SetWindowLong(GWL_EXSTYLE, ${rest[at + 2]})`
					});
				}
			}
		}
		for (const m of src.matchAll(/\bMsgBox\s*\(/g)) {
			const call = callArgs(src, m.index + m[0].length - 1, '`');
			if (call && call.args.length >= 3 && literalCarries(call.args[2], WIN_MSGBOX_TOPMOST_BITS)) {
				found.push({
					kind: 'win.msgboxTopmost',
					index: m.index,
					text: `MsgBox options ${call.args[2].trim()}`
				});
			}
		}
		scan('win.msgboxTopmost', /^\s*MsgBox\s+[^\n(][^\n]*/gm, (m) => {
			const parts = m[0].split(',');
			return parts.length >= 3 && literalCarries(parts[2], WIN_MSGBOX_TOPMOST_BITS);
		});
	} else if (driver === 'powershell') {
		scan(
			'win.topmost',
			/\bTopMost\s*=\s*\$true\b|\bSystemModal\b|\bDefaultDesktopOnly\b|\bServiceNotification\b|\bMB_(?:TOPMOST|SYSTEMMODAL)\b|\bHWND_TOPMOST\b/gi
		);
	}
	if (driver === 'linux') {
		// GI method (`window:set_keep_above(on)`) and FFI function
		// (`gtk_window_set_keep_above(window, on)`): the last argument decides.
		for (const m of src.matchAll(/set_keep_above\s*\(/g)) {
			const call = callArgs(src, m.index + m[0].length - 1, '\\');
			const last = call ? call.args[call.args.length - 1].trim() : null;
			if (last === null || !/^(?:false|0|FALSE)$/.test(last)) {
				found.push({ kind: 'linux.keepAbove', index: m.index, text: `${m[0]}${last})` });
			}
		}
		scan('linux.keepAbove', /\bkeep_above\s*=\s*(?:true|1)\b/g);
		scan(
			'linux.typeHint',
			new RegExp(`type_hint[^\\n]*(?<![A-Za-z0-9])(?:${LINUX_FLOATING_HINTS})\\b`, 'g')
		);
		scan(
			'linux.typeHint',
			new RegExp(`WindowTypeHint\\s*\\.\\s*(?:${LINUX_FLOATING_HINTS})\\b`, 'g')
		);
		scan(
			'linux.typeHint',
			new RegExp(`\\bGDK_WINDOW_TYPE_HINT_(?:${LINUX_FLOATING_HINTS})\\b`, 'g'),
			(m) => !/type_hint[^\n]*$/.test(src.slice(src.lastIndexOf('\n', m.index) + 1, m.index))
		);
		scan('linux.popup', /\bGTK_WINDOW_POPUP\b|WindowType\s*\.\s*POPUP\b|override_redirect/g);
		// A Gtk.Window built with any type but TOPLEVEL is a popup.
		scan(
			'linux.popup',
			/\bGtk\s*\.\s*Window\s*(?:\.\s*new\s*)?\(\s*\{[^}]*?\btype\s*=(?!\s*(?:Gtk\s*\.\s*WindowType\s*\.\s*TOPLEVEL\b|["']TOPLEVEL["']|0\b))/g
		);
		scan('linux.popup', /\bgtk_window_new\s*\((?!\s*(?:0\b|GTK_WINDOW_TOPLEVEL\b))/g);
	}
	if (driver === 'linux' || driver === 'shell') {
		scan(
			'linux.keepAbove',
			/_NET_WM_STATE_ABOVE|--keep-above|\bwmctrl\b[^\n]*-b\s*["']?[^\s"']*\babove\b|\bwindowstate\s+--add\s+ABOVE\b/g
		);
	}
	return found;
}

// =============================================
// =============================================
// ======= 4/ Walking the shipped sources =======
// =============================================
// =============================================

/**
 * Lists the files of one tree with the given extensions, skipping test trees
 * and third-party code.
 * @param {string} dir Absolute directory.
 * @param {string[]} exts Extensions such as '.lua'.
 * @param {string[]} out Accumulator.
 * @returns {string[]}
 */
function walk(dir, exts, out = []) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		const rel = path.relative(DRIVERS_ROOT, full).split(path.sep).join('/');
		if (THIRD_PARTY.some((prefix) => rel === prefix || `${rel}/`.startsWith(prefix))) continue;
		if (entry.isDirectory()) {
			if (!SKIPPED_DIRS.has(entry.name)) walk(full, exts, out);
		} else if (exts.includes(path.extname(entry.name))) {
			out.push(full);
		}
	}
	return out;
}

/**
 * Scans one tree and returns its findings with file:line.
 * @param {{dir: string, detectors: Object<string, string[]>}} root Scan root.
 * @returns {{files: number, findings: {file: string, line: number, kind: string, text: string}[]}}
 */
function scanRoot(root) {
	const files = walk(path.join(DRIVERS_ROOT, root.dir), Object.keys(root.detectors));
	const findings = [];
	for (const file of files) {
		const raw = fs.readFileSync(file, 'utf8').replace(/^﻿/, '');
		const seen = new Set();
		for (const detector of root.detectors[path.extname(file)]) {
			const src = stripFor(detector, raw);
			for (const hit of detect(detector, src)) {
				// Shared Lua runs both Lua detectors; one site is one finding.
				const key = `${hit.kind}@${hit.index}`;
				if (seen.has(key)) continue;
				seen.add(key);
				findings.push({
					file: path.relative(DRIVERS_ROOT, file).split(path.sep).join('/'),
					line: src.slice(0, hit.index).split('\n').length,
					kind: hit.kind,
					text: hit.text.trim().replace(/\s+/g, ' ').slice(0, 90)
				});
			}
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
	['macos', 'canvas:level("floating")', 'mac.level'],
	['macos', 'local L = hs.drawing.windowLevels\nwv:level(L.floating)', 'mac.level'],
	['macos', 'wv:level(hs.drawing.windowLevels[name])', 'mac.level'],
	['macos', 'hs.webview.new(frame):level(hs.drawing.windowLevels.normal + 3)', 'mac.level'],
	['macos', 'local lvl = hs.drawing.windowLevels.normal + 1', 'mac.level'],
	['macos', 'hs.console.level(hs.drawing.windowLevels.floating)', 'mac.level'],
	['macos', 'wv:bringToFront(true)', 'mac.bringToFront'],
	['macos', 'wv:bringToFront()', 'mac.bringToFront'],
	['macos', 'wv["bringToFront"](wv, true)', 'mac.bringToFront'],
	['macos', 'hs.consoleOnTop(true)', 'mac.consoleOnTop'],
	['macos', 'view:level(3)', 'mac.level'],
	['macos', 'local R = require("adapters.graphics_renderer")', 'overlay.adapter'],
	['swift', 'panel.level = .floating', 'mac.level'],
	['swift', 'alert.window.level = .modalPanel', 'mac.level'],
	[
		'swift',
		'NSPanel(contentRect: r, styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)',
		'mac.level'
	],
	['windows', 'G := Gui("+Resize +AlwaysOnTop", "x")', 'win.alwaysOnTop'],
	['windows', 'try g.Opt("+AlwaysOnTop")', 'win.alwaysOnTop'],
	['windows', 'WinSetAlwaysOnTop(1, "ahk_id " . Hwnd)', 'win.alwaysOnTop'],
	['windows', 'G := Gui("-Caption +E0x8", "x")', 'win.exTopmost'],
	['windows', 'G := Gui("-Caption +E0x80008", "x")', 'win.exTopmost'],
	['windows', 'ExStyle |= 0x00000008', 'win.exTopmost'],
	['windows', 'WinSetExStyle(0x8, h)', 'win.exTopmost'],
	['windows', 'WinSetExStyle("^0x8", h)', 'win.exTopmost'],
	[
		'windows',
		'DllCall("User32\\CreateWindowEx", "UInt", 0x00080008, "Str", "Static")',
		'win.exTopmost'
	],
	[
		'windows',
		'DllCall("SetWindowLongPtr", "Ptr", h, "Int", -20, "Ptr", ex | 0x8)',
		'win.exTopmost'
	],
	[
		'windows',
		'DllCall("User32\\SetWindowPos", "Ptr", H, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 3)',
		'win.topmost'
	],
	[
		'windows',
		'static InsertAfter := -1\nDllCall("SetWindowPos", "Ptr", H, "Ptr", this.InsertAfter, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 3)',
		'win.topmost'
	],
	['windows', 'MsgBox("Text", "Title", "Iconi 262144")', 'win.msgboxTopmost'],
	['windows', 'MsgBox(Msg,\n\tTitle, 0x1000 | 0x30)', 'win.msgboxTopmost'],
	['windows', 'MsgBox "Text", "Title", "4096"', 'win.msgboxTopmost'],
	['windows', 'MsgBox("x", "y", 0x41030)', 'win.msgboxTopmost'],
	['windows', 'MsgBox("x", "y", 262192)', 'win.msgboxTopmost'],
	['windows', 'MsgBox("x", "y", 4144)', 'win.msgboxTopmost'],
	['windows', 'MsgBox("x", "y", "YesNo 0x41000")', 'win.msgboxTopmost'],
	['windows', 'Hwnd := GR_CreateWindow(Map("x", 0, "y", 0, "w", 9, "h", 9))', 'overlay.adapter'],
	['powershell', '$form.TopMost = $true', 'win.topmost'],
	[
		'powershell',
		'[Windows.Forms.MessageBox]::Show($t, $c, "OK", "Error", "Button1", "DefaultDesktopOnly")',
		'win.topmost'
	],
	['linux', 'window:set_keep_above(true)', 'linux.keepAbove'],
	['linux', 'C.gtk_window_set_keep_above(win, true)', 'linux.keepAbove'],
	['linux', 'window.keep_above = 1', 'linux.keepAbove'],
	['linux', 'os.execute("wmctrl -r X -b add,sticky,above")', 'linux.keepAbove'],
	['linux', 'os.execute("wmctrl -r X -b toggle,above")', 'linux.keepAbove'],
	['shell', 'wmctrl -r "$TITLE" -b add,above', 'linux.keepAbove'],
	['linux', 'window:set_type_hint(Gdk.WindowTypeHint.UTILITY)', 'linux.typeHint'],
	['linux', 'window:set_type_hint(GDK_WINDOW_TYPE_HINT_UTILITY)', 'linux.typeHint'],
	['linux', 'local w = Gtk.Window({ type = Gtk.WindowType.POPUP })', 'linux.popup'],
	['linux', 'local w = Gtk.Window({ type = 1 })', 'linux.popup'],
	['linux', 'local w = Gtk.Window({ type = "POPUP" })', 'linux.popup'],
	['linux', 'local w = C.gtk_window_new(1)', 'linux.popup'],
	['linux', 'local s = require("adapters.wpm_surface")', 'overlay.adapter']
];
for (const [driver, snippet, kind] of FIXTURES) {
	const kinds = detect(driver, stripFor(driver, snippet)).map((f) => f.kind);
	record(
		`${driver} detector flags ${kind}: ${snippet.replace(/\n\s*/g, ' ')}`,
		kinds.includes(kind),
		[`found: ${JSON.stringify(kinds)}`]
	);
}

const CLEAN_FIXTURES = [
	['macos', 'wv:level(hs.drawing.windowLevels.normal)'],
	['macos', 'local level = wv:level()'],
	['macos', '-- wv:bringToFront(true) used to pin the window'],
	['macos', 'hs.consoleOnTop(false)'],
	['swift', 'panel.level = .normal'],
	['swift', 'panel.level = NSWindow.Level.normal'],
	['windows', 'G := Gui("+Resize +MinSize640x480", "x")'],
	['windows', 'G := Gui("+Resize", "x") ; was +AlwaysOnTop'],
	['windows', 'G := Gui("-Caption +E0x20 +E0x80", "x")'],
	['windows', 'WinSetExStyle("-0x8", h)'],
	['windows', 'DllCall("SetWindowLongPtr", "Ptr", h, "Int", -20, "Ptr", ex & ~0x8)'],
	[
		'windows',
		'DllCall("User32\\SetWindowPos", "Ptr", H, "Ptr", 0, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 3)'
	],
	[
		'windows',
		'DllCall("User32\\SetWindowPos", "Ptr", H, "Ptr", -2, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 3)'
	],
	['windows', 'MsgBox(Msg, Title, "Iconi T2")'],
	['windows', 'MsgBox(Msg, Title, "YesNo Icon? 0x2000")'],
	['windows', 'MsgBox(Format("{1}", 4096), Title, "Iconi")'],
	['powershell', '[void][Windows.Forms.MessageBox]::Show($FailureText, $FailureTitle)'],
	['linux', 'window:set_keep_above(false)'],
	['linux', 'C.gtk_window_set_keep_above(win, false)'],
	['linux', 'Gtk.Window({ type = Gtk.WindowType.TOPLEVEL })'],
	['linux', 'timeout 2 wmctrl -s "$t"'],
	['shell', '# wmctrl -b add,above would pin it'],
	['linux', 'window:set_type_hint(Gdk.WindowTypeHint.NORMAL)']
];
for (const [driver, snippet] of CLEAN_FIXTURES) {
	const kinds = detect(driver, stripFor(driver, snippet)).map((f) => f.kind);
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
const actualCounts = new Map();
for (const root of SCAN_ROOTS) {
	const { files, findings } = scanRoot(root);
	record(`${root.dir}: the walk reaches the shipped sources (${files} files)`, files >= root.min, [
		`expected at least ${root.min} files`
	]);
	const violations = [];
	for (const finding of findings) {
		const entry = allowed.get(finding.file);
		if (entry && Object.hasOwn(entry.kinds, finding.kind)) {
			const key = `${finding.file}#${finding.kind}`;
			if (!actualCounts.has(key)) actualCounts.set(key, []);
			actualCounts.get(key).push(`${finding.file}:${finding.line} ${finding.text}`);
			continue;
		}
		violations.push(`${finding.file}:${finding.line} [${finding.kind}] ${finding.text}`);
	}
	record(
		`${root.dir}: every window is only focused, never kept on top (ui-focus-not-topmost)`,
		violations.length === 0,
		[
			'Windows must be shown, raised and focused by the driver present helper; only',
			'the overlay allowlist in this file may stay above other applications:',
			...violations
		]
	);
}

const drift = [];
for (const entry of ALLOWLIST) {
	for (const [kind, expected] of Object.entries(entry.kinds)) {
		const sites = actualCounts.get(`${entry.file}#${kind}`) || [];
		if (sites.length !== expected) {
			drift.push(
				`${entry.file} [${kind}] expected ${expected} site(s), found ${sites.length} (${entry.reason}):`
			);
			for (const site of sites) drift.push(`    ${site}`);
		}
	}
}
record(
	'every allowlisted overlay holds exactly its pinned sites (no new window inside an exemption, no stale entry)',
	drift.length === 0,
	drift
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
