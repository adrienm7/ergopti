// tools/audit/structure/edits.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Explicit Edits
 * DESCRIPTION:
 * The few sites whose new text is a decision rather than a rewrite: a scan
 * over a folder the plan scatters, whose new scope (what it must now include
 * or skip) no path rule can know. Each edit names the file as it stands when
 * the edit runs, the folder whose emptying triggers it (tree-relative), or
 * with `moves` the file whose move does, and its exact text before and after.
 * A `from` the file no longer holds refuses the step instead of passing
 * silently.
 *
 * This file is never rewritten by the steps (plan.cjs NEVER_REWRITTEN): its
 * texts are what the files hold before their step.
 * ==============================================================================
 */

'use strict';

const FOLDER_EDITS = [
	{
		// _shared/modules and _shared/lua become the feature folders of _shared:
		// the scan reads all of it but the tests and the migration registry,
		// which must keep naming the retired key until explicit cleanup.
		file: 'tools/test/test-space-wrap-toggle-retired.cjs',
		empties: '_shared/lua',
		from: `	{ dir: path.join(SP, '_shared', 'modules'), exts: ['.toml', '.json', '.lua'] },
	{ dir: path.join(SP, '_shared', 'lua'), exts: ['.lua'], skip: ['test'] },`,
		to: `	{ dir: path.join(SP, '_shared'), exts: ['.toml', '.json', '.lua'], skip: ['tests', 'settings'] },
	{ dir: path.join(SP, '_shared', 'settings'), exts: ['.toml', '.json', '.lua'], skip: ['data'] },
	{ dir: path.join(SP, '_shared', 'settings', 'data'), exts: ['.toml', '.json', '.lua'], skip: ['config_schema'] },`
	},
	{
		// _shared/keymap/ and _shared/data/keycodes/ join the layouts data folder.
		file: 'tools/test/test-shared-contract-gate-coverage.cjs',
		empties: '_shared/keymap',
		from: `const SHARED_TREES = ['core', 'tests', 'keymap'];
const SHARED_FILES = ['data/keycodes/physical_keys.json'];`,
		to: `const SHARED_TREES = ['core', 'tests', 'layouts/data'];
const SHARED_FILES = ['layouts/data/keycodes/physical_keys.json'];`
	},
	{
		// A one-word module name in a table field the load-site rule cannot tell
		// from an error record's module tag.
		file: 'static/ergopti_plus/_shared/lua/test/byte_limits_contract.lua',
		empties: '_shared/lua',
		from: '{ module = "program_providers", field = "MAX_CATALOGUE_BYTES"',
		to: '{ module = "apps.engine.program_providers", field = "MAX_CATALOGUE_BYTES"'
	},
	{
		// The site loader check matches the folder by a regular expression.
		file: 'tools/test/test-action-catalogue-codegen.cjs',
		empties: '_shared/modules/actions',
		from: '/ACTIONS_ROOT[\\s\\S]*?modules[/\\\\]actions/.test(SITE_LOADER)',
		to: '/ACTIONS_ROOT[\\s\\S]*?shortcuts[/\\\\]data[/\\\\]actions/.test(SITE_LOADER)'
	},
	{
		// Paths.shared_llm_path(name) resolves under the AI data folder.
		file: 'tools/test/test-shared-root-resolvers.cjs',
		empties: '_shared/modules/llm',
		from: "m[1] === 'shared_llm_path' ? `modules/llm/${arg}` : arg",
		to: "m[1] === 'shared_llm_path' ? `ai/data/${arg}` : arg"
	},
	{
		// The walk fixture's expected request of that wrapper, under the same
		// folder and in the sorted place its new name takes.
		file: 'tools/test/test-shared-root-resolvers.cjs',
		empties: '_shared/modules/llm',
		from: "[...requested.keys()].sort(), [\n\t\t'missing-runtime.txt',\n\t\t'modules/llm/fixture.json',",
		to: "[...requested.keys()].sort(), [\n\t\t'ai/data/fixture.json',\n\t\t'missing-runtime.txt',"
	},
	{
		// The E2E bootstrap check joins the shared decoder onto run_e2e.lua's
		// own shared_lua variable, which no scan of this file can read.
		file: 'tools/test/test-bash-resolution.cjs',
		empties: '_shared/lua',
		from: 'assert(json_path == shared_lua .. "/json.lua"',
		to: 'assert(json_path == shared_lua .. "/core/text/engine/json.lua"'
	},
	{
		// The serve-command receiving test copies the shared Python the emitted
		// command loads; S01 splits _shared/python into the ai and network
		// features, so the one source folder becomes the two it lands in.
		file: 'tools/diagnostics/macos_ollama_serve_command_receiving_test.py',
		empties: '_shared/python',
		from: '                "static/ergopti_plus/_shared/python",',
		to: '                "static/ergopti_plus/_shared/ai/adapters/python",\n                "static/ergopti_plus/_shared/core/network/adapters",'
	},
	{
		// The bundle guard's needle for the daemon authority's shared load: the
		// longer path no longer fits the Python line, and the formatter breaks
		// the expression before its operator, as the needle now spells it.
		file: 'tools/test/test-macos-bundle-payload.cjs',
		empties: '_shared/python',
		from: `'Path(__file__).absolute().parents[2] / "_shared/python/managed_ollama_daemon_authority.py"'`,
		to: `'Path(__file__).absolute().parents[2]\\n    / "_shared/ai/adapters/python/managed_ollama_daemon_authority.py"'`
	},
	{
		// The sourcing gate's self-test sources the identifiers from a synthetic
		// script three folders below _shared, which no move carries along.
		file: 'tools/test/test-shell-identifiers-sourcing.cjs',
		moves: '_shared/data/identifiers.sh',
		from: `'. "$SCRIPT_DIR/../../../data/identifiers.sh"',`,
		to: `'. "$SCRIPT_DIR/../../../core/text/data/identifiers.sh"',`
	},
	{
		// The shared helper ratchet scans the production Lua of _shared/lua but
		// its tests. The root switch widens the scan to _shared, whose test tree
		// (tests/lua and the fixtures beside it) it must skip whole.
		file: 'tools/test/test-shared-lua-helpers-single-use.cjs',
		empties: '_shared/lua',
		from: "{ dir: '_shared/lua', excluded: '_shared/lua/test/', minFiles: 200 }",
		to: "{ dir: '_shared', excluded: '_shared/tests/', minFiles: 200 }"
	},
	// The port compliance gate reads the AHK adapters of windows/adapters. S02
	// moves the crypto adapter to windows/core/crypto, and the folder's nearest
	// new home is the driver root, whose top level holds no adapter: the gate
	// reads both homes instead.
	{
		file: 'tools/test/test-port-compliance.cjs',
		moves: 'windows/adapters/crypto.ahk',
		from: "const AHK_ADAPTERS_DIR = path.join(ROOT, 'static/ergopti_plus/windows/adapters');",
		to:
			'const AHK_ADAPTERS_DIRS = [\n' +
			"\tpath.join(ROOT, 'static/ergopti_plus/windows/adapters'),\n" +
			"\tpath.join(ROOT, 'static/ergopti_plus/windows/core/crypto')\n" +
			'];'
	},
	{
		file: 'tools/test/test-port-compliance.cjs',
		moves: 'windows/adapters/crypto.ahk',
		from:
			'const ahkFiles = fs\n' +
			'\t.readdirSync(AHK_ADAPTERS_DIR)\n' +
			"\t.filter((f) => f.endsWith('.ahk'))\n" +
			'\t.map((f) => path.join(AHK_ADAPTERS_DIR, f));',
		to:
			'const ahkFiles = AHK_ADAPTERS_DIRS.flatMap((dir) =>\n' +
			'\tfs\n' +
			'\t\t.readdirSync(dir)\n' +
			"\t\t.filter((f) => f.endsWith('.ahk'))\n" +
			'\t\t.map((f) => path.join(dir, f))\n' +
			');'
	},
	{
		file: 'tools/test/test-port-compliance.cjs',
		moves: 'windows/adapters/crypto.ahk',
		from:
			'\tconst adapterFile = path.join(\n' +
			'\t\tAHK_ADAPTERS_DIR,\n' +
			"\t\tpascalToUpperSnake(portName).toLowerCase() + '.ahk'\n" +
			'\t);',
		to:
			'\tconst adapterName = pascalToUpperSnake(portName).toLowerCase();\n' +
			'\tconst adapterFile =\n' +
			'\t\tAHK_ADAPTERS_DIRS.map((dir) => path.join(dir, `${adapterName}.ahk`)).find((f) =>\n' +
			'\t\t\tfs.existsSync(f)\n' +
			'\t\t) || path.join(AHK_ADAPTERS_DIRS[0], `${adapterName}.ahk`);'
	},
	{
		// windows/platform was never in the convention lint's scan; S28 moves this
		// file into keyboard/engine, which is, and its banner was never balanced.
		// The fix lands with the move, so the cohort receipt pinning it is
		// requalified there.
		file: 'static/ergopti_plus/windows/platform/remap/altgr_criteria.ahk',
		moves: 'windows/platform/remap/altgr_criteria.ahk',
		from: '; ==============================================\n; ==============================================\n; ======= 1/ AltGr tap-hold owner criteria =====\n; ==============================================\n; ==============================================\n',
		to: '; ================================================\n; ================================================\n; ======= 1/ AltGr tap-hold owner criteria =======\n; ================================================\n; ================================================\n'
	},
	{
		// windows/platform was never in the convention lint's scan; S28 moves this
		// file into keyboard/engine, which is, and its first section followed
		// #Requires with no blank line. The fix lands with the move, so the cohort
		// receipt pinning it is requalified there.
		file: 'static/ergopti_plus/windows/platform/remap/one_shot_shift.ahk',
		moves: 'windows/platform/remap/one_shot_shift.ahk',
		from: '#Requires AutoHotkey v2.0\n; ====',
		to: '#Requires AutoHotkey v2.0\n\n\n\n\n\n; ===='
	},
	{
		// windows/platform was never in the convention lint's scan; S34 moves this
		// file into tap_hold/engine, which is, and one section had four blank lines
		// before it. The fix lands with the move, so the cohort receipt pinning it
		// is requalified there.
		file: 'static/ergopti_plus/windows/platform/remap/tap_hold_loader.ahk',
		moves: 'windows/platform/remap/tap_hold_loader.ahk',
		from: '\treturn Resolved\n}\n\n\n\n\n; =========================================',
		to: '\treturn Resolved\n}\n\n\n\n\n\n; ========================================='
	},
	{
		// windows/platform was never in the convention lint's scan; S34 moves this
		// file into tap_hold/engine, which is, and its first section followed the
		// includes with one blank line. The fix lands with the move, so the cohort
		// receipt pinning it is requalified there.
		file: 'static/ergopti_plus/windows/platform/remap/tap_hold_writer.ahk',
		moves: 'windows/platform/remap/tap_hold_writer.ahk',
		// Anchored after the include, which earlier steps respell.
		from: 'native_number.ahk\n\n; ===========================\n; ======',
		to: 'native_number.ahk\n\n\n\n\n\n; ===========================\n; ======'
	},
	{
		// The neutral category's expected tail names the bundled hotstrings
		// root by its last folder; S01 makes that root hotstrings/data/catalogue.
		// No file has the tail, so no path rule can follow it.
		file: 'static/ergopti_plus/windows/tests/unit/modules/hotstrings/catalogue/test_hotstring_language_packs.ahk',
		moves: '_shared/modules/hotstrings/_index.toml',
		from: 'AssertTrue(SubStr(Neutral, -StrLen("\\hotstrings\\autocorrection.toml")) == "\\hotstrings\\autocorrection.toml",',
		to: 'AssertTrue(SubStr(Neutral, -StrLen("\\catalogue\\autocorrection.toml")) == "\\catalogue\\autocorrection.toml",'
	},
	{
		// The section order vectors name a bundled file by its tail under the
		// shared hotstrings root, which S01 moves to hotstrings/data/catalogue.
		// The folder alone would read as the driver's own modules/hotstrings.
		file: 'static/ergopti_plus/windows/tests/unit/infra/config/scope/test_hotstring_category_scope.ahk',
		moves: '_shared/modules/hotstrings/_index.toml',
		from: 'Wanted := "\\modules\\hotstrings\\" . (Vector',
		to: 'Wanted := "\\hotstrings\\data\\catalogue\\" . (Vector'
	},
	{
		// The source contract test pins the clock evidence's expression as text;
		// S38 moves the fixture into tests/support/core, and the expression
		// follows it there (MAC + '...' is rewritten in the evidence itself).
		file: 'tools/test/test-native-pac-source-contract.cjs',
		moves: 'macos/tests/support/native_http_fixture_main.swift',
		from: "(MAC + 'tests/support/native_http_fixture_main.swift',)",
		to: "(MAC + 'tests/support/core/native_http_fixture_main.swift',)"
	},
	{
		// The manifest reader climbs one named folder per level to its driver;
		// S19 moves it from infra/ into menu/engine/, one level deeper.
		file: 'static/ergopti_plus/macos/infra/manifest_reader.lua',
		moves: 'macos/infra/manifest_reader.lua',
		from: 'local infra_dir = NativePath.dirname(source) or source\nlocal driver_dir = NativePath.dirname(infra_dir) or infra_dir',
		to: 'local engine_dir = NativePath.dirname(source) or source\nlocal feature_dir = NativePath.dirname(engine_dir) or engine_dir\nlocal driver_dir = NativePath.dirname(feature_dir) or feature_dir'
	},
	{
		// The manifest reader climbs one named folder per level to its driver;
		// S19 moves it from infra/ into menu/engine/, one level deeper.
		file: 'static/ergopti_plus/linux/infra/manifest_reader.lua',
		moves: 'linux/infra/manifest_reader.lua',
		from: 'local infra_dir = NativePath.dirname(source) or source\nlocal driver_dir = NativePath.dirname(infra_dir) or infra_dir',
		to: 'local engine_dir = NativePath.dirname(source) or source\nlocal feature_dir = NativePath.dirname(engine_dir) or engine_dir\nlocal driver_dir = NativePath.dirname(feature_dir) or feature_dir'
	},
	{
		// The lease helper finds its driver by the names of the folders it sits
		// in; S28 moves it from platform/remap to keyboard/adapters/karabiner.
		file: 'static/ergopti_plus/macos/platform/remap/lease_helper.lua',
		moves: 'macos/platform/remap/lease_helper.lua',
		from: '\tlocal remap = NativePath.dirname(source)\n\tlocal platform = remap and NativePath.basename(remap) == "remap" and NativePath.dirname(remap) or nil\n\tif not platform or NativePath.basename(platform) ~= "platform" then return nil end\n\treturn NativePath.dirname(platform)',
		to: '\tlocal karabiner = NativePath.dirname(source)\n\tlocal adapters = karabiner and NativePath.basename(karabiner) == "karabiner" and NativePath.dirname(karabiner) or nil\n\tlocal keyboard = adapters and NativePath.basename(adapters) == "adapters" and NativePath.dirname(adapters) or nil\n\tif not keyboard or NativePath.basename(keyboard) ~= "keyboard" then return nil end\n\treturn NativePath.dirname(keyboard)'
	},
	{
		// The webview manager finds its driver by the folder it sits in; S12
		// moves it from ui/ to core/ui/ui/, two levels deeper.
		file: 'static/ergopti_plus/linux/ui/webview_manager.lua',
		moves: 'linux/ui/webview_manager.lua',
		from: '\tif NativePath.basename(src) ~= "ui" then return "." end\n\treturn NativePath.dirname(src) or "."',
		to: '\tif NativePath.basename(src) ~= "ui" then return "." end\n\tlocal feature = NativePath.dirname(src) or ""\n\tif NativePath.basename(feature) ~= "ui" then return "." end\n\tlocal core = NativePath.dirname(feature) or ""\n\tif NativePath.basename(core) ~= "core" then return "." end\n\treturn NativePath.dirname(core) or "."'
	},
	{
		// The remap core reads the keyboard data beside it; S28 moves the core
		// into keyboard/engine and the data into keyboard/data.
		file: 'static/ergopti_plus/macos/platform/remap/init.lua',
		moves: 'macos/platform/remap/data/tap_hold_keys.json',
		from: 'or "./") .. "data/"',
		to: 'or "./") .. "../data/"'
	},
	{
		// The tap-hold file reads the same data from platform/remap until S34
		// moves it to tap_hold/engine, as deep: both reach keyboard/data alike.
		file: 'static/ergopti_plus/macos/platform/remap/tap_hold_file.lua',
		moves: 'macos/platform/remap/data/tap_hold_keys.json',
		from: 'or "./") .. "data/"',
		to: 'or "./") .. "../../keyboard/data/"'
	},
	{
		// The tray source reader read every section from ui/menu/; the sections
		// leave it for their features from S18 on, so it finds each by name.
		file: 'static/ergopti_plus/linux/tests/helpers.lua',
		moves: 'linux/ui/menu/menu_configuration.lua',
		from: '\tlocal directory = M.driver_root() .. "/ui/menu/"\n\tlocal function read(name)\n\t\tlocal handle = assert(io.open(directory .. name .. ".lua", "rb"))\n\t\tlocal text = assert(handle:read("*a"))\n\t\tassert(handle:close())\n\t\treturn text\n\tend\n\t-- A part may bind another part (the dialogs), which the root no longer names.\n\tlocal texts, seen, index = { read("builder") }, {}, 1\n\twhile texts[index] do\n\t\tfor name in texts[index]:gmatch(\'require%("ui%.menu%.(menu_[a-z_]+)"%)\') do\n\t\t\tif not seen[name] then\n\t\t\t\tseen[name] = true\n\t\t\t\ttexts[#texts + 1] = read(name)\n\t\t\tend\n\t\tend',
		to: '\tlocal root = M.driver_root()\n\tlocal search = root .. "/?.lua;" .. root .. "/?/init.lua"\n\tlocal function read(path)\n\t\tlocal handle = assert(io.open(path, "rb"))\n\t\tlocal text = assert(handle:read("*a"))\n\t\tassert(handle:close())\n\t\treturn text\n\tend\n\t-- A part may bind another part (the dialogs), which the root no longer names.\n\t-- The sections live in their features\' folders: each is found by its module\n\t-- name; a menu module outside the driver (a shared one) is not a section.\n\tlocal texts, seen, index = { read(assert(package.searchpath("ui.menu.builder", search))) }, {}, 1\n\twhile texts[index] do\n\t\tfor name in texts[index]:gmatch(\'require%("([%w_%.]*menu[%w_%.]*)"%)\') do\n\t\t\tlocal path = not seen[name] and package.searchpath(name, search)\n\t\t\tseen[name] = true\n\t\t\tif path then texts[#texts + 1] = read(path) end\n\t\tend'
	},
	{
		// The flush bridge test names each dashboard bridge by its app folder;
		// S30 moves both under metrics/ui.
		file: 'static/ergopti_plus/linux/tests/unit/ui/metrics/test_metrics_flush_bridge.lua',
		moves: 'linux/ui/metrics_apps/bridge.lua',
		from: 'H.load_module("ui." .. app .. ".bridge")',
		to: 'H.load_module("metrics.ui." .. app .. ".bridge")'
	},
	{
		// The native HTTP worker's historical whole-source pin names the bundled
		// proxy policy at its first place; S01 moves the policy, so the reader
		// spells it back there before every pinned projection.
		file: 'tools/test/macos_native_http_receiving_facts_test.py',
		moves: '_shared/modules/network/proxy_policy.json',
		from: 'def worker_source():\n    """Read the worker with the newest reviewed layer peeled, as every historical pin expects."""\n    return managed_lookup_stage_projection(\n        route_kind_observation_projection(WORKER.read_text(encoding="utf-8"))\n    )\n',
		to: '# The structure migration moved the bundled proxy policy into the network\n# feature; every historical pin names its first place.\nSTRUCTURE_MOVE_INVERSE = (\n    (\n        "Contents/Resources/static/ergopti_plus/_shared/core/network/data/proxy_policy.json",\n        "Contents/Resources/static/ergopti_plus/_shared/modules/network/proxy_policy.json",\n    ),\n)\n\n\ndef structure_move_projection(source):\n    """Spell each moved resource at its historical place, exactly once."""\n    for new, old in STRUCTURE_MOVE_INVERSE:\n        if source.count(new) != 1 or old in source:\n            raise ValueError("Structure move projection refused")\n        source = source.replace(new, old, 1)\n    return source\n\n\ndef worker_source():\n    """Read the worker with the newest reviewed layer peeled, as every historical pin expects."""\n    return managed_lookup_stage_projection(\n        route_kind_observation_projection(\n            structure_move_projection(WORKER.read_text(encoding="utf-8"))\n        )\n    )\n'
	},
	{
		// The installed network fixture stages two shared modules under _shared/lua;
		// S01 sends them to folders of different depths, which it must create.
		file: 'tools/test/test-linux-network-runtime.cjs',
		moves: '_shared/lua/json.lua',
		from: "\t\tfs.mkdirSync(path.join(shared, 'lua'), { recursive: true });\n\t\tfs.mkdirSync(cwd);\n\t\tfor (const name of ['runtime_probe.lua', 'native_proxy_runtime.lua'])\n\t\t\tfs.copyFileSync(\n\t\t\t\tpath.join(ROOT, DRIVER, 'platform/network', name),\n\t\t\t\tpath.join(driver, 'platform/network', name)\n\t\t\t);\n\t\tfs.copyFileSync(path.join(ROOT, SHARED, 'lua/json.lua'), path.join(shared, 'lua/json.lua'));\n\t\tfs.mkdirSync(path.join(shared, 'lua/compat'));\n\t\tfs.copyFileSync(\n\t\t\tpath.join(ROOT, SHARED, 'lua/compat/utf8.lua'),\n\t\t\tpath.join(shared, 'lua/compat/utf8.lua')\n\t\t);",
		to: "\t\tfs.mkdirSync(shared, { recursive: true });\n\t\tfs.mkdirSync(cwd);\n\t\tfor (const name of ['runtime_probe.lua', 'native_proxy_runtime.lua'])\n\t\t\tfs.copyFileSync(\n\t\t\t\tpath.join(ROOT, DRIVER, 'platform/network', name),\n\t\t\t\tpath.join(driver, 'platform/network', name)\n\t\t\t);\n\t\t// Each shared module is staged under its own folder, whatever its depth.\n\t\tfor (const name of ['core/text/engine/json.lua', 'core/lifecycle/engine/compat/utf8.lua']) {\n\t\t\tfs.mkdirSync(path.dirname(path.join(shared, name)), { recursive: true });\n\t\t\tfs.copyFileSync(path.join(ROOT, SHARED, name), path.join(shared, name));\n\t\t}"
	},
	{
		// The launcher test climbs from the locales folder to _shared by count;
		// S01 moves the locales two levels deeper, into core/i18n/data.
		file: 'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/CatalogUpdateUserDriverTests.swift',
		moves: '_shared/data/locales/en.json',
		from: '\t\tlet manifestURL = URL(fileURLWithPath: localesDirectory)\n\t\t\t.deletingLastPathComponent().deletingLastPathComponent()\n\t\t\t.appendingPathComponent("ui/apps.manifest.json")',
		to: '\t\tlet manifestURL = URL(fileURLWithPath: localesDirectory)\n\t\t\t.deletingLastPathComponent().deletingLastPathComponent()\n\t\t\t.deletingLastPathComponent().deletingLastPathComponent()\n\t\t\t.appendingPathComponent("ui/apps.manifest.json")'
	},
	{
		// The XI2 receiver derives the shared Lua root from the logger shim's
		// path; S01 moves the shim to core/logger/engine under _shared itself.
		file: 'static/ergopti_plus/linux/tests/hardware/xi2_luajit_receiver.lua',
		moves: '_shared/lua/logger/shim.lua',
		from: 'logger_source:match("^(.*)/logger/shim%.lua$")',
		to: 'logger_source:match("^(.*)/core/logger/engine/shim%.lua$")'
	},
	{
		// The ledger's family contracts leave one folder for two, and lose the
		// name prefixes that told them from their neighbours there.
		file: 'tools/test/test-contract-vector-ledger.cjs',
		moves: '_shared/lua/test/menu_numbered_caption_contract.lua',
		from: "const FAMILY = [[['lua', 'test'], /^(config_scope|toml_|menu_)/]];",
		to:
			'const FAMILY = [\n' +
			"\t[['tests', 'lua', 'menu'], /^(?!feature_notice_contract)/],\n" +
			"\t[['tests', 'lua', 'settings'], /^(scope_(?!owner_|sparse_)|toml_)/]\n" +
			'];'
	},
	{
		// The package setup fixture makes the folder it copies the identifiers
		// into; _shared/data scatters, and its nearest home (_shared) is not
		// where the identifiers land.
		file: 'tools/test/test-linux-package-setup.cjs',
		moves: '_shared/data/identifiers.sh',
		from: "fs.mkdirSync(path.join(bundle, '_shared/data'), { recursive: true });",
		to: "fs.mkdirSync(path.join(bundle, '_shared/core/text/data'), { recursive: true });"
	},
	{
		// The locale is found relative to the page under test, a variable
		// the scan cannot evaluate.
		file: 'tools/test/support/metrics-apps-page.cjs',
		empties: '_shared/data/locales',
		from: "path.resolve(path.dirname(page), '../../data/locales/fr.json')",
		to: "path.resolve(path.dirname(page), '../../core/i18n/data/locales/fr.json')"
	},
	// The Windows bundle excludes three shared folders whole. S01 scatters
	// them, and their nearest new folder (_shared itself) would exclude every
	// shared file: each glob lists the new homes of exactly what it matched.
	{
		file: 'tools/build/windows_bundle_manifest.json',
		empties: '_shared/core/config_schema',
		from: '"globs": ["static/ergopti_plus/_shared/core/**"],',
		to:
			'"globs": [\n\t\t\t\t"static/ergopti_plus/_shared/core/features.json",\n' +
			'\t\t\t\t"static/ergopti_plus/_shared/core/ports/**",\n' +
			'\t\t\t\t"static/ergopti_plus/_shared/core/text/data/domain/**",\n' +
			'\t\t\t\t"static/ergopti_plus/_shared/settings/data/config_schema/**"\n\t\t\t],'
	},
	{
		file: 'tools/build/windows_bundle_manifest.json',
		empties: '_shared/modules',
		from: '"globs": ["static/ergopti_plus/_shared/modules/**/*.js"],',
		to:
			'"globs": [\n\t\t\t\t"static/ergopti_plus/_shared/core/network/data/*.js",\n' +
			'\t\t\t\t"static/ergopti_plus/_shared/core/ui/data/tooltip/*.js",\n' +
			'\t\t\t\t"static/ergopti_plus/_shared/updater/data/*.js"\n\t\t\t],'
	},
	{
		// The shared Lua root becomes _shared itself; its one non-Lua file
		// keeps its exclusion, and **/*.lua covers the rest.
		file: 'tools/build/windows_bundle_manifest.json',
		empties: '_shared/lua',
		from: '"globs": ["static/ergopti_plus/_shared/lua/**", "**/*.lua"],',
		to: '"globs": ["**/*.lua", "static/ergopti_plus/_shared/keyboard/engine/chord/vectors.json"],'
	},
	{
		// The standalone layout editor fetches its Lua sources from the shared
		// Lua root, spelled as a URL relative to the page: now _shared itself.
		file: 'static/ergopti_plus/_shared/ui/layout_editor/standalone.js',
		empties: '_shared/lua',
		from: "const LUA_ROOT = new URL('../../lua/', location.href);",
		to: "const LUA_ROOT = new URL('../../', location.href);"
	},
	{
		// verify-change's cross-driver contracts were the specifications under
		// _shared/core; their nearest new folder (_shared) would make every
		// shared file one, selecting every suite. The new homes of exactly them.
		file: 'tools/test/verify-change.cjs',
		empties: '_shared/core/config_schema',
		from: "\t\tf.startsWith('static/ergopti_plus/_shared/core/') ||\n",
		to:
			"\t\tf === 'static/ergopti_plus/_shared/core/features.json' ||\n" +
			"\t\tf.startsWith('static/ergopti_plus/_shared/core/ports/') ||\n" +
			"\t\tf.startsWith('static/ergopti_plus/_shared/core/text/data/domain/') ||\n" +
			"\t\tf.startsWith('static/ergopti_plus/_shared/settings/data/config_schema/') ||\n"
	},
	{
		// The gate coverage test probes a contract under each of those trees;
		// _shared/core becomes a feature folder, its contracts are the ports.
		file: 'tools/test/test-shared-lua-gate-coverage.cjs',
		empties: '_shared/core/config_schema',
		from: "for (const tree of ['core', 'tests']) {",
		to: "for (const tree of ['core/ports', 'tests']) {"
	},
	{
		// The Go sources join the native folder, which the pattern above
		// already excludes (the edit holds the new spelling of both).
		file: 'tools/build/macos-bundle-manifest.json',
		empties: '_shared/go',
		from: '"ergopti_plus/_shared/native/**",\n\t\t\t\t"ergopti_plus/_shared/go/**"',
		to: '"ergopti_plus/_shared/core/network/native/**"'
	},
	{
		// The shared test contracts join the shared test tree, which the
		// pattern above already excludes.
		file: 'tools/build/macos-bundle-manifest.json',
		empties: '_shared/lua',
		from: '"ergopti_plus/_shared/tests/**",\n\t\t\t\t"ergopti_plus/_shared/lua/test/**",',
		to: '"ergopti_plus/_shared/tests/**",'
	},
	{
		file: 'tools/build/windows_bundle_manifest.json',
		empties: '_shared/python',
		from: '"static/ergopti_plus/_shared/python/**",',
		to: '"static/ergopti_plus/_shared/ai/adapters/python/**",'
	}
];

