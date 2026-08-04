// tools/test/test-is-word-flag-is-honoured-identically.cjs

/**
 * ==============================================================================
 * MODULE: `is_word` Must Mean The Same Thing On All Three Drivers
 * DESCRIPTION:
 * `is_word = true` says "this trigger only fires when a word boundary precedes
 * it". Until 2026-08-04 the three drivers answered that question three different
 * ways, and no two of them ever agreed at once:
 *
 *   - macOS  exempted any trigger whose FIRST BYTE was one of a separator set
 *            (space, the two no-break spaces, ";"), skipping the check entirely.
 *   - Windows exempted nothing (`_HSE_WordBoundaryAllows`, hotstring_match.ahk).
 *   - Linux   exempted nothing either, but skipped the check when the trigger
 *            filled the whole buffer instead of consulting a start-of-buffer
 *            flag, which is what the other two both do.
 *
 * The rule now lives once, in `HotstringCore.decide`. This gate holds the DATA
 * side of that convergence, which is the half a Lua test cannot see.
 *
 * WHY THE DATA NEEDED FIXING TOO, AND WHY THAT IS THE INTERESTING PART:
 * removing the macOS exemption is only safe if nothing shipped depended on it.
 * Four entries did — and measuring them showed the exemption was covering for
 * WRONG DATA rather than implementing a rule:
 *
 *   " = _"      autocorrection.toml   → " = _" cannot follow a word character
 *   " -> ★"     magickey.toml         →  and neither can these two, so on
 *   " = /=>★"   magickey.toml         →  Windows and Linux they never fired at
 *                                        all. `is_word` was killing the very
 *                                        usage they exist for.
 *   "°C★"       magickey.toml         → exempted on macOS ONLY because U+00B0
 *                                        starts with byte 0xC2, which the byte
 *                                        class caught by accident. "25°C★" fired
 *                                        there and nowhere else.
 *
 * A trigger that begins with a word boundary CARRIES its own boundary. Asking
 * for one in front of it as well is not a stricter rule, it is an unsatisfiable
 * one — the flag can only ever subtract behaviour. So the flag came off, and all
 * three drivers now expand all four.
 *
 * FEATURES & RATIONALE:
 * 1. Mechanical invariant: no shipped trigger may combine `is_word = true` with
 *    a leading word-boundary character. This is the class, not the instances.
 * 2. Pinned instances: the four entries above are named and re-checked, because
 *    "°C★" is not covered by the invariant (U+00B0 is a word character under the
 *    shared rule) and would otherwise be free to regress silently.
 * 3. A floor on the scan, so a broken parser reports zero offenders rather than
 *    passing.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const HOTSTRINGS_DIR = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'modules', 'hotstrings');

// A TOML entry line: "TRIGGER" = { output = "…", is_word = …, … }
const ENTRY_RE = /^\s*"((?:[^"\\]|\\.)*)"\s*=\s*\{(.*)$/;

// Floor, measured 2026-08-04 at 2 994 entry lines across the five TOML files.
// Anything near zero means the line parser stopped matching and this gate is
// inspecting nothing, which is the failure mode every scanner here has had at
// least once.
const MIN_ENTRIES_SCANNED = 2500;

/**
 * The characters that CARRY a word boundary: a trigger beginning with one of
 * these is already separated from whatever precedes it.
 *
 * Deliberately NOT "every non-word character". 1 301 shipped triggers begin with
 * a symbol — `$forall$`, `(c)★`, `:D★`, `#_` — and `is_word` is meaningful on
 * every one of them: it is what stops `(c)` expanding inside `func(c)`. The
 * symbol sits GLUED to the character before it, so asking whether that character
 * opens a word is a real question. Whitespace is the case where it is not: the
 * space is itself the separation, so requiring another one in front of it asks
 * for two.
 */
const SELF_BOUNDING_FIRST_CHARS = new Set([' ', '\t', '\n', '\r', ' ', ' ']);

