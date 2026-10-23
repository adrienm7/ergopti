// tools/codegen/codegen-layout-composer-corpus.cjs

/**
 * ==============================================================================
 * MODULE: Layout Composer Corpus Codegen
 * DESCRIPTION:
 * Compiles _shared/tests/corpus/layouts/composer/composition.json into
 * composed.keylayout, the file every driver's composer test installs and
 * replays vectors.json through. The layout is built by the shared model
 * (_shared/ui/layout_composer/composer_model.js) from the registry layouts, so
 * the corpus never drifts from the compiler.
 *
 * FEATURES & RATIONALE:
 * 1. Deterministic: the same declaration and registry give the same bytes.
 * 2. Fail fast: a declaration the model refuses stops the generation with its
 *    problem codes.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { shared } = require('../lib/paths.cjs');
const { loadComposer } = require('../lib/layout-composer.cjs');

const CORPUS_DIR = shared('tests', 'corpus', 'layouts', 'composer');
const DECLARATION_PATH = path.join(CORPUS_DIR, 'composition.json');
const OUT_PATH = path.join(CORPUS_DIR, 'composed.keylayout');

/**
 * Compiles the corpus declaration.
 * @returns {string} The .keylayout text.
 */
function buildSource() {
	const { Composer, TABLE, SOURCES } = loadComposer();
	const declaration = JSON.parse(fs.readFileSync(DECLARATION_PATH, 'utf8'));
	const built = Composer.build(declaration, SOURCES, TABLE);
	if (!built.ok)
		throw new Error(`the corpus composition is refused: ${JSON.stringify(built.problems)}`);
	return Composer.serialize(built.layout, TABLE);
}

/**
 * Writes the generated file.
 */
function main() {
	console.log('codegen:layout-composer-corpus — compiling the corpus composition…');
	fs.writeFileSync(OUT_PATH, buildSource());
	console.log(`codegen:layout-composer-corpus — wrote ${OUT_PATH}`);
}

if (require.main === module) main();

module.exports = { buildSource, OUT_PATH };
