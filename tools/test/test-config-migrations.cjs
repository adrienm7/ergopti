// tools/test/test-config-migrations.cjs

/**
 * ==============================================================================
 * MODULE: Config Migration Registry Gate
 * DESCRIPTION:
 * Pins the versioned config.toml contract shared by the three drivers: the
 * shipped registry (_shared/core/config_schema/migrations.toml) is contiguous
 * and uses only the closed op set, every corpus case is well formed and listed,
 * and an independent reference interpreter replays the corpus so an
 * expected.toml cannot silently describe behaviour no interpreter has.
 *
 * FEATURES & RATIONALE:
 * 1. Registry shape. current_version and unstamped_version bound a gap-free
 *    chain of steps named v<from>_to_v<to>, each for a non-empty set of known
 *    drivers, each op carrying exactly its declared fields with bare names.
 * 2. Statically idempotent ops. A map_value whose target is also a source
 *    would change a value again on replay, so its from and to sets must be
 *    disjoint; a move into its own subtree is refused likewise.
 * 3. Replay. The reference interpreter below is a third implementation of the
 *    op semantics (after windows/infra/config_migrate.ahk and
 *    _shared/lua/config_migrate.lua). It decides every case's outcome, compares
 *    the migrated model with expected.toml and replays the steps on their own
 *    output, which must change nothing.
 * 4. Coverage floors. Every op kind, every outcome and every driver appears in
 *    the corpus, so a new op cannot ship without a case the three interpreters
 *    replay.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const TOML = require('smol-toml');
const { shared } = require('../lib/paths.cjs');

const REGISTRY_PATH = shared('core/config_schema/migrations.toml');
const CORPUS_DIR = shared('tests/corpus/config_migrations');

const DRIVERS = ['ahk', 'hs', 'linux'];
const OUTCOMES = ['migrated', 'current', 'newer', 'invalid', 'unsupported'];
const BARE = /^[A-Za-z0-9_-]+$/;

// Required and optional fields of each op of the closed set.
const OPS = {
	rename: { required: ['section', 'key'], optional: ['to_section', 'to_key'] },
	move_section: { required: ['section', 'to_section'], optional: [] },
	merge_into: { required: ['section', 'to_section'], optional: [] },
	map_value: { required: ['section', 'key', 'map'], optional: [] },
	delete: { required: ['section'], optional: ['key'] },
	set_if_absent: { required: ['section', 'key', 'value'], optional: [] }
};

const failures = [];

/**
 * Records one failure with its location.
 * @param {string} where - File or case the failure belongs to.
 * @param {string} message - What is wrong.
 */
function fail(where, message) {
	failures.push(`${where}: ${message}`);
}

// ==================================
// ==================================
// ======= 1/ Registry shape =======
// ==================================
// ==================================

/**
 * Whether a value is a TOML scalar the interpreters compare by type and value.
 * @param {*} value
 * @returns {boolean}
 */
function isScalar(value) {
	return ['string', 'boolean', 'number', 'bigint'].includes(typeof value);
}

/**
 * Whether a dotted section path is made of bare segments only.
 * @param {*} value
 * @returns {boolean}
 */
function isSectionPath(value) {
	return typeof value === 'string' && value.split('.').every((segment) => BARE.test(segment));
}

/**
 * Type-strict equality of two TOML values (numbers by value).
 * @param {*} left
 * @param {*} right
 * @returns {boolean}
 */
function sameValue(left, right) {
	const kind = (value) =>
		typeof value === 'bigint' ? 'number' : Array.isArray(value) ? 'array' : typeof value;
	if (kind(left) !== kind(right)) return false;
	if (Array.isArray(left)) {
		return (
			left.length === right.length && left.every((item, index) => sameValue(item, right[index]))
		);
	}
	if (left !== null && typeof left === 'object') {
		const keys = Object.keys(left).sort();
		const otherKeys = Object.keys(right).sort();
		return (
			keys.length === otherKeys.length &&
			keys.every((key, index) => key === otherKeys[index] && sameValue(left[key], right[key]))
		);
	}
	if (typeof left === 'bigint' || typeof right === 'bigint') return Number(left) === Number(right);
	return left === right;
}

