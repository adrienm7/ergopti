// tools/lib/keymap-layers.cjs

/**
 * ==============================================================================
 * MODULE: Keymap Layers — JavaScript Reference Loader
 * DESCRIPTION:
 * Reads a layer file (the shipped layers.recommended.toml or a user's
 * layers.toml), validates it against the physical-key registry and the layer
 * vocabulary, and resolves each binding for one OS. It implements the same
 * contract as the two driver loaders — _shared/lua/keymap/layers.lua and
 * windows/platform/remap/layers_loader.ahk — so the JS gates can check the
 * shipped data, and so the shared corpus under
 * _shared/tests/corpus/keymap_layers/ can hold all three implementations to one
 * answer.
 *
 * FEATURES & RATIONALE:
 * 1. One grammar: a binding is a named action, repeat_count:<N> or
 *    keystroke:<chord>; a resolution is keystroke:<chords>, call:<handler> or
 *    none. Both go through the same chord parser.
 * 2. Errors are data: every problem is an { code, layer, section, key, detail }
 *    record with a stable code, so the corpus can assert the exact rejection
 *    each driver must produce, not just "something failed".
 * 3. File-level errors (unreadable TOML, missing or unsupported schema
 *    version) reject the whole file; entry-level errors drop that entry only
 *    and are all reported.
 * 4. One file format: a layer file is the line-oriented TOML subset described
 *    in layer_actions.toml. It is checked line by line before smol-toml reads
 *    the file, exactly as the Lua and AHK loaders check it, so a file one
 *    TOML parser reads and another cannot is rejected by all of them.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const TOML = require('smol-toml');
const { shared } = require('./paths.cjs');

const REGISTRY_PATH = shared('data', 'keycodes', 'physical_keys.json');
const VOCABULARY_PATH = shared('keymap', 'layer_actions.toml');
const RECOMMENDED_PATH = shared('keymap', 'layers.recommended.toml');

const ACTION_ID = /^[a-z][a-z0-9_]*$/;
const LAYER_ID = /^[a-z][a-z0-9_]*$/;
const SECTION_ALL = 'all';

// The layer-file format (layer_actions.toml, "File format"). The Lua loader
// and the AHK reader implement the same rules; the corpus holds them together.
const BOM = '﻿';
const CONTROL_CHARACTER = /[\u0000-\u0008\u000A-\u001F\u007F]/;
const TABLE_HEADER = /^\[[ \t]*[A-Za-z0-9_-]+(?:[ \t]*\.[ \t]*[A-Za-z0-9_-]+)*[ \t]*\][ \t]*(?:#.*)?$/;
const KEY_VALUE = /^(?:[A-Za-z0-9_-]+|"((?:[^"\\]|\\.)*)"|'[^']*')[ \t]*=[ \t]*(.*)$/;
const BASIC_STRING_VALUE = /^"((?:[^"\\]|\\.)*)"[ \t]*(?:#.*)?$/;
const LITERAL_STRING_VALUE = /^'[^']*'[ \t]*(?:#.*)?$/;
const BOOLEAN_VALUE = /^(?:true|false)[ \t]*(?:#.*)?$/;
const INTEGER_VALUE = /^[+-]?(0|[1-9](?:_?[0-9])*)[ \t]*(?:#.*)?$/;
const FLOAT_VALUE = /^[+-]?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?[ \t]*(?:#.*)?$/;
// The most digits every loader holds exactly: JS numbers are exact to 2^53,
// and AutoHotkey wraps a longer integer round instead of refusing it.
const MAX_INTEGER_DIGITS = 15;
const MAX_UNICODE_SCALAR = 0x10ffff;
const SURROGATE_FIRST = 0xd800;
const SURROGATE_LAST = 0xdfff;
const SIMPLE_ESCAPES = 'btnfr"\\';

/**
 * Checks the escapes of a basic string's contents (TOML 1.0 escapes only).
 * @param {string} contents - The text between the quotes.
 * @returns {string|null} Why the escapes are invalid, or null.
 */
function escapeProblem(contents) {
	for (let i = 0; i < contents.length; i++) {
		if (contents[i] !== '\\') continue;
		const next = contents[i + 1];
		if (SIMPLE_ESCAPES.includes(next)) {
			i += 1;
			continue;
		}
		const width = next === 'u' ? 4 : next === 'U' ? 8 : 0;
		const hex = contents.slice(i + 2, i + 2 + width);
		if (width === 0 || hex.length !== width || /[^0-9A-Fa-f]/.test(hex)) return `"\\${next}" is not a TOML escape`;
		const code = parseInt(hex, 16);
		if (code === 0 || code > MAX_UNICODE_SCALAR || (code >= SURROGATE_FIRST && code <= SURROGATE_LAST))
			return `"\\${next}${hex}" is not a character a layer file can hold`;
		i += 1 + width;
	}
	return null;
}