/**
 * Files whose path literals are synthetic coordinates, not references to the
 * tree: a fake source root (@C:/repo/shared/config_migrate.lua) that a
 * lexical owner normalizes, compares or derives siblings from. Rewriting some
 * of them to the new layout breaks the arithmetic between the others, and
 * none of them names a file of the repository.
 */
const SYNTHETIC_PATHS = [
	{
		file: 'static/ergopti_plus/_shared/lua/test/module_source_identity_contract.lua',
		why: 'module_source_identity.sibling() derives one fake source from another'
	}
];

/**
 * Tools that name Lua modules in their own tables, compared against the
 * require sites they parse (a menu delegation map keyed by module name):
 * every quoted name of a moved module in them is a module name.
 */
const MODULE_NAME_FILES = [
	{
		file: 'tools/lib/menu-shared-delegation.cjs',
		why: 'MODULES and its comparisons name the shared menu modules a driver delegates to'
	},
	{
		file: 'tools/lib/menu-native-llm-parent-binding.cjs',
		why: 'its imports tables name the modules a Linux menu part requires'
	},
	{
		file: 'tools/lib/menu-hotstring-language-binding.cjs',
		why: 'its imports table names the modules the hotstring language menu requires'
	},
	{
		file: 'static/ergopti_plus/_shared/ui/layout_editor/lua_runner.js',
		why: 'MODULES lists the shared Lua modules the page loads into fengari, in load order'
	},
	{
		file: 'tools/lib/config-key-tokens.cjs',
		why: "it collapses require('config_keys').KEY.X by comparing the module's name"
	},
	{
		file: 'tools/test/test-layouts-defaults-single-source.cjs',
		why: 'it compares a parsed require argument with the layout registry module'
	}
];