/**
 * Validates one op against the closed set.
 * @param {object} op
 * @param {string} where
 */
function validateOp(op, where) {
	if (op === null || typeof op !== 'object' || Array.isArray(op))
		return fail(where, 'an op must be an inline table');
	const spec = OPS[op.op];
	if (!spec)
		return fail(where, `unknown op '${op.op}' (closed set: ${Object.keys(OPS).join(', ')})`);
	const allowed = new Set(['op', ...spec.required, ...spec.optional]);
	for (const field of Object.keys(op)) {
		if (!allowed.has(field)) fail(where, `${op.op} does not take '${field}'`);
	}
	for (const field of spec.required) {
		if (op[field] === undefined) fail(where, `${op.op} needs '${field}'`);
	}
	for (const field of ['section', 'to_section']) {
		if (op[field] !== undefined && !isSectionPath(op[field]))
			fail(where, `'${field}' must be a dotted path of bare segments`);
	}
	for (const field of ['key', 'to_key']) {
		if (op[field] !== undefined && !(typeof op[field] === 'string' && BARE.test(op[field]))) {
			fail(where, `'${field}' must be one bare segment`);
		}
	}
	if (op.op === 'rename') {
		if (op.to_section === undefined && op.to_key === undefined)
			fail(where, 'rename needs to_section or to_key');
		if ((op.to_section ?? op.section) === op.section && (op.to_key ?? op.key) === op.key) {
			fail(where, 'rename must change the section or the key');
		}
	}
	if (op.op === 'move_section' || op.op === 'merge_into') {
		const from = op.section;
		const to = op.to_section;
		// merge_into may fold a section into its own parent; a subtree move may not.
		const intoOwnSubtree = String(to).startsWith(`${from}.`);
		const outOfOwnParent = op.op === 'move_section' && String(from).startsWith(`${to}.`);
		if (from === to || intoOwnSubtree || outOfOwnParent) {
			fail(where, `${op.op} cannot move a section onto itself or across its own subtree`);
		}
	}
	if (op.op === 'map_value') {
		if (!Array.isArray(op.map) || op.map.length === 0)
			return fail(where, 'map_value needs a non-empty map');
		for (const pair of op.map) {
			if (
				pair === null ||
				typeof pair !== 'object' ||
				Object.keys(pair).sort().join(',') !== 'from,to'
			) {
				fail(where, 'each map entry is exactly { from, to }');
				continue;
			}
			if (!isScalar(pair.from) || !isScalar(pair.to))
				fail(where, 'map_value compares scalars only');
		}
		const froms = op.map.map((pair) => pair && pair.from);
		const tos = op.map.map((pair) => pair && pair.to);
		froms.forEach((from, index) => {
			if (froms.findIndex((other) => sameValue(other, from)) !== index)
				fail(where, 'map_value lists a from twice');
			if (tos.some((to) => sameValue(to, from))) {
				fail(where, 'map_value from and to sets must be disjoint, or a replay would map again');
			}
		});
	}
	if (op.op === 'set_if_absent') {
		const value = op.value;
		const ok = isScalar(value) || (Array.isArray(value) && value.every(isScalar));
		if (!ok) fail(where, 'set_if_absent writes a scalar or an array of scalars');
	}
}

/**
 * Validates a registry document and returns its ordered steps.
 * @param {object} doc - Parsed migrations.toml.
 * @param {string} where - Label for failures.
 * @returns {{current: number, unstamped: number, steps: object[]}|null}
 */