/**
 * Checks that a layer file stays inside the layer-file format.
 * @param {string} text - The file content without its byte order mark.
 * @returns {string|null} The first problem, naming its line, or null.
 */
function formatProblem(text) {
	const lines = text.split('\n');
	for (let index = 0; index < lines.length; index++) {
		const where = `line ${index + 1}`;
		let line = lines[index];
		// A CRLF line end is one line end; any other carriage return is a
		// control character.
		if (line.endsWith('\r')) line = line.slice(0, -1);
		if (CONTROL_CHARACTER.test(line)) return `${where}: control characters other than tab are not allowed`;
		line = line.replace(/^[ \t]+|[ \t]+$/g, '');
		if (line === '' || line.startsWith('#')) continue;
		if (line.startsWith('[')) {
			if (!TABLE_HEADER.test(line)) return `${where}: a table header names bare keys only, like [layers.nav.all]`;
			continue;
		}
		const pair = KEY_VALUE.exec(line);
		if (!pair) return `${where}: expected a table header or one key = value pair (dotted keys are not part of the format)`;
		if (pair[1] !== undefined) {
			const problem = escapeProblem(pair[1]);
			if (problem) return `${where}: ${problem}`;
		}
		const value = pair[2];
		const basic = BASIC_STRING_VALUE.exec(value);
		if (basic) {
			const problem = escapeProblem(basic[1]);
			if (problem) return `${where}: ${problem}`;
			continue;
		}
		if (LITERAL_STRING_VALUE.test(value) || BOOLEAN_VALUE.test(value)) continue;
		// An integer is read as an integer or not at all: it never falls
		// through to the float form, whatever its length.
		const integer = INTEGER_VALUE.exec(value);
		if (integer) {
			if (integer[1].replace(/_/g, '').length > MAX_INTEGER_DIGITS) return `${where}: an integer has at most ${MAX_INTEGER_DIGITS} digits`;
			continue;
		}
		if (FLOAT_VALUE.test(value)) continue;
		return `${where}: a value is a one-line string, true, false, a decimal integer or a decimal float`;
	}
	return null;
}

/**
 * Loads the registry and the vocabulary once.
 * @returns {{registry: object, vocabulary: object, platforms: string[]}}
 */
function loadContext() {
	const registry = JSON.parse(fs.readFileSync(REGISTRY_PATH, 'utf8'));
	const vocabulary = TOML.parse(fs.readFileSync(VOCABULARY_PATH, 'utf8'));
	return { registry, vocabulary, platforms: vocabulary._meta.platforms };
}

function error(code, layer, section, key, detail, extra) {
	return Object.assign({ code, layer, section, key, detail }, extra || {});
}

/**
 * Parses `mod+…+Key[,mod+…+Key…]` into chords of raw (unresolved) modifiers.
 * @returns {{chords?: Array<{mods: string[], key: string}>, problem?: string}}
 */
function parseChords(text, ctx) {
	const order = ctx.vocabulary._meta.modifier_order;
	const chords = [];
	for (const part of text.split(',')) {
		const tokens = part.split('+');
		const key = tokens.pop();
		if (!key) return { problem: `empty chord in "${text}"` };
		const entry = ctx.registry.keys[key];
		if (!entry || entry.kind !== 'key') return { problem: `"${key}" is not a keyboard key in the physical-key registry` };
		const seen = new Set();
		for (const mod of tokens) {
			if (mod !== 'primary' && !order.includes(mod)) return { problem: `unknown modifier "${mod}"` };
			if (seen.has(mod)) return { problem: `modifier "${mod}" named twice` };
			seen.add(mod);
		}
		chords.push({ mods: tokens, key });
	}
	return { chords };
}

/**
 * Parses one binding value. Syntax only: availability on an OS is checked later.
 * @returns {{binding?: object, error?: {code: string, detail: string}}}
 */
function parseBinding(value, ctx) {
	if (typeof value !== 'string') return { error: { code: 'invalid_value_type', detail: 'a binding must be a string' } };
	const colon = value.indexOf(':');
	if (colon < 0) {
		if (!ACTION_ID.test(value) || !ctx.vocabulary.actions[value]) return { error: { code: 'unknown_action', detail: `"${value}" is not a layer action` } };
		return { binding: { type: 'action', id: value } };
	}
	const head = value.slice(0, colon);
	const rest = value.slice(colon + 1);
	if (head === 'repeat_count') {
		const p = ctx.vocabulary.parameters.repeat_count;
		if (!/^[0-9]+$/.test(rest) || Number(rest) < p.min || Number(rest) > p.max)
			return { error: { code: 'invalid_parameter', detail: `repeat_count takes an integer from ${p.min} to ${p.max}` } };
		return { binding: { type: 'repeat_count', count: Number(rest) } };
	}
	if (head === 'keystroke') {
		const parsed = parseChords(rest, ctx);
		if (parsed.problem) return { error: { code: 'invalid_keystroke', detail: parsed.problem } };
		return { binding: { type: 'keystroke', chords: parsed.chords } };
	}
	return { error: { code: 'unknown_action', detail: `"${head}:" is not a binding form` } };
}

