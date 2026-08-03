// tools/test/test-action-chord-notation.cjs

/**
 * ==============================================================================
 * MODULE: Action Chord Notation Validity (I4)
 * DESCRIPTION:
 * Every keystroke the action registry declares must be written in notation its
 * driver can actually execute.
 *
 * THE SILENT FAILURE:
 * A chord is data, and a wrong one is not a crash. `emit_ahk_mods = ["control"]`
 * instead of `["ctrl"]`, or `emit_linux = "ctl+Tab"`, produces a modifier the
 * driver does not recognise: the keystroke fires without it, or does not fire at
 * all. Nothing raises, no test fails, and the symptom reaches the user as a
 * gesture that pastes instead of copying — behaviour indistinguishable from a
 * mis-assigned gesture, which is where the debugging time goes.
 *
 * The registry is 58 AutoHotkey chords, 27 Hammerspoon chords and 26 Linux
 * chords, all currently well-formed and held that way by nothing at all.
 *
 * THE `platform` FIELD IS CHECKED HERE TOO, and for the same reason. It gained a
 * comma-separated list form on 2026-08-03 ("hs,ahk"), because it could not say
 * "two drivers out of three" — the two window cyclers ship on macOS and Windows
 * and not on Linux, so "all" declared rows Linux cannot perform and a single key
 * hid half the feature. A list is more expressive and also more mistakeable:
 * "hs, ahk " with a stray space, or "mac", silently drops the action from a
 * driver's picker with nothing to see. Same failure shape as a wrong modifier
 * name, same gate.
 *
 * THREE NOTATIONS, ON PURPOSE:
 * `emit_ahk_key` + `emit_ahk_mods`, `emit_hs_key` + `emit_hs_mods`, and
 * `emit_linux` as a single "ctrl+shift+Tab" string are not an accident of
 * migration — test-action-emit-is-per-os.cjs records that 13 of 24 keystrokes
 * genuinely differ across the platforms (Ctrl where macOS wants Cmd, and so on),
 * so a single neutral chord could not describe them. What CAN be shared is the
 * vocabulary, which is what this checks: the same five modifier names mean the
 * same thing everywhere, whichever spelling of the row carries them.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const REGISTRY = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'modules', 'actions', 'actions.toml');

// The one modifier vocabulary. "super" is stored neutrally and each driver maps
// it to its own physical key, which is why "win" and "meta" are not spellings
// here — a second name for the same modifier is how two rows come to disagree.
const MODIFIERS = new Set(['alt', 'ctrl', 'cmd', 'shift', 'super']);

// Floors per driver: the registry has 58/27/26 today. A parse that stops
// matching would find nothing malformed and pass having validated nothing.
const MIN_CHORDS = { ahk: 40, hs: 20, linux: 18 };

// The driver keys a `platform` field may name, plus the "all" shorthand.
const PLATFORM_KEYS = new Set(['hs', 'ahk', 'linux']);

// Floor on the number of platform fields read, for the same reason as MIN_CHORDS.
const MIN_PLATFORM_FIELDS = 150;

const TABLE_HEADER = /^(\[+)([A-Za-z0-9_.]+)(\]+)\s*$/;
const STRING_FIELD = (f) => new RegExp(`^${f}\\s*=\\s*"([^"]*)"`, 'm');
const ARRAY_FIELD = (f) => new RegExp(`^${f}\\s*=\\s*\\[([^\\]]*)\\]`, 'm');

const errors = [];

if (!fs.existsSync(REGISTRY)) {
	console.error('\x1b[31m[ERROR] actions.toml is missing.\x1b[0m');
	process.exit(1);
}

// Accumulate each table's body under its header.
const tables = [];
let current = null;
for (const line of fs.readFileSync(REGISTRY, 'utf8').split(/\r?\n/)) {
	const m = line.match(TABLE_HEADER);
	if (m) {
		if (current) tables.push(current);
		current = { name: m[2], body: [] };
		continue;
	}
	if (current) current.body.push(line);
}
if (current) tables.push(current);

const counts = { ahk: 0, hs: 0, linux: 0 };
let platformFields = 0;

for (const t of tables) {
	const body = t.body.join('\n');
	const str = (f) => {
		const m = body.match(STRING_FIELD(f));
		return m ? m[1] : null;
	};
	const arr = (f) => {
		const m = body.match(ARRAY_FIELD(f));
		return m ? [...m[1].matchAll(/"([^"]*)"/g)].map((x) => x[1]) : null;
	};
	const id = str('id') || t.name;

	// The platform field: "all", one driver key, or a comma-separated list.
	const platform = str('platform');
	if (platform !== null) {
		platformFields++;
		if (platform === '') {
			errors.push(`${id}: platform is empty — write "all" if that is what is meant`);
		} else if (platform !== 'all') {
			const keys = platform.split(',');
			for (const raw of keys) {
				if (raw !== raw.trim()) {
					errors.push(
						`${id}: platform "${platform}" has whitespace around "${raw}". Every reader compares ` +
							'the parts exactly, so the padded one matches no driver and the action vanishes ' +
							'from that picker with nothing to see.'
					);
				}
				const key = raw.trim();
				if (!PLATFORM_KEYS.has(key)) {
					errors.push(
						`${id}: platform "${platform}" names "${key}", which is not a driver ` +
							`(${[...PLATFORM_KEYS].join(', ')}, or "all"). No picker will list it, and no gate ` +
							'other than this one can tell that apart from a deliberate restriction.'
					);
				}
			}
			if (new Set(keys.map((k) => k.trim())).size !== keys.length) {
				errors.push(`${id}: platform "${platform}" repeats a driver`);
			}
			if (keys.length >= PLATFORM_KEYS.size) {
				errors.push(
					`${id}: platform "${platform}" lists every driver — write "all", so that a driver added ` +
						'later inherits it instead of being silently excluded by a list nobody revisits'
				);
			}
		}
	}

	// The two paired notations.
	for (const drv of ['ahk', 'hs']) {
		const key = str(`emit_${drv}_key`);
		const mods = arr(`emit_${drv}_mods`);

		if (key === null && mods === null) continue;
		counts[drv]++;

		// A key with no mods array, or mods with no key, is half a chord. The
		// driver reads one field and gets nothing for the other.
		if (key === null || mods === null) {
			errors.push(
				`${id}: emit_${drv}_key and emit_${drv}_mods must appear together — one without the other ` +
					'leaves the driver reading a chord that is half declared'
			);
			continue;
		}
		if (key === '') {
			errors.push(`${id}: emit_${drv}_key is empty — there is no key to send`);
		}
		for (const mod of mods) {
			if (!MODIFIERS.has(mod)) {
				errors.push(
					`${id}: emit_${drv}_mods contains "${mod}", which is not a modifier name ` +
						`(${[...MODIFIERS].join(', ')}). The driver drops what it does not recognise, so the ` +
						'keystroke fires without it — no error, just the wrong shortcut.'
				);
			}
		}
		if (new Set(mods).size !== mods.length) {
			errors.push(`${id}: emit_${drv}_mods repeats a modifier`);
		}
	}

	// The Linux single-string notation: "mod+mod+Key".
	const lin = str('emit_linux');
	if (lin !== null) {
		counts.linux++;
		const parts = lin.split('+');
		const key = parts[parts.length - 1];
		if (lin.trim() === '' || key === '') {
			errors.push(`${id}: emit_linux "${lin}" has no key — a chord that is only modifiers sends nothing`);
		}
		for (const mod of parts.slice(0, -1)) {
			if (!MODIFIERS.has(mod)) {
				errors.push(
					`${id}: emit_linux "${lin}" uses "${mod}" as a modifier, which is not one of ` +
						`${[...MODIFIERS].join(', ')}. xdotool receives a name it does not know and the ` +
						'keystroke is wrong or silently dropped.'
				);
			}
		}
	}
}

if (platformFields < MIN_PLATFORM_FIELDS) {
	errors.push(
		`read only ${platformFields} platform field(s) (floor ${MIN_PLATFORM_FIELDS}) — the registry parse ` +
			'is broken, and the platform check above validated nothing'
	);
}

for (const [drv, min] of Object.entries(MIN_CHORDS)) {
	if (counts[drv] < min) {
		errors.push(
			`${drv}: found only ${counts[drv]} chord(s) (floor ${min}) — the registry parse is broken, and ` +
				'this guard would then report nothing malformed while having read nothing'
		);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] action chord notation:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] every declared chord is well formed (${counts.ahk} AutoHotkey, ${counts.hs} ` +
		`Hammerspoon, ${counts.linux} Linux), and all ${platformFields} platform field(s) name real ` +
		'drivers.\x1b[0m'
);
