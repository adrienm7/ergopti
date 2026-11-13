// tools/test/test-layout-editor-target-exports.cjs

/**
 * ==============================================================================
 * MODULE: Layout Editor XKB and KLC Export Tests
 * DESCRIPTION:
 * Loads the layout editor's scripts in a vm context in the order index.html
 * loads them, with the vendored fengari VM, the shared Lua export adapter and
 * the generated KLC generator the site loads on demand, and checks that the
 * page's Linux XKB archive and Windows .klc equal, byte for byte, what the
 * repository tool writes (`export-xkb`, `export-klc`) for the corpus fixture
 * and a registry layout, refusals included.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { REPO_ROOT, shared } = require('../lib/paths.cjs');
const { loadLayoutSource } = require('../lib/layout-source.cjs');
const { exportXkb } = require('../lib/layout-source-xkb.cjs');
const { exportKlc } = require('../lib/layout-source-klc.cjs');
const klcCodegen = require('../codegen/codegen-layout-editor-klc-js.cjs');

const UI = shared('ui');
const XKB_DATA = path.join(REPO_ROOT, 'static', 'ergopti', 'linux', 'xkb_generation', 'data');
// The scripts the site loads on demand, after the page's own.
const ON_DEMAND = ['vendor/fengari-web.js', 'layout_editor/_generated/klc_generator.js'];

/** The page's scripts as index.html lists them, then the on-demand ones. */
function loadPage() {
	const html = fs.readFileSync(path.join(UI, 'layout_editor', 'index.html'), 'utf8');
	const scripts = [...html.matchAll(/<script src="([^"]+)"/g)]
		.map((m) => path.relative(UI, path.resolve(path.join(UI, 'layout_editor'), m[1])))
		.filter(
			(file) =>
				!['i18n.js', 'layout_editor/editor_page.js', 'layout_editor/standalone.js'].includes(file)
		);
	for (const needed of ['layout_composer/target_export.js', 'layout_editor/lua_runner.js'])
		assert(scripts.includes(needed), `index.html loads ${needed}`);
	const context = vm.createContext({ TextEncoder });
	// fengari-web's UMD wrapper reads the page's `window`.
	context.window = context;
	for (const file of scripts.concat(ON_DEMAND)) {
		const text = fs
			.readFileSync(path.join(UI, file), 'utf8')
			.replace(
				/^const (LAYOUT_COMPOSER_DATA|LAYER_EDITOR_DATA|LAYOUT_SOURCE_TABLES) =/m,
				'var $1 ='
			);
		vm.runInContext(text, context, { filename: file });
	}
	return vm.runInContext(
		'({ IO: LayoutSourceIO, Lua: LayoutLuaRunner, generator: LayoutKlcGenerator, fengari: LayoutLuaRunner.loadedVm(globalThis) })',
		context
	);
}

const page = loadPage();
const luaSources = Object.fromEntries(
	page.Lua.MODULES.map((name) => [name, fs.readFileSync(shared(page.Lua.modulePath(name)), 'utf8')])
);
const assets = {
	lua: page.Lua.create(page.fengari, luaSources),
	keysyms: JSON.parse(fs.readFileSync(path.join(XKB_DATA, 'key_sym.json'), 'utf8')),
	template: fs.readFileSync(path.join(XKB_DATA, 'xkb_symbols.txt'), 'utf8'),
	types: fs.readFileSync(path.join(XKB_DATA, 'xkb_types.txt'), 'utf8'),
	generator: page.generator
};
const Source = loadLayoutSource();
const clone = (value) => JSON.parse(JSON.stringify(value));
const fixture = Source.read(
	fs.readFileSync(shared('tests', 'corpus', 'layouts', 'source', 'source.toml'), 'utf8')
);
const registryXml = (id) =>
	fs.readFileSync(
		path.join(REPO_ROOT, 'static', 'layouts', 'registry', id, `${id}.keylayout`),
		'utf8'
	);
