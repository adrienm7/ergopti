// src/routes/ergopti-plus/action-platforms.js

/**
 * ==============================================================================
 * MODULE: Ergopti+ Page — Action Platform Filter
 * DESCRIPTION:
 * Decides whether a catalogue action is listed for the page's OS toggle. The
 * shared actions.toml `platform` field is "all" or a comma-separated list of
 * driver keys ("ahk", "hs,ahk", …), the form
 * tools/codegen/codegen-action-catalogue.cjs validates for the drivers.
 * ==============================================================================
 */

/**
 * Whether an action declared for `platform` is available on the driver `tag`.
 * @param {string} platform The action's catalogue platform field.
 * @param {string|null} tag The selected OS's driver key, null when none.
 * @returns {boolean}
 */
export function isActionOnPlatform(platform, tag) {
	if (platform === 'all') return true;
	if (tag === null) return false;
	return platform
		.split(',')
		.map((key) => key.trim())
		.includes(tag);
}
