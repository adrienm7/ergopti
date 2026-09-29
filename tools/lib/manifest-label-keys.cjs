// tools/lib/manifest-label-keys.cjs

/**
 * ==============================================================================
 * MODULE: Manifest Label Candidate Keys
 * DESCRIPTION:
 * JavaScript port of `_MenuLabelCandidateKeys` in
 * `static/ergopti_plus/windows/infra/manifest_descriptions.ahk`: the ordered
 * locale keys a manifest entry's label is looked up under. The locale files
 * store many feature labels in a folded form (`layout.ergopti_base` ->
 * `layout.ergoptibase`), so a manifest `description_key` alone does not name
 * the key that exists.
 *
 * FEATURES & RATIONALE:
 * 1. One port: the menu-label guard and the onboarding catalogue generator
 *    resolve labels through the same chain the driver uses, so a label the
 *    wizard shows is the label the tray shows.
 * 2. Order is significant: the first candidate present in the locale wins.
 * ==============================================================================
 */

'use strict';

/**
 * Removes underscores from every dotted segment, keeping the dots.
 * @param {string} key Dotted locale key.
 * @returns {string} Folded key.
 */
function strip(key) {
	return key.split('_').join('');
}

/**
 * Builds the ordered candidate locale keys for one manifest entry.
 * @param {string} descKey The entry's description_key, or "".
 * @param {string} entryPath The entry's canonical dotted path, or "".
 * @returns {string[]} Candidate keys, first match wins.
 */
function candidateKeys(descKey, entryPath) {
	const out = [];
	if (descKey !== '') out.push(descKey);
	if (descKey.length > 5 && descKey.slice(0, 5) === 'menu.') {
		const noMenu = descKey.slice(5);
		out.push(noMenu, strip(noMenu));
		if (noMenu.length > 11 && noMenu.slice(0, 11) === 'hotstrings.') {
			const noHs = noMenu.slice(11);
			out.push(noHs, strip(noHs));
		}
	}
	if (entryPath !== '' && entryPath !== descKey) {
		out.push(entryPath);
		let trimmed = entryPath;
		if (trimmed.length > 4 && trimmed.slice(0, 4) === 'ahk.') {
			trimmed = trimmed.slice(4);
			out.push(trimmed);
		}
		if (trimmed.length > 11 && trimmed.slice(0, 11) === 'hotstrings.') {
			trimmed = trimmed.slice(11);
			out.push(trimmed);
		}
		out.push(strip(trimmed));
	}
	const combined = descKey !== '' ? descKey : entryPath;
	const dyn = combined.indexOf('.dynamic.');
	if (dyn >= 0) {
		const section = combined.slice(dyn + 9);
		if (section !== '')
			out.push(`dynamichotstrings.${section}`, `dynamichotstrings.${strip(section)}`);
	}
	return out;
}

module.exports = { candidateKeys, strip };
