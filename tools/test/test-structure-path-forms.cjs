// tools/test/test-structure-path-forms.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Path Forms
 * DESCRIPTION:
 * A moved file is named in more forms than one path token. After S01 the
 * suites and generators failed on each form the plan missed:
 * - a path built from pieces, path.join(SP, '_shared', 'data', 'locales');
 * - Paths.shared("modules/hotstrings"), read as the driver's own
 *   modules/hotstrings folder because that one exists too;
 * - repository .. "/static/ergopti_plus/…", a repository path behind a slash;
 * - a redaction corpus's "<config>/hotstrings/x", read relative to the old
 *   shared Lua root although it is a user path;
 * - and a moved file finding itself: "../../vendor/x" from its own folder,
 *   source:match("^(.*)/modules/llm/x%.lua$"), and three nested dirname()
 *   climbs to _shared that need four from the new depth;
 * - a path rewritten twice: the folder row _shared/core → _shared rewrote
 *   inside the …/_shared/core/network/data/x.json a file row had just written;
 * - a corpus captured byte for byte, whose header was rewritten under its pin;
 * - what a rewrite leaves inconsistent beside a path: sub(1, 12) == "_shared/",
 *   and a fixture's mkdir list holding _shared twice and no parent of a deeper
 *   new folder;
 * - driver_root() .. "/../_shared/modules/x" written in a _shared file, whose
 *   "../_shared" was dropped, so it named a folder of the driver.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const Plan = require('../audit/structure/plan.cjs');
const Apply = require('../audit/structure/apply-step.cjs');
const Edits = require('../audit/structure/edits.cjs');
const fs = require('node:fs');
const path = require('node:path');

const P = 'static/ergopti_plus/';
// Synthetic paths, so the test holds before and after phase 2.
const FAKE = [
	'_shared/zz_probe_data/locales/en.json',
	'_shared/zz_probe_mod/hotstrings/a.toml',
	'_shared/zz_probe_mod/hotstrings/a.json',
	'linux/zz_probe_mod/hotstrings/b.lua',
	'_shared/zz_probe_lua/codec/x.lua',
	'macos/zz_probe_vendor/manifest.lua',
	'macos/zz_probe_llm/binary.lua',
	'_shared/zz_probe_mod/other.json',
	'_shared/lua/zz_probe_hot/p.lua',
	'_shared/lua/zz_probe_hot/q.lua',
	'_shared/zz_inward/x.lua',
	'_shared/zz_inward/y.lua',
	'linux/zz_scatter/x.lua',
	'linux/zz_scatter/y.lua',
	'linux/zz_scatter/d.json',
	'_shared/zz_pyold/x.py'
];
const MAP = new Map([
	['_shared/zz_probe_data/locales/en.json', '_shared/core/zz_probe_i18n/data/locales/en.json'],
	['_shared/zz_probe_mod/hotstrings/a.toml', '_shared/zz_probe_hs/data/a.toml'],
	['_shared/zz_probe_mod/hotstrings/a.json', '_shared/zz_probe_hs/data/a.json'],
	['_shared/zz_probe_lua/codec/x.lua', '_shared/zz_probe_text/codec/x.lua'],
	['linux/zz_probe_mod/hotstrings/b.lua', 'linux/zz_probe_mod/hotstrings/b.lua'],
	['macos/zz_probe_vendor/manifest.lua', 'macos/zz_probe_vendor/manifest.lua'],
	['macos/zz_probe_llm/binary.lua', 'macos/zz_ai/adapters/binary.lua'],
	['_shared/zz_probe_mod/other.json', '_shared/zz_other/data/other.json'],
	['_shared/lua/zz_probe_hot/p.lua', '_shared/zz_hot/engine/p.lua'],
	['_shared/lua/zz_probe_hot/q.lua', '_shared/zz_hot/engine/q.lua'],
	['_shared/zz_inward/x.lua', '_shared/zz_inward/b/x.lua'],
	['_shared/zz_inward/y.lua', '_shared/zz_inward/c/y.lua'],
	['linux/zz_scatter/x.lua', 'linux/zz_scatter/x.lua'],
	['linux/zz_scatter/y.lua', 'linux/zz_core/y/y.lua'],
	// A data file's home is no home of a source scope (S28 put keyboard/data,
	// which holds no Lua, in the convention lint's Lua folders).
	['linux/zz_scatter/d.json', 'linux/zz_data/d.json'],
	['_shared/zz_pyold/x.py', '_shared/zz_pynew/deep/x.py']
]);

function withFakes(fn) {
	const added = [];
	for (const f of FAKE) {
		const parts = (P + f).split('/');
		for (let i = 1; i <= parts.length; i++) {
			const p = parts.slice(0, i).join('/');
			if (!Plan.EXISTING.has(p)) {
				Plan.EXISTING.add(p);
				added.push(p);
			}
		}
	}
	try {
		fn();
	} finally {
		for (const p of added) Plan.EXISTING.delete(p);
	}
}

function rewrite(file, text) {
	const rows = Plan.scanFile(file, text, Plan.referenceContext(MAP));
	const moved = new Map([...MAP].filter(([o, t]) => o !== t).map(([o, t]) => [P + o, P + t]));
	return Apply.rewriteText(text, rows, moved, file);
}

