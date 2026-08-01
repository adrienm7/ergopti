// tools/test/test-menu-manifest-keys-have-readers.cjs

/**
 * ==============================================================================
 * MODULE: Manifest Reader Guard
 * DESCRIPTION:
 * Every field and every top-level section of `menu_manifest.json` must be read
 * by at least one driver. A key nobody reads is a configuration that lies.
 *
 * ROOT CAUSE ENCODED — THREE DECLARATIONS, THREE CODE COPIES:
 * The manifest is meant to describe what the user sees. Three keys described it
 * to nobody, while a copy of the same data drove the render from AutoHotkey
 * source:
 *
 *   * `i18n_dynamic`, on the two metrics rows whose label is computed at
 *     runtime, named the locale key for the prefix. It had **zero** readers
 *     anywhere in the repo; both handlers carried their own literal
 *     `t("menu.metrics.shortcut_prefix")`.
 *   * `accented_letters_group` listed four letter_picker ids while the builder
 *     looped over a hardcoded array of the same four paths.
 *   * `modifier_combos_group` listed three feature-section paths while the same
 *     builder read them from a `_SHORTCUTS_SUBMAP_V1V2` Map.
 *
 * None of it looked broken, because the copies were in sync. The failure is the
 * NEXT edit: adding a fourth accented letter to the manifest changes nothing at
 * all, and there is no error to read — the same silence that let a menu ship
 * with 2 locales out of 21.
 *
 * THE TWO KEYS THAT CAME FIRST:
 * `dynamic_hotstrings_order` duplicated _DYNAMIC_HOTSTRINGS_ORDER in
 * windows/ui/tray_menu.ahk — and DISAGREED with it, spelling the separator
 * "---" where the live one spells it "-". Whichever a reader trusted, one of
 * them was lying. `word_delimiter_defs` carried 20 entries no driver asked for.
 * Both are gone; this guard is what keeps the next pair from accumulating.
 *
 * WHY A COMMENT IS NOT A READER:
 * `manifest_menu.ahk` mentioned both dead sections by name in a comment
 * ("Built-in group: modifier_combos_group, accented_letters_group."). A scan
 * that counted any occurrence would have called them read and found nothing.
 * Comment-only lines are skipped here for exactly that reason.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS = path.join(ROOT, 'static', 'ergopti_plus');
const MANIFEST = path.join(DRIVERS, '_shared', 'modules', 'menu', 'menu_manifest.json');

// Floors — a scan that finds nothing must not pass for free.
const MIN_SOURCES = 400; // 533 non-test driver sources today (tests are excluded below).
const MIN_FIELDS = 10; // 19 today.
const MIN_SECTIONS = 10; // 15 today.

const errors = [];




// =======================================
// =======================================
// ======= 1/ Reading the manifest =======
// =======================================
// =======================================

let manifest;
try {
	manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
} catch (e) {
	console.error(`\x1b[31m[ERROR] cannot read menu_manifest.json: ${e.message}\x1b[0m`);
	process.exit(1);
}

// `_comment*` keys are prose addressed to humans and declare no behaviour.
const sections = Object.keys(manifest).filter((k) => !k.startsWith('_'));

// Field names carried by entries, at any depth below the top level.
const fields = new Set();
(function collect(node, depth) {
	if (Array.isArray(node)) {
		for (const v of node) collect(v, depth + 1);
	} else if (node && typeof node === 'object') {
		for (const [k, v] of Object.entries(node)) {
			if (depth > 0) fields.add(k);
			collect(v, depth + 1);
		}
	}
})(manifest, 0);

for (const s of sections) fields.delete(s);
for (const f of [...fields]) {
	if (f.startsWith('_') || /^\d+$/.test(f)) fields.delete(f);
}

// `type` values name a renderer branch rather than a field; they are covered by
// the renderer's own dispatch and would otherwise be reported as unread fields.
const typeValues = new Set();
(function collectTypes(node) {
	if (Array.isArray(node)) {
		for (const v of node) collectTypes(v);
	} else if (node && typeof node === 'object') {
		if (typeof node.type === 'string') typeValues.add(node.type);
		for (const v of Object.values(node)) collectTypes(v);
	}
})(manifest);
for (const t of typeValues) fields.delete(t);

if (sections.length < MIN_SECTIONS) {
	errors.push(`parsed only ${sections.length} manifest section(s) — the parse is broken`);
}
if (fields.size < MIN_FIELDS) {
	errors.push(`parsed only ${fields.size} manifest field(s) — the parse is broken`);
}




// =======================================
// =======================================
// ======= 2/ Scanning the drivers =======
// =======================================
// =======================================

const sources = [];
(function collectSources(dir) {
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) {
			if (e.name !== 'vendor' && e.name !== 'node_modules') collectSources(p);
		} else if (/\.(lua|ahk|js)$/.test(e.name)) {
			const rel = path.relative(DRIVERS, p).split(path.sep).join('/');
			// The shared tree holds the manifest itself and its schema docs; only a
			// DRIVER reading a key makes that key load-bearing.
			if (rel.startsWith('_shared/')) continue;
			// Nor do tests count. A test naming a section proves the section exists,
			// not that anything renders from it — and this guard's own regression
			// test names both group sections, so counting tests made it pass with
			// the composition it exists to protect deleted. Found by probing it.
			if (/(^|\/)tests?\//.test(rel)) continue;
			sources.push({ rel, src: fs.readFileSync(p, 'utf8') });
		}
	}
})(DRIVERS);

if (sources.length < MIN_SOURCES) {
	errors.push(
		`scanned only ${sources.length} driver source(s) (floor ${MIN_SOURCES}) — the walk is broken, ` +
			'and every key below would then look unread'
	);
}

/** Files that reference a token outside a comment. */
function readersOf(token) {
	const escaped = token.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
	const patterns = [
		new RegExp(`\\.${escaped}\\b`), // entry.platforms
		new RegExp(`\\["${escaped}"\\]`), // entry["platforms"]
		new RegExp(`\\['${escaped}'\\]`),
		new RegExp(`"${escaped}"`), // Has(entry, "platforms")
		new RegExp(`'${escaped}'`)
	];
	const hits = [];
	for (const { rel, src } of sources) {
		for (const line of src.split('\n')) {
			const t = line.trimStart();
			// A comment naming a key is prose, not a reader. Both dead sections were
			// named in one, which is how a naive scan would have missed them.
			if (t.startsWith('--') || t.startsWith(';') || t.startsWith('//')) continue;
			if (patterns.some((p) => p.test(line))) {
				hits.push(rel);
				break;
			}
		}
	}
	return hits;
}