/** Resolves raw modifiers for one OS, or names the modifier that cannot resolve. */
function resolveChords(chords, os, ctx) {
	const order = ctx.vocabulary._meta.modifier_order;
	const restricted = ctx.vocabulary.modifiers || {};
	const out = [];
	for (const chord of chords) {
		const mods = new Set();
		for (const raw of chord.mods) {
			const mod = raw === 'primary' ? ctx.vocabulary.primary_modifier[os] : raw;
			const rule = restricted[mod];
			if (rule && !rule.platforms.includes(os)) return { unavailable: { detail: `modifier "${mod}" does not exist on ${os}`, reason_key: rule.reason_key } };
			mods.add(mod);
		}
		out.push({ mods: order.filter((m) => mods.has(m)), key: chord.key });
	}
	return { chords: out };
}

/** Parses a vocabulary resolution string (keystroke:/call:/none). */
function parseResolution(text, os, ctx) {
	if (text === 'none') return { kind: 'none' };
	if (text.startsWith('call:')) {
		const handler = text.slice(5);
		if (!(ctx.vocabulary.call_handlers[os] || []).includes(handler)) throw new Error(`call:${handler} is not declared for ${os}`);
		return { kind: 'call', handler };
	}
	if (text.startsWith('keystroke:')) {
		const parsed = parseChords(text.slice(10), ctx);
		if (parsed.problem) throw new Error(`vocabulary resolution "${text}": ${parsed.problem}`);
		return { kind: 'keystroke', chords: parsed.chords };
	}
	throw new Error(`vocabulary resolution "${text}" is not keystroke:, call: or none`);
}

/**
 * Says why a physical input cannot be a layer key on one OS, or null when it can.
 * @param {string} code - A registry key code.
 * @returns {{detail: string, reason_key: string}|null}
 */
function sourceUnavailable(code, os, ctx) {
	const kind = ctx.registry.keys[code].kind;
	const rule = (ctx.vocabulary.source_kinds || {})[kind];
	if (rule && !rule.platforms.includes(os)) return { detail: `a ${kind} input cannot be a layer key on ${os}`, reason_key: rule.reason_key };
	return null;
}

/**
 * Resolves one syntactically valid binding on one OS.
 * @returns {{resolved?: object, unavailable?: {detail: string, reason_key: string}}}
 */
function resolveBinding(binding, os, ctx) {
	if (binding.type === 'repeat_count') {
		const p = ctx.vocabulary.parameters.repeat_count;
		if (!p.platforms.includes(os)) return { unavailable: { detail: `repeat_count does not exist on ${os}`, reason_key: p.reason_key } };
		return { resolved: { kind: 'repeat_count', count: binding.count } };
	}
	if (binding.type === 'keystroke') {
		const r = resolveChords(binding.chords, os, ctx);
		if (r.unavailable) return r;
		return { resolved: { kind: 'keystroke', chords: r.chords, repeatable: false, action: null } };
	}
	const action = ctx.vocabulary.actions[binding.id];
	const text = action[os] !== undefined ? action[os] : action[SECTION_ALL];
	if (text === undefined) return { unavailable: { detail: `action "${binding.id}" has no resolution on ${os}`, reason_key: action.reason_key } };
	const res = parseResolution(text, os, ctx);
	if (res.kind === 'keystroke') {
		const r = resolveChords(res.chords, os, ctx);
		if (r.unavailable) throw new Error(`vocabulary action "${binding.id}" uses an unavailable modifier on ${os}`);
		res.chords = r.chords;
	}
	res.repeatable = res.kind !== 'none' && action.repeatable === true;
	res.action = binding.id;
	return { resolved: res };
}

/**
 * Loads a layer file for one OS.
 * @param {string|null} text - File content, or null when the file is absent.
 * @param {string} os - windows | macos | linux.
 * @param {object} ctx - From loadContext().
 * @returns {{ok: boolean, errors: object[], layers: object}}
 */
