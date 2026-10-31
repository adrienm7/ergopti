// tools/codegen/codegen-feature-requirements.cjs

/**
 * ==============================================================================
 * MODULE: Feature Requirements Table Generator
 * DESCRIPTION:
 * Writes docs/design/feature-requirements.md, the feature × OS × requirement
 * table, from the `requires` declarations of _shared/modules/features/manifest.toml
 * and the vocabulary of _shared/modules/features/requirements.toml.
 *
 * FEATURES & RATIONALE:
 * 1. Declarations only: the table shows what the manifest declares. That the
 *    declarations match the code is tools/test/test-feature-requirements.cjs's
 *    job, which also fails when this file is stale.
 * 2. `--check` compares instead of writing, for a gate that must not edit.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const Requirements = require('../lib/feature-requirements.cjs');

const check = process.argv.includes('--check');
const rendered = Requirements.renderTable(Requirements.loadSources());
const relative = path.relative(process.cwd(), Requirements.TABLE_PATH);

if (check) {
	const current = fs.existsSync(Requirements.TABLE_PATH)
		? fs.readFileSync(Requirements.TABLE_PATH, 'utf8')
		: null;
	if (current !== rendered) {
		console.error(`${relative} is stale: run node tools/codegen/codegen-feature-requirements.cjs`);
		process.exit(1);
	}
	console.log(`${relative} is up to date.`);
} else {
	fs.writeFileSync(Requirements.TABLE_PATH, rendered, 'utf8');
	console.log(`Wrote ${relative}.`);
}
