// tools/ci/js-feature-matrix.cjs

/** Build one Common row per declared feature and one row per additional suite. */
'use strict';

const path = require('node:path');
const fs = require('node:fs');

function createMatrix(inventory, ref) {
	if (typeof ref !== 'string' || !/^refs\/(?:heads|pull|tags)\/[^\s]+$/.test(ref))
		throw new Error('A full GitHub ref is required to plan the Common suites');
	if (!Array.isArray(inventory.features) || inventory.features.length === 0)
		throw new Error('Common feature inventory is empty');
	const seen = new Set();
	const include = inventory.features.map((feature) => {
		if (
			typeof feature !== 'string' ||
			!/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(feature) ||
			['properties', 'mutation', 'hotstrings-format'].includes(feature) ||
			seen.has(feature)
		)
			throw new Error('Common feature ids must be unique literal slugs');
		seen.add(feature);
		return { suite: 'js', feature };
	});
	include.push({ suite: 'properties', feature: 'properties' });
	include.push({ suite: 'hotstrings-format', feature: 'hotstrings-format' });
	if (ref === 'refs/heads/main') include.push({ suite: 'mutation', feature: 'mutation' });
	return { include };
}

/** Derive display labels from the actual inventory without a second feature roster. */
function displayPlan(inventory, ref) {
	const metadata = Object.fromEntries(
		createMatrix(inventory, ref).include.map((row) => {
			const lot =
				row.suite === 'js'
					? row.feature[0].toUpperCase() + row.feature.slice(1).replace(/-/g, ' ')
					: {
							properties: 'Property tests',
							mutation: 'Mutation tests',
							'hotstrings-format': 'Hotstring TOML formatting'
						}[row.suite];
			return [lot, row];
		})
	);
	if (Object.keys(metadata).length !== createMatrix(inventory, ref).include.length)
		throw new Error('Common human lot labels must be unique');
	return { matrix: { lot: Object.keys(metadata) }, metadata };
}

/** Admit the whole predecessor map before selecting any Common check. */
function selectLot(inventory, ref, lot, metadata) {
	const expected = displayPlan(inventory, ref).metadata;
	if (metadata !== JSON.stringify(expected))
		throw new Error('Common lot metadata differs from the complete authored inventory');
	if (typeof lot !== 'string' || !Object.hasOwn(expected, lot))
		throw new Error('Unknown Common lot');
	return expected[lot];
}

/** Bind the complete shallow-checkout inventory to the actual source and ref. */
function createPlan(inventory, context) {
	if (
		!context ||
		!/^[0-9a-f]{40}$/.test(context.source || '') ||
		!/^[0-9a-f]{64}$/.test(inventory.digest || '')
	)
		throw new Error('Common plan requires exact source and inventory digests');
	return {
		schema_version: 1,
		source_sha: context.source,
		ref: context.ref,
		inventory_sha256: inventory.digest,
		...displayPlan(inventory, context.ref)
	};
}

/** Reject a missing, foreign or partial plan before a matrix cell executes. */
function admitPlan(inventory, context, encoded) {
	const expected = createPlan(inventory, context);
	if (encoded !== JSON.stringify(expected))
		throw new Error('Common source/ref plan differs from the complete authored inventory');
	return expected;
}

/** Select one human lot only after admitting the complete producer plan. */
function selectPlannedLot(inventory, context, lot, encoded) {
	const plan = admitPlan(inventory, context, encoded);
	return selectLot(inventory, context.ref, lot, JSON.stringify(plan.metadata));
}

if (require.main === module) {
	const { loadInventory } = require('../test/lib/js-feature-inventory.cjs');
	const inventory = loadInventory(path.resolve(__dirname, '../..'));
	if (process.argv.length !== 3 || !['plan', 'select'].includes(process.argv[2]))
		throw new Error('Usage: node tools/ci/js-feature-matrix.cjs plan|select');
	if (!process.env.GITHUB_OUTPUT) throw new Error('GITHUB_OUTPUT is required');
	const context = { source: process.env.GITHUB_SHA, ref: process.env.GITHUB_REF };
	if (process.argv[2] === 'plan') {
		const planned = createPlan(inventory, context);
		fs.appendFileSync(process.env.GITHUB_OUTPUT, 'plan=' + JSON.stringify(planned) + '\n');
	} else {
		const row = selectPlannedLot(
			inventory,
			context,
			process.env.COMMON_LOT,
			process.env.COMMON_PLAN
		);
		fs.appendFileSync(
			process.env.GITHUB_OUTPUT,
			'suite=' + row.suite + '\nfeature=' + row.feature + '\n'
		);
	}
}

module.exports = { createMatrix, displayPlan, selectLot, createPlan, admitPlan, selectPlannedLot };
