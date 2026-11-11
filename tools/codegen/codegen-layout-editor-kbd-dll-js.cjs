// tools/codegen/codegen-layout-editor-kbd-dll-js.cjs

/**
 * ==============================================================================
 * MODULE: Layout Editor Keyboard DLL Writer Codegen
 * DESCRIPTION:
 * Generates `_shared/ui/layout_editor/_generated/kbd_dll_writer.js`, the
 * repository tool's Windows keyboard layout DLL writer (tools/lib/kbd-dll:
 * constants, model, emit-c, source and pe-writer) as a classic script defining
 * `LayoutKbdDll`, so the layout editor page builds the same four DLL images the
 * tool writes with `--writer pe`, with no compiler.
 *
 * FEATURES & RATIONALE:
 * 1. Verbatim: each module's text is wrapped, never rewritten, in a CommonJS
 *    shim; a module may require only the others, and the two files the tool
 *    reads from the repository (node:fs, ../paths.cjs) are refused in the page,
 *    where the physical-key table is passed instead.
 * 2. Deterministic: no timestamp, modules in a fixed order.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { shared, REPO_ROOT } = require('../lib/paths.cjs');

const LIB = path.join(REPO_ROOT, 'tools', 'lib', 'kbd-dll');
// Each module and the modules it may require, in load order.
const MODULES = Object.freeze([
	{ file: 'constants.cjs', requires: [] },
	{ file: 'model.cjs', requires: ['./constants.cjs'] },
	{ file: 'emit-c.cjs', requires: ['./constants.cjs', './model.cjs'] },
	{ file: 'source.cjs', requires: ['./constants.cjs', './model.cjs', 'node:fs', '../paths.cjs'] },
	{ file: 'pe-writer.cjs', requires: ['./constants.cjs', './model.cjs', './emit-c.cjs'] }
]);
// Required only to read the repository; the page passes physicalKeys instead.
const REPOSITORY_ONLY = Object.freeze(['node:fs', '../paths.cjs']);
const OUT_PATH = shared('ui', 'layout_editor', '_generated', 'kbd_dll_writer.js');

/** The module names one source text requires. */
function requiresOf(text) {
	return [...text.matchAll(/\brequire\(\s*'([^']+)'\s*\)/g)].map((m) => m[1]);
}

/**
 * Builds the complete generated file.
 * @returns {string} JS source with LF line ends and a final newline.
 */
function buildSource() {
	const lines = [
		'// _shared/ui/layout_editor/_generated/kbd_dll_writer.js',
		'',
		'// ==========================================',
		'// AUTO-GENERATED — do not edit manually',
		`// Sources: tools/lib/kbd-dll/{${MODULES.map((m) => m.file).join(',')}}`,
		'// Run: npm run codegen:layout-editor-kbd-dll:js',
		'// ==========================================',
		'',
		"// The repository tool's Windows keyboard layout DLL writer, loaded by the layout editor page.",
		'var LayoutKbdDll = (function () {',
		'\tvar loaded = {};',
		'\tvar factories = {};',
		'\tfunction load(name) {',
		`\t\tif (${JSON.stringify(REPOSITORY_ONLY)}.indexOf(name) >= 0)`,
		"\t\t\tthrow new Error(name + ' reads the repository; pass physicalKeys in the page');",
		"\t\tif (!factories[name]) throw new Error('kbd dll module not bundled: ' + name);",
		'\t\tif (!loaded[name]) {',
		'\t\t\tvar module = { exports: {} };',
		'\t\t\tloaded[name] = module;',
		'\t\t\tfactories[name](module, module.exports, load);',
		'\t\t}',
		'\t\treturn loaded[name].exports;',
		'\t}'
	];
	for (const entry of MODULES) {
		const file = path.join(LIB, entry.file);
		const text = fs.readFileSync(file, 'utf8');
		const unexpected = requiresOf(text).filter((name) => !entry.requires.includes(name));
		if (unexpected.length)
			throw new Error(`${file} requires ${unexpected.join(', ')}; the page cannot load it`);
		lines.push(
			`\tfactories['./${entry.file}'] = function (module, exports, require) {`,
			text.replace(/\n$/, ''),
			'\t};'
		);
	}
	lines.push(
		"\tvar Source = load('./source.cjs');",
		"\tvar Writer = load('./pe-writer.cjs');",
		'\treturn {',
		"\t\tModel: load('./model.cjs'),",
		'\t\tfromSource: Source.fromSource,',
		'\t\twriteDlls: Writer.writeDlls,',
		'\t\tIMAGES: Writer.IMAGES',
		'\t};',
		'})();',
		''
	);
	return lines.join('\n');
}

/** Writes the generated file. */
function main() {
	console.log('codegen:layout-editor-kbd-dll:js — wrapping the DLL writer for the layout editor…');
	fs.mkdirSync(path.dirname(OUT_PATH), { recursive: true });
	fs.writeFileSync(OUT_PATH, buildSource());
	console.log(`codegen:layout-editor-kbd-dll:js — wrote ${OUT_PATH}`);
}

if (require.main === module) main();

module.exports = { buildSource, OUT_PATH, MODULES };
