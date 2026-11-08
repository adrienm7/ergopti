// _shared/ui/key_names.js

/**
 * ==============================================================================
 * MODULE: Web Page Key Names
 * DESCRIPTION:
 * Names a key in the user's language from the shared key name table
 * (_shared/data/keycodes/key_names.json, projected to
 * _generated/key_names.js), as the native menus do. A page must load the
 * generated table, then this file, and receive the locale catalogue in
 * window._i18n_strings (i18n.js).
 *
 * FEATURES & RATIONALE:
 * 1. A catalogue miss returns the dotted locale key, like every other label,
 *    so the locale gates and the rendered-row walks refuse it; it never falls
 *    back to the key id.
 * 2. An unknown id or platform throws: it is a page defect, not a key to show.
 * ==============================================================================
 */

/**
 * Names one key on one platform.
 * @param {string} spelling A key id or alias of key_names.json.
 * @param {string} platform "windows", "macos" or "linux".
 * @returns {string} The translated name, or its locale key while none is loaded.
 */
function keyNameLabel(spelling, platform) {
	if (!KEY_NAMES_DATA.platforms.includes(platform))
		throw new Error('key names: unknown platform ' + platform);
	const lower = String(spelling).toLowerCase();
	const id = KEY_NAMES_DATA.keys[lower] ? lower : KEY_NAMES_DATA.aliases[lower];
	if (!id || !KEY_NAMES_DATA.keys[id]) throw new Error('key names: no key ' + spelling);
	const key = KEY_NAMES_DATA.keys[id][platform];
	const strings = window._i18n_strings || {};
	return typeof strings[key] === 'string' && strings[key] !== '' ? strings[key] : key;
}

window.keyNameLabel = keyNameLabel;
