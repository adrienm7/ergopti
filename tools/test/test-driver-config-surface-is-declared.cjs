// tools/test/test-driver-config-surface-is-declared.cjs

/**
 * ==============================================================================
 * MODULE: Driver Config Surface — Declared in the Manifest
 * DESCRIPTION:
 * Every config.toml section/key a driver reads or writes must be declared in
 * _shared/modules/features/manifest.toml FOR THAT PLATFORM. The manifest is the
 * single source of truth for what a config file contains; a key the driver
 * persists but the manifest has never heard of is a setting with no default, no
 * type, no schema entry and no menu row — invisible to every gate that exists.
 *
 * WHY THIS GATE EXISTS:
 * The backlog recorded the Linux half of the namespace invariant as "0 of 324
 * features carry `linux`", which reads like a labelling job. It is not. Measured
 * 2026-08-02, of the ten config surfaces the Linux driver actually touches,
 * exactly ZERO are declared for it:
 *
 *   script.locale            declared for ahk+hs only — Linux writes it anyway
 *   llm.enabled              same
 *   script.layout            no entry
 *   script.onboarding_done   no entry
 *   llm.model                no entry — and llm.models.ollama already means this
 *   llm.ollama_url           no entry
 *   llm.prompt               no entry
 *   paths.*                  no section at all
 *   linux.gestures           a DRIVER-NAMESPACED silo, the exact shape Lot 4
 *   linux.action_parameters  dissolved for [ahk.*] and [hs.*]
 *
 * So adding `linux` to existing features would not have fixed it: most of the
 * keys do not exist, and one of them duplicates a canonical key under another
 * name. That is why this counts SURFACES rather than tokens.
 *
 * HOW THE SURFACE IS FOUND: the writers go through a batch_write of
 * `{ section = "…", key = "…" }` rows, and the readers through
 * `storage.get("section.key")` / `default_for("section.key")`. Both shapes are
 * literal by construction — a driver that computed a section name at runtime
 * would be unable to declare it either.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS_DIR = path.join(ROOT, 'static', 'ergopti_plus');
const MANIFEST = path.join(DRIVERS_DIR, '_shared', 'modules', 'features', 'manifest.toml');

// Frozen baseline — config surfaces a driver touches that the manifest does not
// declare for it. Drive to zero; NEVER raise.
// History: 11 (2026-08-02, first measurement. Ten are Linux; the eleventh is
//            macOS — ui/onboarding/init.lua persists [hotstrings] enabled,
//            a key the manifest has never declared, and its own comment says
//            so: "use_ergopti → [hotstrings].enabled". The wizard writes a
//            setting with no default, no type and no menu row.)
const BASELINE = 11;

const PLATFORM_OF_DRIVER = { windows: 'ahk', macos: 'hs', linux: 'linux' };

/**
 * Parses the manifest into the set of "section.key" paths declared per platform,
 * plus the set of declared section names.
 * @returns {{keys: Map<string, Set<string>>, sections: Map<string, Set<string>>}}
 */
