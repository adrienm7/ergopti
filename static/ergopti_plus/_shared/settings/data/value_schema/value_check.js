// _shared/settings/data/value_schema/value_check.js

/**
 * ==============================================================================
 * MODULE: User Value Check (canonical)
 * DESCRIPTION:
 * Checks one user-entered or stored setting value against its declaration in
 * value_schema.json, the single source of every setting's type, bounds and
 * special values. The shared Lua port (_shared/settings/engine/value_check.lua,
 * macOS and Linux) and the AHK port (windows/infra/value_check.ahk) replay
 * value_check_vectors.json with it, so the three drivers and the web pages
 * accept and refuse the same values.
 *
 * FEATURES & RATIONALE:
 * 1. Three places, one rule: parseEntry() reads what a person typed in a box,
 *    checkValue() reads a value loaded from a TOML file, requireValue() guards
 *    the consuming boundary and throws. All three call the same check, so a
 *    value admitted at entry is never refused at load and the reverse.
 * 2. A refusal names its reason from a closed list (REASONS) and carries the
 *    bounds, so a driver builds the localized message « from {min} to {max} »
 *    without restating the range.
 * 3. Special values (the one-shot 0 = no time limit, a debounce of -1 = off)
 *    are admitted even outside min..max: they are declared, never implied.
 * 4. Entry text accepts a comma as decimal separator (French keyboards type
 *    one) and surrounding blanks, nothing else: no exponent, no hexadecimal,
 *    no « nan » or « inf », no thousands separator.
 * 5. A stored integer setting accepts an integral float (TOML 2000.0, or a
 *    driver's JSON number), never 1.5: a decimal is not silently floored.
 * 6. Pure: no logger, no i18n, no I/O; callers report and localize.
 * ==============================================================================
 */

'use strict';

// Every refusal reason, in the order the vectors and the i18n keys use them.
// The localized message key of a reason is `dialog.value_check.<reason>`.
const REASONS = [
	'empty',
	'wrong_type',
	'not_finite',
	'not_integer',
	'below_minimum',
	'above_maximum',
	'not_allowed',
	'too_long'
];

const TYPES = ['integer', 'decimal', 'boolean', 'enum', 'string', 'path'];

// Plain decimal text: an optional sign, digits, an optional fraction.
const DECIMAL_TEXT = /^[+-]?[0-9]+(?:[.,][0-9]+)?$/;
const INTEGER_TEXT = /^[+-]?[0-9]+$/;

// ==========================================
// ==========================================
// ======= 1/ Schema Lookup ================
// ==========================================
// ==========================================

/**
 * The declaration of one setting, refusing an unknown name.
 * A pattern key may use `*` for one path segment.
 * @param {Object} schema - Parsed value_schema.json.
 * @param {string} key - Dotted setting path, e.g. "tap_holds.sticky_timeout_ms".
 * @return {Object} The declaration.
 */
function entryFor(schema, key) {
	const settings = schema && schema.settings;
	if (!settings || typeof settings !== 'object') throw new Error('value schema has no settings');
	if (Object.prototype.hasOwnProperty.call(settings, key)) return settings[key];
	const segments = String(key).split('.');
	for (const name of Object.keys(settings)) {
		if (!name.includes('*')) continue;
		const pattern = name.split('.');
		if (pattern.length !== segments.length) continue;
		if (pattern.every((part, index) => part === '*' || part === segments[index])) {
			return settings[name];
		}
	}
	throw new Error(`value schema declares no setting ${key}`);
}

// ==========================================
// ==========================================
// ======= 2/ Checks ========================
// ==========================================
// ==========================================

function refusal(reason, entry) {
	const result = { ok: false, reason };
	if (entry.min !== undefined) result.min = entry.min;
	if (entry.max !== undefined) result.max = entry.max;
	return result;
}

function isSpecial(entry, value) {
	return Array.isArray(entry.special) && entry.special.some((item) => item.value === value);
}

function checkNumber(entry, value) {
	if (typeof value !== 'number') return refusal('wrong_type', entry);
	if (!Number.isFinite(value)) return refusal('not_finite', entry);
	if (isSpecial(entry, value)) return { ok: true, value };
	if (entry.type === 'integer' && !Number.isInteger(value)) return refusal('not_integer', entry);
	if (entry.min !== undefined && value < entry.min) return refusal('below_minimum', entry);
	if (entry.max !== undefined && value > entry.max) return refusal('above_maximum', entry);
	return { ok: true, value };
}

/**
 * Checks a value as loaded from a file or received from a host bridge.
 * @param {Object} entry - Declaration from entryFor().
 * @param {*} value - Candidate value.
 * @return {{ok: boolean, value?: *, reason?: string, min?: number, max?: number}}
 */
function checkValue(entry, value) {
	if (!entry || !TYPES.includes(entry.type)) throw new Error('value check needs a declared type');
	switch (entry.type) {
		case 'integer':
		case 'decimal':
			return checkNumber(entry, value);
		case 'boolean':
			return typeof value === 'boolean' ? { ok: true, value } : refusal('wrong_type', entry);
		case 'enum':
			if (typeof value !== 'string' && typeof value !== 'boolean')
				return refusal('wrong_type', entry);
			return entry.values.includes(value) ? { ok: true, value } : refusal('not_allowed', entry);
		default: {
			if (typeof value !== 'string') return refusal('wrong_type', entry);
			if (value === '' && entry.allow_empty !== true) return refusal('empty', entry);
			// Characters, not UTF-16 units: an emoji counts once in every driver.
			if (entry.max_length !== undefined && Array.from(value).length > entry.max_length) {
				return refusal('too_long', entry);
			}
			return { ok: true, value };
		}
	}
}

