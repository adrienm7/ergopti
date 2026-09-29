// tools/test/test-gesture-defaults-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Gesture Recommended Actions Single-Source Guard
 * DESCRIPTION:
 * « Restaurer les valeurs conseillées » under Gestures puts every slot back to
 * Ergopti's recommended action. That value is declared once, per platform, in
 * the features manifest (`gestures.<slot>`), while neutral defaults initialize fresh
 * config.toml. macOS kept its own table (DEFAULT_GESTURES) and Windows its own
 * map (GESTURE_FACTORY_DEFAULTS); the macOS table had already drifted: the
 * manifest bound the two-finger left swipe and the three horizontal axes that
 * the macOS runtime left unbound, so a fresh configuration and a restore gave
 * two different trackpads.
 *
 * WHAT THIS PINS:
 *   1. Neither driver spells a slot's recommended action in source: macOS
 *      builds RECOMMENDED_GESTURES from the manifest reader over its slot lists,
 *      Windows builds GESTURE_FACTORY_DEFAULTS from the manifest reader over
 *      GestureSlotIds().
 *   2. Every slot each driver iterates has a manifest entry on that platform,
 *      so the build cannot fail at load.
 * A hand copy that is found is also compared value by value, so the report
 * names the slots that drifted. The Lua and AHK suites check the built values
 * at runtime.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { parse: parseToml } = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const read = (rel) => fs.readFileSync(path.join(SP, rel), 'utf8');

const MACOS_FILE = 'macos/modules/gestures/init.lua';
const WINDOWS_FILE = 'windows/modules/gestures/actions.ahk';
const WINDOWS_SLOTS_FILE = 'windows/modules/gestures/constants.ahk';

const errors = [];

// ==================================================
// ==================================================
// ======= 1/ The manifest ==========================
// ==================================================
// ==================================================

/**
 * The gesture action defaults the manifest declares for one platform.
 * @param {string} platform "ahk", "hs" or "linux".
 * @returns {Map<string, string>} slot -> action.
 */
function manifestDefaults(platform) {
	const raw = read('_shared/modules/features/manifest.toml').replace(
		/^\[\[features\.([^\]]+)\]\]\r?$/gm,
		(_m, prefix) => `[[entries]]\npath_prefix = "${prefix}"`
	);
	const out = new Map();
	for (const entry of parseToml(raw).entries || []) {
		if (entry.path_prefix !== 'gestures' || entry.type !== 'action') continue;
		if (Array.isArray(entry.platforms) && !entry.platforms.includes(platform)) continue;
		const perPlatform = entry.recommended_per_platform || {};
		out.set(
			entry.id,
			perPlatform[platform] !== undefined ? perPlatform[platform] : entry.recommended
		);
	}
	return out;
}

/**
 * The string literals of one table/array body.
 * @param {string} body Source between the braces or brackets.
 * @returns {string[]}
 */
function quoted(body) {
	return [...body.matchAll(/"([a-z0-9_]+)"/g)].map((m) => m[1]);
}

// ==================================================
// ==================================================
// ======= 2/ macOS =================================
// ==================================================
// ==================================================

{
	const src = read(MACOS_FILE);
	const hs = manifestDefaults('hs');
	if (hs.size < 30)
		errors.push(
			`the manifest declares ${hs.size} macOS gesture slot(s) — the manifest scan is broken.`
		);

	const literal = src.match(/M\.DEFAULT_GESTURES\s*=\s*\{([\s\S]*?)\n\}/);
	const pairs = literal ? [...literal[1].matchAll(/^\s*([a-z0-9_]+)\s*=\s*"([a-z0-9_]+)"/gm)] : [];
	if (pairs.length > 0) {
		const drift = pairs
			.filter(([, slot, action]) => hs.get(slot) !== action)
			.map(([, slot, action]) => `${slot} (macOS "${action}", manifest "${hs.get(slot)}")`);
		errors.push(
			`${MACOS_FILE} spells ${pairs.length} recommended action(s) by hand in DEFAULT_GESTURES` +
				(drift.length ? `, ${drift.length} of them drifted: ${drift.join(', ')}` : '') +
				'.'
		);
	}
	if (
		!/M\.DEFAULT_GESTURES\[slot\]\s*=\s*Manifest\.default_for\("gestures\."\s*\.\.\s*slot\)/.test(
			src
		)
	) {
		errors.push(
			`${MACOS_FILE} must build DEFAULT_GESTURES from Manifest.default_for("gestures." .. slot).`
		);
	}

	if (
		!src.includes('M.RECOMMENDED_GESTURES[slot] = Manifest.recommended_for("gestures." .. slot)')
	) {
		errors.push(
			`${MACOS_FILE} must project explicit recommendations separately from neutral defaults.`
		);
	}

	const slots = [];
	for (const name of ['SINGLE_SLOTS', 'AXIS_SLOTS']) {
		const m = src.match(new RegExp('M\\.' + name + '\\s*=\\s*\\{([\\s\\S]*?)\\}'));
		if (!m) errors.push(`${MACOS_FILE} declares no M.${name}.`);
		else slots.push(...quoted(m[1]));
	}
	if (slots.length < 30)
		errors.push(`${MACOS_FILE} lists ${slots.length} slot(s) — the slot scan is broken.`);
	for (const slot of slots) {
		if (typeof hs.get(slot) !== 'string')
			errors.push(`the manifest has no macOS default for gestures.${slot}.`);
	}
}

