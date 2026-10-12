// tools/ci/validate-js-feature-results.cjs

/** Admit downloaded Common feature journals without replacing native qualification. */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { validateFeatureJournals } = require('../test/lib/js-feature-results.cjs');

function collectJournals(directory) {
	const result = [];
	function visit(current) {
		for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
			const target = path.join(current, entry.name);
			if (entry.isSymbolicLink()) throw new Error(`Refusing linked feature evidence: ${target}`);
			if (entry.isDirectory()) visit(target);
			else if (entry.isFile() && entry.name === 'timings.ndjson') {
				const text = fs.readFileSync(target, 'utf8');
				if (!text.endsWith('\n')) throw new Error(`Truncated feature evidence: ${target}`);
				result.push(
					text
						.trimEnd()
						.split('\n')
						.map((line) => JSON.parse(line))
				);
			}
		}
	}
	visit(directory);
	return result;
}

function main() {
	if (process.argv.length !== 3)
		throw new Error(
			'Usage: node tools/ci/validate-js-feature-results.cjs <downloaded-artifacts-directory>'
		);
	const { loadInventory } = require('../test/lib/js-feature-inventory.cjs');
	const inventory = loadInventory(path.resolve(__dirname, '..', '..'));
	const result = validateFeatureJournals(inventory, collectJournals(process.argv[2]), {
		platform: process.platform,
		source: process.env.GITHUB_SHA,
		run_id: process.env.GITHUB_RUN_ID,
		run_attempt: process.env.GITHUB_RUN_ATTEMPT
	});
	console.log(JSON.stringify(result, null, 2));
	console.log(`Common feature union: ${result.checks} checks passed exactly once.`);
}

if (require.main === module) main();
module.exports = { collectJournals };
