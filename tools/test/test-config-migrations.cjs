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
 * 5. Registry defects. The control of _shared/tests/corpus/
 *    config_migration_registries must pass this validator and every defect
 *    listed there must fail it; the Windows and Lua loaders replay the same
 *    files, so no registry can be valid on one driver and refused on another.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const TOML = require('smol-toml');
const { shared } = require('../lib/paths.cjs');

const REGISTRY_PATH = shared('core/config_schema/migrations.toml');
const CORPUS_DIR = shared('tests/corpus/config_migrations');
const DEFECTS_DIR = shared('tests/corpus/config_migration_registries');

const DRIVERS = ['ahk', 'hs', 'linux'];
const OUTCOMES = ['migrated', 'current', 'newer', 'invalid', 'unsupported'];
const BARE = /^[A-Za-z0-9_-]+$/;

// Required and optional fields of each op of the closed set.
const OPS = {
	rename: { required: ['section', 'key'], optional: ['to_section', 'to_key'] },
	copy_if_absent: { required: ['section', 'key'], optional: ['to_section', 'to_key'] },
	move_chord_action: {
		required: [
			'section',
			'key',
			'to_section',
			'action',
			'conditional_key',
			'disabled_action',
			'platform'
		],
		optional: []
	},
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
	for (const field of ['key', 'to_key', 'conditional_key']) {
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
	if (op.op === 'copy_if_absent' && op.to_section === undefined && op.to_key === undefined)
		fail(where, 'copy_if_absent needs to_section or to_key');
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
	if (op.op === 'move_chord_action') {
		if (op.platform !== 'macos') fail(where, 'move_chord_action requires platform macos');
		for (const field of ['action', 'disabled_action']) {
			if (typeof op[field] !== 'string' || !BARE.test(op[field]))
				fail(where, `${field} must be an action id`);
		}
		if (op.section === op.to_section) fail(where, 'move_chord_action must change section');
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
function flatten(doc, opaquePaths = new Set()) {
	const model = new Map();
	const walk = (node, prefix) => {
		const values = new Map();
		let hasChildTable = false;
		for (const [key, value] of Object.entries(node)) {
			if (
				value !== null &&
				typeof value === 'object' &&
				!Array.isArray(value) &&
				!(value instanceof Date) &&
				!opaquePaths.has(prefix === '' ? key : `${prefix}.${key}`)
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

/** Whether a target's entire namespace is absent, including its ancestors. */
function copyDestinationAbsent(model, section, key) {
	if (model.get(section)?.has(key)) return false;
	const segments = section.split('.');
	let parent = '';
	for (const segment of segments) {
		if (model.get(parent)?.has(segment)) return false;
		parent = parent === '' ? segment : `${parent}.${segment}`;
	}
	return sectionsAtOrBelow(model, `${section}.${key}`).length === 0;
}

/**
 * Applies one op of the closed set to the model.
 * @param {Map<string, Map<string, *>>} model
 * @param {object} op
 */
function chordActionSlot(value, catalogue, platformName) {
	if (
		!value ||
		typeof value !== 'object' ||
		Array.isArray(value) ||
		Object.keys(value).sort().join(',') !== 'key,mods' ||
		typeof value.key !== 'string' ||
		!Array.isArray(value.mods)
	)
		return null;
	const platform = catalogue.platforms[platformName];
	const aliases = new Map();
	for (const modifier of platform.modifiers) {
		aliases.set(modifier.id, modifier.id);
		aliases.set(modifier.hammerspoon, modifier.id);
	}
	const wanted = new Set();
	for (const modifier of value.mods) {
		const id = typeof modifier === 'string' && aliases.get(modifier.toLowerCase());
		if (!id || wanted.has(id)) return null;
		wanted.add(id);
	}
	const candidate = value.key.toLowerCase();
	const key = catalogue.keys.find((item) =>
		[item.id, item.chord_key ?? item.id, item.macos_key ?? item.id].includes(candidate)
	);
	if (!key) return null;
	const group = platform.shortcut_groups.find(
		(item) => item.modifiers.length === wanted.size && item.modifiers.every((id) => wanted.has(id))
	);
	return group ? group.prefix + key.id : null;
}

function moveChordAction(model, op, context) {
	const source = model.get(op.section);
	const childPath = op.section + '.' + op.key;
	const child = model.get(childPath);
	let value,
		childSource = false;
	if (source?.has(op.key)) value = source.get(op.key);
	else if (child) {
		if (sectionsAtOrBelow(model, childPath).length !== 1) return;
		value = Object.fromEntries(child);
		childSource = true;
	} else return;
	const catalogue = context?.modifier_chords;
	const actions = context?.assignable_actions;
	if (!catalogue?.platforms?.[op.platform]?.shortcut_groups || !actions)
		throw new Error('missing chord action context');
	if (!actions.has(op.action) || !actions.has(op.disabled_action))
		throw new Error('migration action is absent from action catalogue');
	const slot = value === false ? null : chordActionSlot(value, catalogue, op.platform);
	if ((value !== false && !slot) || slot === op.conditional_key) return;
	const target = model.get(op.to_section);
	const represented = (key) =>
		target?.has(key)
			? typeof target.get(key) === 'string' && actions.has(target.get(key))
			: copyDestinationAbsent(model, op.to_section, key);
	if (!represented(op.conditional_key) || (slot && !represented(slot))) return;
	if (!target) model.set(op.to_section, new Map());
	const destination = model.get(op.to_section);
	if (slot && !destination.has(slot)) destination.set(slot, op.action);
	if (!destination.has(op.conditional_key)) destination.set(op.conditional_key, op.disabled_action);
	if (childSource) model.delete(childPath);
	else {
		source.delete(op.key);
		dropIfEmpty(model, op.section);
	}
}

function applyOp(model, op, context) {
	switch (op.op) {
		case 'rename': {
			const toSection = op.to_section ?? op.section;
			moveValue(model, op.section, op.key, toSection, op.to_key ?? op.key);
			dropIfEmpty(model, op.section);
			dropIfEmpty(model, toSection);
			break;
		}
		case 'move_chord_action': {
			moveChordAction(model, op, context);
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
		case 'copy_if_absent': {
			const source = model.get(op.section);
			if (!source || !source.has(op.key)) break;
			const toSection = op.to_section ?? op.section;
			const toKey = op.to_key ?? op.key;
			if (!copyDestinationAbsent(model, toSection, toKey)) break;
			if (!model.has(toSection)) model.set(toSection, new Map());
			model.get(toSection).set(toKey, structuredClone(source.get(op.key)));
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
function migrate(model, registry, driver, context) {
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
		if (step.drivers.includes(driver)) for (const op of step.ops) applyOp(out, op, context);
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

// Derive the real macOS action identities from its authoritative generator
// model and the actual shared modifier matrix; no fixture action allowlist.
const actionGenerator = require('../codegen/codegen-action-catalogue.cjs');
const actionModel = actionGenerator.buildModel(
	actionGenerator.parseRegistry(fs.readFileSync(shared('modules/actions/actions.toml'), 'utf8')),
	'hs'
);
const modifierChords = JSON.parse(
	fs.readFileSync(shared('modules/actions/modifier_chords.json'), 'utf8')
);
const assignableActions = new Set(
	actionModel.sgItems.filter((item) => item.kind === 'action').map((item) => item.id)
);
for (const id of actionModel.axItems) assignableActions.add(id);
const modifiers = modifierChords.platforms.macos.modifiers;
for (let mask = 1; mask < 2 ** modifiers.length; mask += 1) {
	const ids = modifiers
		.filter((_, index) => Math.floor(mask / 2 ** index) % 2 === 1)
		.map((item) => item.id);
	for (const key of modifierChords.keys) assignableActions.add(ids.join('_') + '_' + key.id);
}
const migrationContext = { modifier_chords: modifierChords, assignable_actions: assignableActions };

// Inline tables remain opaque only at the exact source of the closed opcode.
// Every unrelated inline-table corpus record keeps the existing parser guard.
function opaqueChordPaths(source, registry, where) {
	const allowed = new Set(
		registry.steps.flatMap((step) =>
			step.ops.filter((op) => op.op === 'move_chord_action').map((op) => op.section + '.' + op.key)
		)
	);
	const paths = new Set();
	let section = '';
	for (const line of source.split('\n')) {
		const header = line.match(/^\s*\[([A-Za-z0-9_.-]+)\]\s*(?:#.*)?$/);
		if (header) section = header[1];
		const inline = line.match(/^\s*([A-Za-z0-9_-]+)\s*=\s*\{/);
		if (inline) {
			const path = section + '.' + inline[1];
			if (!allowed.has(path))
				fail(where, 'uses an unrelated inline table, which the three parsers address differently');
			else paths.add(path);
		} else if (/=\s*\{/.test(line))
			fail(where, 'uses an unrelated inline table, which the three parsers address differently');
	}
	return paths;
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
		const opaqueInput = opaqueChordPaths(
			fs.readFileSync(path.join(dir, 'input.toml'), 'utf8'),
			registry,
			name + '/input.toml'
		);
		const result = migrate(flatten(input, opaqueInput), registry, driver, migrationContext);
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
		const opaqueExpected = opaqueChordPaths(
			fs.readFileSync(expectedPath, 'utf8'),
			registry,
			name + '/expected.toml'
		);
		const wanted = normalized(flatten(expected, opaqueExpected));
		if (!sameValue(actual, wanted)) {
			fail(
				name,
				`${driver}: migrated model differs from expected.toml\n    got      ${JSON.stringify(actual)}\n    expected ${JSON.stringify(wanted)}`
			);
		}
		const replayInput = cloneModel(result.model);
		replayInput.get('_meta').set('schema_version', meta.from_version);
		const replay = migrate(replayInput, registry, driver, migrationContext);
		if (replay.outcome !== 'migrated' || !sameValue(normalized(replay.model), actual)) {
			fail(
				name,
				`${driver}: replaying the steps on their own output changed it (ops must be idempotent)`
			);
		}
	}
}

// Semantic file replay cannot detect shared references. Mutate actual copied
// values and compare untouched destinations with handwritten corpus expectations.
const copyDir = path.join(CORPUS_DIR, 'op_copy_if_absent');
const copyRegistry = validateRegistry(
	readToml(path.join(copyDir, 'migrations.toml')),
	'copy ownership registry'
);
const copyExpected = readToml(path.join(copyDir, 'expected.toml'));
if (copyRegistry && copyExpected) {
	for (const driver of DRIVERS) {
		const result = migrate(
			flatten(readToml(path.join(copyDir, 'input.toml'))),
			copyRegistry,
			driver
		);
		const source = result.model.get('source').get('records');
		const copied = result.model.get('destination').get('records');
		const sibling = result.model.get('sibling').get('records');
		source[0].palette[0].Key = 'edited source';
		source.push({ future: 'source only' });
		if (
			!sameValue(copied, copyExpected.destination.records) ||
			!sameValue(sibling, copyExpected.sibling.records)
		)
			fail('copy ownership', `${driver}: source edits changed a destination`);
		copied[0].palette[0].key = 'edited copy';
		copied[0].visible = true;
		if (
			source[0].palette[0].key !== 'lower' ||
			source[0].visible !== false ||
			!sameValue(sibling, copyExpected.sibling.records)
		)
			fail('copy ownership', `${driver}: destination edits changed the source or sibling`);
		result.model.get('source').get('rows')[0][0] = 99;
		if (!sameValue(result.model.get('destination').get('rows'), copyExpected.destination.rows))
			fail('copy ownership', `${driver}: nested copied arrays share children`);
	}
}

// This fixture's explicitly inline key is one flat value in both native
// interpreters. Keep that address here; generic flattening turns maps into
// sections and remains unsuitable for root inline values in other corpus cases.
const inlineChoices = readToml(
	path.join(CORPUS_DIR, 'copy_preserves_occupied_namespaces', 'inline_ancestor.toml')
);
if (inlineChoices) {
	const model = new Map([
		['source', new Map(Object.entries(inlineChoices.source))],
		['settings', new Map(Object.entries(inlineChoices.settings))]
	]);
	const expected = structuredClone(normalized(model));
	applyOp(model, {
		op: 'copy_if_absent',
		section: 'source',
		key: 'choice',
		to_section: 'settings.inline.deep',
		to_key: 'child'
	});
	applyOp(model, {
		op: 'copy_if_absent',
		section: 'source',
		key: 'choice',
		to_section: 'settings',
		to_key: 'inline'
	});
	if (!sameValue(normalized(model), expected))
		fail('copy occupied namespace', 'the inline ancestor or source choice changed');
}

// The generic corpus guard still rejects unrelated inline tables. This actual
// native-addressed supplementary file pins occupied inline destination bytes.
{
	const dir = path.join(CORPUS_DIR, 'op_move_chord_scalar_ancestor');
	const registry = validateRegistry(
		readToml(path.join(dir, 'migrations.toml')),
		'chord inline ancestor'
	);
	const model = flatten(
		readToml(path.join(dir, 'inline_ancestor.toml')),
		new Set(['hotstrings.editor.shortcut', 'shortcuts.keyboard'])
	);
	applyOp(model, registry.steps[0].ops[0], migrationContext);
	const wanted = {
		'hotstrings.editor': { shortcut: { mods: ['ctrl'], key: 'd' } },
		shortcuts: { keyboard: { magic_editor: 'none', future: false } }
	};
	if (!sameValue(normalized(model), wanted))
		fail('chord inline ancestor', 'complete source and occupied inline choice must survive');
}
{
	const model = new Map([['hotstrings.editor', new Map([['shortcut', false]])]]);
	const op = {
		op: 'move_chord_action',
		section: 'hotstrings.editor',
		key: 'shortcut',
		to_section: 'shortcuts.keyboard',
		action: 'open_hotstrings_editor',
		conditional_key: 'magic_editor',
		disabled_action: 'none',
		platform: 'macos'
	};
	let refused = false;
	try {
		applyOp(model, op);
	} catch (error) {
		refused = error.message.includes('missing chord action context');
	}
	if (!refused || !sameValue(normalized(model), { 'hotstrings.editor': { shortcut: false } }))
		fail(
			'chord missing context',
			'context refusal must preserve the exact typed source without partial writes'
		);
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

// The registry-defect corpus: the control registry must be accepted and every
// listed defect rejected, here and by the Lua and Windows loaders, which replay
// the same files. A defect this validator let through would be one a driver
// may accept while another refuses it.

/**
 * The failures validateRegistry records for one document, taken back out of
 * the gate's own list: a defect case is expected to fail.
 * @param {object} doc - Parsed registry.
 * @param {string} where - Label for the failures.
 * @returns {string[]}
 */
function registryDefects(doc, where) {
	const before = failures.length;
	validateRegistry(doc, where);
	return failures.splice(before);
}

const MIN_DEFECT_CASES = 20;
const defectIndex = readToml(path.join(DEFECTS_DIR, 'cases.toml'));
const defectCorpus = (defectIndex && defectIndex.corpus) || {};
const rejectedCases = Array.isArray(defectCorpus.rejected) ? defectCorpus.rejected : [];
const defectFiles = fs
	.readdirSync(DEFECTS_DIR)
	.filter((file) => file.endsWith('.toml') && file !== 'cases.toml')
	.map((file) => file.slice(0, -'.toml'.length))
	.sort();
if (
	JSON.stringify([defectCorpus.control, ...rejectedCases].sort()) !== JSON.stringify(defectFiles)
) {
	fail(
		'config_migration_registries/cases.toml',
		`declares control "${defectCorpus.control}" and [${rejectedCases.join(', ')}] but the files are [${defectFiles.join(', ')}]`
	);
}
if (rejectedCases.length < MIN_DEFECT_CASES) {
	fail(
		'config_migration_registries',
		`expected at least ${MIN_DEFECT_CASES} rejected registries, found ${rejectedCases.length}`
	);
}
if (typeof defectCorpus.control === 'string') {
	const control = readToml(path.join(DEFECTS_DIR, `${defectCorpus.control}.toml`));
	const defects = control ? registryDefects(control, 'control') : [];
	if (defects.length) {
		fail('config_migration_registries/control.toml', `must be accepted: ${defects.join('; ')}`);
	}
}
for (const name of rejectedCases) {
	const doc = readToml(path.join(DEFECTS_DIR, `${name}.toml`));
	if (doc && registryDefects(doc, name).length === 0) {
		fail(
			`config_migration_registries/${name}.toml`,
			'the reference validator accepts it; every interpreter must reject it'
		);
	}
}

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
const luaContract = readSource(shared('lua/test/config_migrate_contract.lua'));
for (const corpus of ['config_migrations', 'config_migration_registries']) {
	if (!luaContract.includes(`/tests/corpus/${corpus}"`)) {
		fail('wiring', `the shared Lua contract must replay tests/corpus/${corpus}`);
	}
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
	!ahkSuite.includes('\\tests\\corpus\\config_migrations"') ||
	!ahkSuite.includes('_CMG_Has(Spec["drivers"], "ahk")')
) {
	fail(
		'wiring',
		'windows/tests/unit/test_config_migrate.ahk must replay the corpus for driver "ahk"'
	);
}
if (!ahkSuite.includes('\\tests\\corpus\\config_migration_registries"')) {
	fail(
		'wiring',
		'windows/tests/unit/test_config_migrate.ahk must replay tests/corpus/config_migration_registries'
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
	`Config migration gate: registry v${shipped.unstamped}..v${shipped.current} (${shipped.steps.length} step(s)), ${onDisk.length} corpus case(s), ${replays} driver replay(s), ${rejectedCases.length} rejected registry defect(s) — OK`
);
