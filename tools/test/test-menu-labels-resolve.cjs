// tools/test/test-menu-labels-resolve.cjs

/**
 * ==============================================================================
 * MODULE: Manifest Menu-Label Resolution Gate
 * DESCRIPTION:
 * Two statements about the labels the tray menu derives from the feature
 * manifest's `description_key`.
 *
 * 1. NO description_key may name a driver. This is an assertion of zero, the
 *    i18n half of the namespace invariant (I2). A key like
 *    `menu.ahk.shortcuts.personal` cannot match a catalogue entry — no
 *    catalogue has ever held an `ahk.` key — so it silently degrades through
 *    the fallback chain, and the failure is invisible: the menu shows a raw
 *    identifier where a translation exists. That is not hypothetical. All 21
 *    catalogues carried `menu.shortcuts.personal` ("Personal shortcuts",
 *    "Raccourcis personnels", …) while the manifest asked for
 *    `menu.ahk.shortcuts.personal`, so the Windows tray menu showed the literal
 *    word "personal" in every language.
 *
 * 2. A RATCHET on how many entries still fall all the way through. The chain
 *    (infra/manifest_descriptions.ahk) ends by returning the path's last
 *    segment, so a missing translation is never an error at runtime — it is a
 *    lowercase English identifier in the middle of a translated menu. Nothing
 *    counted them. 110 of 243 entries do. Most are settings the hand-written
 *    menu renders itself and never asks the manifest about, which is why this
 *    is a ratchet rather than an assertion of zero: it makes the number visible
 *    and stops it growing, and Lot 5's menu migration is what drives it down.
 *
 * WHY THE CHAIN IS MODELLED HERE:
 * The resolution order lives in AHK. Re-implementing it in JS is a second
 * statement of the same rule, not a copy of an implementation — if the two ever
 * disagree the ratchet count moves and this gate fails, which is the loud
 * signal. A gate that called into the driver could not run in CI without AHK.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const GEN = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'windows',
	'_generated',
	'features_manifest.ahk'
);
const EN = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'data', 'locales', 'en.json');

// Frozen baseline — manifest entries whose label falls through to the raw path
// tail. Lower it as translations land; NEVER raise it.
// History: 111 → 110 (2026-08-02: the driver namespace left the description_key,
//                     which reconnected shortcuts.personal to the translation
//                     that had been sitting in all 21 catalogues unused.)
const FALLTHROUGH_BASELINE = 110;

/** Segments that name a driver rather than a feature. */
const DRIVER_SEGMENTS = ['ahk', 'hs', 'linux', 'macos', 'windows'];

/** `layout.ergopti_base` -> `layout.ergoptibase`. */
const stripUnderscores = (key) => key.split('_').join('');

/**
 * Rebuilds the ordered candidate list of `_MenuLabelCandidateKeys`.
 * @param {string} descKey - The manifest's description_key.
 * @param {string} entryPath - The canonical v2 path of the entry.
 * @returns {string[]} Candidate i18n keys, best first.
 */
function candidateKeys(descKey, entryPath) {
	const out = [];
	if (descKey) out.push(descKey);

	if (descKey.length > 5 && descKey.startsWith('menu.')) {
		const noMenu = descKey.slice(5);
		out.push(noMenu, stripUnderscores(noMenu));
		if (noMenu.length > 11 && noMenu.startsWith('hotstrings.')) {
			const noHs = noMenu.slice(11);
			out.push(noHs, stripUnderscores(noHs));
		}
	}

	if (entryPath && entryPath !== descKey) {
		out.push(entryPath);
		let trimmed = entryPath;
		if (trimmed.length > 11 && trimmed.startsWith('hotstrings.')) {
			trimmed = trimmed.slice(11);
			out.push(trimmed);
		}
		out.push(stripUnderscores(trimmed));
	}

	// The dynamic-hotstrings category folds to "dynamichotstrings" in the
	// catalogue while the manifest uses the short "dynamic" segment; stripping
	// underscores never bridges the two.
	const combined = descKey || entryPath;
	const dyn = combined.indexOf('.dynamic.');
	if (dyn >= 0) {
		const section = combined.slice(dyn + '.dynamic.'.length);
		if (section) {
			out.push(`dynamichotstrings.${section}`, `dynamichotstrings.${stripUnderscores(section)}`);
		}
	}

	return out;
}