/**
 * Reads what a person typed in an entry box. A declaration with `entry_scale`
 * is typed in another unit than it is stored (milliseconds typed, seconds
 * stored: scale 1000), and `entry_type` says whether the typed number may
 * carry decimals; the bounds of a refusal are then given in the typed unit.
 * @param {Object} entry - Declaration from entryFor().
 * @param {string} text - Raw text of the box.
 * @return {{ok: boolean, value?: *, reason?: string, min?: number, max?: number}}
 */
function parseEntry(entry, text) {
	if (typeof text !== 'string') return entryRefusal('wrong_type', entry);
	if (entry.type === 'string' || entry.type === 'path') return checkValue(entry, text);
	const trimmed = text.trim();
	if (trimmed === '') return entryRefusal('empty', entry);
	if (entry.type === 'integer' || entry.type === 'decimal') {
		if (!DECIMAL_TEXT.test(trimmed)) return entryRefusal('wrong_type', entry);
		const typedType = entry.entry_type || entry.type;
		if (typedType === 'integer' && !INTEGER_TEXT.test(trimmed))
			return entryRefusal('not_integer', entry);
		const typed = Number(trimmed.replace(',', '.'));
		const scale = entry.entry_scale || 1;
		const result = checkNumber(entry, scale === 1 ? typed : typed / scale);
		return result.ok ? result : entryRefusal(result.reason, entry);
	}
	if (entry.type === 'boolean') {
		if (trimmed === 'true') return { ok: true, value: true };
		if (trimmed === 'false') return { ok: true, value: false };
		return refusal('wrong_type', entry);
	}
	return checkValue(entry, trimmed);
}

/**
 * A refusal of typed text, its bounds given in the typed unit.
 * @param {string} reason - One of REASONS.
 * @param {Object} entry - Declaration.
 * @return {Object}
 */
function entryRefusal(reason, entry) {
	const result = refusal(reason, entry);
	const scale = entry.entry_scale || 1;
	if (result.min !== undefined) result.min = scaled(result.min, scale);
	if (result.max !== undefined) result.max = scaled(result.max, scale);
	return result;
}

// Scales a bound to the typed unit, rounded to the microunit so 0.001 * 1000
// reads 1, not 1.0000000000000002.
function scaled(bound, scale) {
	return Math.round(bound * scale * 1e6) / 1e6;
}

/**
 * The localized message of a refusal, as i18n keys with their arguments, for
 * the driver to translate and join: the sentence naming what is accepted,
 * then one sentence per special value. The arguments are the bounds in the
 * unit the person typed; an argument { key } is itself an i18n key to
 * translate before it is inserted.
 * @param {Object} entry - Declaration.
 * @param {Object} result - A refusal from parseEntry() or checkValue().
 * @return {Array<{key: string, args: Array}>}
 */
function messageParts(entry, result) {
	const parts = [];
	if (entry.type === 'integer' || entry.type === 'decimal') {
		const typedType = entry.entry_type || entry.type;
		const unit = entry.entry_unit || entry.unit;
		const base = `dialog.value_check.range_${typedType}`;
		parts.push(
			unit
				? {
						key: `${base}_unit`,
						args: [result.min, result.max, { key: `value_check.unit.${unit}` }]
					}
				: { key: base, args: [result.min, result.max] }
		);
		for (const item of entry.special || []) {
			const shown = scaled(item.value, entry.entry_scale || 1);
			parts.push({ key: 'dialog.value_check.special', args: [shown, { key: item.label_key }] });
		}
	} else if (result.reason === 'too_long') {
		parts.push({ key: 'dialog.value_check.too_long', args: [entry.max_length] });
	} else if (result.reason === 'not_allowed') {
		parts.push({ key: 'dialog.value_check.not_allowed', args: [] });
	} else {
		parts.push({ key: 'dialog.value_check.empty', args: [] });
	}
	return parts;
}

/**
 * Writes a bound: whole numbers without a fraction, at most 15 significant
 * digits otherwise, as the Lua and AHK ports write it.
 * @param {number} value
 * @return {string}
 */
function formatNumber(value) {
	if (Number.isInteger(value)) return String(value);
	return String(Number(value.toPrecision(15)));
}

/**
 * Translates messageParts() with an i18n accessor, fills the positional {1},
 * {2}… placeholders and joins the sentences with a space.
 * @param {Array<{key: string, args: Array}>} parts - From messageParts().
 * @param {function(string): string} translate - Returns the template of a key.
 * @return {string}
 */
function renderMessage(parts, translate) {
	return parts
		.map((part) => {
			const args = part.args.map((arg) =>
				arg !== null && typeof arg === 'object'
					? translate(arg.key)
					: typeof arg === 'number'
						? formatNumber(arg)
						: String(arg)
			);
			const template = translate(part.key);
			if (typeof template !== 'string') throw new Error(`value check: no text for ${part.key}`);
			return template.replace(
				/\{(\d+)\}/g,
				(whole, position) => args[Number(position) - 1] ?? whole
			);
		})
		.join(' ');
}

/**
 * Guards a consuming boundary: returns the value or throws an Error naming the
 * setting, the reason and the value, for the caller to log before failing.
 * @param {Object} schema - Parsed value_schema.json.
 * @param {string} key - Dotted setting path.
 * @param {*} value - Value about to reach the engine.
 * @return {*} The admitted value.
 */
function requireValue(schema, key, value) {
	const result = checkValue(entryFor(schema, key), value);
	if (!result.ok) {
		throw new RangeError(`${key} refused (${result.reason}): ${String(value)}`);
	}
	return result.value;
}

export {
	REASONS,
	TYPES,
	entryFor,
	checkValue,
	parseEntry,
	messageParts,
	formatNumber,
	renderMessage,
	requireValue
};
