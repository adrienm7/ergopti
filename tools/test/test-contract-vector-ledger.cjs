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
 * 5. The "contracts" section lists, for each remaining Lua contract, the sites
 *    fed by a corpus and each site that stays Lua with a reason code, so the
 *    Windows port knows what to write as code. The site count is a ratchet: a
 *    new Lua case without a ledger entry fails.
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
	'detail_equals',
	'reads'
]);

const ledger = JSON.parse(
	fs.readFileSync(path.join(CORPUS, 'contract_conversion_ledger.json'), 'utf8')
);
let checked = 0;

/** Vector ids and schema checks of one family, by corpus shape. */
const SCHEMAS = {
	toml_batch_write(corpus) {
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
		return corpus.vectors.map((vector) => vector.id);
	},
	toml_leaf_rows(corpus) {
		for (const vector of corpus.vectors) {
			assert.equal(typeof vector.id, 'string', 'vector id');
			assert(vector.source === null || typeof vector.source === 'string', `${vector.id}: source`);
			assert(Array.isArray(vector.operations), `${vector.id}: operations`);
			assert.equal(typeof vector.expect.ok, 'boolean', `${vector.id}: expect.ok`);
			if (vector.expect.ok)
				assert(
					vector.expect.decoded || vector.expect.contains || vector.expect.content,
					`${vector.id}: an accepted vector states its result`
				);
		}
		return corpus.vectors.map((vector) => vector.id);
	},
	toml_inline_scalar(corpus) {
		for (const vector of corpus.vectors) {
			assert.equal(typeof vector.id, 'string', 'vector id');
			assert.equal(typeof vector.group, 'string', `${vector.id}: group`);
			assert(typeof vector.source === 'string', `${vector.id}: source must be a string`);
			assert(Array.isArray(vector.rows), `${vector.id}: rows`);
			assert(
				['hint_parents', 'ok', 'content', 'decoded', 'idempotent'].some(
					(key) => key in vector.expect
				),
				`${vector.id}: states no expectation`
			);
		}
		return corpus.vectors.map((vector) => vector.id);
	},
	toml_hotstring_reader(corpus) {
		for (const vector of corpus.vectors) {
			assert.equal(typeof vector.id, 'string', 'vector id');
			assert.equal(typeof vector.group, 'string', `${vector.id}: group`);
			assert.equal(typeof vector.text, 'string', `${vector.id}: text`);
			assert.equal(typeof vector.expect.committed, 'boolean', `${vector.id}: expect.committed`);
		}
		return corpus.vectors.map((vector) => vector.id);
	},
	menu_numbered_caption(corpus) {
		for (const vector of corpus.positive) {
			assert.equal(typeof vector.format, 'string', `${vector.id}: format`);
			assert.equal(typeof vector.expected, 'string', `${vector.id}: expected`);
			assert.equal(
				vector.format.split('{1}').length > 1,
				true,
				`${vector.id}: a positive format holds {1}`
			);
		}
		for (const vector of corpus.grammar_refusals)
			assert.equal(typeof vector.format, 'string', `${vector.id}: format`);
		for (const vector of corpus.ownership_refusals)
			assert.equal(typeof vector.mutation, 'string', `${vector.id}: mutation`);
		return [...corpus.positive, ...corpus.grammar_refusals, ...corpus.ownership_refusals].map(
			(vector) => vector.id
		);
	},
	config_scope_plan(corpus) {
		assert(
			corpus.stored_paths.every((entry) => entry.startsWith('action_parameters.')),
			'stored paths'
		);
		for (const vector of corpus.inventories) {
			assert.equal(Number.isInteger(vector.inventory_count), true, `${vector.id}: inventory_count`);
			assert.equal(typeof vector.scope, 'string', `${vector.id}: scope`);
		}
		for (const vector of corpus.refusals)
			assert.equal(typeof vector.path, 'string', `${vector.id}: path`);
		for (const vector of [
			...corpus.declaration_plans,
			...corpus.declaration_refusals,
			...corpus.declaration_cycles
		]) {
			assert.equal(typeof vector.scope, 'string', `${vector.id}: scope`);
			assert.equal(typeof vector.mode, 'string', `${vector.id}: mode`);
			assert(Array.isArray(vector.declaration.features), `${vector.id}: declaration.features`);
		}
		for (const vector of [...corpus.inventory_collections, ...corpus.inventory_refusals])
			assert(Array.isArray(vector.providers), `${vector.id}: providers`);
		return [
			...corpus.inventories,
			...corpus.refusals,
			...corpus.declaration_plans,
			...corpus.declaration_refusals,
			...corpus.declaration_cycles,
			...corpus.inventory_collections,
			...corpus.inventory_refusals
		].map((vector) => vector.id);
	}
};

