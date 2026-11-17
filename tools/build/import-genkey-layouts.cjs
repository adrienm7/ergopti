// tools/build/import-genkey-layouts.cjs

/**
 * ==============================================================================
 * MODULE: genkey Layout Import
 * DESCRIPTION:
 * Re-encodes the layouts genkey ships (the `layouts/` folder of
 * semilin/genkey, GPL-3.0, at the pinned commit) into the layout library of
 * the layout analysis (_shared/layouts/data/analysis/layout_library.json) as
 * alphabetic blocks, like the Oxeylyzer and cmini ones. Run it again after a
 * change of the rules below; the layout analysis codegen then rebuilds the
 * generated library.
 * USAGE: node tools/build/import-genkey-layouts.cjs <checkout of the genkey repository>,
 *   then `node tools/lint/format.cjs --write` and
 *   `npm run codegen:layout-analysis-data:js`. It finds duplicates in the
 *   generated library, so run the codegen first after editing the library.
 *
 * FEATURES & RATIONALE:
 * 1. One reader: each file goes through the Studio's own genkey reader
 *    (layout_formats.js fromGenkey), so the library holds what a user opening
 *    the same file gets. Only the arrangement is kept (the base character of
 *    each key of the three letter rows), never the file (the re-encoding rule
 *    of docs/memory/maintainer-decisions.md, « Layout library »).
 * 2. Alphabetic blocks: a genkey layout states the three letter rows only, so
 *    its entry is a `keys` block the codegen completes with the US number row
 *    and Shift pairs, and keeps the angle fingering its bottom row states.
 * 3. No silent loss: a file with a key off the three rows' keys, or that
 *    places a letter twice, is not imported; every file left out is listed in
 *    `not_imported` with its reason, genkey's generation template among them.
 * 4. One entry per arrangement: a file with the same letters on the same keys
 *    and the same digits as a layout already in the library is a duplicate,
 *    listed with that layout (`same_as`). genkey's files name no author, so
 *    they add no credit.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { shared } = require('../lib/paths.cjs');
const identifiers = require('../lib/identifiers.cjs');
const { signature, loadReaders } = require('./import-kla-layouts.cjs');

const LIBRARY_PATH = shared('layouts', 'data', 'analysis', 'layout_library.json');
const SOURCE_ID = 'genkey';
const SOURCE = {
	url: `https://${identifiers.hosts.github}/semilin/genkey/tree/f1f41733931c2339d4ed161a5ace5f03412b282e/layouts`,
	commit: 'f1f4173393',
	licence: 'GPL-3.0 (repository); arrangements re-encoded'
};
// genkey reads a file whose name starts with « _ » as its generation template
// (layout.go, LoadLayoutDir), not as a layout.
const TEMPLATE = /^_/;
const LETTER = /^\p{L}$/u;

/**
 * The letters a layout places on more than one key.
 * @param {object} rows - code → four cells.
 * @returns {string[]} Those letters.
 */
function repeatedLetters(rows) {
	const seen = new Set();
	const repeated = new Set();
	for (const row of Object.values(rows)) {
		if (typeof row[0] !== 'string' || !LETTER.test(row[0])) continue;
		if (seen.has(row[0])) repeated.add(row[0]);
		seen.add(row[0]);
	}
	return Array.from(repeated).sort();
}

/**
 * Classifies every genkey file: imported, a duplicate, or left out.
 * @param {string} genkeyDir - The genkey checkout.
 * @returns {{imported: object[], notImported: object[], library: object}} The result.
 */
