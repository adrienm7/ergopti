// tools/codegen/codegen-gesture-emit-actions.cjs

/**
 * ==============================================================================
 * MODULE: Gesture Emit-Action Codegen (Windows)
 * DESCRIPTION:
 * Emits the Windows handlers for every action whose behaviour the shared
 * catalogue fully describes — 58 key+modifier actions and 4 raw sequences.
 *
 * WHY GENERATED RATHER THAN BUILT AT RUNTIME:
 * The obvious move is to have _GestureLoadActionCatalog() install these while it
 * already has the TOML parsed. It must not: that loader is deliberately deferred
 * off the boot path (a SetTimer with a negative period, worth ~100 ms), so
 * building handlers there opens a window in which a gesture fires and finds no
 * handler at all. Generating a plain data function keeps registration at
 * static-init where it is today, with no TOML parse on the boot path.
 *
 * WHY GENERATED RATHER THAN HAND-WRITTEN:
 * These 62 entries were 62 hand-written lambdas — `copy` spelling out
 * `TextPressKey("c", ["Ctrl"])` in a Map literal, and the same intent spelled
 * again in the macOS and Linux registries. That is data pretending to be code:
 * three copies of one fact, and a wrong one is invisible (a `copy` action that
 * sends Ctrl+X is not a crash and not a failing test).
 *
 * The modifier vocabulary is portable — ctrl / alt / shift / super — and this
 * generator maps it to the AHK names TextPressKey expects. `super` becomes
 * "Win" here and would become "Cmd" in a macOS emitter; storing one platform's
 * spelling in the shared catalogue is the silo the one-registry work removes.
 *
 * USAGE:  node tools/codegen/codegen-gesture-emit-actions.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const CATALOGUE = path.join(SP, '_shared', 'modules', 'actions', 'actions.toml');
const OUT = path.join(SP, 'windows', '_generated', 'gesture_emit_actions.ahk');

// Portable modifier token -> the name TextPressKey expects on Windows.
const MOD_TO_AHK = { ctrl: 'Ctrl', alt: 'Alt', shift: 'Shift', super: 'Win' };

const catalogue = toml.parse(fs.readFileSync(CATALOGUE, 'utf8'));
const sg = catalogue.sg_actions || {};

const keyRows = [];
const seqRows = [];

for (const [id, entry] of Object.entries(sg)) {
	if (!entry || typeof entry !== 'object') continue;
	if (entry.emit_key) {
		const mods = (entry.emit_mods || []).map((m) => {
			const ahk = MOD_TO_AHK[m];
			if (!ahk) {
				console.error(`[ERROR] ${id}: modifier "${m}" has no Windows mapping.`);
				process.exit(1);
			}
			return ahk;
		});
		keyRows.push({ id, key: entry.emit_key, mods });
	} else if (entry.emit_ahk) {
		seqRows.push({ id, seq: entry.emit_ahk });
	}
}

if (keyRows.length + seqRows.length === 0) {
	console.error('[ERROR] the catalogue declares no emit rows — refusing to generate an empty registry.');
	process.exit(1);
}

keyRows.sort((a, b) => a.id.localeCompare(b.id));
seqRows.sort((a, b) => a.id.localeCompare(b.id));

/** An AHK v2 double-quoted literal (backtick is the escape character). */
const q = (s) => '"' + String(s).replace(/`/g, '``').replace(/"/g, '`"') + '"';

const lines = [];
lines.push('﻿; _generated/gesture_emit_actions.ahk');
lines.push('; AUTO-GENERATED from _shared/modules/actions/actions.toml.');
lines.push('; DO NOT EDIT BY HAND — run `npm run codegen:gesture-emit-actions` to refresh.');
lines.push('#Requires AutoHotkey v2.0');
lines.push('');
lines.push('; ==============================================================================');
lines.push('; MODULE: Gesture Emit Actions (Windows)');
lines.push('; DESCRIPTION:');
lines.push('; Every action whose behaviour the shared catalogue fully describes: a key plus');
lines.push('; modifiers, or a raw send sequence. modules/gestures/actions.ahk turns these');
lines.push('; into registry handlers at static-init, so nothing here runs on the boot path');
lines.push('; and no TOML is parsed to register them.');
lines.push(';');
lines.push('; These were 62 hand-written lambdas in a Map literal, with the same intent');
lines.push('; spelled again in the macOS and Linux registries — three copies of one fact,');
lines.push('; where a wrong one is invisible: a `copy` action sending Ctrl+X is not a crash');
lines.push('; and not a failing test.');
lines.push('; ==============================================================================');
lines.push('');
lines.push('; id -> { Key, Mods } for a key press, or { Seq } for a raw send sequence.');
lines.push('; A function, not a global, so include order cannot matter.');
lines.push('GestureEmitActionsData() {');
lines.push('\treturn Map(');

const parts = [];
for (const r of keyRows) {
	parts.push(`\t\t${q(r.id)}, { Key: ${q(r.key)}, Mods: [${r.mods.map(q).join(', ')}] }`);
}
for (const r of seqRows) {
	parts.push(`\t\t${q(r.id)}, { Seq: ${q(r.seq)} }`);
}
lines.push(parts.join(',\n'));
lines.push('\t)');
lines.push('}');
lines.push('');

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, lines.join('\n'), 'utf8');
console.log(`  wrote ${path.relative(ROOT, OUT).split(path.sep).join('/')}`);
console.log(`[OK] ${keyRows.length} key action(s) and ${seqRows.length} raw sequence(s) generated.`);
