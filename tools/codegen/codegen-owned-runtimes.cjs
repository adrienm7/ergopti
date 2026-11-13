// tools/codegen/codegen-owned-runtimes.cjs

/**
 * ==============================================================================
 * MODULE: Owned Runtimes Table Generator
 * DESCRIPTION:
 * Writes the tables of docs/design/owned-runtimes.md (headline counts, and the
 * macOS, Linux and Windows rows) from _shared/core/network/data/owned_runtimes.json.
 *
 * FEATURES & RATIONALE:
 * 1. Text splice: the document's prose stays hand-written; only the regions
 *    between its GENERATED markers are replaced (tools/lib/owned-runtimes.cjs).
 * 2. `--check` compares instead of writing, for a gate that must not edit.
 *
 * USAGE:  node tools/codegen/codegen-owned-runtimes.cjs [--check]
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const Registry = require('../lib/owned-runtimes.cjs');

const relative = path.relative(process.cwd(), Registry.DOC_PATH);
const { current, next } = Registry.generate();

if (process.argv.includes('--check')) {
	if (current !== next) {
		console.error(`${relative} is stale: run node tools/codegen/codegen-owned-runtimes.cjs`);
		process.exit(1);
	}
	console.log(`${relative} is up to date.`);
} else if (current === next) {
	console.log(`${relative} already matches the registry.`);
} else {
	fs.writeFileSync(Registry.DOC_PATH, next, 'utf8');
	console.log(`Wrote ${relative}.`);
}