function validateRegistry(doc, where) {
	const registry = doc.registry;
	if (!registry || typeof registry !== 'object') {
		fail(where, 'missing [registry]');
		return null;
	}
	const current = registry.current_version;
	const unstamped = registry.unstamped_version;
	if (
		!Number.isInteger(current) ||
		!Number.isInteger(unstamped) ||
		unstamped < 1 ||
		current < unstamped
	) {
		fail(
			where,
			'current_version and unstamped_version must be integers with 1 <= unstamped <= current'
		);
		return null;
	}
	const unknownRoot = Object.keys(doc).filter((key) => key !== 'registry' && key !== 'steps');
	if (unknownRoot.length) fail(where, `unknown top-level tables: ${unknownRoot.join(', ')}`);
	const unknownRegistry = Object.keys(registry).filter(
		(key) => !['current_version', 'unstamped_version'].includes(key)
	);
	if (unknownRegistry.length) fail(where, `unknown [registry] keys: ${unknownRegistry.join(', ')}`);

	const named = Object.entries(doc.steps || {});
	const steps = [];
	for (const [name, step] of named) {
		const label = `${where} [steps.${name}]`;
		const allowed = ['from', 'to', 'drivers', 'reason', 'ops'];
		for (const field of Object.keys(step))
			if (!allowed.includes(field)) fail(label, `unknown field '${field}'`);
		if (!Number.isInteger(step.from) || step.to !== step.from + 1)
			fail(label, 'to must be from + 1');
		if (name !== `v${step.from}_to_v${step.to}`)
			fail(label, `must be named v${step.from}_to_v${step.to}`);
		if (!Array.isArray(step.drivers) || step.drivers.length === 0)
			fail(label, 'drivers must be a non-empty array');
		else {
			for (const driver of step.drivers)
				if (!DRIVERS.includes(driver)) fail(label, `unknown driver '${driver}'`);
			if (new Set(step.drivers).size !== step.drivers.length)
				fail(label, 'drivers lists a driver twice');
		}
		if (typeof step.reason !== 'string' || step.reason.trim() === '')
			fail(label, 'reason must be a non-empty string');
		if (!Array.isArray(step.ops)) fail(label, 'ops must be an array');
		else step.ops.forEach((op, index) => validateOp(op, `${label} op ${index + 1}`));
		steps.push(step);
	}
	steps.sort((left, right) => left.from - right.from);
	const expectedCount = current - unstamped;
	if (steps.length !== expectedCount)
		fail(
			where,
			`expected ${expectedCount} step(s) from v${unstamped} to v${current}, found ${steps.length}`
		);
	steps.forEach((step, index) => {
		if (step.from !== unstamped + index)
			fail(where, `the chain has a gap or overlap at v${step.from}`);
	});
	return { current, unstamped, steps };
}

// ==========================================
// ==========================================
// ======= 2/ Reference interpreter =======
// ==========================================
// ==========================================

/**
 * Flattens a parsed TOML document into Map<section, Map<key, value>>. Tables
 * become sections; scalars and arrays are values.
 * @param {object} doc
 * @returns {Map<string, Map<string, *>>}
 */
function flatten(doc) {
	const model = new Map();
	const walk = (node, prefix) => {
		const values = new Map();
		let hasChildTable = false;
		for (const [key, value] of Object.entries(node)) {
			if (
				value !== null &&
				typeof value === 'object' &&
				!Array.isArray(value) &&
				!(value instanceof Date)
			) {
				hasChildTable = true;
				walk(value, prefix === '' ? key : `${prefix}.${key}`);
			} else {
				values.set(key, value);
			}
		}
		if (values.size > 0 || (!hasChildTable && prefix !== '')) model.set(prefix, values);
	};
	walk(doc, '');
	return model;
}

/**
 * The model without sections that hold no key: an empty table and an absent
 * one are the same configuration.
 * @param {Map<string, Map<string, *>>} model
 * @returns {object}
 */
function normalized(model) {
	const out = {};
	for (const [section, values] of [...model.entries()].sort(([left], [right]) =>
		left.localeCompare(right)
	)) {
		if (values.size === 0) continue;
		out[section] = Object.fromEntries(
			[...values.entries()].sort(([left], [right]) => left.localeCompare(right))
		);
	}
	return out;
}

function cloneModel(model) {
	return new Map([...model.entries()].map(([section, values]) => [section, new Map(values)]));
}

function sectionsAtOrBelow(model, section) {
	return [...model.keys()]
		.filter((name) => name === section || name.startsWith(`${section}.`))
		.sort();
}

function dropIfEmpty(model, section) {
	if (model.has(section) && model.get(section).size === 0) model.delete(section);
}

