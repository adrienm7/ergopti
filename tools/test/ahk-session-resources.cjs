// tools/test/ahk-session-resources.cjs
'use strict';

/**
 * Finds the AHK test files that need the Windows session to themselves. The
 * clipboard, the foreground window and the injected keyboard stream belong to the
 * session, not to a process, so a per-worker %TEMP% cannot separate two tests that
 * use them: one test's window takes the focus another's SendInput was aimed at.
 *
 * The class is derived from the source, so a new test cannot forget to join it: a
 * test file is exclusive when its code, or the code of a fixture it names, uses one
 * of these resources. Two marker lines state what the scan cannot see:
 *   ; ahk-parallel: session-exclusive <why>    the file reaches one through production code
 *   ; ahk-parallel: operator-only <why>        a fixture no test launches
 * A fixture using a resource that no test names and no marker excuses is refused by
 * unreachedSessionFixtures: its test would run among neighbours unnoticed.
 */

const fs = require('node:fs');
const path = require('node:path');

const EXCLUSIVE_MARKER = /^[ \t]*;[ \t]*ahk-parallel:[ \t]*session-exclusive[ \t]+\S/m;
const OPERATOR_MARKER = /^[ \t]*;[ \t]*ahk-parallel:[ \t]*operator-only[ \t]+\S/m;

