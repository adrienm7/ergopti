// tools/lib/config-key-tokens.cjs

/**
 * ==============================================================================
 * MODULE: Generated Config-Key Constants As Source Tokens
 * DESCRIPTION:
 * Source-shape gates read driver Lua for the string a call passes (a config key,
 * a menu command id). Once code names that string by its generated constant
 * (`ConfigKeys.KEY.LLM_ENABLED`, or a module-local alias of a table such as
 * `KEY.LLM_ENABLED`), the gate must see the same token the literal produced.
 * This module resolves such a reference from the generated tables, so a swap from
 * a literal to its constant keeps every pin and mutation control as strong.
 *
 * FEATURES & RATIONALE:
 * 1. Resolved From Data: names come from the generator's own tables
 *    (tools/codegen/codegen-config-keys.cjs), never from a copy.
 * 2. Refused When Wrong: a name the tables do not hold is left as the plain
 *    identifier tokens, which no literal pin matches; a name that resolves to a
 *    different key yields that key's string, which differs from the pinned one.
 * 3. Only The Spelling The Swap Introduces: `ConfigKeys.KEY.X`, `require("config_keys").KEY.X`
 *    and `CK.KEY.X` for a `local CK = require("config_keys")` collapse. A bare table
 *    alias (`COMMAND.X` after `local COMMAND = require("config_keys").COMMAND`) stays
 *    identifier tokens, because gates already pin that spelling as it is.
 * ==============================================================================
 */

'use strict';

const Codegen = require('../codegen/codegen-config-keys.cjs');
const { scriptTokens } = require('./script-source.cjs');

const TABLES = ['KEY', 'LEAF', 'COMMAND'];
let resolved = null;

/** Name-to-value maps of the generated tables, built once. */
function constants() {
	if (resolved) return resolved;
	const tables = Codegen.collect();
	resolved = {};
	for (const name of TABLES) resolved[name] = new Map(tables[name]);
	return resolved;
}

/**
 * Resolves one constant reference.
 * @param {string} table KEY, LEAF or COMMAND.
 * @param {string} name Constant name.
 * @returns {string|undefined} The value, or undefined when the table has no such name.
 */
function resolve(table, name) {
	const map = constants()[table];
	return map ? map.get(name) : undefined;
}

/**
 * Declared aliases of the config_keys module and of its tables in one token list.
 * @param {Array<{kind: string, value: string}>} code Code tokens of one Lua source.
 * @returns {{roots: Set<string>, tables: Map<string, string>}}
 */
function declaredAliases(code) {
	const roots = new Set(['ConfigKeys']);
	const tables = new Map();
	const at = (i, value) => code[i] && code[i].value === value && code[i].kind !== 'string';
	/** Matches a reference to the module or one of its tables at i; returns [table|null, next]. */
	const reference = (i) => {
		let next = i;
		if (code[next] && roots.has(code[next].value) && code[next].kind === 'identifier') next += 1;
		else if (
			at(next, 'require') &&
			at(next + 1, '(') &&
			code[next + 2] &&
			code[next + 2].kind === 'string' &&
			code[next + 2].value === 'config_keys' &&
			at(next + 3, ')')
		)
			next += 4;
		else return null;
		if (at(next, '.') && code[next + 1] && TABLES.includes(code[next + 1].value))
			return [code[next + 1].value, next + 2];
		return [null, next];
	};
	for (let i = 0; i < code.length; i++) {
		if (!at(i, 'local')) continue;
		const names = [];
		let j = i + 1;
		while (code[j] && code[j].kind === 'identifier') {
			names.push(code[j].value);
			j += 1;
			if (at(j, ',')) j += 1;
			else break;
		}
		if (names.length === 0 || !at(j, '=')) continue;
		j += 1;
		for (const name of names) {
			const ref = reference(j);
			if (!ref) break;
			if (ref[0]) tables.set(name, ref[0]);
			else roots.add(name);
			j = ref[1];
			if (at(j, ',')) j += 1;
		}
	}
	return { roots, tables };
}

/**
 * Collapses constant references into string tokens that keep the span they covered.
 * @param {Array<{kind: string, value: string, start: number, end: number}>} code Code tokens.
 * @returns {Array} The same tokens, each reference replaced by one string token.
 */
function collapseConfigKeys(code) {
	const { roots, tables } = declaredAliases(code);
	const at = (i, value) => code[i] && code[i].value === value && code[i].kind !== 'string';
	const out = [];
	for (let i = 0; i < code.length; i++) {
		const token = code[i];
		const previous = out[out.length - 1];
		const afterAccess =
			previous && previous.kind === 'symbol' && (previous.value === '.' || previous.value === ':');
		// require("config_keys").TABLE.NAME, for a file with no local left to spend on an alias
		if (
			token.kind === 'identifier' &&
			token.value === 'require' &&
			!afterAccess &&
			at(i + 1, '(') &&
			code[i + 2] &&
			code[i + 2].kind === 'string' &&
			code[i + 2].value === 'config_keys' &&
			at(i + 3, ')') &&
			at(i + 4, '.') &&
			code[i + 5] &&
			TABLES.includes(code[i + 5].value) &&
			at(i + 6, '.') &&
			code[i + 7] &&
			code[i + 7].kind === 'identifier'
		) {
			const value = resolve(code[i + 5].value, code[i + 7].value);
			if (value !== undefined) {
				out.push({ kind: 'string', value, start: token.start, end: code[i + 7].end });
				i += 7;
				continue;
			}
		}
		if (token.kind === 'identifier' && !afterAccess) {
			// Root.TABLE.NAME
			if (
				roots.has(token.value) &&
				at(i + 1, '.') &&
				code[i + 2] &&
				TABLES.includes(code[i + 2].value) &&
				at(i + 3, '.') &&
				code[i + 4] &&
				code[i + 4].kind === 'identifier'
			) {
				const value = resolve(code[i + 2].value, code[i + 4].value);
				if (value !== undefined) {
					out.push({ kind: 'string', value, start: token.start, end: code[i + 4].end });
					i += 4;
					continue;
				}
			}
		}
		out.push(token);
	}
	return out;
}

/**
 * The source text with every resolvable constant reference replaced by the quoted string
 * it stands for, for the gates that match source text with a regular expression.
 * @param {string} source Lua source text.
 * @returns {string} Source in which `ConfigKeys.KEY.LLM_ENABLED` reads `"llm.enabled"`.
 */
function expandConfigKeys(source) {
	let out = '';
	let at = 0;
	for (const token of collapseConfigKeys(scriptTokens(source, '.lua'))) {
		if (token.kind !== 'string') continue;
		const first = source[token.start];
		if (first === '"' || first === "'" || first === '[') continue;
		out += source.slice(at, token.start) + JSON.stringify(token.value);
		at = token.end;
	}
	return out + source.slice(at);
}

module.exports = { resolve, collapseConfigKeys, expandConfigKeys };
