// tools/test/test-tap-hold-migrations.cjs

/**
 * ==============================================================================
 * MODULE: Tap-Hold Migration Registry Gate
 * DESCRIPTION:
 * Pins the versioned tap_hold.toml contract: the shipped registry
 * (_shared/tap_hold/migrations.toml) is a gap-free chain over a closed op set,
 * its corpus (_shared/tests/corpus/tap_hold_migrations) is listed and well
 * formed, and an independent reference interpreter replays every case so an
 * expected.toml cannot describe behaviour no driver has. It also keeps this
 * registry apart from the config.toml one that Windows validates at every boot.
 *
 * FEATURES & RATIONALE:
 * 1. Registry shape. current_version and unstamped_version bound a chain of
 *    steps named v<from>_to_v<to>; every op is one of drop_retired_values and
 *    delete, with bare dotted names, and drop_retired_values names a table
 *    that exists in the shared defaults.
 * 2. Separate from config.toml. The config.toml registry must not know the op
 *    this one adds: windows/infra/config_migrate.ahk refuses an op it does not
 *    know, so sharing the registry would break every Windows boot.
 * 3. Replay. The reference interpreter below is a second implementation of the
 *    op semantics (after _shared/lua/tap_hold/migrate.lua). It decides each
 *    case's outcome, compares the migrated document with expected.toml and
 *    replays the steps on their own output, which must change nothing.
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const TOML = require('smol-toml');
const { shared } = require('../lib/paths.cjs');

const REGISTRY_PATH = shared('tap_hold/migrations.toml');
const DEFAULTS_PATH = shared('tap_hold/defaults.toml');
const CONFIG_REGISTRY_PATH = shared('core/config_schema/migrations.toml');
const CORPUS_DIR = shared('tests/corpus/tap_hold_migrations');
const BARE_PATH = /^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$/;
const OUTCOMES = ['migrated', 'current', 'newer', 'invalid'];
const OPS = {
	drop_retired_values: ['op', 'section', 'key', 'retired', 'unless'],
	delete: ['op', 'section', 'key']
};

// A plain-object round trip: smol-toml tables have a null prototype.
const read = (file) => JSON.parse(JSON.stringify(TOML.parse(fs.readFileSync(file, 'utf8'))));
const isTable = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

// -- 1. Registry ------------------------------------------------------------

const registry = read(REGISTRY_PATH);
const defaults = read(DEFAULTS_PATH);
const current = registry.registry.current_version;
const unstamped = registry.registry.unstamped_version;
assert(
	Number.isInteger(current) && Number.isInteger(unstamped) && current > unstamped,
	'registry versions'
);

const steps = Object.entries(registry.steps)
	.map(([name, step]) => {
		assert.strictEqual(name, `v${step.from}_to_v${step.to}`, `${name} is named after its versions`);
		assert.strictEqual(step.to, step.from + 1, `${name} climbs one version`);
		assert(typeof step.reason === 'string' && step.reason !== '', `${name} states its reason`);
		for (const [index, op] of step.ops.entries()) {
			const allowed = OPS[op.op];
			assert(allowed, `${name} op ${index}: unknown op ${op.op}`);
			for (const field of Object.keys(op))
				assert(allowed.includes(field), `${name} op ${index}: stray ${field}`);
			assert(
				BARE_PATH.test(op.section) && BARE_PATH.test(op.key),
				`${name} op ${index}: bare names`
			);
			if (op.op === 'drop_retired_values') {
				const table = op.retired.split('.').reduce((node, part) => node && node[part], defaults);
				assert(
					isTable(table),
					`${name} op ${index}: ${op.retired} is not a table of the shared defaults`
				);
			}
		}
		return step;
	})
	.sort((a, b) => a.from - b.from);
let expectedFrom = unstamped;
for (const step of steps) {
	assert.strictEqual(step.from, expectedFrom, `a step leaves version ${expectedFrom}`);
	expectedFrom = step.to;
}
assert.strictEqual(expectedFrom, current, 'the steps reach current_version');

// -- 2. Apart from the config.toml registry -----------------------------------

const configRegistry = fs.readFileSync(CONFIG_REGISTRY_PATH, 'utf8');
assert(
	!configRegistry.includes('drop_retired_values'),
	'the config.toml registry (validated by Windows at every boot) must not carry a tap_hold op'
);

// -- 3. Reference interpreter --------------------------------------------------

/** The shared defaults' [tap_hold.retired_delays], resolved to Linux key ids. */
function retiredFor(platform) {
	const catalog = defaults.tap_hold.catalog.keys.filter((entry) => entry[platform]);
	const result = {};
	for (const entry of catalog) {
		const seconds = defaults.tap_hold.retired_delays[entry.id];
		if (seconds !== undefined)
			result[entry[platform] === true ? entry.id : entry[platform]] = seconds;
	}
	return result;
}

