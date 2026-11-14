// _shared/ui/value_check.js
// AUTO-GENERATED from _shared/settings/data/value_schema/value_check.js and
// value_schema.json. DO NOT EDIT BY HAND — run `npm run codegen:value-schema` to refresh.
// The shared WebView pages load it as a classic script: window.ErgoptiValueCheck.

(function () {
	'use strict';

/**
 * ==============================================================================
 * MODULE: User Value Check (canonical)
 * DESCRIPTION:
 * Checks one user-entered or stored setting value against its declaration in
 * value_schema.json, the single source of every setting's type, bounds and
 * special values. The shared Lua port (_shared/settings/engine/value_check.lua,
 * macOS and Linux) and the AHK port (windows/core/lifecycle/engine/value_check.ahk) replay
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
	'too_long',
	'not_url'
];

const TYPES = ['integer', 'decimal', 'boolean', 'enum', 'string', 'path', 'url'];

// A web address: a lowercase http or https scheme, then at least one
// character and no ASCII space or control character anywhere, so a stored
// link never reaches a browser or a shell carrying a line break or a space.
const URL_TEXT = /^https?:\/\/[^\x00-\x20\x7f]+$/;

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
			if (entry.type === 'url' && !URL_TEXT.test(value)) return refusal('not_url', entry);
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
	} else if (result.reason === 'not_url') {
		parts.push({ key: 'dialog.value_check.not_url', args: [] });
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

	const SCHEMA = {
		"_comment": "The one declaration of every user-entered setting value: its file, type, inclusive bounds, whether decimals are allowed (integer refuses them) and its special values. Read by value_check.js (web pages), _shared/settings/engine/value_check.lua (macOS, Linux) and the generated windows/_generated/value_schema.ahk. Values stay in the unit the file stores; entry_scale, entry_type and entry_unit describe the unit a person types (milliseconds typed for seconds stored: entry_scale 1000). Defaults are not repeated here: they stay in the feature manifest and the timing registry, and tools/test/test-value-schema.cjs checks that each default passes its declaration. Layout and rules: docs/design/value-validation-inventory.md.",
		"version": 1,
		"settings": {
			"tap_hold.time_activation_seconds": {
				"file": "tap_hold.toml",
				"type": "decimal",
				"unit": "s",
				"min": 0.001,
				"max": 10,
				"entry_scale": 1000,
				"entry_type": "integer",
				"entry_unit": "ms",
				"default_from": {
					"timing": "tap_hold.default_activation_ms",
					"scale": 0.001
				},
				"max_from": {
					"timing": "tap_hold.max_activation_ms",
					"scale": 0.001
				}
			},
			"tap_hold.keys.*.time_activation_seconds": {
				"file": "tap_hold.toml",
				"type": "decimal",
				"unit": "s",
				"min": 0.001,
				"max": 10,
				"entry_scale": 1000,
				"entry_type": "integer",
				"entry_unit": "ms",
				"max_from": {
					"timing": "tap_hold.max_activation_ms",
					"scale": 0.001
				}
			},
			"tap_holds.lone_modifier_tap_max_ms": {
				"file": "config.toml",
				"type": "integer",
				"unit": "ms",
				"min": 0,
				"max": 10000,
				"special": [
					{
						"value": 0,
						"label_key": "value_check.special.off"
					}
				],
				"default_from": {
					"manifest": "tap_holds.lone_modifier_tap_max_ms"
				}
			},
			"mod_combos.simultaneous_threshold_ms": {
				"file": "config.toml",
				"type": "integer",
				"unit": "ms",
				"min": 1,
				"max": 1000,
				"default_from": {
					"manifest": "mod_combos.simultaneous_threshold_ms"
				}
			},
			"hotstrings.expansion_delay": {
				"file": "config.toml",
				"type": "decimal",
				"unit": "s",
				"min": 0,
				"max": 3600,
				"entry_scale": 1000,
				"entry_type": "integer",
				"entry_unit": "ms",
				"special": [
					{
						"value": 0,
						"label_key": "value_check.special.no_time_limit"
					}
				],
				"default_from": {
					"manifest": "hotstrings.expansion_delay"
				}
			},
			"hotstrings.idle_reset_seconds": {
				"file": "config.toml",
				"type": "decimal",
				"unit": "s",
				"min": 0,
				"max": 3600,
				"special": [
					{
						"value": 0,
						"label_key": "value_check.special.never"
					}
				],
				"default_from": {
					"manifest": "hotstrings.idle_reset_seconds"
				}
			},
			"hotstrings.cascade_max_arrows": {
				"file": "config.toml",
				"type": "integer",
				"min": 1,
				"max": 10,
				"default_from": {
					"manifest": "hotstrings.cascade_max_arrows"
				}
			},
			"hotstrings.dynamic.user_code.time_activation_seconds": {
				"file": "config.toml",
				"type": "decimal",
				"unit": "s",
				"min": 0,
				"max": 3600,
				"entry_scale": 1000,
				"entry_type": "integer",
				"entry_unit": "ms"
			},
			"hotstrings_config.*.delay": {
				"file": "hotstrings_config.toml",
				"type": "decimal",
				"unit": "s",
				"min": 0,
				"max": 3600,
				"entry_scale": 1000,
				"entry_type": "integer",
				"entry_unit": "ms"
			},
			"hotstrings_config.*.*.delay": {
				"file": "hotstrings_config.toml",
				"type": "decimal",
				"unit": "s",
				"min": 0,
				"max": 3600,
				"entry_scale": 1000,
				"entry_type": "integer",
				"entry_unit": "ms"
			},
			"hotstrings_config.*.priority": {
				"file": "hotstrings_config.toml",
				"type": "integer",
				"min": 0,
				"max": 100
			},
			"hotstrings_config.*.*.priority": {
				"file": "hotstrings_config.toml",
				"type": "integer",
				"min": 0,
				"max": 100
			},
			"llm.generation.temperature": {
				"file": "config.toml",
				"type": "decimal",
				"min": 0,
				"max": 1.3,
				"default_from": {
					"manifest": "llm.generation.temperature"
				},
				"max_from": {
					"file": "ai/data/inference.json",
					"pattern": "\"max_temperature\": ([0-9.]+)"
				}
			},
			"llm.generation.context_length": {
				"file": "config.toml",
				"type": "integer",
				"unit": "characters",
				"min": 80,
				"max": 4000,
				"default_from": {
					"manifest": "llm.generation.context_length"
				},
				"max_from": {
					"file": "ai/engine/policy/context_buffer.lua",
					"pattern": "M\\.MAX_CONTEXT_LENGTH = ([0-9]+)"
				}
			},
			"llm.generation.min_words": {
				"file": "config.toml",
				"type": "integer",
				"unit": "words",
				"min": 1,
				"max": 20,
				"default_from": {
					"manifest": "llm.generation.min_words"
				}
			},
			"llm.generation.max_words": {
				"file": "config.toml",
				"type": "integer",
				"unit": "words",
				"min": 0,
				"max": 10000,
				"special": [
					{
						"value": 0,
						"label_key": "value_check.special.unlimited"
					}
				],
				"default_from": {
					"manifest": "llm.generation.max_words"
				}
			},
			"llm.profiles.num_predictions": {
				"file": "config.toml",
				"type": "integer",
				"min": 1,
				"max": 10,
				"default_from": {
					"manifest": "llm.profiles.num_predictions"
				}
			},
			"llm.trigger.debounce_ms": {
				"file": "config.toml",
				"type": "integer",
				"unit": "ms",
				"min": 50,
				"max": 10000,
				"special": [
					{
						"value": -1,
						"label_key": "value_check.special.never"
					}
				],
				"default_from": {
					"manifest": "llm.trigger.debounce_ms"
				}
			},
			"llm.trigger.min_request_interval_ms": {
				"file": "config.toml",
				"type": "integer",
				"unit": "ms",
				"min": 0,
				"max": 10000,
				"default_from": {
					"manifest": "llm.trigger.min_request_interval_ms"
				}
			},
			"shortcuts.caps_word.idle_timeout_seconds": {
				"file": "config.toml",
				"type": "decimal",
				"unit": "s",
				"min": 0,
				"max": 3600,
				"special": [
					{
						"value": 0,
						"label_key": "value_check.special.never"
					}
				],
				"default_from": {
					"manifest": "shortcuts.caps_word.idle_timeout_seconds"
				}
			},
			"gestures.sensitivities.*": {
				"file": "config.toml",
				"type": "decimal",
				"unit": "mm",
				"min": 1,
				"max": 60
			},
			"shortcuts.chatgpt_url": {
				"file": "config.toml",
				"type": "url",
				"max_length": 2048,
				"default_from": {
					"manifest": "shortcuts.chatgpt_url"
				}
			},
			"shortcuts.search.search_engine": {
				"file": "config.toml",
				"type": "url",
				"max_length": 2048,
				"default_from": {
					"manifest": "shortcuts.search.search_engine"
				}
			},
			"shortcuts.search.search_engine_url_query": {
				"file": "config.toml",
				"type": "url",
				"max_length": 2048,
				"default_from": {
					"manifest": "shortcuts.search.search_engine_url_query"
				}
			},
			"personal_info.info.*": {
				"file": "personal_info.toml",
				"type": "string",
				"allow_empty": true
			},
			"personal_info.letters.*": {
				"file": "personal_info.toml",
				"type": "string"
			}
		}
	};
	const KEY = {
		"TAP_HOLD_TIME_ACTIVATION_SECONDS": "tap_hold.time_activation_seconds",
		"TAP_HOLD_KEYS_ANY_TIME_ACTIVATION_SECONDS": "tap_hold.keys.*.time_activation_seconds",
		"TAP_HOLDS_LONE_MODIFIER_TAP_MAX_MS": "tap_holds.lone_modifier_tap_max_ms",
		"MOD_COMBOS_SIMULTANEOUS_THRESHOLD_MS": "mod_combos.simultaneous_threshold_ms",
		"HOTSTRINGS_EXPANSION_DELAY": "hotstrings.expansion_delay",
		"HOTSTRINGS_IDLE_RESET_SECONDS": "hotstrings.idle_reset_seconds",
		"HOTSTRINGS_CASCADE_MAX_ARROWS": "hotstrings.cascade_max_arrows",
		"HOTSTRINGS_DYNAMIC_USER_CODE_TIME_ACTIVATION_SECONDS": "hotstrings.dynamic.user_code.time_activation_seconds",
		"HOTSTRINGS_CONFIG_ANY_DELAY": "hotstrings_config.*.delay",
		"HOTSTRINGS_CONFIG_ANY_ANY_DELAY": "hotstrings_config.*.*.delay",
		"HOTSTRINGS_CONFIG_ANY_PRIORITY": "hotstrings_config.*.priority",
		"HOTSTRINGS_CONFIG_ANY_ANY_PRIORITY": "hotstrings_config.*.*.priority",
		"LLM_GENERATION_TEMPERATURE": "llm.generation.temperature",
		"LLM_GENERATION_CONTEXT_LENGTH": "llm.generation.context_length",
		"LLM_GENERATION_MIN_WORDS": "llm.generation.min_words",
		"LLM_GENERATION_MAX_WORDS": "llm.generation.max_words",
		"LLM_PROFILES_NUM_PREDICTIONS": "llm.profiles.num_predictions",
		"LLM_TRIGGER_DEBOUNCE_MS": "llm.trigger.debounce_ms",
		"LLM_TRIGGER_MIN_REQUEST_INTERVAL_MS": "llm.trigger.min_request_interval_ms",
		"SHORTCUTS_CAPS_WORD_IDLE_TIMEOUT_SECONDS": "shortcuts.caps_word.idle_timeout_seconds",
		"GESTURES_SENSITIVITIES_ANY": "gestures.sensitivities.*",
		"SHORTCUTS_CHATGPT_URL": "shortcuts.chatgpt_url",
		"SHORTCUTS_SEARCH_SEARCH_ENGINE": "shortcuts.search.search_engine",
		"SHORTCUTS_SEARCH_SEARCH_ENGINE_URL_QUERY": "shortcuts.search.search_engine_url_query",
		"PERSONAL_INFO_INFO_ANY": "personal_info.info.*",
		"PERSONAL_INFO_LETTERS_ANY": "personal_info.letters.*"
	};

	window.ErgoptiValueCheck = Object.freeze({ REASONS, TYPES, entryFor, checkValue, parseEntry, messageParts, formatNumber, renderMessage, requireValue, SCHEMA, KEY });
})();