// Win32 entry points are named inside DllCall strings, so they are read before
// the string literals are masked.
const NATIVE_CALL =
	/\bDllCall\(\s*["'](?:[\w.]+\\)?(OpenClipboard|EmptyClipboard|SetClipboardData|GetClipboardData|CloseClipboard|AddClipboardFormatListener|SetForegroundWindow|SwitchToThisWindow|AttachThreadInput|SetFocus|GetFocus|GetForegroundWindow|GetActiveWindow|SendInput|keybd_event|mouse_event|BlockInput)["']/g;

// `.Send(` is an HTTP request, hence the lookbehind. Calls need their parenthesis:
// `Send` alone is a parameter or a seam's name in many tests.
const LANGUAGE_USE =
	/(?<![\w.])(A_Clipboard\b|ClipboardAll\b|(?:ClipWait|OnClipboardChange|SendInput|SendEvent|SendPlay|SendText|Send|ControlSend|ControlSendText|ControlFocus|WinActivate|WinWaitActive|WinWaitNotActive|BlockInput)(?=\())|\.Focus\(/g;

// adapters/clipboard.ahk: its CB_ functions reach the real clipboard, so naming
// one counts as a use even though no Win32 name appears in the caller.
const CLIPBOARD_ADAPTER = /(?<![\w.])CB_\w+(?=\()/g;

// A fake transport's `Send() {` makes every Send( of that file its own.
const LOCAL_SEND = /^[ \t]*(?:static[ \t]+)?Send\([^)\n]*\)[ \t]*(?:\{|=>)/m;

/**
 * Blanks comments and, on request, string literals, keeping line numbers.
 * @param {string} source AutoHotkey source.
 * @param {boolean} maskStrings Also blank string literals.
 * @returns {string} The masked source.
 */
function maskSource(source, maskStrings) {
	const blank = (text) => text.replace(/[^\n]/g, ' ');
	let out = '';
	let index = 0;
	while (index < source.length) {
		const char = source[index];
		const atBoundary = index === 0 || /\s/.test(source[index - 1]);
		let stop = index + 1;
		let kept = true;
		if (char === '/' && source[index + 1] === '*' && atBoundary) {
			const end = source.indexOf('*/', index + 2);
			stop = end === -1 ? source.length : end + 2;
			kept = false;
		} else if (char === ';' && atBoundary) {
			const end = source.indexOf('\n', index);
			stop = end === -1 ? source.length : end;
			kept = false;
		} else if (char === '"' || char === "'") {
			while (stop < source.length && source[stop] !== char && source[stop] !== '\n')
				stop += source[stop] === '`' ? 2 : 1;
			stop = Math.min(stop + 1, source.length);
			kept = !maskStrings;
		}
		const piece = source.slice(index, stop);
		out += kept ? piece : blank(piece);
		index = stop;
	}
	return out;
}

/**
 * Lists the session resources a source uses in code. A meta-test that only quotes
 * `SendInput` in a string does not use it.
 * @param {string} source AutoHotkey source.
 * @returns {string[]} Sorted resource tokens.
 */
function sessionUses(source) {
	const found = new Set();
	for (const match of maskSource(source, false).matchAll(NATIVE_CALL)) found.add(match[1]);
	const code = maskSource(source, true);
	for (const match of code.matchAll(LANGUAGE_USE)) found.add(match[1] || '.Focus');
	for (const match of code.matchAll(CLIPBOARD_ADAPTER)) found.add(match[0]);
	if (LOCAL_SEND.test(code)) found.delete('Send');
	return [...found].sort();
}

function listAhkFiles(directory) {
	if (!fs.existsSync(directory)) return [];
	return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
		const full = path.join(directory, entry.name);
		if (entry.isDirectory()) return listAhkFiles(full);
		return entry.name.endsWith('.ahk') ? [full] : [];
	});
}

/**
 * Reads the fixtures. A fixture inherits what the fixtures it names use, since a
 * body is often reached through a wrapper.
 * @param {string} testsDir The tests directory.
 * @returns {Map<string, {source: string, uses: string[]}>} Fixtures by base name.
 */
function readFixtures(testsDir) {
	const fixtures = new Map();
	for (const file of listAhkFiles(path.join(testsDir, 'fixtures'))) {
		const source = fs.readFileSync(file, 'utf8');
		fixtures.set(path.basename(file, '.ahk'), { source, uses: sessionUses(source) });
	}
	let changed = true;
	while (changed) {
		changed = false;
		for (const [name, fixture] of fixtures) {
			for (const [otherName, other] of fixtures) {
				if (otherName === name || !fixture.source.includes(otherName)) continue;
				const added = other.uses.filter((use) => !fixture.uses.includes(use));
				if (added.length) fixture.uses = [...fixture.uses, ...added].sort();
				changed = changed || added.length > 0;
			}
		}
	}
	return fixtures;
}

/**
 * Tells why one test file needs the session to itself.
 * @param {string} source The test file's source.
 * @param {Map<string, {uses: string[]}>} fixtures Result of readFixtures.
 * @returns {string[]} The reasons; empty when it can share the session.
 */
function exclusiveReasons(source, fixtures) {
	const reasons = sessionUses(source);
	for (const [name, fixture] of fixtures)
		if (fixture.uses.length && source.includes(name)) reasons.push(`fixture ${name}`);
	if (EXCLUSIVE_MARKER.test(source)) reasons.push('declared');
	return reasons;
}

/**
 * Selects the exclusive tests of a plan. Tests may share a name and --list runs
 * them together, so one exclusive file makes the name exclusive.
 * @param {Array<{name: string, file: string}>} rows Plan rows, files relative to testsDir.
 * @param {string} testsDir The tests directory.
 * @returns {Set<string>} The test names that run with no neighbour.
 */
function exclusiveTests(rows, testsDir) {
	const fixtures = readFixtures(testsDir);
	const byFile = new Map();
	const exclusive = new Set();
	for (const { name, file } of rows) {
		if (!byFile.has(file)) {
			const source = fs.readFileSync(path.join(testsDir, file), 'utf8');
			byFile.set(file, exclusiveReasons(source, fixtures).length > 0);
		}
		if (byFile.get(file)) exclusive.add(name);
	}
	return exclusive;
}

/**
 * Lists the session-using fixtures whose test cannot be found: no other source
 * under the tests names them, so that test would run among neighbours. A wrapper
 * naming a body inherits its uses, so the wrapper then answers for itself.
 * @param {string} testsDir The tests directory.
 * @returns {string[]} Sorted fixture base names.
 */
function unreachedSessionFixtures(testsDir) {
	const fixtures = readFixtures(testsDir);
	const sources = listAhkFiles(testsDir).map((file) => ({
		name: path.basename(file, '.ahk'),
		source: fs.readFileSync(file, 'utf8')
	}));
	return [...fixtures]
		.filter(
			([name, fixture]) =>
				fixture.uses.length &&
				!OPERATOR_MARKER.test(fixture.source) &&
				!sources.some((other) => other.name !== name && other.source.includes(name))
		)
		.map(([name]) => name)
		.sort();
}

module.exports = {
	sessionUses,
	readFixtures,
	exclusiveReasons,
	exclusiveTests,
	unreachedSessionFixtures
};
