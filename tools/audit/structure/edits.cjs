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
// `derive(source, holder, lib)` gets the source file and the pin holder as
// text, and `lib(path)` loads a module of the tree being measured.
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

module.exports = {
	REQUALIFIED_PINS,
	FOLDER_EDITS,
	SYNTHETIC_PATHS,
	MODULE_NAME_FILES,
	MODULE_MEMBER_FILES,
	DERIVED_PINS
};