// A section may also be reached by composition: the renderer resolves a group's
// rows as `<id>_group`, so the literal name never appears. That is a real
// reader, and the convention is asserted rather than assumed — if nothing
// composes the suffix, no section is reachable that way.
const COMPOSES_GROUP_SUFFIX = /["'`]_group["'`]/;
const composers = sources.filter(({ src }) =>
	src.split('\n').some((line) => {
		const t = line.trimStart();
		if (t.startsWith('--') || t.startsWith(';') || t.startsWith('//')) return false;
		return COMPOSES_GROUP_SUFFIX.test(line);
	})
);

const groupIds = new Set();
(function collectGroupIds(node) {
	if (Array.isArray(node)) {
		for (const v of node) collectGroupIds(v);
	} else if (node && typeof node === 'object') {
		if (node.type === 'group' && typeof node.id === 'string') groupIds.add(node.id);
		for (const v of Object.values(node)) collectGroupIds(v);
	}
})(manifest);




// ======================================
// ======================================
// ======= 3/ Fields and sections =======
// ======================================
// ======================================

for (const field of [...fields].sort()) {
	if (readersOf(field).length > 0) continue;
	errors.push(
		`manifest field "${field}" is declared but no driver reads it. Either a driver holds its own ` +
			'copy of the value — in which case editing the manifest moves nothing and there is no error ' +
			'to read — or the field is dead and belongs deleted (§5.6).'
	);
}

for (const section of [...sections].sort()) {
	if (readersOf(section).length > 0) continue;

	// The `<id>_group` convention: reachable when a group entry declares the id
	// AND something actually composes the suffix.
	const base = section.endsWith('_group') ? section.slice(0, -'_group'.length) : null;
	if (base && groupIds.has(base) && composers.length > 0) continue;

	if (base && groupIds.has(base) && composers.length === 0) {
		errors.push(
			`manifest section "${section}" would be reached as "<id>_group", but nothing in the drivers ` +
				'composes that suffix any more — the convention is gone and the section is unreachable'
		);
		continue;
	}

	errors.push(
		`manifest section "${section}" is declared but no driver reads it, and no group entry claims it ` +
			`by id ("${base || section}"). The rows are then decorative: the render comes from somewhere ` +
			'else, and adding a row here changes nothing.'
	);
}




// ==========================
// ==========================
// ======= 4/ Verdict =======
// ==========================
// ==========================

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] menu manifest keys with no reader:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] all ${fields.size} manifest field(s) and ${sections.length} section(s) are read by a ` +
		`driver (${sources.length} source(s) scanned).\x1b[0m`
);
