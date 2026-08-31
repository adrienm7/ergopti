// tools/build/generators.cjs

/**
 * ==============================================================================
 * MODULE: Generator Registry
 * DESCRIPTION:
 * The one list of every generator in the repo and the files it writes. Consumed
 * by `npm run gen` (run them all) and by the no-drift gate (snapshot exactly
 * what they touch, regenerate, diff, restore).
 *
 * WHY OUTPUTS ARE DECLARED AND NOT GUESSED:
 * The drift gate used to name two files by hand and fell four behind. The fix
 * was to snapshot whole `_generated/` directories instead — better, but still a
 * guess, and a wrong one for the generators that write OUTSIDE those
 * directories. Measured: build-domain.cjs writes twelve files, three of which
 * (`_shared/lua/keymap/terminators_catalogue.lua`,
 * `_shared/modules/menu/menu_manifest.json` and `docs/architecture.md` from its
 * sibling) live nowhere near a `_generated/` folder. Adding that generator to a
 * directory-scoped gate would silently overwrite them in the working tree and
 * never restore them — exactly the bug the directory scan was introduced to fix,
 * one layer up.
 *
 * So each entry states its own outputs, measured by running the generator and
 * recording which files it wrote. A generator that gains an output updates this
 * list, and both consumers follow automatically.
 *
 * ORDER MATTERS: build-domain.cjs is itself an aggregator that re-emits most of
 * the per-target files, so it runs FIRST and the narrower generators run after.
 * Running them the other way round is still correct — every generator is
 * deterministic and idempotent — but this order means the final write of each
 * file comes from its most specific owner.
 * ==============================================================================
 */

'use strict';

/**
 * @type {{script: string, outputs: string[], note?: string}[]}
 * `script` is relative to tools/, `outputs` to the repo root.
 */
const GENERATORS = [
	{
		script: 'build/build-domain.cjs',
		note: 'aggregator: re-emits the manifests, terminators, prompt builder, LLM profiles and keycode data',
		outputs: [
			'static/ergopti_plus/linux/_generated/config_template.toml',
			'static/ergopti_plus/linux/_generated/features_manifest.lua',
			'static/ergopti_plus/macos/_generated/config_template.toml',
			'static/ergopti_plus/macos/_generated/features_manifest.lua',
			'static/ergopti_plus/windows/_generated/config_template.toml',
			'static/ergopti_plus/windows/_generated/features_manifest.ahk',
			'static/ergopti_plus/windows/_generated/llm_profiles_data.ahk',
			'static/ergopti_plus/windows/_generated/prompt_builder.ahk',
			'static/ergopti_plus/windows/_generated/terminators.ahk',
			'static/ergopti_plus/_shared/lua/keymap/terminators_catalogue.lua',
			'static/ergopti_plus/_shared/modules/menu/menu_manifest.json',
			'static/ergopti_plus/_shared/ui/metrics_typing/_generated/keycode_data.js'
		]
	},
	{
		script: 'build/build-features-manifest.js',
		outputs: [
			'static/ergopti_plus/linux/_generated/config_template.toml',
			'static/ergopti_plus/linux/_generated/features_manifest.lua',
			'static/ergopti_plus/macos/_generated/config_template.toml',
			'static/ergopti_plus/macos/_generated/features_manifest.lua',
			'static/ergopti_plus/windows/_generated/config_template.toml',
			'static/ergopti_plus/windows/_generated/features_manifest.ahk'
		]
	},
	{
		script: 'build/build-menu-manifest.js',
		outputs: ['static/ergopti_plus/_shared/modules/menu/menu_manifest.json']
	},
	{
		script: 'build/gen-metrics-category-aliases.cjs',
		outputs: ['static/ergopti_plus/_shared/data/metrics_general_category_aliases.json']
	},
	{
		script: 'codegen/codegen-terminators.cjs',
		outputs: [
			'static/ergopti_plus/windows/_generated/terminators.ahk',
			'static/ergopti_plus/_shared/lua/keymap/terminators_catalogue.lua'
		]
	},
	{
		script: 'codegen/codegen-prompt-builder-ahk.cjs',
		outputs: ['static/ergopti_plus/windows/_generated/prompt_builder.ahk']
	},
	{
		script: 'codegen/codegen-llm-profiles-data-ahk.cjs',
		outputs: ['static/ergopti_plus/windows/_generated/llm_profiles_data.ahk']
	},
	{
		script: 'codegen/codegen-keycode-data-js.cjs',
		outputs: ['static/ergopti_plus/_shared/ui/metrics_typing/_generated/keycode_data.js']
	},
	{
		script: 'codegen/codegen-contracts-json.cjs',
		outputs: ['static/ergopti_plus/_shared/core/ports/contracts.json']
	},
	{
		script: 'codegen/codegen-logger-sub-files.cjs',
		outputs: [
			'static/ergopti_plus/macos/_generated/logger_sub_files.lua',
			'static/ergopti_plus/windows/_generated/logger_sub_files.ahk',
			'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/LoggerTopics.generated.swift'
		]
	},
	{
		script: 'codegen/codegen-locale-tables.cjs',
		outputs: [
			'static/ergopti_plus/macos/_generated/locale_table.lua',
			'static/ergopti_plus/linux/_generated/locale_table.lua',
			'static/ergopti_plus/windows/_generated/locale_table.ahk'
		]
	},
	{
		script: 'codegen/codegen-gesture-emit-actions.cjs',
		outputs: ['static/ergopti_plus/windows/_generated/gesture_emit_actions.ahk']
	},
	{
		script: 'codegen/codegen-gesture-emit-actions-hs.cjs',
		outputs: ['static/ergopti_plus/macos/_generated/gesture_emit_actions.lua']
	},
	{
		script: 'codegen/codegen-gesture-emit-actions-linux.cjs',
		outputs: ['static/ergopti_plus/linux/_generated/gesture_emit_actions.lua']
	},
	{
		script: 'codegen/codegen-unicode-case-linux.cjs',
		outputs: ['static/ergopti_plus/linux/_generated/unicode_case_data.lua']
	},
	{
		script: 'codegen/gen-architecture-diagram.cjs',
		note: 'runs last: it describes the tree the others have just finished writing',
		outputs: ['static/ergopti_plus/docs/architecture.md']
	}
];

/** Every declared output path, de-duplicated. */
function allOutputs() {
	const seen = new Set();
	for (const g of GENERATORS) for (const o of g.outputs) seen.add(o);
	return [...seen].sort();
}

module.exports = { GENERATORS, allOutputs };