// ==================================================
// ==================================================
// ======= 3/ Windows ===============================
// ==================================================
// ==================================================

{
	const src = read(WINDOWS_FILE);
	const ahk = manifestDefaults('ahk');
	if (ahk.size < 10)
		errors.push(
			`the manifest declares ${ahk.size} Windows gesture slot(s) — the manifest scan is broken.`
		);

	const literal = src.match(/GESTURE_FACTORY_DEFAULTS\s*:=\s*Map\(([\s\S]*?)\n\)/);
	if (literal) {
		const values = quoted(literal[1]);
		const drift = [];
		for (let i = 0; i + 1 < values.length; i += 2) {
			if (ahk.get(values[i]) !== values[i + 1])
				drift.push(`${values[i]} (Windows "${values[i + 1]}", manifest "${ahk.get(values[i])}")`);
		}
		errors.push(
			`${WINDOWS_FILE} spells ${values.length / 2} recommended action(s) by hand in GESTURE_FACTORY_DEFAULTS` +
				(drift.length ? `, ${drift.length} of them drifted: ${drift.join(', ')}` : '') +
				'.'
		);
	}
	if (!/global GESTURE_FACTORY_DEFAULTS\s*:=\s*GestureRecommendedActions\(\)/.test(src)) {
		errors.push(
			`${WINDOWS_FILE} must take GESTURE_FACTORY_DEFAULTS from GestureRecommendedActions().`
		);
	}

	if (
		!src.includes(
			'GestureAssignments[_GestureAssignmentSlot] := ManifestDefaultFor("gestures." . _GestureAssignmentSlot)'
		)
	) {
		errors.push(`${WINDOWS_FILE} must initialize assignments with neutral defaults.`);
	}

	const constants = read(WINDOWS_SLOTS_FILE);
	if (!/ManifestRecommendedFor\("gestures\."\s*\.\s*Slot\)/.test(constants)) {
		errors.push(
			`${WINDOWS_SLOTS_FILE} must read each recommended action with ManifestRecommendedFor("gestures." . Slot).`
		);
	}
	const slotList = constants.match(/GestureSlotIds\(\)\s*\{[\s\S]*?static Slots := \[([\s\S]*?)\]/);
	const slots = slotList ? quoted(slotList[1]) : [];
	if (slots.length < 10)
		errors.push(`${WINDOWS_SLOTS_FILE} lists ${slots.length} slot(s) — the slot scan is broken.`);
	for (const slot of slots) {
		if (typeof ahk.get(slot) !== 'string')
			errors.push(`the manifest has no Windows default for gestures.${slot}.`);
	}
}

// ==================================================
// ==================================================
// ======= 4/ Report ================================
// ==================================================
// ==================================================

const linuxSource = read('linux/modules/gestures/manager.lua');
if (
	!linuxSource.includes(
		'M.RECOMMENDED_GESTURES[slot] = Manifest.recommended_for("gestures." .. slot)'
	) ||
	!/function M\.reset_defaults\(\)[\s\S]*?pairs\(M\.RECOMMENDED_GESTURES\)/.test(linuxSource)
) {
	errors.push(
		'Linux must project and restore explicit gesture recommendations separately from initialization.'
	);
}
for (const [slot, action] of manifestDefaults('linux')) {
	if (action !== 'none')
		errors.push(`Linux gesture recommendation gestures.${slot} must remain opt-in (none).`);
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] Gesture recommended actions are not single-sourced:\x1b[0m');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

console.log(
	'\x1b[32m[OK] macOS and Windows build their recommended gesture actions from the manifest.\x1b[0m'
);
