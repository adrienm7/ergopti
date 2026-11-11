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
 *    shim; the module requires nothing, which the wrapper checks.
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
const OUT_PATH = shared('ui', 'layout_editor', '_generated', 'klc_generator.js');

/**
 * Builds the complete generated file.
 * @returns {string} JS source with LF line ends and a final newline.
 */
function buildSource() {
	const text = fs.readFileSync(SOURCE_PATH, 'utf8');
	// The page has no module loader: a dependency would be undefined there.
	if (/\brequire\s*\(/.test(text))
		throw new Error(`${SOURCE_PATH} requires a module; the page cannot load it`);
	const relative = path.relative(REPO_ROOT, SOURCE_PATH).split(path.sep).join('/');
	return [
		'// _shared/ui/layout_editor/_generated/klc_generator.js',
		'',
		'// ==========================================',
		'// AUTO-GENERATED — do not edit manually',
		`// Source: ${relative}`,
		'// Run: npm run codegen:layout-editor-klc:js',
		'// ==========================================',
		'',
		'// The MSKLC generator of the repository tool, loaded by the layout editor page.',
		'var LayoutKlcGenerator = (function () {',
		'\tvar module = { exports: {} };',
		'\t(function (module, exports) {',
		text.replace(/\n$/, ''),
		'\t})(module, module.exports);',
		'\treturn module.exports;',
		'})();',
		''
	].join('\n');
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