function tableAt(document, dotted) {
	let node = document;
	for (const part of dotted.split('.')) {
		node = node[part];
		if (!isTable(node)) return null;
	}
	return node;
}

function prune(document, dotted) {
	const parts = dotted.split('.');
	for (let depth = parts.length; depth >= 1; depth--) {
		let parent = document;
		for (let index = 0; index < depth - 1; index++) parent = parent[parts[index]];
		const node = parent[parts[depth - 1]];
		if (isTable(node) && Object.keys(node).length === 0) delete parent[parts[depth - 1]];
		else return;
	}
}

function applyOp(document, op, retired) {
	if (op.op === 'delete') {
		const section = tableAt(document, op.section);
		if (section) {
			delete section[op.key];
			prune(document, op.section);
		}
		return;
	}
	if (op.unless) {
		const guard = tableAt(document, op.unless.section);
		if (guard && guard[op.unless.key] === op.unless.value) return;
	}
	const section = tableAt(document, op.section);
	if (!section) return;
	for (const [id, seconds] of Object.entries(retired)) {
		const entry = section[id];
		if (isTable(entry) && entry[op.key] === seconds) {
			delete entry[op.key];
			if (Object.keys(entry).length === 0) delete section[id];
		}
	}
	prune(document, op.section);
}

function migrate(document, retired) {
	const meta = document._meta;
	let version = unstamped;
	if (meta !== undefined) {
		if (!isTable(meta)) return { outcome: 'invalid' };
		if (meta.schema_version !== undefined) {
			if (!Number.isInteger(meta.schema_version) || meta.schema_version < 0)
				return { outcome: 'invalid' };
			version = meta.schema_version;
		}
	}
	if (version > current) return { outcome: 'newer', from: version };
	if (version === current) return { outcome: 'current', from: version };
	for (const step of steps) {
		if (step.from >= version) for (const op of step.ops) applyOp(document, op, retired);
	}
	document._meta = { ...(document._meta || {}), schema_version: current };
	return { outcome: 'migrated', from: version };
}

// -- 4. Corpus ------------------------------------------------------------------

const index = read(path.join(CORPUS_DIR, 'cases.toml')).corpus.cases;
const onDisk = fs
	.readdirSync(CORPUS_DIR, { withFileTypes: true })
	.filter((entry) => entry.isDirectory())
	.map((entry) => entry.name)
	.sort();
assert.deepStrictEqual([...index].sort(), onDisk, 'cases.toml lists exactly the case directories');

const seen = new Set();
const retired = retiredFor('linux');
for (const name of index) {
	const dir = path.join(CORPUS_DIR, name);
	const { case: meta } = read(path.join(dir, 'case.toml'));
	assert(OUTCOMES.includes(meta.outcome), `${name}: outcome`);
	assert(Array.isArray(meta.drivers) && meta.drivers.length > 0, `${name}: drivers`);
	seen.add(meta.outcome);
	const input = read(path.join(dir, 'input.toml'));
	const result = migrate(input, retired);
	assert.strictEqual(result.outcome, meta.outcome, `${name}: outcome`);
	if (meta.outcome === 'migrated') {
		assert.strictEqual(result.from, meta.from_version, `${name}: from_version`);
		assert.strictEqual(meta.to_version, current, `${name}: to_version`);
		const expected = read(path.join(dir, 'expected.toml'));
		assert.deepStrictEqual(input, expected, `${name}: migrated document`);
		assert.strictEqual(migrate(input, retired).outcome, 'current', `${name}: replay`);
		assert.deepStrictEqual(input, expected, `${name}: a replay changes nothing`);
	} else {
		assert(
			!fs.existsSync(path.join(dir, 'expected.toml')),
			`${name}: only a migrated case has an expected.toml`
		);
		assert.deepStrictEqual(
			input,
			read(path.join(dir, 'input.toml')),
			`${name}: the document is not edited`
		);
	}
}
for (const outcome of OUTCOMES)
	assert(seen.has(outcome), `the corpus covers the outcome ${outcome}`);

console.log(`tap-hold migrations: ${index.length} corpus cases, ${steps.length} step(s) replayed`);
