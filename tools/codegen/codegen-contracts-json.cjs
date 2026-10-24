// tools/codegen/codegen-contracts-json.cjs

/**
 * ==============================================================================
 * MODULE: Port Contracts JSON Generator
 * DESCRIPTION:
 * Emits static/ergopti_plus/_shared/core/ports/contracts.json from the authoritative
 * portContract definitions in _shared/core/ports/*.spec.js. This collapses the four
 * hand-maintained method/arity mirrors (the macOS PORT_CONTRACTS Lua table, the
 * AHK ADAPTER_* maps, and the JS HS_ADAPTERS stubs) into a single machine
 * readable source that every driver's compliance test can read at runtime.
 *
 * FEATURES & RATIONALE:
 * 1. Single source of truth: the spec.js files remain the human-authored
 *    contract; this script is a pure projection of their portContract.methods
 *    into language-neutral JSON. A method/arity change in one spec.js now flows
 *    to AHK + macOS + Linux compliance automatically.
 * 2. Deterministic output: ports and methods are emitted in sorted order so the
 *    committed JSON only changes when a contract actually changes — making the
 *    "generated files up to date" CI gate meaningful.
 * 3. Zero side channels: the specs are plain CommonJS modules, so we require()
 *    them directly rather than eval-parsing — no fragile text scraping.
 * 4. Closed log vocabulary: the `reason`, `phase`, `[TAG]` and evidence-field
 *    enums of _shared/modules/logger/vocabulary.json are projected beside the
 *    ports as `enums`, so every driver's compliance tooling reads the same
 *    closed sets the logger gate enforces. A malformed, duplicated or unsorted
 *    enum fails here, before any gate could compare a driver against it.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { shared, sharedRel } = require('../lib/paths.cjs');
const { loadCjsModule } = require('../lib/load-cjs-module.cjs');

const PORTS_DIR = shared('core/ports');
const OUTPUT_PATH = path.join(PORTS_DIR, 'contracts.json');
const VOCABULARY_REL = 'modules/logger/vocabulary.json';

// The shape each closed enum's members must have. Reasons, phases and fields
// are lower-case codes (an empty reason or phase is the "none" sentinel); tags are
// the upper-case words written between brackets.
const ENUM_MEMBER_SHAPES = {
	reason: /^(?:|[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*)$/,
	phase: /^(?:|[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*)$/,
	log_tag: /^[A-Z][A-Z0-9]*(?:[-_][A-Z0-9]+)*$/,
	evidence_field: /^[a-z][a-z0-9_]*$/
};

// ==================================================
// ==================================================
// ======= 1/ Spec Discovery & Projection ===========
// ==================================================
// ==================================================

/**
 * Loads a spec.js as a CommonJS module despite the repo being ESM ("type":
 * "module" makes bare .js files ESM, so require() rejects their module.exports).
 *
 * The loader lives in tools/lib now rather than here. It was private to this
 * file, and that mattered: 32 shared modules export only via module.exports, and
 * the ones with no consumer carrying a copy of this shim — the whole
 * modules/tooltip/ set — were unreachable from every tool in the repo. Their
 * "source of truth" functions could not be called by the gate that claimed to
 * compare against them.
 * @param {string} specPath Absolute path to a *.spec.js file.
 * @returns {object} The module.exports of the spec.
 */
function loadSpec(specPath) {
	return loadCjsModule(specPath);
}

/**
 * Loads every *.spec.js port contract and projects it into a plain object.
 * @returns {{ports: Object}} The language-neutral contract registry.
 */
function buildContracts() {
	const specFiles = fs
		.readdirSync(PORTS_DIR)
		.filter((f) => f.endsWith('.spec.js'))
		.sort();

	const ports = {};
	for (const file of specFiles) {
		const specPath = path.join(PORTS_DIR, file);
		// The specs are CommonJS-style modules exporting { portContract, ... }.
		const mod = loadSpec(specPath);
		const contract = mod && mod.portContract;
		if (!contract || typeof contract !== 'object') {
			throw new Error(`${file}: does not export a portContract object`);
		}
		if (!contract.name || !contract.methods) {
			throw new Error(`${file}: portContract missing name or methods`);
		}

		// Re-emit methods in sorted key order for deterministic output.
		const methods = {};
		for (const methodName of Object.keys(contract.methods).sort()) {
			const spec = contract.methods[methodName];
			methods[methodName] = {
				arity: spec.arity,
				required: spec.required !== false
			};
		}

		ports[contract.name] = {
			version: contract.version || '1.0.0',
			methods
		};
	}

	// Sort ports alphabetically for a stable on-disk ordering.
	const sortedPorts = {};
	for (const name of Object.keys(ports).sort()) {
		sortedPorts[name] = ports[name];
	}
	return { ports: sortedPorts };
}

/**
 * Reads and validates the closed log vocabulary.
 * @returns {Object<string, string[]>} One sorted member list per enum.
 */
function buildEnums() {
	const vocabulary = JSON.parse(fs.readFileSync(shared(VOCABULARY_REL), 'utf8'));
	const enums = {};
	for (const [name, shape] of Object.entries(ENUM_MEMBER_SHAPES)) {
		const members = vocabulary[name];
		if (!Array.isArray(members) || members.length === 0)
			throw new Error(`${VOCABULARY_REL}: "${name}" must be a non-empty list`);
		members.forEach((member, index) => {
			if (typeof member !== 'string' || !shape.test(member))
				throw new Error(`${VOCABULARY_REL}: ${name} member ${JSON.stringify(member)} is malformed`);
			if (index > 0 && !(members[index - 1] < member))
				throw new Error(
					`${VOCABULARY_REL}: ${name} must be sorted and unique (${JSON.stringify(members[index - 1])} ` +
						`before ${JSON.stringify(member)})`
				);
		});
		enums[name] = [...members];
	}
	return enums;
}

// ==================================================
// ==================================================
// ======= 2/ Emit ==================================
// ==================================================
// ==================================================

/**
 * Serialises the contracts to JSON with a leading do-not-edit banner.
 * @param {{ports: Object}} contracts
 * @param {Object<string, string[]>} enums The closed log vocabulary.
 * @returns {string}
 */
function serialise(contracts, enums) {
	const payload = {
		_generated: 'GENERATED by tools/codegen/codegen-contracts-json.cjs — DO NOT EDIT.',
		_source: sharedRel('core/ports/*.spec.js'),
		_enums_source: sharedRel(VOCABULARY_REL),
		_regenerate: 'npm run codegen:contracts',
		port_count: Object.keys(contracts.ports).length,
		ports: contracts.ports,
		enums
	};
	return JSON.stringify(payload, null, '\t') + '\n';
}

function main() {
	const contracts = buildContracts();
	const out = serialise(contracts, buildEnums());
	fs.writeFileSync(OUTPUT_PATH, out, 'utf8');
	process.stdout.write(
		`codegen:contracts — wrote ${Object.keys(contracts.ports).length} port contract(s) to ${path.relative(process.cwd(), OUTPUT_PATH)}\n`
	);
}

if (require.main === module) {
	main();
}

module.exports = { buildContracts, buildEnums, serialise, ENUM_MEMBER_SHAPES };
