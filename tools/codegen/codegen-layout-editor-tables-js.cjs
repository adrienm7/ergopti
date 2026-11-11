// tools/codegen/codegen-layout-editor-tables-js.cjs

/**
 * ==============================================================================
 * MODULE: Layout Editor Key Tables Codegen
 * DESCRIPTION:
 * Generates `_shared/ui/layout_editor/_generated/key_tables.js`, the three key
 * tables the layout source compiler (layout_composer/source_compiler.js) takes
 * as its `tables` argument, so the layout editor page compiles a source the
 * way the Node tooling does (tools/lib/layout-source.cjs keyTables()):
 *   - _shared/modules/layouts/mac_keycodes.json (macKeycodes);
 *   - _shared/data/keycodes/physical_keys.json (physicalKeys);
 *   - _shared/data/keycodes/hid_usages.json (hidUsages).
 *
 * FEATURES & RATIONALE:
 * 1. Classic script: the macOS and Linux hosts inline the page, which cannot
 *    fetch file:// JSON, so the tables are a top-level const.
 * 2. Verbatim: each table is the parsed owner file, unchanged, so the page and
 *    the tooling compile from the same data.
 * 3. Deterministic: no timestamp.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { shared, sharedRel } = require('../lib/paths.cjs');

const OUT_PATH = shared('ui', 'layout_editor', '_generated', 'key_tables.js');
const TABLES = [
	['macKeycodes', 'modules/layouts/mac_keycodes.json'],
	['physicalKeys', 'data/keycodes/physical_keys.json'],
	['hidUsages', 'data/keycodes/hid_usages.json']
];

/**
 * The three tables, parsed from their owners.
 * @returns {{macKeycodes: object, physicalKeys: object, hidUsages: object}}
 */
function buildData() {
	const data = {};
	for (const [name, file] of TABLES) data[name] = JSON.parse(fs.readFileSync(shared(file), 'utf8'));
	return data;
}

/**
 * Builds the complete generated file.
 * @returns {string} JS source with LF line ends and a final newline.
 */
function buildSource() {
	const data = buildData();
	const lines = [
		'// _shared/ui/layout_editor/_generated/key_tables.js',
		'',
		'// ==========================================',
		'// AUTO-GENERATED — do not edit manually',
		...TABLES.map(([, file]) => `// Source: ${sharedRel(file)}`),
		'// Run: npm run codegen:layout-editor-tables:js',
		'// ==========================================',
		'',
		'// The key tables the layout source compiler takes, as the tooling reads them.',
		'// Loaded by a <script> tag before the layout editor scripts.',
		'const LAYOUT_SOURCE_TABLES = {',
		TABLES.map(([name]) => `\t"${name}": ${JSON.stringify(data[name])}`).join(',\n'),
		'};',
		''
	];
	return lines.join('\n');
}

/** Writes the generated file. */
function main() {
	console.log('codegen:layout-editor-tables:js — generating the layout editor key tables…');
	fs.mkdirSync(path.dirname(OUT_PATH), { recursive: true });
	fs.writeFileSync(OUT_PATH, buildSource());
	console.log(`codegen:layout-editor-tables:js — wrote ${OUT_PATH}`);
}

if (require.main === module) main();

module.exports = { buildData, buildSource, OUT_PATH };
