// tools/lib/manifest-label-keys.cjs

/**
 * ==============================================================================
 * MODULE: Manifest Label Candidate Keys
 * DESCRIPTION:
 * JavaScript port of `_MenuLabelCandidateKeys` in
 * `static/ergopti_plus/windows/menu/engine/manifest_descriptions.ahk`: the ordered
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
 * 3. The translations audit counts each row's resolved key as used, because no
 *    source names a key this chain derives.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

// The generated Windows manifest is the table the AHK resolver itself walks.
const MANIFEST_RELATIVE = 'static/ergopti_plus/windows/_generated/features_manifest.ahk';

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

/**
 * Reads every manifest row that carries a description_key.
 * @param {string} repoRoot Repository root.
 * @returns {{path: string, key: string, type: string}[]} Rows in manifest order.
 * @throws {Error} When the generated manifest yields almost no rows.
 */
function readManifestLabelRows(repoRoot) {
	const src = fs.readFileSync(path.join(repoRoot, MANIFEST_RELATIVE), 'utf8');
	const rows = [];
	const rowRe = /Map\("path",\s*"([^"]*)"[^\n]*?"description_key",\s*"([^"]*)"/g;
	let m;
	while ((m = rowRe.exec(src)) !== null) {
		const lineEnd = src.indexOf('\n', m.index);
		const line = src.slice(m.index, lineEnd === -1 ? undefined : lineEnd);
		const typeMatch = line.match(/"type",\s*"([^"]*)"/);
		rows.push({ path: m[1], key: m[2], type: typeMatch ? typeMatch[1] : '' });
	}
	// A scan that matches almost nothing would silently resolve no label.
	if (rows.length < 150) {
		throw new Error(
			`${MANIFEST_RELATIVE} yielded ${rows.length} labelled row(s); its shape changed.`
		);
	}
	return rows;
}

/**
 * The locale key a manifest row's label is read from: its first candidate
 * the catalogue holds with a non-empty value.
 * @param {{path: string, key: string}} row Manifest row.
 * @param {Object<string, string>} catalogue Flat locale catalogue.
 * @returns {string|null} The resolved key, or null when the row shows its raw id.
 */
function resolvedLabelKey(row, catalogue) {
	for (const candidate of candidateKeys(row.key, row.path)) {
		if (
			candidate !== '' &&
			typeof catalogue[candidate] === 'string' &&
			catalogue[candidate] !== ''
		) {
			return candidate;
		}
	}
	return null;
}

module.exports = { candidateKeys, readManifestLabelRows, resolvedLabelKey, strip };
