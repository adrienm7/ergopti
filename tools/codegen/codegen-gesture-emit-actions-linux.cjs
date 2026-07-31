// tools/codegen/codegen-gesture-emit-actions-linux.cjs

/**
 * ==============================================================================
 * MODULE: Gesture Emit-Action Codegen (Linux)
 * DESCRIPTION:
 * The Linux twin. Emits the xdotool key combo each action sends, from the
 * `emit_linux` rows in the shared catalogue.
 *
 * WHY A VERBATIM COMBO STRING, NOT key + mods:
 * A split would suggest a portability that does not exist. X11 keysyms
 * (`Return`, `BackSpace`, `Escape`) are not AHK's names and not Hammerspoon's
 * (`return`, `delete`), so a driver would have to rebuild the string from its
 * own vocabulary regardless. Storing what xdotool actually receives keeps the
 * row honest about being Linux's.
 *
 * WHAT THE THREE SETS OF ROWS SHOW:
 * Linux and Windows agree far more often than either agrees with macOS —
 * `close_window` is alt+F4 on both, `word_next` is ctrl+Right on both, while
 * macOS uses cmd+w and alt+right. The divergence is macOS-versus-the-rest
 * rather than three-way, which is what one would expect: two PC-convention
 * platforms and one Mac-convention platform. That is visible in the catalogue
 * now instead of being buried in three registries.
 *
 * USAGE:  node tools/codegen/codegen-gesture-emit-actions-linux.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const CATALOGUE = path.join(SP, '_shared', 'modules', 'actions', 'actions.toml');
const OUT = path.join(SP, 'linux', '_generated', 'gesture_emit_actions.lua');

const sg = toml.parse(fs.readFileSync(CATALOGUE, 'utf8')).sg_actions || {};

const rows = [];
for (const [id, entry] of Object.entries(sg)) {
	if (!entry || typeof entry !== 'object' || typeof entry.emit_linux !== 'string') continue;
	if (entry.emit_linux === '') {
		console.error(`[ERROR] ${id}: emit_linux is empty — that would run "xdotool key " with no key.`);
		process.exit(1);
	}
	// A quote or shell metacharacter would be interpolated into a command line.
	if (/["'`$\\;|&<>]/.test(entry.emit_linux)) {
		console.error(
			`[ERROR] ${id}: emit_linux "${entry.emit_linux}" contains a shell metacharacter. ` +
				'These strings are interpolated into an xdotool command line.'
		);
		process.exit(1);
	}
	rows.push({ id, combo: entry.emit_linux });
}

if (rows.length === 0) {
	console.error('[ERROR] the catalogue declares no emit_linux rows — refusing to generate an empty table.');
	process.exit(1);
}
rows.sort((a, b) => a.id.localeCompare(b.id));

const q = (s) => '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';

const lines = [];
lines.push('--- _generated/gesture_emit_actions.lua');
lines.push('--- AUTO-GENERATED from _shared/modules/actions/actions.toml.');
lines.push('--- DO NOT EDIT BY HAND — run `npm run codegen:gesture-emit-actions:linux` to refresh.');
lines.push('');
lines.push('--- ==============================================================================');
lines.push('--- MODULE: Gesture Emit Actions (Linux)');
lines.push('--- DESCRIPTION:');
lines.push('--- Every action Linux performs as a single xdotool key combo, as');
lines.push('--- action id -> combo. modules/gestures/manager.lua looks the action up here');
lines.push('--- instead of carrying one elseif branch per action.');
lines.push('---');
lines.push('--- The combos are X11 keysym syntax and are Linux\'s own: `Return`, not AHK\'s');
lines.push('--- `Enter` or Hammerspoon\'s `return`. Linux and Windows agree far more often');
lines.push('--- than either agrees with macOS — alt+F4 and ctrl+Right on both, against');
lines.push('--- cmd+w and alt+right — so the divergence is macOS-versus-the-rest.');
lines.push('--- ==============================================================================');
lines.push('');
lines.push('return {');
for (const r of rows) {
	lines.push(`\t[${q(r.id)}] = ${q(r.combo)},`);
}
lines.push('}');
lines.push('');

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, lines.join('\n'), 'utf8');
console.log(`  wrote ${path.relative(ROOT, OUT).split(path.sep).join('/')}`);
console.log(`[OK] ${rows.length} Linux keystroke action(s) generated.`);
