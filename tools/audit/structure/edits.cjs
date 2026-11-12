// tools/audit/structure/edits.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Explicit Edits
 * DESCRIPTION:
 * The few sites whose new text is a decision rather than a rewrite: a scan
 * over a folder the plan scatters, whose new scope (what it must now include
 * or skip) no path rule can know. Each edit names the file as it stands when
 * the edit runs, the folder whose emptying triggers it (tree-relative), and
 * its exact text before and after. A `from` the file no longer holds refuses
 * the step instead of passing silently.
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
		// The locale is found relative to the page under test, a variable
		// the scan cannot evaluate.
		file: 'tools/test/support/metrics-apps-page.cjs',
		empties: '_shared/data/locales',
		from: "path.resolve(path.dirname(page), '../../data/locales/fr.json')",
		to: "path.resolve(path.dirname(page), '../../core/i18n/data/locales/fr.json')"
	}
];

module.exports = { FOLDER_EDITS };
