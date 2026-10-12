// tools/ci/js-feature-matrix.cjs

/** Build one Common row per declared feature and one row per additional suite. */
'use strict';

const path = require('node:path');

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
			['properties', 'mutation'].includes(feature) ||
			seen.has(feature)
		)
			throw new Error('Common feature ids must be unique literal slugs');
		seen.add(feature);
		return { suite: 'js', feature };
	});
	include.push({ suite: 'properties', feature: 'properties' });
	if (ref === 'refs/heads/main') include.push({ suite: 'mutation', feature: 'mutation' });
	return { include };
}

if (require.main === module) {
	if (process.argv.length !== 2) throw new Error('Usage: node tools/ci/js-feature-matrix.cjs');
	const { loadInventory } = require('../test/lib/js-feature-inventory.cjs');
	console.log(
		JSON.stringify(
			createMatrix(loadInventory(path.resolve(__dirname, '../..')), process.env.GITHUB_REF)
		)
	);
}

module.exports = { createMatrix };