/**
 * Extracts every (path, description_key) pair from the generated AHK manifest.
 * @param {string} gen - Generated manifest source.
 * @returns {{path: string, key: string, kind: string}[]} Manifest entries.
 */
function manifestEntries(gen) {
	const out = [];
	// Leaves carry an explicit "path".
	for (const m of gen.matchAll(/"path",\s*"([^"]+)"[^\n]*?"description_key",\s*"([^"]*)"/g)) {
		out.push({ path: m[1], key: m[2], kind: 'leaf' });
	}
	// Sections: the map key IS the path.
	for (const m of gen.matchAll(/^\s*"([A-Za-z0-9_.]+)",\s*Map\("description_key",\s*"([^"]*)"/gm)) {
		out.push({ path: m[1], key: m[2], kind: 'section' });
	}
	return out;
}

const gen = fs.readFileSync(GEN, 'utf8');
const catalogue = JSON.parse(fs.readFileSync(EN, 'utf8'));
const entries = manifestEntries(gen);

if (entries.length === 0) {
	console.error(
		'\x1b[31m[ERROR] No manifest entries parsed — the generated manifest changed shape.\x1b[0m'
	);
	console.error('  A gate that reads nothing reports success by measuring nothing.');
	process.exit(1);
}

const namespaced = entries.filter((e) =>
	DRIVER_SEGMENTS.some((d) => e.key.includes(`.${d}.`) || e.key.startsWith(`${d}.`))
);

const fellThrough = entries.filter(
	(e) => !candidateKeys(e.key, e.path).some((c) => catalogue[c] !== undefined && catalogue[c] !== '')
);

if (process.argv.includes('--measure')) {
	console.log(`manifest entries: ${entries.length}`);
	console.log(`driver-namespaced description_key: ${namespaced.length}`);
	console.log(`falling through to the raw path tail: ${fellThrough.length}`);
	for (const f of fellThrough) console.log(`  [${f.kind}] ${f.path}  key=${f.key}`);
	process.exit(0);
}

let failed = false;
if (namespaced.length > 0) {
	failed = true;
	console.error(
		`\x1b[31m[ERROR] ${namespaced.length} description_key(s) name a driver instead of a feature.\x1b[0m`
	);
	for (const n of namespaced.slice(0, 10)) console.error(`  ${n.path} -> ${n.key}`);
	console.error(
		'\n  No locale catalogue has ever held a driver-prefixed key, so this resolves to\n' +
			'  nothing and the menu falls back to the raw path tail — a lowercase identifier\n' +
			'  where a translation may already exist. Use the semantic path: menu.<path>.'
	);
}
if (fellThrough.length > FALLTHROUGH_BASELINE) {
	failed = true;
	console.error(
		`\x1b[31m[ERROR] Manifest entries with no translated label rose to ${fellThrough.length} (baseline ${FALLTHROUGH_BASELINE}).\x1b[0m`
	);
	console.error(
		'  The candidate chain ends by returning the path\'s last segment, so this never\n' +
			'  fails at runtime — it shows an English identifier inside a translated menu.\n' +
			'  Add the key to the locale catalogues. Do NOT raise the baseline.'
	);
}
if (failed) {
	console.error('  Run `node tools/test/test-menu-labels-resolve.cjs --measure` to list them.');
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] No driver-namespaced description_key; ${fellThrough.length}/${FALLTHROUGH_BASELINE} entries lack a translated label.\x1b[0m`
);
