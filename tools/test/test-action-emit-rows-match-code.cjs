// tools/test/test-action-emit-rows-match-code.cjs

/**
 * ==============================================================================
 * MODULE: Action `emit` Rows Match the Implementation
 * DESCRIPTION:
 * The shared action catalogue now declares, for 62 actions, the keystroke they
 * emit. The Windows registry still emits it in code. Until Lot 6(3) deletes that
 * code, the two must agree — and this gate is the only thing that makes the
 * declaration trustworthy enough to delete the code against.
 *
 * WHY THE DATA WAS DERIVED, NOT WRITTEN:
 * 62 hand-copied key/modifier pairs would carry transcription errors that
 * nothing catches until a user makes the gesture and the wrong shortcut fires.
 * `copy` sending Ctrl+X instead of Ctrl+C is not a crash, not a failing test,
 * and not visible in review. So the rows were generated from the registry, and
 * this gate re-derives them independently and compares — which is what makes the
 * generation step auditable rather than merely convenient.
 *
 * WHAT THE MEASUREMENT CORRECTED:
 * The backlog described these as "62 pure-keystroke Windows actions" that are
 * bare `Send()` lambdas. The count is exactly right; the mechanism was not.
 * Only FOUR are bare `Send(literal)`. The other 58 call
 * `TextPressKey("c", ["Ctrl"])` — a key plus a modifier list, which is why the
 * portable `emit_key` + `emit_mods` pair fits them and a raw send-string does
 * not. Flat keys rather than an inline table: the shared TOML codec silently
 * returns nil on a multi-element array nested inside one — found by writing
 * `mods = ["ctrl", "super"]` and watching the Linux gesture suite lose 14
 * tests. The four that genuinely are raw AHK sequences are stored as `emit_ahk`,
 * because `{Home}{Shift Down}{End}{Shift Up}` has no portable form.
 *
 * "Win" is stored as "super": each driver maps it to its own physical key
 * (Win / Cmd / Super), and baking one platform's name into a shared catalogue is
 * precisely the silo the one-registry work exists to remove.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const CATALOGUE = path.join(SP, '_shared', 'modules', 'actions', 'actions.toml');
const AHK = path.join(SP, 'windows', 'modules', 'gestures', 'actions.ahk');

const MOD_MAP = { Ctrl: 'ctrl', Alt: 'alt', Shift: 'shift', Win: 'super' };

const errors = [];

/** Re-derives every declarative handler from the AHK registry. */
function deriveFromCode() {
	const lines = fs.readFileSync(AHK, 'utf8').split(/\r?\n/);
	const keyRows = new Map();
	const seqRows = new Map();
	for (let i = 0; i < lines.length; i++) {
		const m = lines[i].match(/^\s*"([a-z0-9_]+)",\s*\{\s*$/);
		if (!m) continue;
		const body = [];
		for (let j = i + 1; j < lines.length && !/^\s*\},\s*$/.test(lines[j]); j++) {
			body.push(lines[j].trim());
		}
		const expr = body.join(' ').replace(/^Fn:\s*/, '').replace(/,$/, '');

		const tp = expr.match(/^\(\*\)\s*=>\s*TextPressKey\(\s*"([^"]*)"\s*(?:,\s*\[([^\]]*)\])?\s*\)$/);
		if (tp) {
			const mods = (tp[2] || '')
				.split(',')
				.map((x) => x.trim().replace(/"/g, ''))
				.filter(Boolean);
			keyRows.set(m[1], { key: tp[1], mods: mods.map((x) => MOD_MAP[x] || x) });
			continue;
		}
		const sd = expr.match(/^\(\*\)\s*=>\s*Send(?:FinalResult|Input|Text)?\(\s*"((?:[^"`]|`.)*)"\s*\)$/);
		if (sd) seqRows.set(m[1], sd[1]);
	}
	return { keyRows, seqRows };
}

const { keyRows, seqRows } = deriveFromCode();
const catalogue = toml.parse(fs.readFileSync(CATALOGUE, 'utf8'));
const sg = catalogue.sg_actions || {};

if (keyRows.size + seqRows.size < 50) {
	errors.push(
		`re-derived only ${keyRows.size + seqRows.size} declarative handler(s) from the AHK registry — ` +
			'the parse is broken, and a comparison against nothing passes forever'
	);
}

// ── Every derived handler must be declared, and identically ─────────────────

for (const [id, want] of keyRows) {
	const entry = sg[id];
	if (!entry) {
		errors.push(`${id}: the AHK registry emits a keystroke for it, but the catalogue has no entry`);
		continue;
	}
	if (!entry.emit_key) {
		errors.push(
			`${id}: the AHK registry emits TextPressKey("${want.key}", [${want.mods.join(', ')}]) but the ` +
				'catalogue declares no emit_key row — the declaration is what Lot 6(3) deletes the code against'
		);
		continue;
	}
	if (entry.emit_key !== want.key) {
		errors.push(`${id}: emit_key is "${entry.emit_key}", the code sends "${want.key}"`);
	}
	const got = (entry.emit_mods || []).join(',');
	const exp = want.mods.join(',');
	if (got !== exp) {
		errors.push(`${id}: emit_mods is [${got}], the code sends [${exp}]`);
	}
}

for (const [id, want] of seqRows) {
	const entry = sg[id];
	if (!entry) {
		errors.push(`${id}: the AHK registry sends a raw sequence for it, but the catalogue has no entry`);
		continue;
	}
	if (entry.emit_ahk !== want) {
		errors.push(
			`${id}: emit_ahk is ${JSON.stringify(entry.emit_ahk)}, the code sends ${JSON.stringify(want)}`
		);
	}
}

// ── …and nothing may be declared that the code does not do ──────────────────
//
// The other direction matters just as much: an emit row for an action whose
// handler does something else is a lie the conversion would then implement.

for (const [id, entry] of Object.entries(sg)) {
	if (!entry || typeof entry !== 'object') continue;
	if (entry.emit_key && !keyRows.has(id)) {
		errors.push(
			`${id}: declares an emit row, but the AHK handler is not a plain keystroke. Converting it ` +
				'would silently replace whatever that handler really does.'
		);
	}
	if (entry.emit_ahk && !seqRows.has(id)) {
		errors.push(`${id}: declares emit_ahk, but the AHK handler is not a bare Send of a literal`);
	}
}

// ── Modifier vocabulary ─────────────────────────────────────────────────────

const ALLOWED_MODS = new Set(['ctrl', 'alt', 'shift', 'super']);
for (const [id, entry] of Object.entries(sg)) {
	if (!entry || !entry.emit_mods) continue;
	for (const mod of entry.emit_mods) {
		if (!ALLOWED_MODS.has(mod)) {
			errors.push(
				`${id}: modifier "${mod}" is not in the portable set {${[...ALLOWED_MODS].join(', ')}}. ` +
					'"win"/"cmd" must be stored as "super" — each driver maps it to its own physical key.'
			);
		}
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] action emit rows disagree with the implementation:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] all ${keyRows.size} key+modifier and ${seqRows.size} raw-sequence emit row(s) match the ` +
		'Windows registry exactly, in both directions.\x1b[0m'
);
