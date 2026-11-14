// tools/codegen/codegen-layout-editor-export-assets-js.cjs

/**
 * ==============================================================================
 * MODULE: Layout Editor Export Assets Codegen
 * DESCRIPTION:
 * Generates `_shared/ui/layout_editor/_generated/export_assets.js`, a classic
 * script defining `LayoutExportAssetData`: the text of every Lua module the
 * page's XKB and KLC exports run (LayoutLuaRunner.MODULES) and the XKB
 * converter data (static/ergopti/linux/xkb_generation/data). The layout editor
 * window of the three drivers loads it with the page, so ErgoptiPlus builds
 * both downloads offline from the files it ships, as the site does from the
 * files it serves (standalone.js).
 *
 * FEATURES & RATIONALE:
 * 1. One module list: the names come from lua_runner.js itself, run in a vm.
 * 2. Verbatim: every text crosses as a JSON string; `</` is escaped so a
 *    driver that inlines the script into its document cannot close the tag.
 * 3. Deterministic: no timestamp; the keys keep the MODULES order.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { shared, REPO_ROOT } = require('../lib/paths.cjs');

const RUNNER_PATH = shared('ui', 'layout_editor', 'lua_runner.js');
const XKB_DATA = path.join(REPO_ROOT, 'static', 'ergopti', 'linux', 'xkb_generation', 'data');
const OUT_PATH = shared('ui', 'layout_editor', '_generated', 'export_assets.js');

/**
 * The Lua module names the page's export runner loads.
 * @returns {{MODULES: string[], modulePath: function(string): string}}
 */
function runner() {
	const context = vm.createContext({});
	vm.runInContext(fs.readFileSync(RUNNER_PATH, 'utf8'), context, { filename: RUNNER_PATH });
	return vm.runInContext(
		'({ MODULES: [...LayoutLuaRunner.MODULES], modulePath: LayoutLuaRunner.modulePath })',
		context
	);
}

/** A JSON literal that cannot end an inline script element. */
function literal(value, indent) {
	return JSON.stringify(value, null, indent).replace(/<\//g, '<\\/');
}

/**
 * Builds the complete generated file.
 * @returns {string} JS source with LF line ends and a final newline.
 */
function buildSource() {
	const { MODULES, modulePath } = runner();
	const sources = {};
	for (const name of MODULES) sources[name] = fs.readFileSync(shared(modulePath(name)), 'utf8');
	const data = {
		sources,
		keysyms: JSON.parse(fs.readFileSync(path.join(XKB_DATA, 'key_sym.json'), 'utf8')),
		template: fs.readFileSync(path.join(XKB_DATA, 'xkb_symbols.txt'), 'utf8'),
		types: fs.readFileSync(path.join(XKB_DATA, 'xkb_types.txt'), 'utf8')
	};
	const relative = (file) => path.relative(REPO_ROOT, file).split(path.sep).join('/');
	return [
		'// _shared/ui/layout_editor/_generated/export_assets.js',
		'',
		'// ==========================================',
		'// AUTO-GENERATED — do not edit manually',
		`// Sources: the LayoutLuaRunner.MODULES of ${relative(RUNNER_PATH)}, ${relative(XKB_DATA)}`,
		'// Run: npm run codegen:layout-editor-export-assets:js',
		'// ==========================================',
		'',
		'// What the layout editor window runs for its XKB and KLC downloads, offline.',
		`var LayoutExportAssetData = ${literal(data, '\t')};`,
		''
	].join('\n');
}

/** Writes the generated file. */
function main() {
	console.log(
		'codegen:layout-editor-export-assets:js — bundling the export assets for the layout editor…'
	);
	fs.mkdirSync(path.dirname(OUT_PATH), { recursive: true });
	fs.writeFileSync(OUT_PATH, buildSource());
	console.log(`codegen:layout-editor-export-assets:js — wrote ${OUT_PATH}`);
}

if (require.main === module) main();

module.exports = { buildSource, OUT_PATH };
