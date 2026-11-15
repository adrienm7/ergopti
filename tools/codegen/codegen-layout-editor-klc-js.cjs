// tools/codegen/codegen-layout-editor-klc-js.cjs

/**
 * ==============================================================================
 * MODULE: Layout Editor KLC Generator Codegen
 * DESCRIPTION:
 * Generates `_shared/ui/layout_editor/_generated/klc_generator.js`, the MSKLC
 * generator the repository tool uses (tools/codegen/lib/windows-keyboard-layout.cjs)
 * as a classic script defining `LayoutKlcGenerator`, so the layout editor page
 * writes the same `.klc` the tool writes (_shared/ui/layout_composer/target_export.js
 * calls it in both).
 *
 * FEATURES & RATIONALE:
 * 1. Verbatim: the module text is wrapped, never rewritten, inside a CommonJS
 *    shim; it may require only the dependency-free helpers HELPERS lists,
 *    each wrapped the same way, which the wrapper checks.
 * 2. The page encodes the text with LayoutTargetExport.encodeKlc; the module's
 *    own encodeKlc needs Node's Buffer and is not called there.
 * 3. Deterministic: no timestamp.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { shared, REPO_ROOT } = require('../lib/paths.cjs');

const SOURCE_PATH = path.join(__dirname, 'lib', 'windows-keyboard-layout.cjs');
// The modules the generator may require, by the name it requires them with; each
// requires nothing itself.
const HELPERS = Object.freeze({
	'../../lib/kbd-dll/shortcut-keys.cjs': path.join(
		REPO_ROOT,
		'tools',
		'lib',
		'kbd-dll',
		'shortcut-keys.cjs'
	)
});
const OUT_PATH = shared('ui', 'layout_editor', '_generated', 'klc_generator.js');

/** The module names one source text requires. */
function requiresOf(text) {
	return [...text.matchAll(/\brequire\s*\(\s*'([^']*)'\s*\)/g)].map((match) => match[1]);
}

/**
 * Builds the complete generated file.
 * @returns {string} JS source with LF line ends and a final newline.
 */
function buildSource() {
	const text = fs.readFileSync(SOURCE_PATH, 'utf8');
	// The page has no module loader: only the listed helpers are bundled.
	const required = requiresOf(text);
	if (/\brequire\s*\(/.test(text.replace(/\brequire\s*\(\s*'[^']*'\s*\)/g, '')))
		throw new Error(`${SOURCE_PATH} requires a module by a computed name; the page cannot load it`);
	const unknown = required.filter((name) => !Object.hasOwn(HELPERS, name));
	if (unknown.length)
		throw new Error(`${SOURCE_PATH} requires ${unknown.join(', ')}; the page cannot load it`);
	const relative = (file) => path.relative(REPO_ROOT, file).split(path.sep).join('/');
	const helpers = [...new Set(required)].map((name) => {
		const helper = fs.readFileSync(HELPERS[name], 'utf8');
		if (/\brequire\s*\(/.test(helper))
			throw new Error(`${HELPERS[name]} requires a module; the page cannot load it`);
		return { name, file: HELPERS[name], text: helper };
	});
	const lines = [
		'// _shared/ui/layout_editor/_generated/klc_generator.js',
		'',
		'// ==========================================',
		'// AUTO-GENERATED — do not edit manually',
		`// Source: ${relative(SOURCE_PATH)}`,
		...helpers.map((helper) => `// Helper: ${relative(helper.file)}`),
		'// Run: npm run codegen:layout-editor-klc:js',
		'// ==========================================',
		'',
		'// The MSKLC generator of the repository tool, loaded by the layout editor page.',
		'var LayoutKlcGenerator = (function () {',
		'\tvar helpers = {};'
	];
	for (const helper of helpers)
		lines.push(
			`\thelpers[${JSON.stringify(helper.name)}] = (function () {`,
			'\t\tvar module = { exports: {} };',
			'\t\t(function (module, exports) {',
			helper.text.replace(/\n$/, ''),
			'\t\t})(module, module.exports);',
			'\t\treturn module.exports;',
			'\t})();'
		);
	lines.push(
		'\tfunction require(name) {',
		"\t\tif (!Object.prototype.hasOwnProperty.call(helpers, name)) throw new Error('not bundled: ' + name);",
		'\t\treturn helpers[name];',
		'\t}',
		'\tvar module = { exports: {} };',
		'\t(function (module, exports) {',
		text.replace(/\n$/, ''),
		'\t})(module, module.exports);',
		'\treturn module.exports;',
		'})();',
		''
	);
	return lines.join('\n');
}

/** Writes the generated file. */
function main() {
	console.log('codegen:layout-editor-klc:js — wrapping the KLC generator for the layout editor…');
	fs.mkdirSync(path.dirname(OUT_PATH), { recursive: true });
	fs.writeFileSync(OUT_PATH, buildSource());
	console.log(`codegen:layout-editor-klc:js — wrote ${OUT_PATH}`);
}

if (require.main === module) main();

module.exports = { buildSource, OUT_PATH };