function classify(genkeyDir) {
	const { F, DATA } = loadReaders();
	const library = JSON.parse(fs.readFileSync(LIBRARY_PATH, 'utf8'));
	const modifiers = new Set(Object.values(DATA.model.modifier_keys));
	const codes = Object.keys(DATA.model.fingerings.standard).filter((code) => !modifiers.has(code));
	const others = DATA.layouts.filter((layout) => layout.source !== SOURCE_ID);
	const known = new Map(others.map((layout) => [signature(layout.rows, codes), layout.id]));
	const taken = new Set(others.map((layout) => layout.id));
	const names = new Set(others.map((layout) => layout.name));
	// The US number row the codegen gives an alphabetic block, from a library one.
	const block = others.find((layout) => layout.id === 'qwerty');
	const imported = [];
	const notImported = [];
	for (const file of fs.readdirSync(path.join(genkeyDir, 'layouts')).sort()) {
		const sourcePath = `layouts/${file}`;
		const leave = (reason, sameAs) =>
			notImported.push({
				source: SOURCE_ID,
				source_path: sourcePath,
				reason,
				...(sameAs ? { same_as: sameAs } : {})
			});
		if (TEMPLATE.test(file)) {
			leave("genkey's generation template, not a layout");
			continue;
		}
		const { layout, unmapped } = F.fromGenkey(
			fs.readFileSync(path.join(genkeyDir, 'layouts', file), 'utf8')
		);
		const lost = unmapped.map((entry) => entry.detail);
		if (lost.length > 0) {
			leave(`keys beyond the three letter rows: ${lost.join(' ')}`);
			continue;
		}
		const twice = repeatedLetters(layout.rows);
		if (twice.length > 0) {
			leave(`places ${twice.join(' ')} on two keys`);
			continue;
		}
		const keys = {};
		for (const [code, row] of Object.entries(layout.rows))
			if (code !== 'Space' && typeof row[0] === 'string') keys[code] = row[0];
		// Compared as the codegen completes it: the US digits on the number row.
		const completed = {};
		for (const code of Object.keys(block.rows))
			if (/^Digit/.test(code)) completed[code] = [block.rows[code][0]];
		for (const [code, char] of Object.entries(keys)) completed[code] = [char];
		const sig = signature(completed, codes);
		if (known.has(sig)) {
			leave('the same letters and digits as a library layout', known.get(sig));
			continue;
		}
		// Another version of a library layout (same file name, other keys) says
		// where it comes from in its id and its name.
		const base = file.toLowerCase().replace(/[^a-z0-9]+/g, '_');
		const id = taken.has(base) ? `${base}_genkey` : base;
		taken.add(id);
		const name = names.has(layout.name) || id !== base ? `${layout.name} (genkey)` : layout.name;
		names.add(name);
		imported.push({
			id,
			name,
			language: 'en',
			source: SOURCE_ID,
			source_path: sourcePath,
			fingering: layout.fingering,
			keys
		});
		known.set(sig, id);
	}
	return { imported, notImported, library };
}

/**
 * Writes the library.
 * @param {string} genkeyDir - The genkey checkout.
 */
function main(genkeyDir) {
	if (!genkeyDir || !fs.existsSync(path.join(genkeyDir, 'layouts')))
		throw new Error(
			'usage: node tools/build/import-genkey-layouts.cjs <checkout of semilin/genkey>'
		);
	const { imported, notImported, library } = classify(genkeyDir);
	library.sources[SOURCE_ID] = SOURCE;
	library.layouts = library.layouts.filter((entry) => entry.source !== SOURCE_ID).concat(imported);
	library.not_imported = (library.not_imported || [])
		.filter((entry) => entry.source !== SOURCE_ID)
		.concat(notImported);
	fs.writeFileSync(LIBRARY_PATH, `${JSON.stringify(library, null, '\t')}\n`);
	console.log(
		`import-genkey-layouts — ${imported.length} imported, ${notImported.length} not imported ` +
			`(${notImported.filter((entry) => entry.same_as).length} duplicates)`
	);
	for (const entry of notImported)
		console.log(
			`  ${entry.source_path}: ${entry.reason}${entry.same_as ? ` (${entry.same_as})` : ''}`
		);
}

if (require.main === module) main(process.argv[2]);

module.exports = { classify };
