// tools/test/test-contract-vector-ledger.cjs

/**
 * ==============================================================================
 * MODULE: Contract Vector Ledger Gate
 * DESCRIPTION:
 * PAR-58 moves the cases of the shared Lua contracts into language-neutral JSON
 * vector corpora that the Lua contracts replay on macOS and Linux and an AHK
 * consumer can replay on Windows. This gate keeps that move honest: no case is
 * lost, none is kept twice, and every vector is well formed.
 *
 * FEATURES & RATIONALE:
 * 1. The ledger (_shared/tests/corpus/contract_conversion_ledger.json) lists, per
 *    source contract, each removed case and the vector ids that now hold it. A
 *    vector missing from the ledger, a listed vector missing from the corpus, or
 *    a vector listed twice fails.
 * 2. A removed case title still registered in its Lua contract fails: a case
 *    that runs twice would hide a divergence between the two copies.
 * 3. Each vector is checked against the corpus' own schema (string source, rows
 *    array, one of the documented expectation keys), so a port reading the file
 *    never meets a shape the Lua replayer happened to tolerate.
 * 4. The count each driver's Lua replayer asserts equals the corpus count.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const CORPUS = path.join(SHARED, 'tests', 'corpus');
const CONTRACTS = path.join(SHARED, 'lua', 'test');
const EXPECT_KEYS = new Set([
	'ok',
	'content',
	'unchanged',
	'decoded',
	'contains',
	'not_contains',
	'detail_contains',
	'reads'
]);

const ledger = JSON.parse(
	fs.readFileSync(path.join(CORPUS, 'contract_conversion_ledger.json'), 'utf8')
);
let checked = 0;

for (const family of ledger.families) {
	const corpus = JSON.parse(fs.readFileSync(path.join(CORPUS, family.corpus), 'utf8'));
	const ids = corpus.vectors.map((vector) => vector.id);
	assert.equal(new Set(ids).size, ids.length, `${family.corpus}: duplicate vector ids`);

	const listed = [];
	for (const source of family.sources) {
		const text = fs.readFileSync(path.join(CONTRACTS, source.contract), 'utf8');
		for (const moved of source.moved) {
			assert(moved.vectors.length > 0, `${source.contract}: "${moved.case}" maps to no vector`);
			assert(
				!text.includes(`"${moved.case}`),
				`${source.contract}: the moved case "${moved.case}" is still registered in the Lua contract`
			);
			listed.push(...moved.vectors);
		}
	}
	assert.equal(
		new Set(listed).size,
		listed.length,
		`${family.corpus}: a vector is listed twice in the ledger`
	);
	assert.deepEqual(
		[...listed].sort(),
		[...ids].sort(),
		`${family.corpus}: the ledger and the corpus disagree on the vector ids`
	);

	for (const vector of corpus.vectors) {
		assert.equal(typeof vector.id, 'string', 'vector id');
		assert.equal(typeof vector.group, 'string', `${vector.id}: group`);
		assert.equal(typeof vector.source, 'string', `${vector.id}: source must be a string`);
		assert(Array.isArray(vector.rows) && vector.rows.length > 0, `${vector.id}: rows`);
		assert.equal(typeof vector.expect.ok, 'boolean', `${vector.id}: expect.ok`);
		for (const key of Object.keys(vector.expect))
			assert(EXPECT_KEYS.has(key), `${vector.id}: unknown expectation ${key}`);
		if (vector.expect.ok) {
			assert(
				['content', 'unchanged', 'decoded', 'contains'].some((key) => key in vector.expect),
				`${vector.id}: an accepted vector must state what the bytes are`
			);
		} else {
			assert(!('content' in vector.expect), `${vector.id}: a refused vector yields no bytes`);
		}
		if (vector.expect.unchanged)
			assert.equal(vector.expect.ok, true, `${vector.id}: unchanged implies accepted`);
	}

	// Every driver's replay asserts the corpus' vector count.
	const replayers = [
		'static/ergopti_plus/linux/tests/unit/infra/config/test_toml_codec_shared_decode.lua',
		'static/ergopti_plus/macos/tests/unit/infra/toml/test_toml_writer_transaction.lua'
	];
	for (const relative of replayers) {
		const match = fs
			.readFileSync(path.join(ROOT, relative), 'utf8')
			.match(/batch_write_vectors_contract"\)\(helpers, corpus, (\d+)\)/);
		assert(match, `${relative} does not replay ${family.corpus}`);
		assert.equal(
			Number(match[1]),
			ids.length,
			`${relative} asserts ${match[1]} vectors, the corpus holds ${ids.length}`
		);
	}
	checked += ids.length;
}

console.log(
	`PASS contract vector ledger: ${checked} vectors accounted for, none kept twice, schema valid`
);
