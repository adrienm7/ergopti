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
 * Register leaf generators only: build-domain.cjs is a build-and-validation
 * aggregate already covered separately by the JS suite. Registering it here
 * repeats its generators and its validation on every drift probe. Every output
 * has one execution owner; the architecture diagram runs after those owners.
 * ==============================================================================
 */

'use strict';

/**
 * @type {{script: string, outputs: string[], note?: string}[]}
 * `script` is relative to tools/, `outputs` to the repo root.
 */
const GENERATORS = [
	{
		script: 'codegen/codegen-ollama-release.cjs',
		outputs: ['static/ergopti_plus/macos/modules/llm/ollama-release.sh']
	},
	{
		script: 'codegen/codegen-linux-native-runtime.cjs',
		outputs: [
			'static/ergopti_plus/linux/_generated/native_runtime.lua',
			'static/ergopti_plus/linux/install.sh',
			'tools/build/build-linux-deb.sh',
			'tools/build/build-linux-rpm.sh',
			'tools/build/PKGBUILD',
			'tools/build/nix/flake.nix',
			'tools/build/templates/linux-portable-runtime-env.sh'
		]
	},
	{
		script: 'codegen/codegen-personal-file-descriptors.cjs',
		outputs: [
			'static/ergopti_plus/_shared/lua/hotstrings/personal_files.lua',
			'static/ergopti_plus/windows/_generated/personal_file_descriptors.ahk'
		]
	},
	{
		script: 'codegen/codegen-window-titles.cjs',
		outputs: [
			'static/ergopti_plus/_shared/lua/window_titles.lua',
			'static/ergopti_plus/windows/_generated/window_titles.ahk',
			'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/WindowTitles.generated.swift'
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
		script: 'codegen/codegen-update-channels.cjs',
		outputs: [
			'static/ergopti_plus/_shared/ui/_generated/update_channel_registry.js',
			'static/ergopti_plus/windows/_generated/update_channels.ahk',
			'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/UpdateChannels.generated.swift'
		]
	},
	{
		script: 'codegen/codegen-update-schedule.cjs',
		outputs: ['static/ergopti_plus/windows/_generated/update_schedule.ahk']
	},
	{
		script: 'codegen/codegen-touchpad-registry.cjs',
		outputs: ['static/ergopti_plus/windows/_generated/touchpad_registry.ahk']
	},
	{
		script: 'codegen/codegen-brightness-actions.cjs',
		outputs: ['static/ergopti_plus/_shared/lua/brightness_actions_data.lua']
	},
	{
		script: 'codegen/codegen-layer-editor-data-js.cjs',
		outputs: ['static/ergopti_plus/_shared/ui/layer_editor/_generated/layer_data.js']
	},
	{
		script: 'codegen/codegen-onboarding-catalogue.cjs',
		outputs: [
			'static/ergopti_plus/_shared/ui/_generated/onboarding_catalogue.js',
			'static/ergopti_plus/_shared/ui/_generated/onboarding_catalogue.json'
		]
	},
	{
		script: 'codegen/codegen-contracts-json.cjs',
		outputs: ['static/ergopti_plus/_shared/core/ports/contracts.json']
	},
	{
		script: 'codegen/codegen-app-dirs.cjs',
		outputs: [
			'static/ergopti_plus/_shared/lua/app_dirs.lua',
			'static/ergopti_plus/windows/_generated/app_dirs.ahk',
			'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/AppDirs.generated.swift'
		]
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
		script: 'codegen/codegen-action-catalogue.cjs',
		outputs: [
			'static/ergopti_plus/macos/_generated/action_catalogue.lua',
			'static/ergopti_plus/linux/_generated/action_catalogue.lua',
			'static/ergopti_plus/windows/_generated/action_catalogue.ahk'
		]
	},
	{
		script: 'codegen/codegen-unicode-case.cjs',
		outputs: ['static/ergopti_plus/_shared/lua/unicode_case/data.lua']
	},
	{
		script: 'codegen/codegen-hid-key-identity-hs.cjs',
		outputs: ['static/ergopti_plus/macos/_generated/hid_key_identity.lua']
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