/**
 * Moves one value; an existing target keeps its value.
 */
function moveValue(model, section, key, toSection, toKey) {
	const source = model.get(section);
	if (!source || !source.has(key)) return;
	const value = source.get(key);
	source.delete(key);
	if (!model.has(toSection)) model.set(toSection, new Map());
	const target = model.get(toSection);
	if (!target.has(toKey)) target.set(toKey, value);
}

/**
 * Applies one op of the closed set to the model.
 * @param {Map<string, Map<string, *>>} model
 * @param {object} op
 */
function applyOp(model, op) {
	switch (op.op) {
		case 'rename': {
			const toSection = op.to_section ?? op.section;
			moveValue(model, op.section, op.key, toSection, op.to_key ?? op.key);
			dropIfEmpty(model, op.section);
			dropIfEmpty(model, toSection);
			break;
		}
		case 'move_section': {
			for (const name of sectionsAtOrBelow(model, op.section)) {
				const suffix = name.slice(op.section.length);
				for (const key of [...model.get(name).keys()].sort())
					moveValue(model, name, key, op.to_section + suffix, key);
				model.delete(name);
				dropIfEmpty(model, op.to_section + suffix);
			}
			break;
		}
		case 'merge_into': {
			if (!model.has(op.section)) break;
			for (const key of [...model.get(op.section).keys()].sort())
				moveValue(model, op.section, key, op.to_section, key);
			model.delete(op.section);
			dropIfEmpty(model, op.to_section);
			break;
		}
		case 'map_value': {
			const values = model.get(op.section);
			if (!values || !values.has(op.key)) break;
			const pair = op.map.find((entry) => sameValue(entry.from, values.get(op.key)));
			if (pair) values.set(op.key, pair.to);
			break;
		}
		case 'delete': {
			if (op.key === undefined) {
				for (const name of sectionsAtOrBelow(model, op.section)) model.delete(name);
			} else if (model.has(op.section)) {
				model.get(op.section).delete(op.key);
				dropIfEmpty(model, op.section);
			}
			break;
		}
		case 'set_if_absent': {
			if (!model.has(op.section)) model.set(op.section, new Map());
			const values = model.get(op.section);
			if (!values.has(op.key)) values.set(op.key, op.value);
			break;
		}
		default:
			throw new Error(`unknown op ${op.op}`);
	}
}

/**
 * Runs the registry on a model for one driver.
 * @returns {{outcome: string, model?: Map, from?: number}}
 */
function migrate(model, registry, driver) {
	const meta = model.get('_meta');
	let version = registry.unstamped;
	if (meta && meta.has('schema_version')) {
		version = meta.get('schema_version');
		if (typeof version === 'bigint') version = Number(version);
		if (!Number.isInteger(version) || version < 1) return { outcome: 'invalid' };
	}
	if (version > registry.current) return { outcome: 'newer' };
	if (version === registry.current) return { outcome: 'current' };
	if (version < registry.unstamped) return { outcome: 'unsupported' };
	const out = cloneModel(model);
	for (const step of registry.steps) {
		if (step.from < version) continue;
		if (step.drivers.includes(driver)) for (const op of step.ops) applyOp(out, op);
	}
	if (!out.has('_meta')) out.set('_meta', new Map());
	out.get('_meta').set('schema_version', registry.current);
	return { outcome: 'migrated', model: out, from: version };
}

// ======================================
// ======================================
// ======= 3/ Registry and corpus =======
// ======================================
// ======================================

/**
 * Reads and parses a TOML file, recording a failure instead of throwing.
 * @param {string} file
 * @returns {object|null}
 */
function readToml(file) {
	try {
		return TOML.parse(fs.readFileSync(file, 'utf8'));
	} catch (error) {
		fail(path.relative(CORPUS_DIR, file) || file, `does not parse: ${error.message}`);
		return null;
	}
}

const shipped = validateRegistry(readToml(REGISTRY_PATH) || {}, 'migrations.toml');
if (shipped && shipped.steps.length === 0)
	fail('migrations.toml', 'the registry must hold at least one step');

