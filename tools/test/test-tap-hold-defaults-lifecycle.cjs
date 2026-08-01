// tools/test/test-tap-hold-defaults-lifecycle.cjs

/**
 * ==============================================================================
 * MODULE: Tap-Hold Shared Defaults — Documented Lifecycle Guard
 * DESCRIPTION:
 * _shared/tap_hold/defaults.toml is read at runtime, on every boot, by all three
 * drivers. The documentation said the opposite.
 *
 * ROOT CAUSE ENCODED:
 * SCHEMA.md — the config-schema contract — stated in three separate places that
 * the file is "a generation template only", that the per-driver tap_hold.toml is
 * "the complete config", and that "the shared file is never read again at
 * runtime". Its own header repeated it: "there is no runtime merge with this
 * file". None of that was true:
 *
 *   Windows  lib/tap_hold/tap_hold_loader.ahk parses the shared defaults FIRST
 *            and merges the user file on top PER KEY. Its docstring says so in
 *            as many words — "editing defaults.toml takes effect on every reload
 *            even when the user file exists".
 *   Linux    modules/kanata/manager.lua reads it, but a user file REPLACES it
 *            wholesale. Its comment claims this "mirrors the other drivers",
 *            which is precisely what Windows does not do.
 *   macOS    modules/karabiner/defaults.lua reads [hs_*] in its MODULE BODY at
 *            require time, unconditionally.
 *
 * So a maintainer editing this file to tune a threshold, having read the schema
 * doc, would believe the change could not reach an installed driver. On Windows
 * and macOS it reaches every one of them at the next reload.
 *
 * WHAT THIS GUARDS:
 * 1. No document may re-assert the "never read at runtime" claim while a loader
 *    still reads the file. Prose and code drift apart silently; this makes the
 *    contradiction fail.
 * 2. Each of the three loaders must still reference the shared defaults path. If
 *    one genuinely stops reading it, this gate fails and forces the docs to be
 *    updated in the same commit rather than years later.
 * 3. The two namespaces must keep describing the same physical keys. They use
 *    different ids for the same key, so a key added to one and forgotten in the
 *    other is invisible — this pins the mapping.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const DEFAULTS = path.join(SP, '_shared/tap_hold/defaults.toml');

const errors = [];
const read = (rel) => fs.readFileSync(path.join(SP, rel), 'utf8');

// ── 1. The loaders that make the file a runtime input ───────────────────────

const LOADERS = [
	{
		file: 'windows/infra/tap_hold/tap_hold_loader.ahk',
		needle: 'defaults.toml',
		lifecycle: 'parses the shared defaults first, then merges the user file on top per key'
	},
	{
		file: 'linux/modules/kanata/manager.lua',
		needle: 'tap_hold/defaults.toml',
		lifecycle: 'reads the shared defaults; a user file replaces them wholesale'
	},
	{
		file: 'macos/modules/karabiner/defaults.lua',
		needle: 'tap_hold/defaults.toml',
		lifecycle: 'reads [hs_*] in its module body at require time, unconditionally'
	}
];

for (const l of LOADERS) {
	const abs = path.join(SP, l.file);
	if (!fs.existsSync(abs)) {
		errors.push(`${l.file}: missing — the loader moved and this guard no longer covers it`);
		continue;
	}
	if (!read(l.file).includes(l.needle)) {
		errors.push(
			`${l.file} no longer references "${l.needle}". If it genuinely stopped reading the shared ` +
				`defaults (${l.lifecycle}), the documentation describing that lifecycle must change in ` +
				'the same commit — that is what this gate is for.'
		);
	}
}

// ── 2. No document may claim the file is never read at runtime ──────────────
//
// Only fires while at least one loader above still reads it, so the claim
// becomes legal again the day it becomes true.
const loadersStillRead = errors.length === 0;

const DOCS = [
	'_shared/core/config_schema/SCHEMA.md',
	'_shared/tap_hold/defaults.toml'
];

const FALSE_CLAIMS = [
	/no runtime merge/i,
	/never read again at runtime/i,
	/generation source only/i,
	/\bgeneration template only\b/i
];

if (loadersStillRead) {
	for (const rel of DOCS) {
		const abs = path.join(SP, rel);
		if (!fs.existsSync(abs)) {
			errors.push(`${rel}: missing — this guard cannot check the claim it exists to check`);
			continue;
		}
		const lines = read(rel).split(/\r?\n/);
		lines.forEach((line, i) => {
			for (const re of FALSE_CLAIMS) {
				if (!re.test(line)) continue;
				// Quoting the old claim in order to correct it is fine. The marker can
				// sit on a neighbouring line, because prose wraps — checking only the
				// matched line would force the correction to be written awkwardly to
				// satisfy the gate, and a gate that dictates line breaks gets ignored.
				const context = lines.slice(Math.max(0, i - 3), i + 4).join(' ');
				if (/used to say|was wrong|despite|opposite|previously|no longer true/i.test(context)) return;
				errors.push(
					`${rel}:${i + 1}: claims the shared tap-hold defaults are not read at runtime — ` +
						`"${line.trim().slice(0, 90)}". All three drivers read the file on every boot.`
				);
			}
		});
	}
}

// ── 3. The two namespaces must cover the same physical keys ────────────────
//
// They use different ids for the same key, which is exactly why a mismatch is
// invisible without an explicit mapping.
const cfg = toml.parse(fs.readFileSync(DEFAULTS, 'utf8'));

// Physical key -> [tap_hold.keys id, hs_tap_hold id]. Written out because the
// ids genuinely differ and no rule derives one from the other.
const KEY_MAP = [
	['caps lock', 'caps_lock', 'caps_lock'],
	['left shift', 'left_shift', 'left_shift'],
	['left control', 'left_ctrl', 'left_control'],
	['left alt / option', 'left_alt', 'left_option'],
	['tab', 'tab', 'tab'],
	['right alt (AltGr) / right option', 'alt_gr', 'right_option']
];

// Physical keys one namespace configures and the other deliberately does not.
// Recorded rather than mapped, because inventing a counterpart would assert a
// pairing that does not exist. right_ctrl is the live case: [hs_tap_hold] has
// right_command, right_option and right_shift but NO right-control entry, so the
// key carrying one_shot_shift on Windows and Linux is simply unconfigured on
// macOS. Whether that is intended is Lot 8(7)'s call; this list means it cannot
// grow silently.
const KNOWN_UNPAIRED = new Map([
	['right_ctrl', 'no right-control slot exists in [hs_tap_hold] — the key is unconfigured on macOS']
]);

const thKeys = new Set(Object.keys((cfg.tap_hold && cfg.tap_hold.keys) || {}));
const hsKeys = new Set(Object.keys(cfg.hs_tap_hold || {}));

for (const [physical, thId, hsId] of KEY_MAP) {
	if (!thKeys.has(thId)) {
		errors.push(`[tap_hold.keys.${thId}] is gone (${physical}) — the namespace mapping is stale`);
	}
	if (!hsKeys.has(hsId)) {
		errors.push(`[hs_tap_hold].${hsId} is gone (${physical}) — the namespace mapping is stale`);
	}
}

// Any [tap_hold.keys] entry with no counterpart is a key one platform configures
// and the other silently does not.
for (const id of thKeys) {
	if (KNOWN_UNPAIRED.has(id)) continue;
	if (!KEY_MAP.some(([, thId]) => thId === id)) {
		errors.push(
			`[tap_hold.keys.${id}] has no entry in the KEY_MAP above, so nothing checks whether ` +
				'[hs_tap_hold] configures the same physical key. Add the mapping (and its macOS ' +
				'counterpart), or add it to KNOWN_UNPAIRED with the reason it is Windows/Linux-only.'
		);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] tap-hold shared defaults lifecycle:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] all ${LOADERS.length} driver(s) read _shared/tap_hold/defaults.toml at runtime, ` +
		`no document claims otherwise, and both namespaces cover the same ${KEY_MAP.length} physical key(s) ` +
		`(${KNOWN_UNPAIRED.size} recorded as deliberately unpaired).\x1b[0m`
);
