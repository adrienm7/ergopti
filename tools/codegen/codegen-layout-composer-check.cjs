// tools/codegen/codegen-layout-composer-check.cjs

/**
 * ==============================================================================
 * MODULE: Layout Composer Check Codegen
 * DESCRIPTION:
 * Compiles _shared/modules/layouts/composer_check/composition.json into
 * composed.keylayout, the small composition the Debug menu's « Test the
 * composed layout » check installs on each driver. Unlike the test corpus it
 * ships with the app, so it is built from the built-in reference layouts only
 * and never depends on the registry.
 *
 * FEATURES & RATIONALE:
 * 1. Deterministic: the same declaration gives the same bytes.
 * 2. Fail fast: a declaration the model refuses stops the generation with its
 *    problem codes.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { shared } = require('../lib/paths.cjs');
const { loadComposer } = require('../lib/layout-composer.cjs');

const CHECK_DIR = shared('modules', 'layouts', 'composer_check');
const DECLARATION_PATH = path.join(CHECK_DIR, 'composition.json');
const OUT_PATH = path.join(CHECK_DIR, 'composed.keylayout');

/**
 * Compiles the check declaration.
 * @returns {string} The .keylayout text.
 */
function buildSource() {
	const { Composer, TABLE, SOURCES } = loadComposer();
	const declaration = JSON.parse(fs.readFileSync(DECLARATION_PATH, 'utf8'));
	const built = Composer.build(declaration, SOURCES, TABLE);
	if (!built.ok)
		throw new Error(`the check composition is refused: ${JSON.stringify(built.problems)}`);
	return Composer.serialize(built.layout, TABLE);
}

/**
 * Writes the generated file.
 */
function main() {
	console.log('codegen:layout-composer-check — compiling the check composition…');
	fs.writeFileSync(OUT_PATH, buildSource());
	console.log(`codegen:layout-composer-check — wrote ${OUT_PATH}`);
}

if (require.main === module) main();

module.exports = { buildSource, OUT_PATH };