const index = readToml(path.join(CORPUS_DIR, 'cases.toml'));
const listed = index && index.corpus && Array.isArray(index.corpus.cases) ? index.corpus.cases : [];
const onDisk = fs
	.readdirSync(CORPUS_DIR, { withFileTypes: true })
	.filter((entry) => entry.isDirectory())
	.map((entry) => entry.name)
	.sort();
if (JSON.stringify([...listed].sort()) !== JSON.stringify(onDisk)) {
	fail('cases.toml', `lists [${listed.join(', ')}] but the directories are [${onDisk.join(', ')}]`);
}
const MIN_CASES = 12;
if (onDisk.length < MIN_CASES)
	fail('corpus', `expected at least ${MIN_CASES} cases, found ${onDisk.length}`);

const seenOps = new Set();
const seenOutcomes = new Set();
const seenDrivers = new Set();
let replays = 0;

for (const name of onDisk) {
	const dir = path.join(CORPUS_DIR, name);
	const spec = readToml(path.join(dir, 'case.toml'));
	const meta = spec && spec.case;
	if (!meta) {
		fail(name, 'case.toml needs a [case] table');
		continue;
	}
	if (typeof meta.description !== 'string' || meta.description.trim() === '')
		fail(name, 'needs a description');
	if (!OUTCOMES.includes(meta.outcome)) fail(name, `unknown outcome '${meta.outcome}'`);
	if (
		!Array.isArray(meta.drivers) ||
		meta.drivers.length === 0 ||
		meta.drivers.some((driver) => !DRIVERS.includes(driver))
	) {
		fail(name, 'drivers must be a non-empty subset of ahk, hs, linux');
		continue;
	}
	seenOutcomes.add(meta.outcome);

	for (const file of ['input.toml', 'expected.toml']) {
		const full = path.join(dir, file);
		if (fs.existsSync(full) && /=\s*\{/.test(fs.readFileSync(full, 'utf8'))) {
			fail(name, `${file} uses an inline table, which the three parsers address differently`);
		}
	}

	const ownRegistryPath = path.join(dir, 'migrations.toml');
	const registry = fs.existsSync(ownRegistryPath)
		? validateRegistry(readToml(ownRegistryPath) || {}, `${name}/migrations.toml`)
		: shipped;
	if (!registry) continue;
	for (const step of registry.steps) for (const op of step.ops || []) seenOps.add(op.op);

	const input = readToml(path.join(dir, 'input.toml'));
	if (!input) continue;
	const expectedPath = path.join(dir, 'expected.toml');
	const hasExpected = fs.existsSync(expectedPath);
	if ((meta.outcome === 'migrated') !== hasExpected)
		fail(name, 'expected.toml is required for, and only for, outcome "migrated"');
	const expected = hasExpected ? readToml(expectedPath) : null;

	for (const driver of meta.drivers) {
		const result = migrate(flatten(input), registry, driver);
		replays += 1;
		if (result.outcome !== meta.outcome) {
			fail(name, `${driver}: outcome '${result.outcome}', case says '${meta.outcome}'`);
			continue;
		}
		if (result.outcome !== 'migrated' || !expected) continue;
		seenDrivers.add(driver);
		if (result.from !== meta.from_version || registry.current !== meta.to_version) {
			fail(
				name,
				`${driver}: crosses v${result.from} to v${registry.current}, case says v${meta.from_version} to v${meta.to_version}`
			);
		}
		const actual = normalized(result.model);
		const wanted = normalized(flatten(expected));
		if (!sameValue(actual, wanted)) {
			fail(
				name,
				`${driver}: migrated model differs from expected.toml\n    got      ${JSON.stringify(actual)}\n    expected ${JSON.stringify(wanted)}`
			);
		}
		const replayInput = cloneModel(result.model);
		replayInput.get('_meta').set('schema_version', meta.from_version);
		const replay = migrate(replayInput, registry, driver);
		if (replay.outcome !== 'migrated' || !sameValue(normalized(replay.model), actual)) {
			fail(
				name,
				`${driver}: replaying the steps on their own output changed it (ops must be idempotent)`
			);
		}
	}
}

for (const op of Object.keys(OPS))
	if (!seenOps.has(op)) fail('corpus', `no case exercises op '${op}'`);
for (const outcome of OUTCOMES)
	if (!seenOutcomes.has(outcome)) fail('corpus', `no case expects outcome '${outcome}'`);
for (const driver of DRIVERS)
	if (!seenDrivers.has(driver))
		fail('corpus', `no migrated case is replayed by driver '${driver}'`);
const MIN_REPLAYS = 30;
if (replays < MIN_REPLAYS)
	fail('corpus', `expected at least ${MIN_REPLAYS} driver replays, ran ${replays}`);

// ======================================
// ======================================
// ======= 4/ Interpreter wiring =======
// ======================================
// ======================================

const REGISTRY_RELATIVE = path.relative(shared(), REGISTRY_PATH).split(path.sep).join('/');

/**
 * Reads a repository file, recording a failure when it is missing.
 * @param {string} file - Absolute path.
 * @returns {string}
 */
function readSource(file) {
	if (!fs.existsSync(file)) {
		fail('wiring', `${path.relative(shared('..', '..', '..'), file)} is missing`);
		return '';
	}
	return fs.readFileSync(file, 'utf8');
}

// The Lua engine names the registry the drivers load, and both Lua suites
// replay the corpus through the shared contract with their own driver id.
const luaEngine = readSource(shared('lua/config_migrate.lua'));
if (!luaEngine.includes(`M.REGISTRY_PATH = "${REGISTRY_RELATIVE}"`)) {
	fail('wiring', `_shared/lua/config_migrate.lua must name the registry as "${REGISTRY_RELATIVE}"`);
}
if (
	!readSource(shared('lua/test/config_migrate_contract.lua')).includes(
		'/tests/corpus/config_migrations'
	)
) {
	fail('wiring', 'the shared Lua contract must replay tests/corpus/config_migrations');
}
// The Windows interpreter names the same registry, and the AHK suite that
// replays the corpus with the ahk driver id is one run_all.ahk actually runs.
const ahkEngine = readSource(shared('..', 'windows', 'infra', 'config_migrate.ahk'));
if (!ahkEngine.includes(`static Relative := "${REGISTRY_RELATIVE}"`)) {
	fail(
		'wiring',
		`windows/infra/config_migrate.ahk must name the registry as "${REGISTRY_RELATIVE}"`
	);
}
const ahkSuite = readSource(shared('..', 'windows', 'tests', 'unit', 'test_config_migrate.ahk'));
if (
	!ahkSuite.includes('\\tests\\corpus\\config_migrations') ||
	!ahkSuite.includes('_CMG_Has(Spec["drivers"], "ahk")')
) {
	fail(
		'wiring',
		'windows/tests/unit/test_config_migrate.ahk must replay the corpus for driver "ahk"'
	);
}
const runAll = readSource(shared('..', 'windows', 'tests', 'run_all.ahk'));
for (const include of [
	'#Include ../infra/config_migrate.ahk',
	'#Include unit/test_config_migrate.ahk'
]) {
	if (!runAll.split(/\r?\n/).includes(include)) {
		fail('wiring', `windows/tests/run_all.ahk must hold "${include}"`);
	}
}
for (const [driver, id] of [
	['macos', 'hs'],
	['linux', 'linux']
]) {
	const runner = readSource(
		shared('..', driver, 'tests', 'unit', 'infra', 'test_config_migrate.lua')
	);
	if (
		!runner.includes(
			`require("test.config_migrate_contract").register(helpers, { driver = "${id}" })`
		)
	) {
		fail(
			'wiring',
			`${driver}/tests/unit/infra/test_config_migrate.lua must register the contract for driver "${id}"`
		);
	}
}

if (failures.length) {
	console.error(`Config migration gate: ${failures.length} failure(s)`);
	for (const line of failures) console.error(`  - ${line}`);
	process.exit(1);
}
console.log(
	`Config migration gate: registry v${shipped.unstamped}..v${shipped.current} (${shipped.steps.length} step(s)), ${onDisk.length} corpus case(s), ${replays} driver replay(s) — OK`
);