function loadLayers(text, os, ctx) {
	const result = { ok: true, errors: [], layers: {} };
	const reject = (e) => {
		result.errors.push(e);
		result.ok = false;
		result.layers = {};
		return result;
	};
	if (text === null) return result;
	const body = text.startsWith(BOM) ? text.slice(BOM.length) : text;
	const problem = formatProblem(body);
	if (problem) return reject(error('toml_invalid', null, null, null, problem));
	let doc;
	try {
		doc = TOML.parse(body);
	} catch (e) {
		return reject(error('toml_invalid', null, null, null, e.message));
	}
	if (Object.keys(doc).length === 0) return result;
	const meta = doc._meta;
	if (meta === null || typeof meta !== 'object' || meta.schema_version === undefined)
		return reject(error('schema_version_missing', null, null, null, '[_meta].schema_version is required'));
	if (meta.schema_version !== ctx.vocabulary._meta.layers_schema_version)
		return reject(error('schema_version_unsupported', null, null, null, `schema_version ${meta.schema_version} is not ${ctx.vocabulary._meta.layers_schema_version}`));
	const report = (e) => {
		result.errors.push(e);
		result.ok = false;
	};
	for (const key of Object.keys(meta).sort()) if (key !== 'schema_version') report(error('unknown_field', null, '_meta', key, `[_meta].${key} is not a field`));
	for (const key of Object.keys(doc).sort()) if (key !== '_meta' && key !== 'layers') report(error('unknown_field', null, null, key, `top-level "${key}" is not a field`));
	const layers = doc.layers === undefined ? {} : doc.layers;
	if (layers === null || typeof layers !== 'object' || Array.isArray(layers)) return reject(error('invalid_value_type', null, null, 'layers', '"layers" must be a table'));

	const sections = [SECTION_ALL, ...ctx.platforms];
	for (const layerId of Object.keys(layers).sort()) {
		if (!LAYER_ID.test(layerId)) {
			report(error('invalid_layer_id', layerId, null, null, `layer id "${layerId}" must match ${LAYER_ID}`));
			continue;
		}
		const layer = layers[layerId];
		if (layer === null || typeof layer !== 'object' || Array.isArray(layer)) {
			report(error('invalid_value_type', layerId, null, null, 'a layer must be a table'));
			continue;
		}
		const parsed = {};
		for (const section of Object.keys(layer).sort()) {
			if (!sections.includes(section)) {
				report(error('unknown_layer_section', layerId, section, null, `"${section}" is not one of ${sections.join(', ')}`));
				continue;
			}
			const table = layer[section];
			if (table === null || typeof table !== 'object' || Array.isArray(table)) {
				report(error('invalid_value_type', layerId, section, null, 'a layer section must be a table'));
				continue;
			}
			parsed[section] = {};
			for (const code of Object.keys(table).sort()) {
				if (!ctx.registry.keys[code]) {
					report(error('unknown_key', layerId, section, code, `"${code}" is not in the physical-key registry`));
					continue;
				}
				const p = parseBinding(table[code], ctx);
				if (p.error) report(error(p.error.code, layerId, section, code, p.error.detail));
				else parsed[section][code] = p.binding;
			}
		}
		// The OS entry replaces the `all` entry for its key, even when it is the
		// invalid one: a rejected override must not quietly fall back.
		const effective = {};
		for (const section of [SECTION_ALL, os]) {
			const raw = layer[section];
			if (raw === null || typeof raw !== 'object') continue;
			for (const code of Object.keys(raw)) effective[code] = { section, binding: parsed[section] && parsed[section][code] };
		}
		const out = {};
		for (const code of Object.keys(effective).sort()) {
			const { section, binding } = effective[code];
			if (!binding) continue;
			const source = sourceUnavailable(code, os, ctx);
			const r = source ? { unavailable: source } : resolveBinding(binding, os, ctx);
			if (r.unavailable) report(error('unavailable_on_os', layerId, section, code, r.unavailable.detail, { reason_key: r.unavailable.reason_key }));
			else out[code] = r.resolved;
		}
		result.layers[layerId] = out;
	}
	return result;
}

/**
 * The canonical text form of one resolution, shared by the three loaders'
 * corpus replays: keystroke:ctrl+shift+Home, keystroke:End,Enter@repeat,
 * call:maximize_window, repeat_count:3, none.
 */
function formatResolution(r) {
	if (r.kind === 'none') return 'none';
	if (r.kind === 'repeat_count') return `repeat_count:${r.count}`;
	const suffix = r.repeatable ? '@repeat' : '';
	if (r.kind === 'call') return `call:${r.handler}${suffix}`;
	return 'keystroke:' + r.chords.map((c) => [...c.mods, c.key].join('+')).join(',') + suffix;
}

/**
 * The comparable identity of one error, shared with the Lua and AHK loaders:
 * code|layer|section|key|reason_key with absent parts empty. The detail text is
 * for humans and is not compared.
 */
function errorSignature(e) {
	return [e.code, e.layer, e.section, e.key, e.reason_key].map((part) => (part === null || part === undefined ? '' : String(part))).join('|');
}

module.exports = {
	REGISTRY_PATH,
	VOCABULARY_PATH,
	RECOMMENDED_PATH,
	loadContext,
	loadLayers,
	parseChords,
	parseResolution,
	formatResolution,
	errorSignature
};
