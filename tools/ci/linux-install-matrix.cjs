// tools/ci/linux-install-matrix.cjs

/** Plan human-readable Linux lots from their single authored map and mandatory coverage. */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

/** Validate the full map before it chooses any install container or package subject. */
function validateMap(metadata, coverage) {
	assert.ok(metadata && typeof metadata === 'object' && !Array.isArray(metadata));
	const subjects = coverage.jobs['install-linux'].subjects;
	const ids = [];
	for (const [lot, cell] of Object.entries(metadata)) {
		assert.match(lot, /^[A-Za-z0-9.][A-Za-z0-9 .:()-]*$/);
		assert.ok(cell && typeof cell === 'object' && !Array.isArray(cell));
		assert.ok(['install', 'first', 'deb', 'rpm', 'appimage'].includes(cell.kind));
		const fields = ['id', 'kind', 'container'];
		if (cell.kind === 'install' || cell.kind === 'first') fields.push('distro', 'image');
		if (cell.kind === 'install') fields.push('prep');
		if (cell.kind === 'first' && Object.hasOwn(cell, 'prep')) fields.push('prep');
		if (cell.kind === 'first' && Object.hasOwn(cell, 'known')) {
			fields.push('known');
			assert.equal(cell.known, 'webkit');
		}
		assert.deepEqual(Object.keys(cell).sort(), fields.sort());
		for (const [key, value] of Object.entries(cell)) {
			assert.equal(typeof value, 'string');
			assert.ok(!/[\r\n\x00]/.test(value));
			if (key !== 'container') assert.notEqual(value, '');
		}
		assert.equal(subjects[cell.id], 1);
		ids.push(cell.id);
	}
	assert.deepEqual(
		ids,
		Object.keys(subjects),
		'Linux lot order must retain every mandatory subject exactly once'
	);
	return { matrix: { lot: Object.keys(metadata) }, metadata };
}

/** Reject a foreign receiver lot or modified transport without requiring Node in containers. */
function selectLot(plan, lot, metadata) {
	assert.equal(
		metadata,
		JSON.stringify(plan.metadata),
		'Linux metadata must retain the whole authored map'
	);
	assert.ok(typeof lot === 'string' && Object.hasOwn(plan.metadata, lot), 'Unknown Linux lot');
	return plan.metadata[lot];
}

function loadPlan(root) {
	const source = fs.readFileSync(path.join(root, '.github/linux-install-matrix.json'), 'utf8');
	const metadata = JSON.parse(source);
	assert.equal(
		source,
		JSON.stringify(metadata, null, '\t') + '\n',
		'Linux map must have canonical closed JSON bytes'
	);
	const coverage = JSON.parse(
		fs.readFileSync(path.join(root, '.github/linux-ci-coverage.json'), 'utf8')
	);
	return validateMap(metadata, coverage);
}

if (require.main === module) {
	if (process.argv.length !== 2 || !process.env.GITHUB_OUTPUT)
		throw new Error('Usage: node tools/ci/linux-install-matrix.cjs with GITHUB_OUTPUT');
	const { matrix, metadata } = loadPlan(path.resolve(__dirname, '../..'));
	fs.appendFileSync(
		process.env.GITHUB_OUTPUT,
		'matrix=' + JSON.stringify(matrix) + '\nmetadata=' + JSON.stringify(metadata) + '\n'
	);
}

module.exports = { validateMap, selectLot, loadPlan };