// The page validates its own documents: give it a copy made in its realm.
const pageDoc = (document) => {
	const parsed = page.IO.parse(Source.write(document));
	assert(parsed.ok, 'the page reads the source the tool writes');
	return parsed.doc;
};
let checks = 0;

/** The page's XKB archive holds the tool's files, byte for byte, under one folder. */
function sameXkb(document, label) {
	const tool = exportXkb(document);
	const archive = page.IO.xkbArchive(pageDoc(document), assets);
	assert.deepEqual(
		clone(archive.files.map((file) => file.path)),
		[...tool.files.keys()],
		`${label}: same file tree`
	);
	for (const file of archive.files)
		assert.equal(file.text, tool.files.get(file.path), `${label}: ${file.path}`);
	const text = Buffer.from(archive.bytes).toString('latin1');
	for (const file of archive.files)
		assert(text.includes(`${tool.report.name}_xkb/${file.path}`), `${label}: zipped ${file.path}`);
	assert.equal(archive.filename, `${tool.report.name}_xkb.zip`);
	checks++;
}

/** The page's .klc bytes are the tool's. */
function sameKlc(document, label) {
	const tool = exportKlc(document);
	const name = `${document.exports.windows.dll_name}.klc`;
	const file = page.IO.klcFile(pageDoc(document), assets);
	assert.equal(file.filename, name);
	assert(Buffer.from(file.bytes).equals(Buffer.from(tool.files.get(name))), `${label}: KLC bytes`);
	assert.deepEqual(
		clone(file.report),
		JSON.parse(tool.files.get('export.json')),
		`${label}: report`
	);
	checks++;
}

// The generated KLC generator is the tool's module, wrapped verbatim.
assert.equal(fs.readFileSync(klcCodegen.OUT_PATH, 'utf8'), klcCodegen.buildSource());
assert.deepEqual(
	Object.keys(page.generator),
	Object.keys(require('../codegen/lib/windows-keyboard-layout.cjs'))
);
checks++;

// The corpus fixture: XKB equal; KLC refused by both with the same reason.
sameXkb(fixture, 'fixture');
{
	let toolReason = null;
	try {
		exportKlc(fixture);
	} catch (error) {
		toolReason = error.message;
	}
	assert(toolReason, 'the tool refuses the fixture KLC');
	assert.throws(
		() => page.IO.klcFile(pageDoc(fixture), assets),
		(error) => error.code === 'target_export_refused' && error.path === toolReason
	);
	checks++;
}

// A registry layout, preserved and structured, both targets.
{
	const windows = { locale: 'fr-FR', layout_id: '0000040c', dll_name: 'kbdergo' };
	const preserved = Source.importKeylayout(registryXml('ergopti'), 'ergopti', 'iso');
	preserved.exports = { windows };
	const structured = clone(Source.importStructured(registryXml('ergopti'), 'ergopti', 'iso'));
	structured.exports.windows = windows;
	sameXkb(preserved, 'ergopti preserved');
	sameXkb(structured, 'ergopti structured');
	sameKlc(preserved, 'ergopti preserved');
	sameKlc(structured, 'ergopti structured');
}

// The direct compilers' extra levels: XKB's fifth level, KLC's Kana and Roya bits.
{
	const direct = Source.read(
		fs.readFileSync(shared('tests', 'corpus', 'layouts', 'source', 'direct_levels.toml'), 'utf8')
	);
	sameXkb(direct, 'direct levels');
	sameKlc(direct, 'direct levels');
}

// A Lua refusal reaches the page as the tool's reason.
{
	const read = assets.lua.call('read', { xml: '<keyboard/>' });
	assert.equal(read.ok, false);
	assert.equal(typeof read.reason, 'string');
	checks++;
}

console.log(
	`[OK] layout editor target exports: ${checks} checks (XKB and KLC byte equality with the tool, refusals)`
);
