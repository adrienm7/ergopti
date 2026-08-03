// tools/test/test-reason-keys-are-readable.cjs

/**
 * ==============================================================================
 * MODULE: Platform-Restriction Reasons Reach a Reader (I2)
 * DESCRIPTION:
 * `reason_key` explains why a feature is unavailable on a platform. Until
 * 2026-08-03 it was a field with no possible reader, and the reason is worth
 * stating precisely because it is not the obvious one.
 *
 * It was not that nobody had written the display yet. It was that the data never
 * reached the driver: `build-features-manifest.js` filters the feature list per
 * platform, so a feature restricted to Windows does not appear in
 * `features_manifest.lua` AT ALL. macOS could not enumerate its own absences,
 * let alone explain one. Writing the 142 reasons into that would have produced
 * ~3 000 translated strings in 19 languages that no code path could ever show —
 * which is exactly the objection test-platform-restrictions-explained.cjs raises
 * against filling them, and it was right.
 *
 * WHAT THIS HOLDS, so the field cannot go back to being decorative:
 * 1. Every generated manifest ships an `unavailable` table, and it is non-empty.
 *    That table is the ONLY way a driver learns a feature exists elsewhere.
 * 2. Every `reason_key` in the source manifest resolves in all 21 catalogues.
 *    A reason that does not translate renders its own dotted key to the user,
 *    which is worse than the silence it was meant to replace.
 * 3. At least one reason exists. A chain with nothing flowing through it is
 *    indistinguishable from a broken one.
 * 4. Something actually reads the table. A generator emitting a section no code
 *    consumes is the precedent this field already set once — `description_key`
 *    is emitted into both manifests and, by its own generated header, read by no
 *    macOS module.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const SOURCE = path.join(SP, '_shared', 'modules', 'features', 'manifest.toml');
const LOCALES = path.join(SP, '_shared', 'data', 'locales');

// The generated manifests, and the shape each one spells the table in.
const GENERATED = [
	{ label: 'macOS', file: path.join(SP, 'macos', '_generated', 'features_manifest.lua'), re: /M\.unavailable = \{([\s\S]*?)\n\}/, entry: /path = /g },
	{ label: 'Linux', file: path.join(SP, 'linux', '_generated', 'features_manifest.lua'), re: /M\.unavailable = \{([\s\S]*?)\n\}/, entry: /path = /g },
	{ label: 'Windows', file: path.join(SP, 'windows', '_generated', 'features_manifest.ahk'), re: /"unavailable", \[([\s\S]*?)\n {4}\]/, entry: /"path"/g }
];

// Floor per driver. Each is missing ~100 features today; a table that collapsed
// to a handful would pass every assertion below while shipping almost nothing.
const MIN_UNAVAILABLE = 40;

// The files that must consume the table. A generator emitting a section nobody
// reads is how `description_key` came to be dead weight in both manifests.
const READERS = [
	{ file: path.join(SP, 'macos', 'infra', 'manifest_reader.lua'), token: 'unavailable' },
	{ file: path.join(SP, 'macos', 'ui', 'healthcheck', 'helpers.lua'), token: 'coverage_gaps' },
	{ file: path.join(SP, 'macos', 'ui', 'healthcheck', 'core.lua'), token: 'platform_coverage' }
];

const errors = [];




// ==================================================
// ======= 1/ The absences are shipped ==============
// ==================================================

for (const g of GENERATED) {
	if (!fs.existsSync(g.file)) {
		errors.push(`${g.label}: ${path.relative(ROOT, g.file)} is missing`);
		continue;
	}
	const src = fs.readFileSync(g.file, 'utf8');
	const block = src.match(g.re);
	if (!block) {
		errors.push(
			`${g.label}: the generated manifest carries no "unavailable" table. Its feature list is ` +
				'filtered to that platform, so without this table the driver cannot know a feature ' +
				'exists elsewhere — and every reason_key becomes unreadable by construction.'
		);
		continue;
	}
	const count = (block[1].match(g.entry) || []).length;
	if (count < MIN_UNAVAILABLE) {
		errors.push(
			`${g.label}: only ${count} absence(s) shipped (floor ${MIN_UNAVAILABLE}) — the table is ` +
				'present but nearly empty, which reports the platform as feature-complete'
		);
	}
}




// ==================================================
// ======= 2/ Every reason translates ===============
// ==================================================

const source = fs.readFileSync(SOURCE, 'utf8');
const reasonKeys = [...source.matchAll(/^reason_key\s*=\s*"([^"]+)"/gm)].map((m) => m[1]);

if (reasonKeys.length === 0) {
	errors.push(
		'no feature declares a reason_key. The chain from the generator through manifest_reader to ' +
			'the healthcheck exists but carries nothing, which is indistinguishable from a broken one. ' +
			'Write one, on a restriction whose reason is a platform truth rather than a missing feature.'
	);
}

const localeFiles = fs.readdirSync(LOCALES).filter((f) => f.endsWith('.json'));
if (localeFiles.length < 21) {
	errors.push(`found ${localeFiles.length} locale catalogue(s), expected the full set of 21`);
}

for (const key of reasonKeys) {
	const missing = [];
	for (const file of localeFiles) {
		const json = JSON.parse(fs.readFileSync(path.join(LOCALES, file), 'utf8'));
		const value = json[key];
		if (typeof value !== 'string' || value.trim() === '') missing.push(file.slice(0, -5));
	}
	if (missing.length > 0) {
		errors.push(
			`reason_key "${key}" does not resolve in ${missing.length} locale(s): ${missing.join(', ')}. ` +
				'The coverage report would show the user the dotted key itself — worse than the silence ' +
				'the reason was written to replace.'
		);
	}
}




// ==================================================
// ======= 3/ Something reads it ====================
// ==================================================

for (const r of READERS) {
	if (!fs.existsSync(r.file)) {
		errors.push(`${path.relative(ROOT, r.file)} is missing — the consumer chain is broken`);
		continue;
	}
	// Comment lines do not count: a mention in prose is exactly how two dead
	// manifest sections were once judged "read".
	const code = fs
		.readFileSync(r.file, 'utf8')
		.split(/\r?\n/)
		.filter((l) => !/^\s*(--|;|\/\/)/.test(l))
		.join('\n');
	if (!code.includes(r.token)) {
		errors.push(
			`${path.relative(ROOT, r.file)} no longer references "${r.token}" outside comments. The ` +
				'chain generator → reader → healthcheck is what makes reason_key readable at all; a ' +
				'broken link turns it back into the decorative field it was.'
		);
	}
}




if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] platform-restriction reasons:\x1b[0m');
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] absences shipped to all ${GENERATED.length} driver(s); ${reasonKeys.length} ` +
		`reason(s) resolve in ${localeFiles.length} locale(s); ${READERS.length} reader(s) consume ` +
		'them.\x1b[0m'
);