function parseManifest() {
	const lines = fs.readFileSync(MANIFEST, 'utf8').split(/\r?\n/);
	const sectionPlatforms = new Map();
	const keys = new Map();

	let table = null;
	let entry = null;
	for (const line of lines) {
		const sec = line.match(/^\[sections\.([A-Za-z0-9_.]+)\]\s*$/);
		if (sec) {
			table = { kind: 'section', name: sec[1] };
			entry = null;
			continue;
		}
		const arr = line.match(/^\[\[features\.([A-Za-z0-9_.]+)\]\]\s*$/);
		if (arr) {
			table = { kind: 'features', name: arr[1] };
			entry = { id: null, platforms: null };
			if (!keys.has(arr[1])) keys.set(arr[1], []);
			keys.get(arr[1]).push(entry);
			continue;
		}
		if (/^\[/.test(line)) {
			table = null;
			entry = null;
			continue;
		}
		if (!table) continue;
		const p = line.match(/^platforms\s*=\s*\[(.*)\]/);
		const plats = p ? p[1].replace(/["'\s]/g, '').split(',').filter(Boolean) : null;
		if (table.kind === 'section' && plats && !sectionPlatforms.has(table.name)) {
			sectionPlatforms.set(table.name, new Set(plats));
		}
		if (table.kind === 'features' && entry) {
			const id = line.match(/^id\s*=\s*"([^"]+)"/);
			if (id) entry.id = id[1];
			if (plats) entry.platforms = new Set(plats);
		}
	}

	// Effective platform set per "section.key".
	const declared = new Map(); // platform -> Set of "section.key" and "section"
	for (const [platform] of Object.entries(PLATFORM_OF_DRIVER).map(([, v]) => [v])) {
		declared.set(platform, new Set());
	}
	for (const [section, plats] of sectionPlatforms) {
		for (const p of plats) declared.get(p)?.add(section);
	}
	for (const [section, entries] of keys) {
		for (const e of entries) {
			if (!e.id) continue;
			const eff = e.platforms || sectionPlatforms.get(section) || new Set();
			for (const p of eff) declared.get(p)?.add(`${section}.${e.id}`);
		}
	}
	return declared;
}

/**
 * Every "section.key" (or bare section) a driver's own source reads or writes.
 * @param {string} driver - Driver directory name.
 * @returns {Set<string>} Config surfaces, as written in the source.
 */
function surfaceOf(driver) {
	const out = new Set();
	const root = path.join(DRIVERS_DIR, driver);
	(function walk(dir) {
		if (!fs.existsSync(dir)) return;
		for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
			const p = path.join(dir, e.name);
			if (e.isDirectory()) {
				if (e.name === 'tests' || e.name === '_generated' || e.name === 'vendor') continue;
				walk(p);
				continue;
			}
			if (!/\.(lua|ahk)$/.test(e.name)) continue;
			const src = fs.readFileSync(p, 'utf8');
			// batch_write rows: { section = "x", key = "y" }
			for (const m of src.matchAll(/section\s*=\s*"([A-Za-z0-9_.]+)"\s*,\s*key\s*=\s*"([A-Za-z0-9_.]+)"/g)) {
				out.add(`${m[1]}.${m[2]}`);
			}
			// A row whose key is a runtime value still names its section.
			for (const m of src.matchAll(/section\s*=\s*"([A-Za-z0-9_.]+)"\s*,\s*key\s*=\s*[A-Za-z_]/g)) {
				out.add(m[1]);
			}
			// storage.get("section.key") / default_for("section.key")
			for (const m of src.matchAll(/(?:storage\.(?:get|set)|default_for|find_entry_by_path)\(\s*"([A-Za-z0-9_]+\.[A-Za-z0-9_.]+)"/g)) {
				out.add(m[1]);
			}
			// Windows boot-owned scalar reads. These bypass the manifest-backed
			// Features tree, so omitting them made a real config surface invisible
			// to this ratchet.
			for (const m of src.matchAll(/_FeatureStateIniGet\(\s*[^,]+,\s*"([A-Za-z0-9_.]+)"\s*,\s*"([A-Za-z0-9_.]+)"/g)) {
				out.add(`${m[1]}.${m[2]}`);
			}
			// The [linux.*] silo is read as a TABLE, not key by key, so no pattern
			// above reaches it — and a silo nobody can see is how it survived the
			// migration that dissolved [ahk.*] and [hs.*].
			for (const m of src.matchAll(/\blinux\.(gestures|action_parameters)\b/g)) {
				out.add(`linux.${m[1]}`);
			}
		}
	})(root);
	return out;
}

const declared = parseManifest();
const DRIVERS = Object.keys(PLATFORM_OF_DRIVER).filter((d) =>
	fs.existsSync(path.join(DRIVERS_DIR, d, 'adapters'))
);

const undeclared = [];
for (const driver of DRIVERS) {
	const platform = PLATFORM_OF_DRIVER[driver];
	const known = declared.get(platform) || new Set();
	for (const surface of [...surfaceOf(driver)].sort()) {
		if (known.has(surface)) continue;
		// A key is covered when its own section is declared AND the key is too;
		// a bare section is covered by the section alone.
		undeclared.push({ driver, platform, surface });
	}
}

if (process.argv.includes('--measure')) {
	console.log(`drivers: ${DRIVERS.join(', ')}`);
	console.log(`\nundeclared config surfaces: ${undeclared.length}`);
	for (const u of undeclared) console.log(`  ${u.driver.padEnd(8)} ${u.surface}`);
	process.exit(0);
}

if (undeclared.length > BASELINE) {
	console.error(
		`\x1b[31m[ERROR] Undeclared driver config surfaces rose to ${undeclared.length} (baseline ${BASELINE}).\x1b[0m`
	);
	for (const u of undeclared) console.error(`  ${u.driver.padEnd(8)} ${u.surface}`);
	console.error(
		'\n  A config key the driver persists but the manifest has never heard of has no\n' +
			'  default, no type, no schema entry and no menu row — it is invisible to every\n' +
			'  gate in this repo. Declare it in manifest.toml with the right platforms, or\n' +
			'  point the driver at the canonical key that already means the same thing.\n' +
			'  Do NOT raise the baseline.'
	);
	console.error('  Run `node tools/test/test-driver-config-surface-is-declared.cjs --measure` to list them.');
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] Driver config surfaces declared in the manifest (${undeclared.length}/${BASELINE} undeclared).\x1b[0m`
);
