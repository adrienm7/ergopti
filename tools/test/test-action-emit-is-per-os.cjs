// tools/test/test-action-emit-is-per-os.cjs

/**
 * ==============================================================================
 * MODULE: Action Emit Rows Are Per-OS, and Must Stay That Way
 * DESCRIPTION:
 * The shared action catalogue carries `emit_ahk_*` and `emit_hs_*` separately,
 * not one portable row. This gate records why, in data rather than prose, so the
 * next person to reach for a single `emit` field finds the measurement first.
 *
 * WHAT WAS MEASURED:
 * Of the 24 actions BOTH drivers implement as a bare keystroke, **13 use a
 * different key or modifier**:
 *
 *   close_window   alt+F4        vs  cmd+w
 *   fullscreen     F11           vs  cmd+ctrl+f
 *   word_next      ctrl+Right    vs  alt+right
 *   doc_start      ctrl+Home     vs  cmd+up
 *   sel_word_prev  ctrl+shift+…  vs  shift+alt+…
 *   …plus key-name spellings that differ outright: BackSpace/delete,
 *   Enter/return, Delete/forwarddelete.
 *
 * These are not accidents to be normalised away. macOS moves by word with
 * Option and Windows with Control; macOS closes a window with cmd+w and Windows
 * with alt+F4. They are the platforms' own conventions, and a user pressing a
 * gesture expects their platform's behaviour.
 *
 * WHY A GATE AND NOT A COMMENT:
 * The rows were briefly named `emit_key` / `emit_mods`, which reads as portable
 * and invites exactly one change: "map super→cmd and share them." That change
 * would compile, pass every existing test, and silently give macOS the wrong
 * keystroke for more than half of these actions — `word_next` sending
 * ctrl+Right on macOS does nothing at all. Nothing else in the suite can see
 * that, because no test invokes a gesture handler.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const CATALOGUE = path.join(
	ROOT,
	'static/ergopti_plus/_shared/modules/actions/actions.toml'
);

const errors = [];
const sg = toml.parse(fs.readFileSync(CATALOGUE, 'utf8')).sg_actions || {};

const ahkRows = Object.entries(sg).filter(([, v]) => v && v.emit_ahk_key);
const hsRows = Object.entries(sg).filter(([, v]) => v && v.emit_hs_key);

if (ahkRows.length < 40) {
	errors.push(`only ${ahkRows.length} emit_ahk_key row(s) — the catalogue lost its Windows rows`);
}
if (hsRows.length < 20) {
	errors.push(`only ${hsRows.length} emit_hs_key row(s) — the catalogue lost its macOS rows`);
}

// ── 1. No portable row may reappear ─────────────────────────────────────────
//
// A bare `emit_key`/`emit_mods` is the shape that was measured wrong. If one
// comes back, it means somebody concluded the two platforms agree.

for (const [id, entry] of Object.entries(sg)) {
	if (!entry || typeof entry !== 'object') continue;
	if (entry.emit_key !== undefined || entry.emit_mods !== undefined) {
		errors.push(
			`${id}: declares a portable emit_key/emit_mods row. The two platforms do NOT agree — 13 of ` +
				'the 24 actions both implement as a keystroke use a different key or modifier. Use ' +
				'emit_ahk_* and emit_hs_*.'
		);
	}
}

// ── 2. The divergence must still be there ───────────────────────────────────
//
// If these ever converge, the per-OS split stops being justified and this gate
// should be revisited deliberately — not left asserting a distinction that no
// longer exists. Pinned by name so the reason survives.

const KNOWN_DIVERGENT = {
	close_window: 'macOS closes with cmd+w; Windows with alt+F4',
	fullscreen: 'macOS cmd+ctrl+f; Windows F11',
	word_prev: 'macOS moves by word with Option; Windows with Control',
	word_next: 'macOS moves by word with Option; Windows with Control',
	para_prev: 'same Option-vs-Control split, by paragraph',
	para_next: 'same Option-vs-Control split, by paragraph',
	doc_start: 'macOS cmd+up; Windows ctrl+Home',
	doc_end: 'macOS cmd+down; Windows ctrl+End'
};

/** True when the two rows describe the same keystroke, ignoring key-name case. */
function agrees(entry) {
	const aKey = String(entry.emit_ahk_key || '').toLowerCase();
	const hKey = String(entry.emit_hs_key || '').toLowerCase();
	const aMods = (entry.emit_ahk_mods || []).slice().sort().join('+');
	const hMods = (entry.emit_hs_mods || []).slice().sort().join('+');
	return aKey === hKey && aMods === hMods;
}

for (const [id, why] of Object.entries(KNOWN_DIVERGENT)) {
	const entry = sg[id];
	if (!entry) {
		errors.push(`${id}: recorded as platform-divergent but absent from the catalogue`);
		continue;
	}
	if (!entry.emit_ahk_key || !entry.emit_hs_key) continue;
	if (agrees(entry)) {
		errors.push(
			`${id}: the Windows and macOS rows now agree, but this action is recorded as divergent ` +
				`(${why}). Either the change is wrong, or the record is stale — decide deliberately ` +
				'rather than letting the gate rot.'
		);
	}
}

// ── 3. Report the current split, so the number stays visible ────────────────

const both = Object.entries(sg).filter(([, v]) => v && v.emit_ahk_key && v.emit_hs_key);
const divergent = both.filter(([, v]) => !agrees(v));

if (both.length > 0 && divergent.length === 0) {
	errors.push(
		'every action now emits identically on both platforms. That would make the per-OS split ' +
			'unnecessary — a real result, but one to act on deliberately rather than discover here.'
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] action emit rows:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] emit rows stay per-OS: ${ahkRows.length} Windows, ${hsRows.length} macOS, ` +
		`${divergent.length} of ${both.length} shared actions genuinely divergent.\x1b[0m`
);