function run() {
	withFakes(() => {
		// os.path.join pieces in a Python script with no extension.
		assert.equal(
			rewrite(
				`${P}macos/apps/X.app/Contents/MacOS/X`,
				'#!/usr/bin/env python3\nd = os.path.join(root,\n    "_shared", "zz_probe_data", "locales",\n)\n'
			),
			'#!/usr/bin/env python3\nd = os.path.join(root,\n    "_shared", "core", "zz_probe_i18n", "data", "locales",\n)\n'
		);
		// A folder whose files only move into its own subfolders keeps its name,
		// escapes and all: S02 rewrote such a regex into invalid JavaScript.
		const inward = 'const m = f.match(/^static\\/ergopti_plus\\/_shared\\/zz_inward\\/(.+)$/);';
		assert.equal(rewrite('tools/x.cjs', inward), inward);
		// A driver folder that scatters with the driver root as its nearest
		// home: a list element names each real home, never the whole driver;
		// elsewhere the folder, which keeps files, keeps its name (S02 widened
		// the lint scopes of windows/adapters to windows).
		assert.equal(
			rewrite('tools/lint/x.cjs', "const TREES = [\n\t'linux/zz_scatter',\n\t'macos/ui'\n];"),
			"const TREES = [\n\t'linux/zz_scatter',\n\t'linux/zz_core/y',\n\t'macos/ui'\n];"
		);
		// A property line is no list element: its key would be duplicated.
		const property = "const o = {\n\ta: 1,\n\troots: 'linux/zz_scatter',\n\tb: 2\n};";
		assert.ok(
			!rewrite('tools/lint/x.cjs', property).includes('zz_core'),
			'a property names no list'
		);
		const kept = "fail('route OS access through linux/zz_scatter/ instead');";
		assert.equal(rewrite('tools/lint/x.cjs', kept), kept);
		// Regular expressions of a path: behind the variable holding the checkout,
		// and the Windows spelling that names the shared root first.
		assert.equal(
			rewrite(
				'tools/x.cjs',
				'assert.match(s, /\\$REPO_ROOT\\/static\\/ergopti_plus\\/_shared\\/zz_probe_mod\\/hotstrings\\/a\\.json/);'
			),
			'assert.match(s, /\\$REPO_ROOT\\/static\\/ergopti_plus\\/_shared\\/zz_probe_hs\\/data\\/a\\.json/);'
		);
		assert.equal(
			rewrite(
				'tools/x.cjs',
				'assert.match(s, /_shared\\\\zz_probe_mod\\\\hotstrings\\\\a\\.json/);'
			),
			'assert.match(s, /_shared\\\\zz_probe_hs\\\\data\\\\a\\.json/);'
		);
		// A Go module path names the module, wherever its folder moves: the
		// relay binary built from it stays the committed one.
		const goImport =
			'import "github.com/adrienm7/ergopti/static/ergopti_plus/_shared/zz_probe_mod/hotstrings"';
		assert.equal(rewrite(`${P}_shared/zz_probe_mod/x.go`, goImport), goImport);
		// A Python path anchored on its own file: the climb follows the file's
		// new place (S01 moved the proxy policy reader two folders deeper).
		assert.equal(
			rewrite(
				`${P}_shared/zz_pyold/x.py`,
				'p = Path(__file__).parent.parent / "zz_probe_mod/other.json"\n'
			),
			'p = Path(__file__).parent.parent.parent / "zz_other/data/other.json"\n'
		);
		assert.equal(
			rewrite(
				`${P}_shared/zz_pyold/x.py`,
				'p = Path(__file__).resolve().parents[1] / "zz_probe_mod/other.json"\n'
			),
			'p = Path(__file__).resolve().parents[2] / "zz_other/data/other.json"\n'
		);
		// A regex of the Go module line is the module path, escapes and all.
		const goRegex =
			'assert.match(m, /^module github\\.com\\/adrienm7\\/ergopti\\/static\\/ergopti_plus\\/_shared\\/zz_probe_mod\\/hotstrings$/m);';
		assert.equal(rewrite('tools/x.cjs', goRegex), goRegex);
		// Driver sections key paths of their driver, never the shared folder
		// of the same name; a moved driver file follows on its own line.
		const Edits = require('../audit/structure/edits.cjs');
		const sections = `${P}_shared/zz_requirements.toml`;
		Edits.DRIVER_SECTION_FILES.push({ file: sections, why: 'probe' });
		try {
			assert.equal(
				rewrite(
					sections,
					'[detection.linux.x.owners]\n"zz_probe_mod/hotstrings/" = ["a"]\n"zz_scatter/y.lua" = ["b"]\n'
				),
				'[detection.linux.x.owners]\n"zz_probe_mod/hotstrings/" = ["a"]\n"zz_core/y/y.lua" = ["b"]\n'
			);
		} finally {
			Edits.DRIVER_SECTION_FILES.pop();
		}
		// A shell exclusion of a bare _shared path, unquoted.
		assert.equal(
			rewrite(
				'tools/build/x.sh',
				'copy_tree "$S/" "$B/" --exclude zz_probe_mod/hotstrings/a.json\n'
			),
			'copy_tree "$S/" "$B/" --exclude zz_probe_hs/data/a.json\n'
		);
		// A Lua pattern anchored on a path tail, embedded in a tool or in Lua.
		assert.equal(
			rewrite('tools/x.cjs', 'const lua = `if p:match("/zz_probe_mod/hotstrings/a%.json$") then`;'),
			'const lua = `if p:match("/zz_probe_hs/data/a%.json$") then`;'
		);
		assert.equal(
			rewrite(`${P}linux/y.lua`, "assert(path:find('/_shared/zz_probe_mod/hotstrings/a%.json$'))"),
			"assert(path:find('/_shared/zz_probe_hs/data/a%.json$'))"
		);
		// A bare resolve imported from path, and a folder piece with its trailing
		// slash concatenated onto a name: the locale catalogue read per code.
		assert.equal(
			rewrite(
				'tools/x.cjs',
				"const { resolve } = require('path');\n" +
					"const SHARED = resolve(__dirname, '..', 'static/ergopti_plus/_shared');\n" +
					"read(resolve(SHARED, 'zz_probe_data/locales/' + code + '.json'));"
			),
			"const { resolve } = require('path');\n" +
				"const SHARED = resolve(__dirname, '..', 'static/ergopti_plus/_shared');\n" +
				"read(resolve(SHARED, 'core/zz_probe_i18n/data/locales/' + code + '.json'));"
		);
		assert.equal(
			rewrite('tools/x.cjs', "const L = path.join(SP, '_shared', 'zz_probe_data', 'locales');"),
			"const L = path.join(SP, '_shared', 'core', 'zz_probe_i18n', 'data', 'locales');"
		);
		// A shared argument that climbs into a driver keeps its climb (S35 cut
		// "../macos/updater/…" to "dater/…" by slicing the _shared prefix).
		assert.equal(
			rewrite(`${P}macos/y.lua`, 'local s = Paths.shared("../macos/zz_probe_llm/binary.lua")'),
			'local s = Paths.shared("../macos/zz_ai/adapters/binary.lua")'
		);
		assert.equal(
			rewrite(`${P}linux/y.lua`, 'local d = Paths.shared("zz_probe_mod/hotstrings")'),
			'local d = Paths.shared("zz_probe_hs/data")',
			'a Paths.shared argument names the shared folder, not the driver one'
		);
		assert.equal(
			rewrite('tools/x.cjs', "const T = shared('zz_probe_mod/hotstrings/a.toml');"),
			"const T = shared('zz_probe_hs/data/a.toml');",
			'a tool reads _shared through shared() too'
		);
		assert.equal(
			rewrite(
				'tools/x.cjs',
				'assert.match(text, /static\\/ergopti_plus\\/_shared\\/zz_probe_mod\\/hotstrings\\/a\\.toml/);'
			),
			'assert.match(text, /static\\/ergopti_plus\\/_shared\\/zz_probe_hs\\/data\\/a\\.toml/);',
			'a path escaped in a regular expression'
		);
		assert.equal(
			rewrite(
				'tools/build/x.cjs',
				"const S = require('../../static/ergopti_plus/_shared/zz_probe_mod/hotstrings/a.toml');"
			),
			"const S = require('../../static/ergopti_plus/_shared/zz_probe_hs/data/a.toml');",
			'a tool spells a path relative to itself'
		);
		// MOD names a folder the plan scatters: it becomes _shared, and a join
		// onto it is respelled from there.
		assert.equal(
			rewrite(
				'tools/build/m.json',
				'{"target": "ergopti_plus/_shared/zz_probe_data/locales/generated.json"}'
			),
			'{"target": "ergopti_plus/_shared/core/zz_probe_i18n/data/locales/generated.json"}',
			'a generated file the index does not hold follows its folder'
		);
		for (const [file, before, after] of [
			[
				`${P}linux/z.lua`,
				'local d = SHARED_DIR .. "/zz_probe_mod/hotstrings/"',
				'local d = SHARED_DIR .. "/zz_probe_hs/data/"'
			],
			[
				'tools/z.py',
				'D = SHARED / "zz_probe_mod/hotstrings/a.toml"',
				'D = SHARED / "zz_probe_hs/data/a.toml"'
			],
			[
				`${P}linux/z.sh`,
				'cp -r "${SRC_SHARED}/zz_probe_mod/hotstrings" x',
				'cp -r "${SRC_SHARED}/zz_probe_hs/data" x'
			],
			[
				'src/z.js',
				"const D = resolve(SHARED_ROOT, 'zz_probe_mod/hotstrings');",
				"const D = resolve(SHARED_ROOT, 'zz_probe_hs/data');"
			]
		])
			assert.equal(rewrite(file, before), after, `joined onto a name for _shared: ${before}`);
		assert.equal(
			rewrite('tools/lib/z.cjs', "const A_REL = 'zz_probe_mod/hotstrings/a.toml';\nshared(A_REL);"),
			"const A_REL = 'zz_probe_hs/data/a.toml';\nshared(A_REL);",
			'a _shared-relative constant beside shared()'
		);
		assert.equal(
			rewrite(
				'tools/test/x.cjs',
				"write(path.join(TMP, 'static', 'ergopti_plus', '_shared', 'zz_probe_data', 'locales', 'planted.json'));"
			),
			"write(path.join(TMP, 'static', 'ergopti_plus', '_shared', 'core', 'zz_probe_i18n', 'data', 'locales', 'planted.json'));",
			'a planted file in a folder that moves whole follows it'
		);
		assert.equal(
			rewrite(
				`${P}windows/z.ahk`,
				'Data := FileRead(_SharedDir . "\\zz_probe_mod\\hotstrings\\a.toml")'
			),
			'Data := FileRead(_SharedDir . "\\zz_probe_hs\\data\\a.toml")',
			'an AHK path joined onto _SharedDir keeps its leading backslash'
		);
		assert.equal(
			rewrite(
				'tools/test/z.cjs',
				'src.includes(\'FileRead(_SharedDir . "\\\\zz_probe_mod\\\\hotstrings\\\\a.toml")\')'
			),
			'src.includes(\'FileRead(_SharedDir . "\\\\zz_probe_hs\\\\data\\\\a.toml")\')',
			'a tool spells the AHK path with escaped backslashes'
		);
		assert.equal(
			rewrite(`${P}macos/z.lua`, 'return read(helpers.shared("zz_probe_data/" .. v.file))'),
			'return read(helpers.shared("core/zz_probe_i18n/data/" .. v.file))',
			'a one-folder prefix handed to shared()'
		);
		assert.equal(
			rewrite('tools/test/z.cjs', "const fake = '/tmp/x/shared/zz_probe_mod/hotstrings/a.toml';"),
			"const fake = '/tmp/x/shared/zz_probe_hs/data/a.toml';",
			'a fake file system root named for _shared'
		);
		assert.equal(
			rewrite(
				`${P}linux/tests/z.lua`,
				'assert_eq(path, "/owned-shared/zz_probe_mod/hotstrings/a.toml")'
			),
			'assert_eq(path, "/owned-shared/zz_probe_hs/data/a.toml")',
			'a fake root named for _shared with a qualifier'
		);
		assert.equal(
			rewrite(
				'tools/test/z.cjs',
				"const t = fs.readFileSync(shared('zz_probe_data', vector.file), 'utf8');"
			),
			"const t = fs.readFileSync(shared('core', 'zz_probe_i18n', 'data', vector.file), 'utf8');",
			'a folder handed to shared() with a name to join'
		);
		assert.equal(
			rewrite(`${P}linux/tests/z.lua`, 'mkdir_chain(shared_dir, "zz_probe_data", "locales")'),
			'mkdir_chain(shared_dir, "core", "zz_probe_i18n", "data", "locales")',
			'a Lua call that spells a shared path in pieces'
		);
		assert.equal(
			rewrite(
				`${P}linux/tests/z.lua`,
				'local root = helpers.driver_root() .. "/../_shared/zz_probe_mod/"\nlocal f = io.open(root .. "hotstrings/a.toml")'
			),
			'local root = helpers.driver_root() .. "/../_shared/"\nlocal f = io.open(root .. "zz_probe_hs/data/a.toml")',
			'a folder held in a Lua local, joined later'
		);
		assert.equal(
			rewrite(
				`${P}linux/tests/z.lua`,
				'paths.shared = function(path)\n\tif path == "zz_probe_mod/hotstrings" then return nil end\nend'
			),
			'paths.shared = function(path)\n\tif path == "zz_probe_hs/data" then return nil end\nend',
			'the argument a stand-in of the shared resolver is compared with'
		);
		assert.equal(
			rewrite('tools/test/z.cjs', "assert.ok(src.includes('zz_probe_mod/hotstrings/a.toml'));"),
			"assert.ok(src.includes('zz_probe_hs/data/a.toml'));",
			'a source check names a file by the tail of its path'
		);
		// A whole shared folder handed to the resolver: respelled when it moves
		// whole, a refusal when the plan scatters it.
		assert.equal(
			rewrite(`${P}linux/z.lua`, 'local d = Paths.shared("zz_probe_lua")'),
			'local d = Paths.shared("zz_probe_text")'
		);
		const scattered = Plan.scanFile(
			`${P}linux/z.lua`,
			'local d = Paths.shared("zz_probe_mod")',
			Plan.referenceContext(MAP)
		);
		assert.deepEqual(
			scattered.map((r) => r.kind),
			['dir-split'],
			'a scattered shared folder named whole refuses the step'
		);
		assert.equal(
			rewrite(`${P}_shared/zz_probe_mod/vendor.js`, 'e.paths = ["./zz_probe_lua"]'),
			'e.paths = ["./zz_probe_lua"]',
			'a ./ path is relative to its file, never to the tree root'
		);
		// The folder part of a longer path is that path's, not a folder reference:
		// a bare path to a file nobody holds stays (here, a driver file).
		assert.equal(
			rewrite(
				`${P}_shared/zz_probe_mod/m.toml`,
				'# Linux gained it in zz_probe_mod/hotstrings/zz_x.lua.'
			),
			'# Linux gained it in zz_probe_mod/hotstrings/zz_x.lua.'
		);
		assert.equal(
			rewrite(`${P}_shared/zz_probe_mod/notes.md`, 'It lives in _shared/zz_probe_lua/.'),
			'It lives in _shared/zz_probe_text/.',
			'a folder that ends its sentence'
		);
		// A lone scattered folder whose nearest new folder is the tree root
		// itself would become an empty name: the step refuses it.
		const lone = Plan.scanFile(
			`${P}linux/tests/z.lua`,
			'mkdir(shared_dir .. "/zz_probe_mod")',
			Plan.referenceContext(MAP)
		);
		assert.ok(
			lone.some((r) => Plan.REFUSED_KINDS.has(r.kind)),
			'a lone root-successor folder in live code refuses the step'
		);
		// A base built from a parameter that defaults to a known constant.
		const fromParam = (folder, ...pieces) =>
			[
				"const ROOT = path.resolve(__dirname, '..', '..');",
				'function main(root = ROOT) {',
				`\tconst d = path.join(root, 'static/ergopti_plus/_shared${folder}');`,
				`\treturn path.join(d, ${pieces.map((x) => `'${x}'`).join(', ')});`,
				'}'
			].join('\n');
		assert.equal(
			rewrite('tools/codegen/x.cjs', fromParam('/zz_probe_mod', 'hotstrings', 'a.toml')),
			fromParam('', 'zz_probe_hs', 'data', 'a.toml'),
			'joins onto a base derived from a defaulted parameter follow its folder'
		);
		// A Python path joined with the / operator, read from the tree it passes.
		assert.equal(
			rewrite(
				'tools/test/z.py',
				'S = ROOT / "static" / "ergopti_plus" / "_shared" / "zz_probe_mod" / "hotstrings" / "a.toml"'
			),
			'S = ROOT / "static" / "ergopti_plus" / "_shared" / "zz_probe_hs" / "data" / "a.toml"'
		);
		assert.equal(
			rewrite(`${P}linux/tests/z.py`, 'locales = case / "_shared" / "zz_probe_data" / "locales"'),
			'locales = case / "_shared" / "core" / "zz_probe_i18n" / "data" / "locales"'
		);
		assert.equal(
			rewrite(
				'tools/build/z.cjs',
				"const F = path.join(__dirname, '..', '..', 'static', 'ergopti_plus', '_shared', 'zz_probe_mod', 'hotstrings', 'a.toml');"
			),
			"const F = path.join(__dirname, '..', '..', 'static', 'ergopti_plus', '_shared', 'zz_probe_hs', 'data', 'a.toml');",
			"a join from the file's own folder"
		);
		assert.equal(
			rewrite(
				'tools/build/z.py',
				'S = (\n    ROOT\n    / "static"\n    / "ergopti_plus"\n    / "_shared"\n    / "zz_probe_mod"\n    / "hotstrings"\n    / "a.toml"\n)'
			),
			'S = (\n    ROOT\n    / "static" / "ergopti_plus" / "_shared" / "zz_probe_hs" / "data" / "a.toml"\n)',
			'a Python / chain the formatter wrapped over lines'
		);
		// A tool's regular expressions of a shared path: AutoHotkey backslashes
		// and a bare relative path a driver hands to its shared resolver.
		assert.equal(
			rewrite(
				'tools/test/z.cjs',
				'assert.match(ahk, /\\\\zz_probe_mod\\\\hotstrings\\\\a\\.toml"/);'
			),
			'assert.match(ahk, /\\\\zz_probe_hs\\\\data\\\\a\\.toml"/);'
		);
		assert.equal(
			rewrite(
				'tools/test/z.cjs',
				'assert.match(lua, /shared\\("zz_probe_mod\\/hotstrings\\/a\\.toml"\\)/);'
			),
			'assert.match(lua, /shared\\("zz_probe_hs\\/data\\/a\\.toml"\\)/);'
		);
		// A join is respelled where it is, not wherever its pieces recur.
		assert.equal(
			rewrite(
				'tools/test/z.cjs',
				"const d = path.join(SHARED, 'zz_probe_lua');\nconst ext = lua ? 'zz_probe_lua' : 'ahk';"
			),
			"const d = path.join(SHARED, 'zz_probe_text');\nconst ext = lua ? 'zz_probe_lua' : 'ahk';"
		);
		// An inline list joined onto a shared-named base.
		assert.equal(
			rewrite(
				'tools/test/z.cjs',
				"for (const rel of ['zz_probe_mod/hotstrings/a.toml']) {\n\tfs.writeFileSync(resolve(sharedDir, rel), t);\n}"
			),
			"for (const rel of ['zz_probe_hs/data/a.toml']) {\n\tfs.writeFileSync(resolve(sharedDir, rel), t);\n}"
		);
		// A template's leading folder, and the folder of a shared() constant.
		assert.equal(
			rewrite(
				'tools/test/z.cjs',
				"const root = path.resolve(__dirname, '../../static/ergopti_plus/_shared/zz_probe_mod');\nread(path.join(root, `hotstrings/${name}.toml`));"
			),
			"const root = path.resolve(__dirname, '../../static/ergopti_plus/_shared');\nread(path.join(root, `zz_probe_hs/data/${name}.toml`));"
		);
		assert.equal(
			rewrite(
				'tools/test/z.cjs',
				"const F = shared('zz_unmoved', 'x');\nconst L = path.join(path.dirname(F), '..', 'zz_probe_mod', 'hotstrings', 'a.toml');"
			),
			"const F = shared('zz_unmoved', 'x');\nconst L = path.join(path.dirname(F), '..', 'zz_probe_hs', 'data', 'a.toml');"
		);
		// A derived base that would itself move has no respelling: a refusal.
		assert.ok(
			Plan.scanFile(
				'tools/test/z.cjs',
				"const F = shared('zz_probe_mod', 'x');\nconst L = path.join(path.dirname(F), 'hotstrings', 'a.toml');",
				Plan.referenceContext(MAP)
			).some((r) => Plan.REFUSED_KINDS.has(r.kind))
		);
		// A tool's bare path of a file only _shared holds.
		assert.equal(
			rewrite(
				'tools/test/z.cjs',
				"const SPEC_ONLY = { 'zz_probe_mod/hotstrings/a.toml': 'read by humans' };"
			),
			"const SPEC_ONLY = { 'zz_probe_hs/data/a.toml': 'read by humans' };"
		);
		assert.equal(
			rewrite('tools/z.py', 'p = shared("zz_probe_mod", "hotstrings", "a.toml")'),
			'p = shared("zz_probe_hs", "data", "a.toml")',
			"a Python call of the tools' shared() resolver"
		);
		assert.equal(
			rewrite(
				'tools/build/z.json',
				'{ "patterns": ["ergopti_plus/_shared/zz_probe_lua/codec/x_*.lua"] }'
			),
			'{ "patterns": ["ergopti_plus/_shared/zz_probe_text/codec/x_*.lua"] }',
			'a glob whose folder moves whole'
		);
		// A driver-named base keeps its own folder of a shared folder's name.
		assert.equal(
			rewrite(
				'tools/test/z.cjs',
				'const a = `${SHARED_REL}/zz_probe_mod/hotstrings`;\nconst b = `${DRIVER_REL}/zz_probe_mod/hotstrings/b.lua`;'
			),
			'const a = `${SHARED_REL}/zz_probe_hs/data`;\nconst b = `${DRIVER_REL}/zz_probe_mod/hotstrings/b.lua`;'
		);
		// A folder row never rewrites the head of a longer path (a driver
		// file's own header under a folder that shares a shared folder's name).
		assert.equal(
			rewrite(
				`${P}linux/zz_probe_mod/hotstrings/b.lua`,
				'--- zz_probe_mod/hotstrings/b.lua\nlocal d = Paths.shared("zz_probe_mod/hotstrings")'
			),
			'--- zz_probe_mod/hotstrings/b.lua\nlocal d = Paths.shared("zz_probe_hs/data")'
		);
		assert.equal(
			rewrite(
				'tools/test/z.cjs',
				'const SKIP = /_shared\\/zz_probe_mod\\/hotstrings\\/a\\.(toml|json)$/;'
			),
			'const SKIP = /_shared\\/zz_probe_hs\\/data\\/a\\.(toml|json)$/;',
			'a regex path with an extension alternation'
		);
		// One folder name joined onto an unknown base is no reference; onto a
		// base named for _shared it is.
		assert.equal(
			rewrite(`${P}linux/tests/z.lua`, 'local root = parent .. "/zz_probe_data"'),
			'local root = parent .. "/zz_probe_data"',
			'a temporary folder that shares a name with a shared folder'
		);
		assert.equal(
			rewrite(`${P}linux/tests/z.lua`, 'local root = shared_dir .. "/zz_probe_data"'),
			'local root = shared_dir .. "/core/zz_probe_i18n/data"'
		);
		assert.equal(
			rewrite(`${P}linux/z.lua`, 'local k = shared_json("zz_probe_mod/hotstrings/a.toml", true)'),
			'local k = shared_json("zz_probe_hs/data/a.toml", true)',
			'one path argument before a flag stays one argument'
		);
		assert.equal(
			rewrite(`${P}_shared/zz_probe_mod/x.go`, '//hotstrings:build !windows\n\npackage x\n'),
			'//hotstrings:build !windows\n\npackage x\n',
			'a Go build directive (//go:build in _shared/go) is not a folder'
		);
		assert.equal(
			rewrite(
				'tools/codegen/x.cjs',
				"const SOURCES = ['zz_probe_mod/hotstrings/a.toml'];\nconst h = SOURCES.map((s) => `// Source: ${sharedRel(s)}`);"
			),
			"const SOURCES = ['zz_probe_hs/data/a.toml'];\nconst h = SOURCES.map((s) => `// Source: ${sharedRel(s)}`);",
			'a list whose elements the file hands to a shared helper'
		);
		assert.equal(
			rewrite(
				'tools/codegen/x.cjs',
				"const TABLES = [['a', 'zz_probe_mod/hotstrings/a.toml']];\nfor (const [name, file] of TABLES) read(shared(file));"
			),
			"const TABLES = [['a', 'zz_probe_hs/data/a.toml']];\nfor (const [name, file] of TABLES) read(shared(file));",
			'the same through a for…of loop'
		);
		assert.equal(
			rewrite('tools/x.cjs', "const T = read('zz_probe_mod/hotstrings/a.toml', SHARED);"),
			"const T = read('zz_probe_hs/data/a.toml', SHARED);",
			'a reader that takes the shared base after the path'
		);
		assert.equal(
			rewrite(
				`${P}linux/tests/z.lua`,
				'local root = helpers.driver_root() .. "/../_shared/zz_probe_mod/"\nlocal f = io.open(root .. "hotstrings/" .. name)'
			),
			'local root = helpers.driver_root() .. "/../_shared/"\nlocal f = io.open(root .. "zz_probe_hs/data/" .. name)',
			'a folder piece joined onto a Lua local keeps its trailing slash'
		);
		assert.equal(
			rewrite(
				`${P}linux/z.lua`,
				'local ORDER = "zz_probe_mod/hotstrings/a.toml"\nreturn read_shared(ORDER)'
			),
			'local ORDER = "zz_probe_hs/data/a.toml"\nreturn read_shared(ORDER)',
			'a constant handed to a shared reader'
		);
		const constants = (mod, last) =>
			[
				"const ROOT = path.resolve(__dirname, '..', '..');",
				`const MOD = path.join(ROOT, ${mod});`,
				last
			].join('\n');
		assert.equal(
			rewrite(
				'tools/test/x.cjs',
				constants(
					"'static', 'ergopti_plus', '_shared', 'zz_probe_mod'",
					"const T = fs.readFileSync(path.join(MOD, 'hotstrings', 'a.toml'));"
				)
			),
			constants(
				"'static', 'ergopti_plus', '_shared'",
				"const T = fs.readFileSync(path.join(MOD, 'zz_probe_hs', 'data', 'a.toml'));"
			),
			'a join onto a constant the file defines follows the constant'
		);
		assert.equal(
			rewrite(
				'tools/x.cjs',
				"const T = path.join(SHARED, 'zz_probe_mod', 'hotstrings', 'a.toml');"
			),
			"const T = path.join(SHARED, 'zz_probe_hs', 'data', 'a.toml');",
			'pieces joined onto a _shared base'
		);
		assert.equal(
			rewrite(
				'tools/x.cjs',
				"base = 'file:///A.app/Contents/Resources/_shared/zz_probe_mod/hotstrings/';"
			),
			"base = 'file:///A.app/Contents/Resources/_shared/zz_probe_hs/data/';",
			'a bundle path embeds the tree'
		);
		assert.equal(
			rewrite('tools/x.cjs', 'const T = `${SP}/_shared/zz_probe_mod/hotstrings/a.toml`;'),
			'const T = `${SP}/_shared/zz_probe_hs/data/a.toml`;',
			'a tree path joined onto the drivers root'
		);
		assert.equal(
			rewrite(`${P}linux/y.lua`, 'local d = root .. "/zz_probe_mod/hotstrings"'),
			'local d = root .. "/zz_probe_mod/hotstrings"',
			'outside Paths.shared the driver folder wins, and it stays'
		);
		assert.equal(
			rewrite(
				`${P}linux/y.lua`,
				'mkdir(base .. "/zz_probe_mod/hotstrings"); copy(base .. "/zz_probe_mod/hotstrings/a.toml")'
			),
			'mkdir(base .. "/zz_probe_hs/data"); copy(base .. "/zz_probe_hs/data/a.toml")',
			'a fixture tree that spells a shared file names its folder as the shared one too'
		);
		assert.equal(
			rewrite(
				'tools/t.lua',
				'loadfile(repo .. "/static/ergopti_plus/_shared/zz_probe_lua/codec/x.lua")'
			),
			'loadfile(repo .. "/static/ergopti_plus/_shared/zz_probe_text/codec/x.lua")'
		);
		assert.equal(
			rewrite(`${P}_shared/tests/corpus/redaction.json`, '{"in": "<config>/zz_probe_hot"}'),
			'{"in": "<config>/zz_probe_hot"}',
			'a user path in a corpus is not a folder of the old shared Lua root'
		);
		const own = `${P}macos/zz_probe_llm/binary.lua`;
		assert.equal(
			rewrite(own, 'local m = dofile(dir .. "../zz_probe_vendor/manifest.lua")'),
			'local m = dofile(dir .. "../../zz_probe_vendor/manifest.lua")',
			'a moving file respells a relative path to a file that stays'
		);
		assert.equal(
			rewrite(own, 'local root = source:match("^(.*)/zz_probe_llm/binary%.lua$")'),
			'local root = source:match("^(.*)/zz_ai/adapters/binary%.lua$")'
		);
	});

	const climbs = Plan.ownClimbs(
		'local source = debug.getinfo(1, "S").source:gsub("^@", "")\n' +
			'local shared = NativePath.dirname(assert(NativePath.dirname(assert(NativePath.dirname(source)))))',
		'_shared/lua/test/x_contract.lua',
		'_shared/tests/lua/core/x_contract.lua'
	);
	assert.deepEqual(climbs, [
		{
			old: 'NativePath.dirname(assert(NativePath.dirname(assert(NativePath.dirname(source)))))',
			new: 'NativePath.dirname(assert(NativePath.dirname(assert(NativePath.dirname(assert(NativePath.dirname(source)))))))'
		}
	]);
	// One climb per line: a folder deeper needs one line more.
	assert.deepEqual(
		Plan.ownClimbs(
			[
				'local src = debug and debug.getinfo and debug.getinfo(1, "S") and debug.getinfo(1, "S").source',
				'\tlocal shared = NativePath.dirname(src)',
				'\tshared = shared and NativePath.dirname(shared)',
				'\tshared = shared and NativePath.dirname(shared)'
			].join('\n'),
			'_shared/lua/keycodes/evdev.lua',
			'_shared/platform/input/keycodes/evdev.lua'
		).map((c) => c.new.split('\n').length),
		[5 - 1]
	);
	assert.deepEqual(
		Plan.ownTails(
			'local root = source:match("^(.*)" .. sep .. "lua" .. sep .. "test" .. sep .. "m_contract%.lua$")',
			'_shared/lua/test/m_contract.lua',
			'_shared/tests/lua/settings/m_contract.lua'
		).map((t) => t.new),
		['"^(.*)" .. sep .. "tests" .. sep .. "lua" .. sep .. "settings" .. sep .. "m_contract%.lua$"']
	);
	assert.deepEqual(
		Plan.ownTails(
			'return source:match("^(.*)/infra/[^/]+$")',
			'macos/infra/dev_source.lua',
			'macos/core/lifecycle/engine/dev_source.lua'
		).map((t) => t.new),
		['/core/lifecycle/engine/[^/]+$']
	);
	// A rewritten path is final: the folder row _shared/core → _shared must not
	// rewrite inside the new …/_shared/core/network/data/x.json a file row wrote.
	const repoRow = (old, next, kind = 'path') => ({
		kind,
		old,
		new: next,
		file: 'tools/x.cjs',
		resolution: { form: 'repo', lead: '', newRepo: next }
	});
	assert.equal(
		Apply.rewriteText(
			"a = 'static/ergopti_plus/_shared/data/x.json'; b = 'static/ergopti_plus/_shared/core'",
			[
				repoRow(
					'static/ergopti_plus/_shared/data/x.json',
					'static/ergopti_plus/_shared/core/network/data/x.json'
				),
				repoRow('static/ergopti_plus/_shared/core', 'static/ergopti_plus/_shared', 'dir-successor')
			],
			new Map(),
			'tools/x.cjs'
		),
		"a = 'static/ergopti_plus/_shared/core/network/data/x.json'; b = 'static/ergopti_plus/_shared'"
	);
	// driver_root() .. "/../_shared/x" in a _shared file climbs from a driver root.
	assert.equal(
		Apply.newPathToken(
			{
				old: '/../_shared/modules/menu/menu_manifest.json',
				file: `${P}_shared/lua/test/m_contract.lua`,
				resolution: { form: 'root', lead: '', newRepo: `${P}_shared/menu/data/menu_manifest.json` }
			},
			new Map()
		),
		'/../_shared/menu/data/menu_manifest.json'
	);
	// A corpus captured byte for byte (its SHA-256 pinned elsewhere) keeps the
	// old paths it holds: rewriting its header broke the legacy reader's pin.
	const pinned = Plan.pinnedBytes();
	assert.ok(
		pinned.has(
			`${P}_shared/tests/corpus/hotstrings/common_autocorrection_legacy/autocorrection.toml`
		),
		'the captured legacy autocorrection corpus is pinned'
	);
	assert.ok(
		![...pinned].some((f) => /\.(lua|ahk)$/.test(f)),
		'no source file is exempt: a digest manifest follows its sources'
	);
	// What a rewrite leaves inconsistent beside the path it changed.
	assert.equal(
		Apply.repairCoupled(
			'if r:sub(1, 12) == "_shared/lua/" then end',
			'if r:sub(1, 12) == "_shared/" then end'
		),
		'if r:sub(1, 8) == "_shared/" then end',
		'a prefix check keeps measuring its literal'
	);
	assert.equal(
		Apply.repairCoupled(
			'for _, dir in ipairs({ d, d .. "/a", d .. "/a/b" }) do uv.fs_mkdir(dir, 448) end',
			'for _, dir in ipairs({ d, d .. "/x", d .. "/x", d .. "/x/y/z" }) do uv.fs_mkdir(dir, 448) end'
		),
		'for _, dir in ipairs({ d, d .. "/x", d .. "/x/y", d .. "/x/y/z" }) do uv.fs_mkdir(dir, 448) end',
		'a fixture tree built one mkdir at a time creates each folder once, parents first'
	);
	assert.equal(
		Apply.repairCoupled(
			'for _, r in ipairs({ "a", "a/b" }) do mkdir(w .. "/" .. r) end',
			'for _, r in ipairs({ "x", "x", "x/y/z" }) do mkdir(w .. "/" .. r) end'
		),
		'for _, r in ipairs({ "x", "x/y", "x/y/z" }) do mkdir(w .. "/" .. r) end',
		'the same with bare relative entries joined onto a base by the loop'
	);
	// A join that climbs out of the repository has no folder to follow; the
	// search for one stopped at '.' forever and hung the first S01 apply.
	Plan.scanFile(
		'tools/test/z.cjs',
		"const ROOT = path.resolve(__dirname, '..', '..');\nconst X = path.join(ROOT, '..', 'zz_nowhere', 'y.txt');\n",
		Plan.referenceContext(MAP)
	);
	// A generated table is one long run of path characters with no file
	// name in it; the scan stays linear (the first S01 apply spent three
	// minutes on a 400 KB table, retrying the token at every position).
	const run = 'a-b_c%d'.repeat(30000);
	const started = Date.now();
	Plan.scanFile('tools/z.cjs', `const t = '${run}';`, Plan.referenceContext(MAP));
	assert.ok(Date.now() - started < 5000, 'a long run of path characters scans in linear time');
	// Every listed edit still matches the file it names, so the step that
	// empties its folder rewrites it instead of refusing.
	const full = Plan.moveMap().map;
	const fullCtx = Plan.referenceContext(full);
	const repo = path.resolve(__dirname, '..', '..');
	for (const e of Edits.FOLDER_EDITS) {
		// Once applied (the proof branch), the folder is gone and so is the
		// text, or the file itself moved with it.
		if (!fs.existsSync(path.join(repo, e.file))) continue;
		const text = fs.readFileSync(path.join(repo, e.file), 'utf8');
		if (!fs.existsSync(path.join(repo, P, e.moves || e.empties)) && !text.includes(e.from))
			continue;
		const kinds = Plan.scanFile(e.file, text, fullCtx)
			.filter((r) => r.old === e.from)
			.map((r) => r.kind);
		assert.deepEqual(kinds, ['folder-edit'], `${e.file}: the listed edit applies`);
	}
	// The resolver walk test prefixes the llm wrapper's argument and expects
	// the prefixed request: both edits of its folder land, or the walk fails.
	const resolverTest = 'tools/test/test-shared-root-resolvers.cjs';
	if (fs.existsSync(path.join(repo, resolverTest))) {
		const before = fs.readFileSync(path.join(repo, resolverTest), 'utf8');
		const after = Apply.rewriteText(
			before,
			Plan.scanFile(resolverTest, before, fullCtx),
			new Map(),
			resolverTest
		);
		const prefix = after.match(/'shared_llm_path' \? `([^`$]*)\$\{arg\}`/)[1];
		const expected = after
			.match(/\[\.\.\.requested\.keys\(\)\]\.sort\(\), \[([^\]]*)\]/)[1]
			.match(/'[^']*'/g)
			.map((t) => t.slice(1, -1));
		assert.ok(expected.includes(`${prefix}fixture.json`), `${resolverTest}: ${prefix} expected`);
		assert.deepEqual(
			expected,
			[...expected].sort(),
			`${resolverTest}: the expected list stays sorted`
		);
	}
	// The gate coverage test probes a contract under each tree verify-change
	// holds binding on every driver: both edits of _shared/core land together.
	const rewritten = (file) => {
		const before = fs.readFileSync(path.join(repo, file), 'utf8');
		return Apply.rewriteText(before, Plan.scanFile(file, before, fullCtx), new Map(), file);
	};
	if (fs.existsSync(path.join(repo, P, '_shared/core/config_schema'))) {
		const selector = rewritten('tools/test/verify-change.cjs');
		const trees = rewritten('tools/test/test-shared-lua-gate-coverage.cjs')
			.match(/for \(const tree of \[([^\]]*)\]\)/)[1]
			.match(/'[^']*'/g)
			.map((t) => t.slice(1, -1));
		for (const tree of trees)
			assert.ok(
				selector.includes(`f.startsWith('static/ergopti_plus/_shared/${tree}/')`),
				`verify-change holds _shared/${tree} binding on every driver`
			);
	}
	// A file of synthetic coordinates keeps them all: rewriting the arguments of
	// sibling() and not its fake source made the loader contract fail.
	const moved = new Map([...full].filter(([o, t]) => t && o !== t).map(([o, t]) => [P + o, P + t]));
	for (const e of Edits.SYNTHETIC_PATHS) {
		if (!fs.existsSync(path.join(repo, e.file))) continue;
		const text = fs.readFileSync(path.join(repo, e.file), 'utf8');
		const out = Apply.rewriteText(text, Plan.scanFile(e.file, text, fullCtx), moved, e.file);
		const coordinates = (t) => t.split('\n').filter((l) => /@[A-Za-z]?:?[/.\\]/.test(l));
		assert.deepEqual(coordinates(out), coordinates(text), `${e.file}: ${e.why}`);
	}
	// \..\..\_shared\lua\x.lua in an AutoHotkey script climbs to the tree it
	// names: its backslashes separate, they escape nothing. Read as escaped,
	// the path stayed; read against the shared Lua root, it lost its climb.
	const climbed = '_shared/lua/keystats/aggregator_helpers.lua';
	if (fs.existsSync(path.join(repo, P, climbed)) && full.get(climbed) !== climbed) {
		const ahk = 'static/ergopti_plus/windows/tests/unit/z.ahk';
		const line =
			'\tPath := A_ScriptDir . "\\..\\..\\_shared\\lua\\keystats\\aggregator_helpers.lua"\n';
		const out = Apply.rewriteText(line, Plan.scanFile(ahk, line, fullCtx), moved, ahk);
		assert.equal(
			out,
			`\tPath := A_ScriptDir . "\\..\\..\\${full.get(climbed).replace(/\//g, '\\')}"\n`,
			'an AutoHotkey climb keeps its climb and follows the file'
		);
	}
	// A list of a driver's folders naming one a step's file leaves names the
	// folder it moves into: S02 took crypto out of adapters into core, and
	// every scanner list, fixture copy and test group missed core.
	const gainMap = new Map([
		['windows/adapters/crypto.ahk', 'windows/core/crypto/crypto.ahk'],
		['windows/infra/a.ahk', 'windows/infra/a.ahk'],
		['windows/platform/b.ahk', 'windows/platform/b.ahk']
	]);
	const gainText =
		"const T = ['adapters', 'infra', 'platform'];\n" +
		'const G = /^unit\\/(adapters|infra)\\//;\n' +
		"const D = ['adapters', 'docs'];\n";
	assert.equal(
		Apply.rewriteText(
			gainText,
			Plan.scanFile('tools/test/z.cjs', gainText, Plan.referenceContext(gainMap)),
			new Map(),
			'tools/test/z.cjs'
		),
		"const T = ['adapters', 'infra', 'platform', 'core'];\n" +
			'const G = /^unit\\/(adapters|infra|core)\\//;\n' +
			"const D = ['adapters', 'docs'];\n",
		'a sibling folder list gains the folder the step creates'
	);
	// $shared = Join-Path $PSScriptRoot '..\..\static\ergopti_plus\_shared', then
	// Join-Path $shared 'modules\control\x.json': the joined path follows its
	// file. Left as it was, the control CLI read a spec S01 had moved.
	const control = '_shared/modules/control/driver_control.json';
	if (fs.existsSync(path.join(repo, P, control)) && full.get(control) !== control) {
		const ps1 = 'tools/control/z.ps1';
		const script =
			"$shared = Join-Path $PSScriptRoot '..\\..\\static\\ergopti_plus\\_shared'\n" +
			"$spec = Join-Path $shared 'modules\\control\\driver_control.json'\n";
		const out = Apply.rewriteText(script, Plan.scanFile(ps1, script, fullCtx), moved, ps1);
		const rel = full.get(control).slice('_shared/'.length).replace(/\//g, '\\');
		assert.ok(
			out.includes(`Join-Path $shared '${rel}'`),
			'a PowerShell joined path follows its file'
		);
	}
	// "im)^#Include\s+\.\./_shared/modules/x\.ahk\s*$" in an AutoHotkey meta
	// test checks the entry's #Include: it follows the file, dots escaped. Left
	// as it was, the boot-order check found no policy include after S01.
	const policy = '_shared/modules/features/layout_rows_policy.ahk';
	if (fs.existsSync(path.join(repo, P, policy)) && full.get(policy) !== policy) {
		const ahk = 'static/ergopti_plus/windows/tests/meta/z.ahk';
		const line =
			'P := RegExMatch(E, "im)^#Include\\s+\\.\\./_shared/modules/features/layout_rows_policy\\.ahk\\s*$")\n';
		const out = Apply.rewriteText(line, Plan.scanFile(ahk, line, fullCtx), moved, ahk);
		const spelled = `\\.\\./${full.get(policy).replace(/\./g, '\\.')}`;
		assert.ok(out.includes(spelled), `an AutoHotkey include regex follows its file: ${out}`);
	}
	// [IO.Path]::Combine($SharedRoot, 'data', 'identifiers.json') with
	// $SharedRoot = [IO.Path]::Combine($RepoRoot, 'static', 'ergopti_plus',
	// '_shared'): the pieces follow the file. Left as they were, the Windows
	// field report collector read identifiers S01 had moved.
	const ids = '_shared/data/identifiers.json';
	if (fs.existsSync(path.join(repo, P, ids)) && full.get(ids) !== ids) {
		const ps1 = 'tools/dev/z.ps1';
		const script =
			"$SharedRoot = [IO.Path]::Combine($RepoRoot, 'static', 'ergopti_plus', '_shared')\n" +
			"$I = [IO.Path]::Combine($SharedRoot, 'data', 'identifiers.json')\n";
		const out = Apply.rewriteText(script, Plan.scanFile(ps1, script, fullCtx), moved, ps1);
		const fresh = full
			.get(ids)
			.slice('_shared/'.length)
			.split('/')
			.map((x) => `'${x}'`)
			.join(', ');
		assert.ok(
			out.includes(`[IO.Path]::Combine($SharedRoot, ${fresh})`),
			'a PowerShell Combine path follows its file'
		);
	}
	// MAC + 'tests/support/x.swift' with const MAC = 'static/ergopti_plus/macos/':
	// a path concatenated onto a constant the file defines follows its file.
	// Left as it was, the native HTTP clock evidence listed a moved fixture.
	const concat = 'macos/tests/support/native_http_fixture_main.swift';
	if (fs.existsSync(path.join(repo, P, concat)) && full.get(concat) !== concat) {
		const js = 'tools/ci/z.cjs';
		const src =
			"const MAC = 'static/ergopti_plus/macos/';\nconst F = MAC + 'tests/support/native_http_fixture_main.swift';\n";
		const out = Apply.rewriteText(src, Plan.scanFile(js, src, fullCtx), moved, js);
		assert.ok(
			out.includes(`MAC + '${full.get(concat).slice('macos/'.length)}'`),
			`a path concatenated onto a known constant follows its file: ${out}`
		);
	}
	// RELAY_SOURCE + 'cmd/x/main.go' where RELAY_SOURCE's own folder moves with
	// the step: the piece stays spelled from the constant's new place, never a
	// refusal (S01 refused the Linux native artifacts list).
	const relay = '_shared/go/native_http/cmd/ergopti-proxy-relay/main.go';
	if (fs.existsSync(path.join(repo, P, relay)) && full.get(relay) !== relay) {
		const js = 'tools/test/z.cjs';
		const src =
			"const RELAY_SOURCE = 'static/ergopti_plus/_shared/go/native_http/';\n" +
			"const F = RELAY_SOURCE + 'cmd/ergopti-proxy-relay/main.go';\n";
		const rows = Plan.scanFile(js, src, fullCtx);
		assert.ok(!rows.some((r) => r.kind === 'dir-split'), 'a moving constant is no refusal');
		const out = Apply.rewriteText(src, rows, moved, js);
		assert.ok(out.includes("RELAY_SOURCE + 'cmd/ergopti-proxy-relay/main.go'"), out);
	}
	// Third-party code keeps its own paths; our scripts in a vendor folder move.
	assert.ok(Plan.neverRewritten('static/ergopti_plus/_shared/ui/vendor/fengari-web.js'));
	assert.ok(Plan.neverRewritten('static/ergopti_plus/windows/vendor/WebView2.ahk'));
	assert.ok(!Plan.neverRewritten('static/ergopti_plus/windows/vendor/ergopti_uninstall.ps1'));
	console.log('[OK] every path form the structure plan rewrites follows the moved file.');
}

run();
