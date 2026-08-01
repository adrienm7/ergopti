/**
 * ==============================================================================
 * MODULE: Tooltip Corpus Parity — JSON against the JS source of truth
 * DESCRIPTION:
 * The shared JSON corpus that both drivers replay must match what
 * `layoutTestVectors()` and `dequeueTestVectors()` return.
 *
 * ROOT CAUSE ENCODED:
 * This gate was registered as "tooltip corpus parity (JSON corpus matches JS
 * layoutTestVectors + dequeueTestVectors)" and **loaded neither JS module**. It
 * checked that the JSON had 6 and 3 vectors and that their fields were the right
 * types — a structural check wearing a parity name. The numbers 6 and 3 came
 * from the JS originally and had since become plain literals, so the JS could
 * change and nothing anywhere would notice.
 *
 * It could not have loaded them. package.json declares `"type": "module"`, which
 * makes every bare `.js` file ESM, so the tooltip modules' `module.exports = {}`
 * is dead code: `require()` rejects them and `import()` yields an empty
 * namespace. Measured across `_shared/`, **32 modules** are in that state. The
 * port specs escaped it only because codegen-contracts-json.cjs carried a
 * private CommonJS-in-ESM loader; the tooltip modules had no such consumer, so
 * their declared source of truth was unreachable from every tool in the repo.
 *
 * That loader is now tools/lib/load-cjs-module.cjs, and this gate uses it to do
 * what its name always claimed.
 *
 * WHAT IS COMPARED:
 * Ids, order, and every expected value — not counts. A corpus with the right
 * number of vectors carrying the wrong coordinates is precisely the drift a
 * count cannot see, and the drivers replay these expectations as ground truth.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert').strict;
const { readFileSync } = require('node:fs');
const path = require('node:path');
const { loadCjsModule } = require('../lib/load-cjs-module.cjs');

const root = path.resolve(__dirname, '../../static/ergopti_plus');
const tooltipDir = path.join(root, '_shared/modules/tooltip');

const layoutJs = loadCjsModule(path.join(tooltipDir, 'layout.js'));
const dequeueJs = loadCjsModule(path.join(tooltipDir, 'dequeue.js'));

assert.ok(
	typeof layoutJs.layoutTestVectors === 'function',
	'layout.js must export layoutTestVectors() — it is the declared source of truth for the corpus'
);
assert.ok(
	typeof dequeueJs.dequeueTestVectors === 'function',
	'dequeue.js must export dequeueTestVectors()'
);

/** Deep-compares one vector field, reporting the vector id and field name. */
function sameValue(actual, expected, where) {
	assert.deepStrictEqual(
		actual,
		expected,
		`${where}: the JSON corpus and the JS source of truth disagree. The drivers replay the ` +
			'JSON as ground truth, so a difference here means they are asserting something the ' +
			'shared implementation no longer says.'
	);
}

/**
 * Compares a JSON corpus against its JS vectors, by id and in order.
 * @param {string} label Corpus name, for failure messages.
 * @param {string} jsonPath Absolute path to the corpus.
 * @param {object[]} jsVectors What the JS returns.
 */
function compareCorpus(label, jsonPath, jsVectors) {
	const corpus = JSON.parse(readFileSync(jsonPath, 'utf-8'));

	assert.ok(
		typeof corpus.description === 'string' && corpus.description.length > 0,
		`${label} corpus must have a description`
	);
	assert.ok(Array.isArray(corpus.vectors), `${label} corpus must have a vectors array`);

	assert.strictEqual(
		corpus.vectors.length,
		jsVectors.length,
		`${label}: the corpus has ${corpus.vectors.length} vector(s) and the JS returns ` +
			`${jsVectors.length}. One of them gained or lost a case.`
	);

	const jsonIds = corpus.vectors.map((v) => v.id);
	const jsIds = jsVectors.map((v) => v.id);
	assert.deepStrictEqual(
		jsonIds,
		jsIds,
		`${label}: vector ids differ (or are in a different order) between the corpus and the JS. ` +
			'Order matters because the drivers index into these by position in places.'
	);

	for (let i = 0; i < jsVectors.length; i++) {
		const js = jsVectors[i];
		const json = corpus.vectors[i];
		for (const key of Object.keys(js)) {
			// `description` is prose; the drivers never assert on it.
			if (key === 'description') continue;
			sameValue(json[key], js[key], `${label} vector "${js.id}" field "${key}"`);
		}
	}
}

compareCorpus(
	'layout',
	path.resolve(root, '_shared/tests/corpus/tooltip/layout_vectors.json'),
	layoutJs.layoutTestVectors()
);

compareCorpus(
	'dequeue',
	path.resolve(root, '_shared/tests/corpus/tooltip/dequeue_vectors.json'),
	dequeueJs.dequeueTestVectors()
);

console.log(
	`\x1b[32m[OK] tooltip corpus matches the JS source of truth: ` +
		`${layoutJs.layoutTestVectors().length} layout and ${dequeueJs.dequeueTestVectors().length} ` +
		'dequeue vector(s), compared field by field.\x1b[0m'
);
