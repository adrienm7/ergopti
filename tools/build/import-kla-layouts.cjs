// tools/build/import-kla-layouts.cjs

/**
 * ==============================================================================
 * MODULE: KLA Layout Import
 * DESCRIPTION:
 * Re-encodes the built-in layouts of Keyboard Layout Analyzer (the `layouts/`
 * folder of patorjk/keyboard-layout-analyzer, MIT, at the pinned commit) into
 * the layout library of the layout analysis
 * (_shared/layouts/data/analysis/layout_library.json) and their credits into
 * layout_credits.json. Run it again after a change of the rules below; the
 * layout analysis codegen then rebuilds the generated library.
 * USAGE: node tools/build/import-kla-layouts.cjs <checkout of the KLA repository>,
 *   then `node tools/lint/format.cjs` on the two JSON files and
 *   `npm run codegen:layout-analysis-data:js`. It finds duplicates in the
 *   generated library, so run the codegen first after editing the library.
 *
 * FEATURES & RATIONALE:
 * 1. One reader: each file goes through the Studio's own KLA reader
 *    (layout_formats.js fromKla), so the library holds what a user importing
 *    the same file gets. Only the arrangement is kept (what each key types on
 *    its four levels), never the file (the re-encoding rule of
 *    docs/memory/maintainer-decisions.md, « Layout library »).
 * 2. Whole layouts: a KLA file states every key and level, so its entry keeps
 *    them (`rows`) instead of an alphabetic block the codegen completes.
 * 3. No silent loss: a file with characters on keys the library's keyboard
 *    model has no code for (a modifier key of the standard board but Tab,
 *    Caps Lock, Enter and the right Control; every ErgoDox key has one, its
 *    board-only keys included), or that places a letter twice, is not
 *    imported; a thumb key
 *    drawing only KLA's action signs (⌦ ⇞) types nothing and loses nothing.
 *    Every file left out is listed in `not_imported` with its reason.
 * 4. One entry per arrangement: a file with the same letters on the same keys
 *    and the same digits as a layout already in the library is a duplicate;
 *    it gives that layout a credit only when the layout has none.
 * 5. Credits as stated: KLA's « author » field names the designer or the
 *    person who submitted the layout, so these credits have the basis
 *    « collection » until checked against the author's own page.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { shared } = require('../lib/paths.cjs');
const identifiers = require('../lib/identifiers.cjs');

const LIBRARY_PATH = shared('layouts', 'data', 'analysis', 'layout_library.json');
const CREDITS_PATH = shared('layouts', 'data', 'analysis', 'layout_credits.json');
const UI_DIR = shared('ui');
const SOURCE_ID = 'kla';
const SOURCE = {
	name: 'Keyboard Layout Analyzer',
	url: `https://${identifiers.hosts.github}/patorjk/keyboard-layout-analyzer/tree/c4f2f9bb43ca8de98c8cb0cd28a78043602c7dcb/layouts`,
	commit: 'c4f2f9bb43',
	licence:
		'MIT (repository, « Copyright (C) 2015-present Patrick Gillespie and other contributors »); arrangements re-encoded'
};
const CREDIT_BASIS = 'collection';
// The origin the codegen gives an imported layout (registry and reference
// layouts take their credits from this repository).
const LIBRARY_ORIGIN = 'library';
const LEVELS = 4;
const DIGITS = [
	'Digit1',
	'Digit2',
	'Digit3',
	'Digit4',
	'Digit5',
	'Digit6',
	'Digit7',
	'Digit8',
	'Digit9',
	'Digit0'
];
// KLA's own author: he added classics to the collection, he did not design them.
const COLLECTION_AUTHOR = /^Patrick ?Gillespie$/;
const LETTER = /^\p{L}$/u;

// The language of each file whose layout is not made for English.
const LANGUAGES = {
	'european.azerty': 'fr',
	'european.bepo': 'fr',
	'european.bvofrak1': 'fr',
	'european.colemak-estonian': 'et',
	'european.colemak_hu': 'hu',
	'european.germandvorak2': 'de',
	'european.qwerty-danish': 'da',
	'european.qwerty-estonian': 'et',
	'european.qwerty-spanish': 'es',
	'standard.adnw': 'de',
	'standard.azerty': 'fr',
	'standard.bvofrak1': 'fr',
	'standard.neo2': 'de',
	'standard.neo2_new': 'de',
	'standard.qwerty-danish': 'da',
	'standard.spanish-dvorak': 'es',
	'ergodox.buteck': 'de',
	'ergodox.kinesis-asr': 'sv',
	'ergodox.neo2_inprogress': 'de',
	'ergodox.neo2_inprogress2': 'de',
	'ergodox.taserfr': 'fr'
};
// Display names where KLA's label is not one: the board in the name, a label
// in lower case like an identifier, a key the analysis does not measure, the
// author's name as the label.
const NAMES = {
	'european.bvofrak1': 'BvoFRak 1.0 FR',
	'standard.dangvu': 'Dangvu',
	'standard.siwei': 'Siwei',
	// The caps-lock key KLA turns into Backspace is not measured.
	'standard.dvorakmod': 'Dvorak IU Swap',
	'standard.spanish-dvorak': 'Spanish Dvorak (Jorge Sanz)',
	'ergodox.buteck': 'BuTeck',
	'ergodox.colemakcub': 'Colemak Cub',
	'ergodox.gelatin': 'Gelatin',
	'ergodox.jeff': 'Jeff',
	'ergodox.kinesis-asr': 'Svorak-r',
	'ergodox.modified-upd': 'Modified UPD',
	'ergodox.neo2_inprogress': 'Neo 2 in progress (Samuel Suther)',
	'ergodox.neo2_inprogress2': 'Neo 2 in progress (Wolf Belschner)',
	'ergodox.qgmlwbcub': 'QGMLWB Cub',
	'ergodox.qgmlwycub': 'QGMLWY Cub',
	'ergodox.workman': 'Workman Cub'
};
// Authors where the file names KLA's own author, who added the layout.
const AUTHORS = {
	'standard.spanish-dvorak': ['Jorge Sanz']
};
// Ids where the file name alone would collide (KLA names a second Tarmak 3
// and 4 « tarmak3_ » and « tarmak4_ »).
const IDS = {
	'standard.tarmak3': 'tarmak3_etr',
	'standard.tarmak3_': 'tarmak3',
	'standard.tarmak4': 'tarmak4_etro',
	'standard.tarmak4_': 'tarmak4'
};
// Files left out by judgement, with the reason (the rules find the others).
const LEFT_OUT = {
	'standard.neo2':
		'an earlier entry of Neo 2 without its umlauts; standard.neo2_new holds the layout',
	'standard.hackers-dvorak-on': 'the same keys as standard.programmer-dvorak-on, by the same author'
};
// Between two KLA files of one arrangement, the European (ISO) board's file is
// kept: it also places the key between left Shift and Z.
const BOARD_RANK = { european: 0, standard: 1, ergodox: 2 };

// ==========================
// ======= 1/ Reading =======
// ==========================

/**
 * The Studio's layout readers, loaded as the classic scripts a page loads.
 * @returns {{F: object, DATA: object, E: object}} LAYOUT_FORMATS,
 *   LAYOUT_ANALYSIS_DATA and LAYOUT_ANALYSIS.
 */
