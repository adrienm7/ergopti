// tools/codegen/codegen-key-legend-js.cjs

/**
 * ==============================================================================
 * MODULE: Key Legend Formatter Codegen
 * DESCRIPTION:
 * Generates `_shared/ui/_generated/key_legend.js`, the site's key legend
 * formatter (src/lib/keyboard/keyLegend.js) as a classic script defining
 * `KEY_LEGEND`, so the layout editor and the Comparer, which the app hosts
 * inline as classic scripts, format legends with the site's own code.
 *
 * FEATURES & RATIONALE:
 * 1. Verbatim: the module's text is kept; only its `export` keywords are
 *    dropped, and the exported names are returned from one wrapper.
 * 2. Fail fast: an import, a default export or an export list cannot be
 *    wrapped this way and stops the generation.
 * 3. Deterministic: no timestamp.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { shared, REPO_ROOT } = require('../lib/paths.cjs');

const SOURCE_PATH = path.join(REPO_ROOT, 'src', 'lib', 'keyboard', 'keyLegend.js');
const OUT_PATH = shared('ui', '_generated', 'key_legend.js');
const EXPORT = /^export (const|function) ([A-Za-z_$][\w$]*)/gm;

/**
 * Builds the complete generated file.
 * @returns {string} JS source with LF line ends and a final newline.
 * @throws {Error} When the module has a form the wrapper cannot keep.
 */
function buildSource() {
	const text = fs.readFileSync(SOURCE_PATH, 'utf8');
	if (/^\s*import\b/m.test(text))
		throw new Error(`${SOURCE_PATH} imports; the page cannot load it`);
	if (/^export (default|\{|let|var|class|async)/m.test(text))
		throw new Error(`${SOURCE_PATH} has an export the wrapper cannot keep`);
	const names = [...text.matchAll(EXPORT)].map((match) => match[2]);
	if (names.length === 0) throw new Error(`${SOURCE_PATH} exports nothing`);
	const body = text.replace(EXPORT, '$1 $2').replace(/\n$/, '');
	return [
		'// _shared/ui/_generated/key_legend.js',
		'',
		'// ==========================================',
		'// AUTO-GENERATED — do not edit manually',
		'// Source: src/lib/keyboard/keyLegend.js',
		'// Run: npm run codegen:key-legend:js',
		'// ==========================================',
		'',
		"// The site's key legend formatter, for the layout editor and the Comparer.",
		'var KEY_LEGEND = (function () {',
		body,
		`\treturn { ${names.join(', ')} };`,
		'})();',
		''
	].join('\n');
}

/** Writes the generated file. */
function main() {
	console.log('codegen:key-legend:js — wrapping the key legend formatter…');
	fs.mkdirSync(path.dirname(OUT_PATH), { recursive: true });
	fs.writeFileSync(OUT_PATH, buildSource());
	console.log(`codegen:key-legend:js — wrote ${OUT_PATH}`);
}

if (require.main === module) main();

module.exports = { buildSource, OUT_PATH, SOURCE_PATH };
