// tools/ci/site-matrix.cjs

/** Transport the complete authored site map through adjacent Build and Testbuild stages. */
'use strict';

const fs = require('node:fs');
const { siteLots, selectSiteLot } = require('../dev/site-context.cjs');

/** Both Build cells forward the same whole admitted map, never a row-dependent output. */
function planSiteLots(mode, env) {
	if (!['plan', 'admit'].includes(mode)) throw new Error('Unknown site matrix operation');
	const metadata = siteLots();
	if (mode === 'admit') {
		const row = selectSiteLot(env.SITE_LOT, env.SITE_METADATA);
		if (row.target !== env.ERGOPTI_SITE_TARGET || row.base_path !== env.BASE_PATH)
			throw new Error('Selected site lot differs from the actual build target and base');
	}
	return { matrix: { lot: Object.keys(metadata) }, metadata };
}

if (require.main === module) {
	if (process.argv.length !== 3 || !process.env.GITHUB_OUTPUT)
		throw new Error('Usage: node tools/ci/site-matrix.cjs plan|admit with GITHUB_OUTPUT');
	const { matrix, metadata } = planSiteLots(process.argv[2], process.env);
	fs.appendFileSync(
		process.env.GITHUB_OUTPUT,
		'matrix=' + JSON.stringify(matrix) + '\nmetadata=' + JSON.stringify(metadata) + '\n'
	);
}

module.exports = { planSiteLots };