// Tools that name a shared module's method by the record name the menu
// delegation builds, '<module>.<method>': the module part follows the module.
const MODULE_MEMBER_FILES = [
	{
		file: 'tools/test/test-menu-shared-delegation.cjs',
		why: 'it asserts the record names delegatedMenuSources builds from MODULES'
	},
	{
		file: 'tools/test/test-menu-manifest.cjs',
		why: 'it finds the magic key source rows by their delegated record name'
	}
];

// Pins of a value derived from a file rather than of its bytes. repin.cjs
// re-derives each one: the derivation must reproduce the pin from the
// pre-step bytes, or the step stops, so an entry cannot fall behind its test.
// `derive(source, holder, lib, sourcePath)` gets the source file and the pin
// holder as text, `lib(path)` loads a module of the tree being measured, and
// `sourcePath` is the source's absolute path in that tree.
const DERIVED_PINS = [
	{
		file: 'tools/test/fixtures/personal-section-owner-counterexamples.cjs',
		source: 'static/ergopti_plus/macos/ui/menu/menu_hotstrings_custom.lua',
		why:
			'it pins the producer, read through the config-key source view, with its ' +
			'section row restored to ORIGINAL_SECTION_ROW',
		derive(raw, holder, lib) {
			const { expandConfigKeys } = lib('tools/lib/config-key-tokens.cjs');
			const source = expandConfigKeys(raw);
			const row = holder.match(/const ORIGINAL_SECTION_ROW = `([^`]*)`;/)[1];
			const start = '\n\t\t\t\tlocal ready = group_enabled and not paused';
			const end = '\n\t\t\t\ttarget[#target + 1] = row';
			const at = source.indexOf(start);
			const last = source.indexOf(end, at);
			if (at < 0 || last < 0) return null;
			const original = source.slice(0, at) + row + source.slice(last + end.length);
			return require('node:crypto').createHash('sha256').update(original).digest('hex');
		}
	},
	{
		// The Windows proxy relay manifest pins its sources: the Go pin, then
		// each source of the module by sorted relative path and SHA-256, as the
		// relay builder computes it. A step that rewrites only their comments,
		// the module path kept (apply-step.cjs GO_MODULE_PATH), builds the same
		// binary (checked with the pinned Go on S01), so the pin follows them.
		file: 'static/ergopti_plus/windows/vendor/ergopti-proxy-relay.json',
		source: 'static/ergopti_plus/_shared/go/native_http/go.mod',
		why: 'source_fingerprint is the identity of the relay sources the committed binary was built from',
		derive(_goMod, holder, _lib, goModPath) {
			const fs = require('node:fs');
			const path = require('node:path');
			const crypto = require('node:crypto');
			const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');
			const module = path.dirname(goModPath);
			const sources = ['go.mod'];
			for (const directory of ['proxyrelay', 'cmd/ergopti-proxy-relay'])
				for (const name of fs.readdirSync(path.join(module, directory)))
					if (name.endsWith('.go') && !name.endsWith('_test.go'))
						sources.push(`${directory}/${name}`);
			let identity = `${JSON.parse(holder).go_version}\n`;
			for (const relative of sources.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)))
				identity += `${relative}\n${sha(fs.readFileSync(path.join(module, relative)))}\n`;
			return sha(Buffer.from(identity, 'utf8'));
		}
	},
	{
		// The navigation owner manifest pins its sources and recipe as the
		// builder's Get-SourceRecipeFingerprint computes them: each fingerprint
		// file by repository path and canonical-LF SHA-256, then the recipe. A
		// step moves the sources and rewrites only their comments and the
		// builder's paths; no __FILE__ and no debug record reach the /Brepro
		// DLL, and every Windows CI lane recompiles and tests the moved sources.
		file: 'static/ergopti_plus/windows/vendor/ergopti_nav_owner.manifest.json',
		source: 'tools/build/build_windows_nav_owner.ps1',
		why: 'source_fingerprint_sha256 is the identity of the sources and recipe the tracked DLL was built from',
		derive(builder, holder, _lib, builderPath) {
			const fs = require('node:fs');
			const path = require('node:path');
			const crypto = require('node:crypto');
			const root = path.resolve(path.dirname(builderPath), '..', '..');
			const own = path.relative(root, builderPath).split(path.sep).join('/');
			const dir = builder.match(/^\$sourceDir = Join-Path \$repoRoot "([^"]+)"$/m);
			if (!dir) return null;
			const sourceDir = dir[1].split('\\').join('/');
			const files = fs
				.readdirSync(path.join(root, sourceDir), { withFileTypes: true })
				.filter((d) => d.isFile() && (/\.(c|h|def)$/.test(d.name) || d.name === 'CMakeLists.txt'))
				.map((d) => `${sourceDir}/${d.name}`)
				.concat(own)
				.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
			const manifest = JSON.parse(holder);
			// The builder rejects a manifest whose list differs from the tree's.
			if (JSON.stringify(manifest.fingerprint_files) !== JSON.stringify(files)) return null;
			const lines = ['ergopti-nav-owner-source-recipe-v1'];
			files.forEach((f, i) => {
				const text = fs
					.readFileSync(path.join(root, f), 'utf8')
					.replace(/^\uFEFF/, '')
					.replace(/\r\n?/g, '\n');
				lines.push(`input[${i}].path=${f}`);
				lines.push(
					`input[${i}].sha256=${crypto.createHash('sha256').update(text, 'utf8').digest('hex').toUpperCase()}`
				);
			});
			lines.push(`recipe.executable=${manifest.build_recipe.executable}`);
			manifest.build_recipe.arguments.forEach((a, i) => lines.push(`recipe.argument[${i}]=${a}`));
			return crypto
				.createHash('sha256')
				.update(`${lines.join('\n')}\n`, 'utf8')
				.digest('hex')
				.toUpperCase();
		}
	}
];

// Receipts designed to be immutable: the Windows cohort input frames and the
// pins of those frames. A step re-pins them only as an explicit
// requalification: repin.cjs reports every old→new pin with the file it
// follows, the runner writes them into the step's commit body, and a pin in
// them that no file of the step accounts for stops the step. The cohorts are
// then requalified on the real Windows PC.
const REQUALIFIED_PINS = [
	{
		file: 'tools/ci/windows-key-combination-cohort-original-inputs.json',
		why: 'the original key-combination cohort frame, read by its owner as --legacy-inputs'
	},
	{
		file: 'tools/ci/windows-updater-original-diagnostic-cohort-inputs.json',
		why: 'the original updater diagnostic cohort frame'
	},
	{
		file: 'tools/test/portable-control-inputs.json',
		why: 'the portable control inputs of the key-combination cohort'
	},
	{
		file: 'tools/ci/prepare_windows_key_combination_cohort_inputs.py',
		why: 'LEGACY_SHA pins the original key-combination frame'
	},
	{
		file: 'tools/test/test_windows_key_combination_source_roster.py',
		why: 'OLD and HELPER pin the original frame and the cohort runner'
	}
];

// Files whose [detection.<driver>.…] sections key paths relative to that
// driver ("modules/llm/" = macos/modules/llm under [detection.macos.ollama]),
// never to the shared tree the file lives in.
const DRIVER_SECTION_FILES = [
	{
		file: 'static/ergopti_plus/_shared/modules/features/requirements.toml',
		why: 'the owner and plumbing selectors of each driver are folders or file prefixes of that driver'
	}
];

module.exports = {
	DRIVER_SECTION_FILES,
	REQUALIFIED_PINS,
	FOLDER_EDITS,
	SYNTHETIC_PATHS,
	MODULE_NAME_FILES,
	MODULE_MEMBER_FILES,
	DERIVED_PINS
};