function loadReaders() {
	const sandbox = { TextDecoder };
	vm.createContext(sandbox);
	for (const file of [
		'layout_analysis/_generated/analysis_data.js',
		'layout_analysis/analysis_engine.js',
		'layout_analysis/layout_formats.js'
	])
		vm.runInContext(fs.readFileSync(path.join(UI_DIR, file), 'utf8'), sandbox, { filename: file });
	return {
		F: vm.runInContext('LAYOUT_FORMATS', sandbox),
		DATA: vm.runInContext('LAYOUT_ANALYSIS_DATA', sandbox),
		E: vm.runInContext('LAYOUT_ANALYSIS', sandbox)
	};
}

/**
 * An http(s) link of a KLA file, or none.
 * @param {object} json - The parsed file.
 * @returns {string|undefined} The author's page, else the « more info » page.
 */
function linkOf(json) {
	for (const url of [json.authorUrl, json.moreInfoUrl])
		if (typeof url === 'string' && /^https?:\/\//.test(url)) return url;
	return undefined;
}

/**
 * What identifies an arrangement: the letters on every key and the digits.
 * @param {object} rows - code → four cells.
 * @param {string[]} codes - The measured codes.
 * @returns {string} The signature.
 */
function signature(rows, codes) {
	const letters = codes.map((code) => {
		const base = rows[code] ? rows[code][0] : null;
		return typeof base === 'string' && LETTER.test(base) ? base : '·';
	});
	const digits = DIGITS.map((code) => (rows[code] ? rows[code][0] || '·' : '·'));
	return `${letters.join('')}|${digits.join('')}`;
}

/**
 * The letters a layout places on more than one key's base level.
 * @param {object} rows - code → four cells.
 * @returns {string[]} Those letters.
 */
function repeatedLetters(rows) {
	const seen = new Set();
	const repeated = new Set();
	for (const row of Object.values(rows)) {
		const base = row[0];
		if (typeof base !== 'string' || !LETTER.test(base)) continue;
		if (seen.has(base)) repeated.add(base);
		seen.add(base);
	}
	return Array.from(repeated).sort();
}

/**
 * The library id of a KLA file, unique in the library.
 * @param {string} file - The file name (board.name).
 * @param {Set<string>} taken - The ids already used.
 * @returns {string} The id.
 */
function idOf(file, taken) {
	if (IDS[file]) {
		if (taken.has(IDS[file])) throw new Error(`${file}: the id ${IDS[file]} is taken`);
		return IDS[file];
	}
	const base = file
		.slice(file.indexOf('.') + 1)
		.toLowerCase()
		.replace(/[^a-z0-9]+/g, '_')
		.replace(/^_+|_+$/g, '');
	const id = /^[a-z]/.test(base) ? base : `kla_${base}`;
	return taken.has(id) ? `${id}_kla` : id;
}

// ==========================
// ======= 2/ Import ========
// ==========================

/**
 * Classifies every KLA file: imported, a duplicate, or left out.
 * @param {string} klaDir - The KLA checkout.
 * @returns {{imported: object[], notImported: object[], credits: object}} The result.
 */
function classify(klaDir) {
	const { F, DATA, E } = loadReaders();
	const library = JSON.parse(fs.readFileSync(LIBRARY_PATH, 'utf8'));
	// Every key a layout types on, the ErgoDox's board-only keys included.
	const codes = E.typingCodes();
	// The layouts already in the library, from the generated data (alphabetic
	// blocks completed), less any earlier KLA import.
	const known = new Map();
	const origins = new Map(DATA.layouts.map((layout) => [layout.id, layout.origin]));
	for (const layout of DATA.layouts)
		if (layout.source !== SOURCE_ID) known.set(signature(layout.rows, codes), layout.id);
	const taken = new Set(DATA.layouts.filter((l) => l.source !== SOURCE_ID).map((l) => l.id));
	const names = new Set(DATA.layouts.filter((l) => l.source !== SOURCE_ID).map((l) => l.name));
	const files = fs.readdirSync(path.join(klaDir, 'layouts')).sort((a, b) => {
		const rank = BOARD_RANK[a.split('.')[0]] - BOARD_RANK[b.split('.')[0]];
		return rank !== 0 ? rank : a < b ? -1 : 1;
	});
	const imported = [];
	const notImported = [];
	const credits = {};
	for (const file of files) {
		const json = JSON.parse(fs.readFileSync(path.join(klaDir, 'layouts', file), 'utf8'));
		const sourcePath = `layouts/${file}`;
		const leave = (reason, sameAs) =>
			notImported.push({
				source: SOURCE_ID,
				source_path: sourcePath,
				reason,
				...(sameAs ? { same_as: sameAs } : {})
			});
		if (LEFT_OUT[file]) {
			leave(LEFT_OUT[file]);
			continue;
		}
		const { layout, unmapped } = F.fromKla(json);
		const twice = repeatedLetters(layout.rows);
		if (twice.length > 0) {
			leave(`places ${twice.join(' ')} on two keys`);
			continue;
		}
		const sig = signature(layout.rows, codes);
		if (known.has(sig)) {
			const sameAs = known.get(sig);
			leave('the same letters and digits as a library layout', sameAs);
			// A registry or reference layout is credited from this repository.
			const author = (AUTHORS[file] || [json.author])[0];
			if (
				author &&
				!COLLECTION_AUTHOR.test(author) &&
				!credits[sameAs] &&
				origins.get(sameAs) === LIBRARY_ORIGIN
			)
				credits[sameAs] = { authors: [author.trim()], url: linkOf(json) };
			continue;
		}
		// What the board has no code for: a character on a modifier key; an
		// ErgoDox thumb key's action signs type nothing.
		const lost = unmapped
			.filter((entry) => entry.what === 'key')
			.flatMap((entry) => entry.detail.replace(/^\d+ \(|\)$/g, '').split(' '))
			.filter((cell) => cell.trim() !== '' && !F.KLA_ACTION_SIGN.test(cell));
		if (lost.length > 0) {
			leave(`characters on keys the library's keyboards have no code for: ${lost.join(' ')}`);
			continue;
		}
		const id = idOf(file, taken);
		taken.add(id);
		let name = NAMES[file] || json.label.trim();
		if (names.has(name)) name = `${name} (KLA)`;
		names.add(name);
		const rows = {};
		for (const code of codes)
			if (layout.rows[code]) rows[code] = layout.rows[code].slice(0, LEVELS);
		imported.push({
			id,
			name,
			language: LANGUAGES[file] || 'en',
			source: SOURCE_ID,
			source_path: sourcePath,
			fingering: 'standard',
			rows
		});
		// A later file of the same arrangement is its duplicate.
		known.set(sig, id);
		const authors = AUTHORS[file] || (json.author ? [json.author.trim()] : []);
		if (authors.length > 0 && !authors.some((author) => COLLECTION_AUTHOR.test(author)))
			credits[id] = { authors, url: linkOf(json) };
	}
	return { imported, notImported, credits, library };
}

/**
 * A list's KLA entries replaced by this import's: each kept entry at its
 * earlier place, a new one appended, one no longer produced removed, so a run
 * that changes a few files changes only their entries.
 * @param {object[]} list - The library's entries (layouts or not_imported).
 * @param {object[]} fresh - This import's entries for that list.
 * @param {function(object): string} keyOf - The identity of an entry.
 * @returns {object[]} The new list.
 */
function inPlace(list, fresh, keyOf) {
	const byKey = new Map(fresh.map((entry) => [keyOf(entry), entry]));
	const out = [];
	for (const entry of list) {
		if (entry.source !== SOURCE_ID) out.push(entry);
		else if (byKey.has(keyOf(entry))) {
			out.push(byKey.get(keyOf(entry)));
			byKey.delete(keyOf(entry));
		}
	}
	return out.concat(Array.from(byKey.values()));
}

/**
 * Writes the library and the credits.
 * @param {string} klaDir - The KLA checkout.
 */
function main(klaDir) {
	if (!klaDir || !fs.existsSync(path.join(klaDir, 'layouts')))
		throw new Error(
			'usage: node tools/build/import-kla-layouts.cjs <checkout of patorjk/keyboard-layout-analyzer>'
		);
	const { imported, notImported, credits, library } = classify(klaDir);
	const earlier = new Set(
		library.layouts.filter((entry) => entry.source === SOURCE_ID).map((entry) => entry.id)
	);
	library.sources[SOURCE_ID] = SOURCE;
	library.layouts = inPlace(library.layouts, imported, (entry) => entry.id);
	library.not_imported = inPlace(
		library.not_imported || [],
		notImported,
		(entry) => entry.source_path
	);
	fs.writeFileSync(LIBRARY_PATH, `${JSON.stringify(library, null, '\t')}\n`);
	const creditFile = JSON.parse(fs.readFileSync(CREDITS_PATH, 'utf8'));
	// An earlier KLA import's credits are replaced and a checked credit kept;
	// the other collections' credits, of the same basis, are not this file's.
	for (const [id, entry] of Object.entries(creditFile.credits))
		if (entry.basis === CREDIT_BASIS && (earlier.has(id) || credits[id]))
			delete creditFile.credits[id];
	for (const [id, credit] of Object.entries(credits)) {
		if (creditFile.credits[id]) continue;
		creditFile.credits[id] = {
			authors: credit.authors,
			...(credit.url ? { url: credit.url } : {}),
			basis: CREDIT_BASIS
		};
	}
	fs.writeFileSync(CREDITS_PATH, `${JSON.stringify(creditFile, null, '\t')}\n`);
	console.log(
		`import-kla-layouts — ${imported.length} imported, ${notImported.length} not imported ` +
			`(${notImported.filter((entry) => entry.same_as).length} duplicates)`
	);
	for (const entry of notImported)
		console.log(
			`  ${entry.source_path}: ${entry.reason}${entry.same_as ? ` (${entry.same_as})` : ''}`
		);
}

if (require.main === module) main(process.argv[2]);

module.exports = { classify, signature, loadReaders };
