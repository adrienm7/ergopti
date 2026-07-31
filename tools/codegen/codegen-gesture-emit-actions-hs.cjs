// tools/codegen/codegen-gesture-emit-actions-hs.cjs

/**
 * ==============================================================================
 * MODULE: Gesture Emit-Action Codegen (macOS)
 * DESCRIPTION:
 * The macOS twin of codegen-gesture-emit-actions.cjs. Emits the keystroke each
 * action sends on macOS, from the `emit_hs_*` rows in the shared catalogue.
 *
 * WHY A SEPARATE SET OF ROWS FROM WINDOWS:
 * Because the two platforms genuinely differ. Of the 24 actions both implement
 * as a bare keystroke, 15 use a different key or modifier — macOS moves by word
 * with Option where Windows uses Control, closes a window with cmd+w against
 * alt+F4, reaches the document start with cmd+up against ctrl+Home — and
 * several more differ in key-name spelling alone (`return`/`Enter`,
 * `delete`/`BackSpace`, `forwarddelete`/`Delete`). Sharing one row and mapping
 * super→cmd would have compiled, passed every test, and sent the wrong
 * keystroke on macOS for more than half of them.
 *
 * ONE DIFFERENCE FROM THE WINDOWS EMITTER, WORTH KNOWING:
 * The AHK side has to build its handlers in helper functions, because a closure
 * created inside an AHK loop captures the loop VARIABLE and every action would
 * end up emitting the last iteration's keystroke. Lua does not have that
 * problem: each iteration of a generic `for` binds fresh locals, so a closure
 * created in the loop captures its own values. The consuming loop can therefore
 * be direct, and this file needs no factory indirection.
 *
 * USAGE:  node tools/codegen/codegen-gesture-emit-actions-hs.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const CATALOGUE = path.join(SP, '_shared', 'modules', 'actions', 'actions.toml');
const OUT = path.join(SP, 'macos', '_generated', 'gesture_emit_actions.lua');

// Hammerspoon's hs.eventtap.keyStroke takes these modifier names verbatim.
const ALLOWED_MODS = new Set(['cmd', 'ctrl', 'alt', 'shift', 'fn']);

const sg = toml.parse(fs.readFileSync(CATALOGUE, 'utf8')).sg_actions || {};

const rows = [];
for (const [id, entry] of Object.entries(sg)) {
	if (!entry || typeof entry !== 'object' || !entry.emit_hs_key) continue;
	const mods = entry.emit_hs_mods || [];
	for (const m of mods) {
		if (!ALLOWED_MODS.has(m)) {
			console.error(
				`[ERROR] ${id}: modifier "${m}" is not one hs.eventtap.keyStroke accepts ` +
					`(${[...ALLOWED_MODS].join(', ')}).`
			);
			process.exit(1);
		}
	}
	rows.push({ id, key: entry.emit_hs_key, mods });
}

if (rows.length === 0) {
	console.error('[ERROR] the catalogue declares no emit_hs rows — refusing to generate an empty table.');
	process.exit(1);
}
rows.sort((a, b) => a.id.localeCompare(b.id));

/** A Lua double-quoted literal. */
const q = (s) => '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';

const lines = [];
lines.push('--- _generated/gesture_emit_actions.lua');
lines.push('--- AUTO-GENERATED from _shared/modules/actions/actions.toml.');
lines.push('--- DO NOT EDIT BY HAND — run `npm run codegen:gesture-emit-actions:hs` to refresh.');
lines.push('');
lines.push('--- ==============================================================================');
lines.push('--- MODULE: Gesture Emit Actions (macOS)');
lines.push('--- DESCRIPTION:');
lines.push('--- Every action macOS performs as a plain keystroke, as { key, mods } for');
lines.push('--- hs.eventtap.keyStroke. modules/gestures/actions.lua registers these instead');
lines.push('--- of spelling each one out as its own closure.');
lines.push('---');
lines.push('--- These are macOS values, NOT shared ones. Of the 24 actions both drivers');
lines.push('--- implement as a bare keystroke, 15 use a different key or modifier: macOS');
lines.push('--- moves by word with Option where Windows uses Control, closes a window with');
lines.push('--- cmd+w against alt+F4, and spells several keys differently outright');
lines.push('--- (return/Enter, delete/BackSpace). The Windows values live in the same');
lines.push('--- catalogue under emit_ahk_*.');
lines.push('--- ==============================================================================');
lines.push('');
lines.push('return {');
for (const r of rows) {
	const mods = r.mods.map(q).join(', ');
	lines.push(`\t{ id = ${q(r.id)}, key = ${q(r.key)}, mods = { ${mods} } },`);
}
lines.push('}');
lines.push('');

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, lines.join('\n'), 'utf8');
console.log(`  wrote ${path.relative(ROOT, OUT).split(path.sep).join('/')}`);
console.log(`[OK] ${rows.length} macOS keystroke action(s) generated.`);