/** Counts passed to one replayer by both drivers' TOML suites. */
function replayerCounts(contract, held, label) {
	const found = [];
	for (const relative of [
		'static/ergopti_plus/linux/tests/unit/infra/config/test_toml_codec_shared_decode.lua',
		'static/ergopti_plus/macos/tests/unit/infra/toml/test_toml_writer_transaction.lua'
	]) {
		const match = fs
			.readFileSync(path.join(ROOT, relative), 'utf8')
			.match(new RegExp(`require\\("test\\.${contract}"\\)\\(helpers, corpus, (\\d+)\\)`));
		assert(match, `${relative} does not replay the ${label} vectors`);
		found.push([relative, Number(match[1]), held]);
	}
	return found;
}

/** The vector counts each Lua replayer asserts, by family. */
const LUA_COUNTS = {
	toml_batch_write(corpus) {
		const found = [];
		for (const relative of [
			'static/ergopti_plus/linux/tests/unit/infra/config/test_toml_codec_shared_decode.lua',
			'static/ergopti_plus/macos/tests/unit/infra/toml/test_toml_writer_transaction.lua'
		]) {
			const match = fs
				.readFileSync(path.join(ROOT, relative), 'utf8')
				.match(/batch_write_vectors_contract"\)\(helpers, corpus, (\d+)\)/);
			assert(match, `${relative} does not replay the batch writer vectors`);
			found.push([relative, Number(match[1]), corpus.vectors.length]);
		}
		return found;
	},
	toml_inline_scalar(corpus) {
		return replayerCounts(
			'toml_inline_scalar_vectors_contract',
			corpus.vectors.length,
			'inline scalar'
		);
	},
	toml_hotstring_reader(corpus) {
		return replayerCounts(
			'toml_hotstring_reader_vectors_contract',
			corpus.vectors.length,
			'hotstring reader'
		);
	},
	toml_leaf_rows(corpus) {
		const found = [];
		for (const relative of [
			'static/ergopti_plus/linux/tests/unit/infra/config/test_toml_codec_shared_decode.lua',
			'static/ergopti_plus/macos/tests/unit/infra/toml/test_toml_writer_transaction.lua'
		]) {
			const match = fs
				.readFileSync(path.join(ROOT, relative), 'utf8')
				.match(/leaf_rows_vectors_contract"\)\(helpers, corpus, (\d+)\)/);
			assert(match, `${relative} does not replay the leaf rows vectors`);
			found.push([relative, Number(match[1]), corpus.vectors.length]);
		}
		return found;
	},
	menu_numbered_caption(corpus) {
		const match = fs
			.readFileSync(path.join(CONTRACTS, 'menu_numbered_caption_contract.lua'), 'utf8')
			.match(
				/#corpus\.positive == (\d+) and #corpus\.grammar_refusals == (\d+) and #corpus\.ownership_refusals == (\d+)/
			);
		assert(match, 'menu_numbered_caption_contract.lua must assert its vector counts');
		return [
			['positive', Number(match[1]), corpus.positive.length],
			['grammar_refusals', Number(match[2]), corpus.grammar_refusals.length],
			['ownership_refusals', Number(match[3]), corpus.ownership_refusals.length]
		];
	},
	config_scope_plan(corpus) {
		const match = fs
			.readFileSync(path.join(CONTRACTS, 'config_scope_plan_contract.lua'), 'utf8')
			.match(
				/#corpus\.stored_paths == (\d+) and #corpus\.inventories == (\d+) and #corpus\.refusals == (\d+)\s+and #corpus\.declaration_plans == (\d+) and #corpus\.declaration_refusals == (\d+) and #corpus\.declaration_cycles == (\d+)\s+and #corpus\.inventory_collections == (\d+) and #corpus\.inventory_refusals == (\d+)/
			);
		assert(match, 'config_scope_plan_contract.lua must assert its vector counts');
		return [
			['stored_paths', Number(match[1]), corpus.stored_paths.length],
			['inventories', Number(match[2]), corpus.inventories.length],
			['refusals', Number(match[3]), corpus.refusals.length],
			['declaration_plans', Number(match[4]), corpus.declaration_plans.length],
			['declaration_refusals', Number(match[5]), corpus.declaration_refusals.length],
			['declaration_cycles', Number(match[6]), corpus.declaration_cycles.length],
			['inventory_collections', Number(match[7]), corpus.inventory_collections.length],
			['inventory_refusals', Number(match[8]), corpus.inventory_refusals.length]
		];
	}
};

for (const family of ledger.families) {
	const corpus = JSON.parse(fs.readFileSync(path.join(CORPUS, family.corpus), 'utf8'));
	assert(SCHEMAS[family.schema], `${family.family}: unknown schema ${family.schema}`);
	const ids = SCHEMAS[family.schema](corpus);
	assert.equal(new Set(ids).size, ids.length, `${family.corpus}: duplicate vector ids`);

	const listed = [];
	for (const source of family.sources) {
		const text = fs.readFileSync(path.join(CONTRACTS, source.contract), 'utf8');
		for (const moved of source.moved) {
			assert(moved.vectors.length > 0, `${source.contract}: a moved entry maps to no vector`);
			if (moved.case !== undefined) {
				assert(
					!text.includes(`"${moved.case}`),
					`${source.contract}: the moved case "${moved.case}" is still registered in the Lua contract`
				);
			}
			for (const literal of moved.absent ?? []) {
				assert(
					!text.includes(literal),
					`${source.contract}: the case data "${literal}" is still written in the Lua contract`
				);
			}
			assert(
				moved.case !== undefined || (moved.absent ?? []).length > 0,
				`${source.contract}: an entry names no case`
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
	for (const [where, asserted, held] of LUA_COUNTS[family.schema](corpus))
		assert.equal(asserted, held, `${where} asserts ${asserted} vectors, the corpus holds ${held}`);
	checked += ids.length;
}

/** Registration sites of a Lua contract: one per it( or test(" call line. */
function luaSites(text) {
	return text
		.split('\n')
		.filter(
			(line) =>
				(!/function\s+test\b/.test(line) && /helpers\.it\(/.test(line)) || /\btest\("/.test(line)
		).length;
}

let sites = 0;
let staysInLua = 0;
assert(ledger.reasons && Object.keys(ledger.reasons).length > 0, 'ledger.reasons');
const seenContracts = new Set();
for (const entry of ledger.contracts) {
	assert(!seenContracts.has(entry.contract), `${entry.contract}: listed twice`);
	seenContracts.add(entry.contract);
	const text = fs.readFileSync(path.join(CONTRACTS, entry.contract), 'utf8');
	assert.equal(
		entry.lua_sites,
		luaSites(text),
		`${entry.contract}: ${luaSites(text)} registration sites, the ledger lists ${entry.lua_sites}`
	);
	assert.equal(
		entry.data_driven.length + entry.stays_in_lua.length,
		entry.lua_sites,
		`${entry.contract}: every site is either data driven or stays Lua with a reason`
	);
	for (const item of entry.data_driven)
		assert(
			fs.existsSync(path.join(CORPUS, item.corpus)),
			`${entry.contract}: corpus ${item.corpus}`
		);
	for (const item of entry.stays_in_lua) {
		assert(ledger.reasons[item.reason], `${entry.contract}: unknown reason ${item.reason}`);
		assert(
			text.includes(item.case.replace(/ \(.*$/, '').slice(0, 30)),
			`${entry.contract}: "${item.case}" is not a case of the contract`
		);
		staysInLua += 1;
	}
	sites += entry.lua_sites;
}
const onDisk = fs
	.readdirSync(CONTRACTS)
	.filter((name) => /^(config_scope|toml_|menu_)/.test(name) && !name.includes('vectors_contract'));
for (const name of onDisk)
	assert(seenContracts.has(name), `${name}: a family contract missing from the ledger contracts`);

console.log(
	`PASS contract vector ledger: ${checked} vectors accounted for, none kept twice, schema valid; ` +
		`${sites} Lua sites classified (${staysInLua} stay Lua with a reason)`
);