// The four entries whose `is_word` was cleared on 2026-08-04, keyed by their
// trigger text so moving a line cannot silently drop one from this list.
const CLEARED_ON_PURPOSE = [
	{ trigger: ' = _', why: 'a leading space already is the boundary; the flag only blocked it' },
	{ trigger: ' -> ★', why: 'a leading space already is the boundary; the flag only blocked it' },
	{ trigger: ' = /=>★', why: 'a leading space already is the boundary; the flag only blocked it' },
	{ trigger: '°C★', why: 'typed glued to a digit ("25°C★"); the flag made it unreachable everywhere but macOS, and there only by a byte-class accident' },
];

/**
 * The shared word-character rule, transcribed from
 * `_shared/lua/text_utils/init.lua` (`is_hotstring_word_char`). Every non-ASCII
 * codepoint counts as a word character, deliberately, so accented letters behave
 * like letters without a Unicode category table.
 * @param {string} ch A single codepoint.
 * @returns {boolean} True when `ch` is part of a word.
 */
function isWordChar(ch) {
	if (typeof ch !== 'string' || ch === '') return false;
	if (ch.codePointAt(0) > 127) return true;
	if (ch === '@') return true;
	return /^[0-9A-Za-z_]$/.test(ch);
}

const errors = [];
let scanned = 0;
const offenders = [];
/** @type {Map<string, {file: string, line: number, isWord: boolean}>} */
const byTrigger = new Map();

for (const file of fs.readdirSync(HOTSTRINGS_DIR).sort()) {
	if (!file.endsWith('.toml')) continue;
	const text = fs.readFileSync(path.join(HOTSTRINGS_DIR, file), 'utf8');
	let lineNo = 0;
	for (const line of text.split('\n')) {
		lineNo++;
		const m = line.match(ENTRY_RE);
		if (!m) continue;
		scanned++;
		const trigger = m[1].replace(/\\"/g, '"').replace(/\\\\/g, '\\');
		const isWord = /is_word\s*=\s*true/.test(m[2]);
		if (!byTrigger.has(trigger)) byTrigger.set(trigger, { file, line: lineNo, isWord });
		if (!isWord) continue;
		const first = Array.from(trigger)[0];
		if (first !== undefined && SELF_BOUNDING_FIRST_CHARS.has(first)) {
			offenders.push(
				`${file}:${lineNo}  ${JSON.stringify(trigger)} — starts with U+` +
					first.codePointAt(0).toString(16).toUpperCase().padStart(4, '0')
			);
		}
	}
}

// ── 1. The scan has to have seen the catalogue ──────────────────────────────
if (scanned < MIN_ENTRIES_SCANNED) {
	errors.push(
		`only ${scanned} entry line(s) parsed (floor ${MIN_ENTRIES_SCANNED}) — the entry regex no longer ` +
			'matches the TOML shape, so an empty offender list below means nothing was looked at'
	);
}

// ── 2. The class: is_word on a self-bounded trigger ─────────────────────────
if (offenders.length > 0) {
	errors.push(
		`${offenders.length} trigger(s) combine is_word = true with leading whitespace:\n` +
			offenders.map((o) => '        ' + o).join('\n') +
			'\n      A trigger that begins with whitespace carries its own boundary. Requiring another one ' +
			'in front of it asks for two separators in a row, so the flag can only remove behaviour — which ' +
			'is exactly what it did on Windows and Linux, where three shipped entries never fired at all. ' +
			'Set is_word = false.'
	);
}

// ── 3. The instances, pinned by trigger text ────────────────────────────────
for (const entry of CLEARED_ON_PURPOSE) {
	const found = byTrigger.get(entry.trigger);
	if (!found) {
		errors.push(
			`the entry ${JSON.stringify(entry.trigger)} is no longer in the catalogue. If it was removed on ` +
				'purpose, drop it from CLEARED_ON_PURPOSE here and say so; if it was renamed, re-pin it. ' +
				'Leaving this list pointing at nothing is how a pinned regression stops being pinned.'
		);
		continue;
	}
	if (found.isWord) {
		errors.push(
			`${found.file}:${found.line} — ${JSON.stringify(entry.trigger)} carries is_word = true again. ` +
				`It was cleared on 2026-08-04 because ${entry.why}.`
		);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] is_word must mean the same thing on all three drivers:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] ${scanned} hotstring entries scanned; no trigger asks for a word boundary it already ` +
		`carries, and all ${CLEARED_ON_PURPOSE.length} entries cleared on 2026-08-04 are still clear.\x1b[0m`
);
