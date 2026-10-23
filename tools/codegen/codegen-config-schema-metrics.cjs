// tools/codegen/codegen-config-schema-metrics.cjs

/**
 * ==============================================================================
 * MODULE: Config Schema Metrics Codegen
 * DESCRIPTION:
 * Regenerates the `metrics` definition of `config.schema.json` from the
 * `[[features.metrics]]` entries of the shared feature manifest.
 *
 * ROOT CAUSE ENCODED:
 * The hand-written definition required `enabled`, listed keys no driver writes
 * (`show_wpm_menubar`, `menubar{}`, `float{}`), omitted real ones
 * (`wpm_widget_*`) and set `additionalProperties: true`, so it validated
 * nothing: a misspelled metrics key passed the gate on all three drivers. The
 * manifest already declares every metrics key with its type, so the schema now
 * derives from it and rejects anything it does not declare.
 *
 * FEATURES & RATIONALE:
 * 1. One source: property names and types come from the manifest only.
 * 2. Text splice: the rest of the schema file keeps its hand-written layout;
 *    only the `metrics` definition block between its two markers is replaced.
 * 3. Check mode: `--check` fails when the committed block differs, for the
 *    drift test.
 *
 * USAGE:  node tools/codegen/codegen-config-schema-metrics.cjs [--check]
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const MANIFEST = path.join(SHARED, 'modules', 'features', 'manifest.toml');
const SCHEMA = path.join(SHARED, 'core', 'config_schema', 'config.schema.json');

// The block starts at the definition (two tabs deep, under $defs) and ends at
// the first closing brace at the same depth.
const BLOCK_START = '\t\t"metrics": {\n\t\t\t"type": "object",';
const BLOCK_END = '\n\t\t},\n';

/**
 * JSON-Schema fragment for one manifest value type.
 * @param {string} id Entry id, for the error message.
 * @param {string} type Manifest type.
 * @returns {string} Inline JSON fragment.
 */
function fragmentFor(id, type) {
	if (type === 'boolean') return '{ "type": "boolean" }';
	if (type === 'number') return '{ "type": "number" }';
	if (type === 'string') return '{ "type": "string" }';
	if (type === 'array') return '{ "type": "array", "items": { "type": "string" } }';
	throw new Error(`metrics.${id}: no schema fragment for manifest type "${type}"`);
}

/**
 * Builds the generated definition block.
 * @param {object[]} entries The manifest's `features.metrics` entries.
 * @returns {string} The block text, ending with the closing brace line.
 */
function buildBlock(entries) {
	const seen = new Set();
	const lines = [];
	for (const entry of entries) {
		if (typeof entry.id !== 'string' || entry.id === '') {
			throw new Error('a metrics manifest entry has no id');
		}
		if (seen.has(entry.id)) throw new Error(`metrics.${entry.id} is declared twice`);
		seen.add(entry.id);
		lines.push(`\t\t\t\t"${entry.id}": ${fragmentFor(entry.id, entry.type)}`);
	}
	if (lines.length === 0) throw new Error('the manifest declares no metrics entry');
	return (
		'\t\t"metrics": {\n' +
		'\t\t\t"type": "object",\n' +
		'\t\t\t"additionalProperties": false,\n' +
		'\t\t\t"properties": {\n' +
		lines.join(',\n') +
		'\n\t\t\t}\n' +
		'\t\t},\n'
	);
}

/**
 * Replaces the metrics definition inside the schema text.
 * @param {string} schemaText Current schema file content.
 * @param {string} block Generated block.
 * @returns {string} Updated schema text.
 */
function splice(schemaText, block) {
	const start = schemaText.indexOf(BLOCK_START);
	if (start < 0 || schemaText.indexOf(BLOCK_START, start + 1) >= 0) {
		throw new Error('config.schema.json must contain exactly one metrics definition block');
	}
	const end = schemaText.indexOf(BLOCK_END, start);
	if (end < 0) throw new Error('the metrics definition block has no closing brace');
	return schemaText.slice(0, start) + block + schemaText.slice(end + BLOCK_END.length);
}

/**
 * Computes the schema text the manifest implies.
 * @returns {{current: string, next: string}} Committed and regenerated text.
 */
function generate() {
	const manifest = toml.parse(fs.readFileSync(MANIFEST, 'utf8'));
	const current = fs.readFileSync(SCHEMA, 'utf8');
	const next = splice(current, buildBlock(manifest.features.metrics));
	JSON.parse(next);
	return { current, next };
}

if (require.main === module) {
	const { current, next } = generate();
	if (process.argv.includes('--check')) {
		if (current !== next) {
			console.error(
				'config.schema.json metrics is stale: run npm run codegen:config-schema-metrics'
			);
			process.exit(1);
		}
		console.log('config.schema.json metrics matches the manifest.');
	} else if (current === next) {
		console.log('config.schema.json metrics already matches the manifest.');
	} else {
		fs.writeFileSync(SCHEMA, next);
		console.log(`wrote ${path.relative(ROOT, SCHEMA)}`);
	}
}

module.exports = { buildBlock, splice, generate };
