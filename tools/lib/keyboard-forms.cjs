// tools/lib/keyboard-forms.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard Forms
 * DESCRIPTION:
 * Every keyboard form a key can be drawn on: the ANSI and ISO boards of the
 * physical-key registry (_shared/layouts/data/keycodes/physical_keys.json) and
 * the JIS and ABNT boards keyboard_forms.json draws from one of them. The one
 * reader of keyboard_forms.json for the generators (the layout editor's key
 * data, the layout analysis data), so a page gets each key's geometry on every
 * form without a resolver of its own.
 *
 * FEATURES & RATIONALE:
 * 1. A derived form is its base form, minus the keys it lacks, with the keys it
 *    moves or adds: the registry every driver parses at boot keeps two forms.
 * 2. Fail fast: an unknown form or base, or a form naming a key the registry
 *    does not draw, throws before anything is generated.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const { shared } = require('./paths.cjs');

const KEYBOARD_FORMS_PATH = shared('layouts', 'data', 'keycodes', 'keyboard_forms.json');

/**
 * Reads keyboard_forms.json and checks it against the registry.
 * @param {object} registry - Decoded physical_keys.json.
 * @param {object} [document] - Decoded keyboard_forms.json, read from the repository when absent.
 * @returns {object} form id -> {base, absent: string[], keys: object}.
 * @throws {Error} On a form the registry cannot resolve.
 */
function readForms(registry, document) {
	const data = document || JSON.parse(fs.readFileSync(KEYBOARD_FORMS_PATH, 'utf8'));
	if (data.schema_version !== 1) throw new Error('keyboard_forms.json: schema_version must be 1');
	for (const [form, spec] of Object.entries(data.forms)) {
		if (registry.forms.includes(form))
			throw new Error(`keyboard_forms.json: ${form} is a registry form`);
		if (!registry.forms.includes(spec.base))
			throw new Error(`keyboard_forms.json: ${form} has no base form ${spec.base}`);
		for (const code of spec.absent.concat(Object.keys(spec.keys)))
			if (!registry.keys[code] || !registry.keys[code].geometry)
				throw new Error(`keyboard_forms.json: ${form} names ${code}, which no board draws`);
	}
	return data.forms;
}

/**
 * Every form id: the registry's, then the derived ones.
 * @param {object} registry - Decoded physical_keys.json.
 * @param {object} forms - From readForms.
 * @returns {string[]}
 */
function allForms(registry, forms) {
	return registry.forms.concat(Object.keys(forms));
}

/**
 * One key's geometry on one form, or undefined when the form lacks the key.
 * @param {object} registry - Decoded physical_keys.json.
 * @param {object} forms - From readForms.
 * @param {string} code - A registry key.
 * @param {string} form - A form id of allForms.
 * @returns {object|undefined} {row, col, width, ...} as the registry writes it.
 */
function geometryOn(registry, forms, code, form) {
	const own = registry.keys[code] && registry.keys[code].geometry;
	if (!own) return undefined;
	if (registry.forms.includes(form)) return own[form];
	const spec = forms[form];
	if (!spec) throw new Error(`unknown keyboard form ${form}`);
	if (Object.hasOwn(spec.keys, code)) return spec.keys[code];
	if (spec.absent.includes(code)) return undefined;
	return own[spec.base];
}

/**
 * A key's geometry on every form it is on, in allForms order.
 * @param {object} registry - Decoded physical_keys.json.
 * @param {object} forms - From readForms.
 * @param {string} code - A registry key.
 * @returns {object|undefined} form -> geometry; undefined for a key no board draws.
 */
function geometryOfKey(registry, forms, code) {
	if (!registry.keys[code].geometry) return undefined;
	const out = {};
	for (const form of allForms(registry, forms)) {
		const g = geometryOn(registry, forms, code, form);
		if (g) out[form] = g;
	}
	return out;
}

module.exports = { KEYBOARD_FORMS_PATH, readForms, allForms, geometryOn, geometryOfKey };
