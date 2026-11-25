// tools/build/import-keycraft-layouts.cjs

/**
 * ==============================================================================
 * MODULE: keycraft Reference Layout Import
 * DESCRIPTION:
 * Re-encodes the reference layouts keycraft scores a layout against (the
 * `data/layouts` folder of rbscholtus/keycraft, BSD-3-Clause, at the pinned
 * commit) into _shared/layouts/data/analysis/keycraft_reference.json: for
 * each layout, its geometry and the character of each of the 42 keys of
 * keycraft's grid. The keycraft scorer of the Studio
 * (_shared/ui/layout_analysis/analyser_scores.js) takes the median and
 * interquartile range of each metric over them, as `keycraft rank` does.
 * USAGE: node tools/build/import-keycraft-layouts.cjs <checkout of rbscholtus/keycraft>,
 *   then `node tools/lint/format.cjs --write` and
 *   `npm run codegen:layout-analysis-data:js`, which ships the statistics of
 *   every built-in corpus.
 *
 * FEATURES & RATIONALE:
 * 1. keycraft's own selection: every `.klf` file of its folder, without the
 *    names its scorer leaves out of the statistics (scorer.go
 *    isReferenceLayout: a leading « _ », « -flipped », « -best », « -opt »),
 *    in its directory order (file name order).
 * 2. keycraft's own reading (layout.go NewLayoutFromFile): its geometry line
 *    by prefix, four rows of 12, 12, 12 and 6 keys, « ~ » an empty key,
 *    « _ » a space, « ~~ », « __ » and « ## » the characters themselves; a
 *    file it would refuse (a row of another length, a character twice, a key
 *    that is not one ASCII byte) stops the import.
 * 3. Only the arrangement is kept, never the file (the re-encoding rule of
 *    docs/memory/maintainer-decisions.md, « Layout library »); a space is
 *    written as an empty key, since keycraft's corpus reader never counts
 *    white space. The licence notice of the source travels with the data.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { shared } = require('../lib/paths.cjs');
const identifiers = require('../lib/identifiers.cjs');

const OUT_PATH = shared('layouts', 'data', 'analysis', 'keycraft_reference.json');
const COMMIT = 'f8c6419';
const SOURCE = {
	name: 'keycraft',
	author: 'Barend Scholtus (rbscholtus)',
	url: `https://${identifiers.hosts.github}/rbscholtus/keycraft/tree/${COMMIT}/data/layouts`,
	commit: COMMIT,
	licence: 'BSD-3-Clause (LICENSE); arrangements re-encoded'
};
const TYPES = ['rowstag', 'anglemod', 'ortho', 'colstag'];
const ROW_KEYS = [12, 12, 12, 6];
const KEYS = 42;
const EMPTY = ' ';
// keycraft's escapes for the characters its notation uses (layout.go keyMap).
const ESCAPES = { '~': EMPTY, _: EMPTY, '~~': '~', __: '_', '##': '#' };
// Floor: a folder read as empty must not ship an empty reference set.
const MIN_LAYOUTS = 100;

/** Whether keycraft's scorer takes a layout into its statistics (scorer.go). */
function isReference(name) {
	return (
		!name.startsWith('_') &&
		!name.includes('-flipped') &&
		!name.includes('-best') &&
		!name.includes('-opt')
	);
}

/**
 * One `.klf` file as keycraft reads it.
 * @param {string} file - Its path.
 * @returns {{type: string, keys: string, credit: string}} Its geometry, its 42
 *   keys (one code point each, a space for an empty key) and its first comment.
 * @throws {Error} On a file keycraft would refuse.
 */
function readKlf(file) {
	const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
	const comment = lines.find((line) => line.trim().startsWith('#'));
	const content = lines.map((line) => line.trim()).filter((line) => line && !line.startsWith('#'));
	const type = TYPES.find((name) => content[0] && content[0].toLowerCase().startsWith(name));
	if (!type) throw new Error(`${file}: unknown layout type ${JSON.stringify(content[0])}`);
	const keys = [];
	const seen = new Set();
	ROW_KEYS.forEach((expected, r) => {
		const tokens = (content[r + 1] || '').split(/\s+/).filter(Boolean);
		if (tokens.length !== expected)
			throw new Error(`${file}: row ${r + 1} has ${tokens.length} keys, expected ${expected}`);
		for (const token of tokens) {
			const escaped = ESCAPES[token.toLowerCase()];
			// Its reader takes the key's first byte and refuses a longer key, so a
			// key outside ASCII is refused too.
			if (escaped === undefined && Buffer.byteLength(token, 'utf8') !== 1)
				throw new Error(`${file}: key ${JSON.stringify(token)} is not one ASCII character`);
			const char = escaped === undefined ? token : escaped;
			if (char !== EMPTY) {
				if (seen.has(char)) throw new Error(`${file}: ${JSON.stringify(char)} twice`);
				seen.add(char);
			}
			keys.push(char);
		}
	});
	if (keys.length !== KEYS) throw new Error(`${file}: ${keys.length} keys`);
	return { type, keys: keys.join(''), credit: comment ? comment.trim().replace(/^#\s*/, '') : '' };
}

/**
 * The reference set of a keycraft checkout.
 * @param {string} keycraftDir - The checkout.
 * @returns {object} The JSON document.
 */
function build(keycraftDir) {
	const dir = path.join(keycraftDir, 'data', 'layouts');
	const licence = fs.readFileSync(path.join(keycraftDir, 'LICENSE'), 'utf8').trim();
	const files = fs
		.readdirSync(dir)
		.filter((f) => f.toLowerCase().endsWith('.klf'))
		.sort();
	const layouts = [];
	for (const file of files) {
		const name = file.slice(0, -path.extname(file).length);
		if (!isReference(name)) continue;
		layouts.push(Object.assign({ name }, readKlf(path.join(dir, file))));
	}
	if (layouts.length < MIN_LAYOUTS)
		throw new Error(`only ${layouts.length} keycraft layouts read from ${dir}`);
	return {
		_description:
			'Generated by tools/build/import-keycraft-layouts.cjs, do not edit. keycraft’s reference layouts (the layouts its `rank` takes the median and interquartile range of each metric over), re-encoded: per layout its geometry and the character of each of the 42 keys of its grid (three rows of 12 keys, then 6 thumb keys), one code point per key, a space for an empty key.',
		source: Object.assign({}, SOURCE, { licence_notice: licence }),
		layouts
	};
}

/**
 * Writes the reference set.
 * @param {string} keycraftDir - The keycraft checkout.
 */
function main(keycraftDir) {
	if (!keycraftDir || !fs.existsSync(path.join(keycraftDir, 'data', 'layouts')))
		throw new Error(
			'usage: node tools/build/import-keycraft-layouts.cjs <checkout of rbscholtus/keycraft>'
		);
	const document = build(keycraftDir);
	fs.writeFileSync(OUT_PATH, `${JSON.stringify(document, null, '\t')}\n`);
	console.log(`import-keycraft-layouts — ${document.layouts.length} reference layouts`);
}

if (require.main === module) main(process.argv[2]);

module.exports = { build, readKlf, isReference };
