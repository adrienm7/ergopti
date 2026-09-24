// tools/test/test-keyboard-slot-recommended-bindings.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard-Slot Default Bindings Gate
 * DESCRIPTION:
 * The features manifest declares each driver's shipped keyboard-slot bindings
 * (features.shortcuts.keyboard). "Generate an AI prediction" is bound to the
 * chord each OS leaves for it: Ctrl+Space on macOS (hs_ctrl_space), Win+Space
 * on Windows (win_space), Super+Space on Linux (super_space). macOS and Linux
 * read these defaults from their generated manifest at runtime; Windows keeps
 * KEYBOARD_SHORTCUT_DEFAULTS in AutoHotkey, so this gate holds that copy to the
 * manifest.
 *
 * WHY:
 * The dedicated AI trigger-shortcut settings were replaced by these keyboard
 * slots. A binding declared in the manifest and missing from the Windows map
 * would leave Windows without a way to ask for a prediction while the menu
 * describes one.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const MANIFEST = path.join(SP, '_shared', 'modules', 'features', 'manifest.toml');
const AHK_DEFAULTS = path.join(SP, 'windows', 'infra', 'feature_state.ahk');
const DRIVER_MODULES = {
	hs: path.join(SP, 'macos', 'modules', 'shortcuts', 'keyboard_shortcuts.lua'),
	linux: path.join(SP, 'linux', 'modules', 'shortcuts', 'keyboard_shortcuts.lua'),
};
const PREDICTION_SLOTS = { ahk: 'win_space', hs: 'hs_ctrl_space', linux: 'super_space' };

// Manifest slots Windows does not bind yet, found when this gate was written.
// win_sc029 (Win+², the instant capture) lost its Windows hotkey when the key
// became a tap key; whether the chord keeps a default is a separate decision.
// Ratchet: an entry that stops being a gap must be removed from this list.
const KNOWN_WINDOWS_GAPS = ['win_sc029'];

const errors = [];
let checks = 0;
const check = (ok, message) => {
	checks += 1;
	if (!ok) errors.push(message);
};

// Parsed as tools/build/build-features-manifest.js does: a nested
// [[features.X.Y]] block is, to TOML, a sub-array of the last [[features.X]]
// entry, so each block is rewritten into one flat [[entries]] array first.
const manifest = toml.parse(fs.readFileSync(MANIFEST, 'utf8').replace(
	/^\[\[features\.([^\]]+)\]\]\r?$/gm,
	(_match, prefix) => `[[entries]]\npath_prefix = "${prefix}"`
));
const slots = (manifest.entries || []).filter((entry) => entry.path_prefix === 'shortcuts.keyboard');
check(slots.length >= 15, `only ${slots.length} shortcuts.keyboard entr(ies) parsed — the walk collapsed`);

for (const [platform, slot] of Object.entries(PREDICTION_SLOTS)) {
	const bound = slots.filter((entry) => entry.default === 'llm_generate_prediction'
		&& (entry.platforms || []).includes(platform));
	check(bound.length === 1 && bound[0].id === slot,
		`${platform}: exactly one keyboard slot must default to llm_generate_prediction, and it must be ${slot}; found ${JSON.stringify(bound.map((e) => e.id))}`);
	if (bound[0]) {
		check(JSON.stringify(bound[0].platforms) === JSON.stringify([platform]),
			`${slot} must be declared for ${platform} only: the chord is that OS's`);
		check(bound[0].type === 'action', `${slot} must be an action entry`);
	}
}

// Windows: every ahk manifest slot default is in KEYBOARD_SHORTCUT_DEFAULTS.
const ahk = fs.readFileSync(AHK_DEFAULTS, 'utf8').replace(/^\uFEFF/, '');
const block = (ahk.match(/global KEYBOARD_SHORTCUT_DEFAULTS := Map\(([\s\S]*?)\n\)/) || [])[1] || '';
const windowsDefaults = new Map([...block.matchAll(/"(\w+)",\s*"(\w+)"/g)].map((m) => [m[1], m[2]]));
check(windowsDefaults.size >= 15, `only ${windowsDefaults.size} Windows default(s) parsed`);
for (const entry of slots.filter((e) => (e.platforms || []).includes('ahk'))) {
	const matches = windowsDefaults.get(entry.id) === entry.default;
	if (KNOWN_WINDOWS_GAPS.includes(entry.id)) {
		check(!matches, `${entry.id} is now bound on Windows: remove it from KNOWN_WINDOWS_GAPS`);
		continue;
	}
	check(matches,
		`windows KEYBOARD_SHORTCUT_DEFAULTS must map ${entry.id} to ${entry.default}, has ${windowsDefaults.get(entry.id)}`);
}

// macOS and Linux have no copy: their slot modules seed from the manifest.
for (const [platform, file] of Object.entries(DRIVER_MODULES)) {
	const source = fs.readFileSync(file, 'utf8');
	check(/Manifest\.features\(\)/.test(source) && /"shortcuts\.keyboard"/.test(source),
		`${platform}: keyboard_shortcuts.lua must seed its defaults from the manifest's shortcuts.keyboard entries`);
}

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}
console.log(`\x1b[32m[OK] keyboard-slot default bindings: ${checks} check(s) passed.\x1b[0m`);
