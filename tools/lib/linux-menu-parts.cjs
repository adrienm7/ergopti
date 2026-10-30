// tools/lib/linux-menu-parts.cjs

/**
 * Follows the Linux tray root across its per-section modules.
 *
 * `linux/ui/menu/menu_builder.lua` keeps the tray root and binds each section
 * builder from its own module:
 *
 *     local _build_quit = require("ui.menu.menu_quit").build
 *
 * The menu gates are single-source analysers: they prove a builder's wiring
 * by reading its body next to the root's imports and facade checks. This
 * resolver admits one closed wiring and recomposes the root the analysers
 * already read: each binding is replaced by the definitions of the module it
 * names, so a mutation inside a split module reaches every gate exactly as it
 * did when the code lived in the root. Any other wiring (a foreign module, a
 * renamed export, an extra statement, an import the root does not hold, a
 * second write of a bound name) is refused with a reason, never composed.
 *
 * This is a finite lexical route check, not a Lua evaluator.
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { scriptTokens } = require('./script-source.cjs');

const LINUX_MENU_ROOT = 'linux/ui/menu/menu_builder.lua';
const PART_MODULE = /^ui\.menu\.menu_([a-z][a-z_]*)$/;

/** The repository-relative file of one part module, or null for a foreign name. */
function partFile(moduleName) {
	const match = PART_MODULE.exec(moduleName);
	if (!match || match[1] === 'builder') return null;
	return 'linux/ui/menu/menu_' + match[1] + '.lua';
}

/** Lexes Lua with each token's block depth; null on unbalanced blocks. */
function lex(source) {
	if (typeof source !== 'string') return null;
	const tokens = scriptTokens(source, '.lua');
	const depth = [],
		braces = [],
		stack = [],
		brackets = [],
		closes = new Map();
	let awaitingDo = 0;
	for (let at = 0; at < tokens.length; at++) {
		const token = tokens[at];
		depth[at] = stack.length;
		braces[at] = brackets.at(-1);
		if (token.kind === 'symbol' && ['{', '(', '['].includes(token.value))
			brackets.push(token.value);
		if (token.kind === 'symbol' && ['}', ')', ']'].includes(token.value)) brackets.pop();
		// A closing label (::continue::) is followed by a keyword, not a method name.
		const afterLabel =
			tokens[at - 1]?.value === ':' &&
			tokens[at - 2]?.value === ':' &&
			tokens[at - 3]?.kind === 'identifier' &&
			tokens[at - 4]?.value === ':' &&
			tokens[at - 5]?.value === ':';
		if (token.kind !== 'identifier' || (['.', ':'].includes(tokens[at - 1]?.value) && !afterLabel))
			continue;
		if (['function', 'if', 'for', 'while', 'repeat'].includes(token.value)) {
			stack.push({ word: token.value, at });
			if (['for', 'while'].includes(token.value)) awaitingDo++;
		} else if (token.value === 'do') {
			if (awaitingDo) awaitingDo--;
			else stack.push({ word: 'do', at });
		} else if (token.value === 'end' || token.value === 'until') {
			const block = stack.pop();
			if (!block || (token.value === 'until') !== (block.word === 'repeat')) return null;
			closes.set(block.at, at);
		}
	}
	return stack.length || brackets.length ? null : { source, tokens, depth, braces, closes };
}

/** Whether the tokens at `at` spell `statement`, string bytes included. */
function spells(unit, at, statement) {
	const wanted = scriptTokens(statement, '.lua');
	return wanted.every((token, offset) => {
		const actual = unit.tokens[at + offset];
		return (
			actual?.kind === token.kind &&
			actual.value === token.value &&
			(token.kind !== 'string' ||
				unit.source.slice(actual.start, actual.end) === statement.slice(token.start, token.end))
		);
	})
		? at + wanted.length
		: null;
}

/** The text of tokens [from, to). */
function text(unit, from, to) {
	return unit.source.slice(unit.tokens[from].start, unit.tokens[to - 1].end);
}

/** Parses `local N = require("ui.menu.menu_P").F` at `at`; null when it is not one. */
function partBinding(unit, at) {
	const t = unit.tokens;
	if (
		t[at]?.value !== 'local' ||
		t[at + 1]?.kind !== 'identifier' ||
		t[at + 2]?.value !== '=' ||
		t[at + 3]?.value !== 'require' ||
		t[at + 4]?.value !== '(' ||
		t[at + 5]?.kind !== 'string' ||
		t[at + 6]?.value !== ')' ||
		t[at + 7]?.value !== '.' ||
		t[at + 8]?.kind !== 'identifier'
	)
		return null;
	return {
		at,
		end: at + 9,
		name: t[at + 1].value,
		module: t[at + 5].value,
		field: t[at + 8].value
	};
}

/** The export a binding of `name` must read: `build` for a section builder, else its own name. */
function expectedField(name, moduleName) {
	const match = PART_MODULE.exec(moduleName);
	return match && name === '_build_' + match[1] ? 'build' : name;
}

/** Positions where `name` is declared or assigned outside table keys. */
function writesOf(unit, name) {
	const found = [];
	const t = unit.tokens;
	for (let at = 0; at < t.length; at++) {
		if (t[at].kind !== 'identifier' || t[at].value !== name) continue;
		if (['.', ':'].includes(t[at - 1]?.value)) continue;
		const previous = t[at - 1]?.value;
		if (previous === 'local' || previous === 'function' || previous === 'for') {
			found.push(at);
			continue;
		}
		if (previous === ',' && t[at - 2]?.kind === 'identifier' && unit.braces[at] === undefined) {
			// Part of a local/assignment name list: walk back to its head.
			let head = at - 2;
			while (t[head - 1]?.value === ',' && t[head - 2]?.kind === 'identifier') head -= 2;
			if (t[head - 1]?.value === 'local') {
				found.push(at);
				continue;
			}
		}
		if (t[at + 1]?.value === '=' && t[at + 2]?.value !== '=' && unit.braces[at] !== '{')
			found.push(at);
	}
	return found;
}

/** Index of the first token after the top-level statement that starts at `at`; null if unknown. */
function statementEnd(unit, at) {
	const t = unit.tokens;
	if (t[at].value === 'local' && t[at + 1]?.value === 'function') {
		const close = unit.closes.get(at + 1);
		return close === undefined ? null : close + 1;
	}
	if (t[at].value === 'if') {
		const close = unit.closes.get(at);
		return close === undefined ? null : close + 1;
	}
	// A plain statement ends where a name follows a finished value: Lua has no
	// terminator, and the part grammar holds no call statement to confuse it.
	const operators = new Set(['and', 'or', 'not', 'then', 'in', 'do']);
	const finished = (token) =>
		token.kind === 'string' ||
		[')', ']', '}'].includes(token.value) ||
		/^[0-9]$/.test(token.value) ||
		(token.kind === 'identifier' && !operators.has(token.value) && token.value !== 'local');
	let end = at + 1;
	while (end < t.length) {
		const token = t[end];
		if (
			unit.depth[end] === 0 &&
			unit.braces[end] === undefined &&
			token.kind === 'identifier' &&
			!operators.has(token.value) &&
			!['.', ':'].includes(t[end - 1]?.value) &&
			finished(t[end - 1])
		)
			break;
		end++;
	}
	return end;
}

// The only globals a part's header may read before it declares anything.
const HEADER_GLOBALS = ['require', 'pcall', 'type', 'rawget', 'package'];
const LUA_WORDS = new Set([
	'and',
	'or',
	'not',
	'nil',
	'true',
	'false',
	'if',
	'then',
	'end',
	'local'
]);

/** Names a `local a, b = ...` header statement declares. */
function headerDeclares(unit, at) {
	const t = unit.tokens,
		names = [];
	if (t[at].value !== 'local') return names;
	for (let k = at + 1; t[k]?.kind === 'identifier'; k += 2) {
		names.push(t[k].value);
		if (t[k + 1]?.value !== ',') break;
	}
	return names;
}

/** Free names a header statement reads: not a field, not a keyword, not its own declaration. */
function headerReads(unit, at, end) {
	const t = unit.tokens,
		declared = headerDeclares(unit, at),
		valueAt = declared.length ? at + declared.length * 2 : at;
	const reads = [];
	for (let index = at; index < end; index++) {
		const token = t[index];
		if (token.kind !== 'identifier' || LUA_WORDS.has(token.value)) continue;
		if (['.', ':'].includes(t[index - 1]?.value)) continue;
		if (index < valueAt && declared.includes(token.value)) continue;
		// The boot guard assigns the facade it declared just before.
		if (t[at].value === 'if' && t[index + 1]?.value === '=' && t[index + 2]?.value !== '=')
			continue;
		reads.push(token.value);
	}
	return reads;
}

/**
 * Reads one part module into its header imports, its definitions and its exports.
 * @returns {{ ok: true, imports: object[], partBindings: object[], span: string, exports: Map<string,string> } | { ok: false, reason: string }}
 */
function readPart(file, source) {
	const unit = lex(source);
	if (!unit) return { ok: false, reason: file + ': unbalanced Lua blocks' };
	const t = unit.tokens;
	const moduleName = 'ui.menu.' + path.basename(file, '.lua');
	const imports = [],
		partBindings = [],
		definitions = new Set(),
		exports = new Map(),
		known = new Set(HEADER_GLOBALS);
	let at = 0,
		phase = 'header',
		spanStart = null,
		spanEnd = null;
	const refuse = (reason) => ({ ok: false, reason: file + ': ' + reason });
	at = spells(unit, 0, 'local M = {}');
	if (at === null) return refuse('must open with `local M = {}`');
	while (at < t.length) {
		if (unit.depth[at] !== 0) return refuse('statement outside the top level');
		const token = t[at];
		if (token.value === 'return') {
			if (spells(unit, at, 'return M') !== t.length) return refuse('must end with `return M`');
			at = t.length;
			break;
		}
		if (token.value === 'M') {
			// `M.F = NAME`, after every definition.
			if (
				t[at + 1]?.value !== '.' ||
				t[at + 2]?.kind !== 'identifier' ||
				t[at + 3]?.value !== '=' ||
				t[at + 4]?.kind !== 'identifier' ||
				!definitions.has(t[at + 4].value)
			)
				return refuse('an export must be `M.<field> = <local function>`');
			const field = t[at + 2].value,
				name = t[at + 4].value;
			if (exports.has(field) || [...exports.values()].includes(name))
				return refuse('duplicate export of ' + field);
			if (expectedField(name, moduleName) !== field)
				return refuse('`M.' + field + ' = ' + name + '` exports under a foreign field');
			exports.set(field, name);
			phase = 'exports';
			at += 5;
			continue;
		}
		if (phase === 'exports') return refuse('a statement follows the exports');
		const binding = partBinding(unit, at);
		if (binding && PART_MODULE.test(binding.module)) {
			if (phase !== 'header') return refuse('a part binding follows a definition');
			if (expectedField(binding.name, binding.module) !== binding.field)
				return refuse('binding ' + binding.name + ' reads a foreign field');
			partBindings.push({ ...binding, text: text(unit, binding.at, binding.end) });
			known.add(binding.name);
			at = binding.end;
			continue;
		}
		if (token.value === 'local' && t[at + 1]?.value === 'function') {
			const name = t[at + 2];
			if (name?.kind !== 'identifier' || definitions.has(name.value))
				return refuse('duplicate or unnamed definition');
			const end = statementEnd(unit, at);
			if (end === null) return refuse('unclosed definition ' + name.value);
			definitions.add(name.value);
			if (spanStart === null) spanStart = at;
			spanEnd = end;
			phase = 'definitions';
			at = end;
			continue;
		}
		if (token.value === 'local' && t[at + 1]?.value === 'LOG') {
			const end = spells(unit, at, 'local LOG = "' + moduleName + '"');
			if (end === null || t[end]?.value === '..') return refuse('LOG must name this module');
			if (phase !== 'header') return refuse('LOG follows a definition');
			at = end;
			continue;
		}
		if (token.value === 'local' || token.value === 'if') {
			const end = statementEnd(unit, at);
			if (end === null || end <= at) return refuse('unreadable statement');
			const statement = text(unit, at, end);
			const constant =
				token.value === 'local' &&
				t[at + 1]?.kind === 'identifier' &&
				t[at + 2]?.value === '=' &&
				(t[at + 3].kind === 'string'
					? end === at + 4
					: t.slice(at + 3, end).every((digit) => /^[0-9]$/.test(digit.value)));
			if (constant && phase === 'definitions') {
				if (definitions.has(t[at + 1].value)) return refuse('duplicate constant');
				definitions.add(t[at + 1].value);
				spanEnd = end;
				at = end;
				continue;
			}
			if (phase !== 'header') return refuse('an import follows a definition: ' + statement);
			// The recomposed root reads the root's own copy of this statement, so a
			// name the module never declared would go unseen there and be a nil
			// global here.
			const unknown = headerReads(unit, at, end).find((name) => !known.has(name));
			if (unknown !== undefined)
				return refuse('`' + statement + '` reads ' + unknown + ', which the module never declared');
			for (const name of headerDeclares(unit, at)) known.add(name);
			imports.push({ statement, at, end });
			at = end;
			continue;
		}
		return refuse('unsupported top-level statement at `' + token.value + '`');
	}
	if (!exports.size) return refuse('exports nothing');
	if (spanStart === null) return refuse('defines nothing');
	// The module table is only built and returned here: a definition that reads
	// or writes it would mean something else once recomposed into the root.
	for (let index = spanStart; index < spanEnd; index++)
		if (t[index].kind === 'identifier' && t[index].value === 'M' && t[index - 1]?.value !== '.')
			return refuse('a definition touches the module table');
	for (const name of exports.values())
		if (writesOf(unit, name).length !== 1) return refuse(name + ' is written more than once');
	return {
		ok: true,
		unit,
		imports,
		partBindings,
		exports,
		span: unit.source.slice(t[spanStart].start, t[spanEnd - 1].end)
	};
}

/** Whether the root holds `statement` verbatim as one top-level statement. */
function rootHolds(root, statement) {
	const wanted = scriptTokens(statement, '.lua');
	for (let at = 0; at < root.tokens.length; at++) {
		if (root.depth[at] !== 0 || root.braces[at] !== undefined) continue;
		const end = spells(root, at, statement);
		if (end === null) continue;
		if (['.', ':', '(', '[', '{'].includes(root.tokens[end]?.value)) continue;
		if (['.', ':', '='].includes(root.tokens[at - 1]?.value)) continue;
		if (end - at === wanted.length) return true;
	}
	return false;
}

/**
 * Recomposes the Linux tray root from its part modules.
 * @param {Record<string,string>} sources repository-relative path (under static/ergopti_plus) to text.
 * @returns {{ ok: true, source: string, parts: string[] } | { ok: false, reason: string }}
 */
function composeLinuxMenuRoot(sources) {
	const rootSource = sources?.[LINUX_MENU_ROOT];
	const refuse = (reason) => ({ ok: false, reason });
	const root = lex(rootSource);
	if (!root) return refuse(LINUX_MENU_ROOT + ': unreadable root');
	const t = root.tokens;
	const blocks = [];
	for (let at = 0; at < t.length; at++) {
		if (t[at].kind !== 'string' || !PART_MODULE.test(t[at].value)) continue;
		if (t[at].value === 'ui.menu.menu_builder') {
			// The root's own log source is the one other place its name appears.
			if (spells(root, at - 3, 'local LOG = "ui.menu.menu_builder"') === at + 1) continue;
			return refuse(LINUX_MENU_ROOT + ': the root names itself outside its LOG');
		}
		const binding = partBinding(root, at - 5);
		if (!binding || root.depth[binding.at] !== 0 || root.braces[binding.at] !== undefined)
			return refuse(
				LINUX_MENU_ROOT + ': ' + t[at].value + ' is wired other than `local N = require(...).F`'
			);
		if (expectedField(binding.name, binding.module) !== binding.field)
			return refuse(LINUX_MENU_ROOT + ': ' + binding.name + ' reads a foreign field');
		const writes = writesOf(root, binding.name);
		if (writes.length !== 1 || writes[0] !== binding.at + 1)
			return refuse(LINUX_MENU_ROOT + ': ' + binding.name + ' is bound more than once');
		const last = blocks.at(-1);
		if (last && last.module === binding.module && last.end === binding.at) {
			last.end = binding.end;
			last.bindings.push(binding);
		} else {
			if (blocks.some((block) => block.module === binding.module))
				return refuse(LINUX_MENU_ROOT + ': ' + binding.module + ' is bound in two places');
			blocks.push({
				module: binding.module,
				at: binding.at,
				end: binding.end,
				bindings: [binding]
			});
		}
	}
	const composed = new Set();
	let result = '',
		previous = 0;
	for (const block of blocks) {
		const file = partFile(block.module);
		if (!file) return refuse(block.module + ' is not a part module');
		const part = readPart(file, sources[file]);
		if (!part.ok) return part;
		for (const binding of block.bindings)
			if (part.exports.get(binding.field) !== binding.name)
				return refuse(file + ' does not export ' + binding.field + ' as ' + binding.name);
		for (const { statement } of part.imports)
			if (!rootHolds(root, statement))
				return refuse(file + ': the root does not hold `' + statement + '`');
		for (const binding of part.partBindings) {
			if (!composed.has(binding.module))
				return refuse(file + ': ' + binding.module + ' must be bound in the root first');
			if (!rootHolds(root, binding.text))
				return refuse(file + ': the root does not hold `' + binding.text + '`');
		}
		composed.add(block.module);
		result += rootSource.slice(previous, t[block.at].start) + part.span;
		previous = t[block.end - 1].end;
	}
	result += rootSource.slice(previous);
	return { ok: true, source: result, parts: blocks.map((block) => partFile(block.module)) };
}

/** Root plus every part module it binds, read from `<pluginRoot>/linux/ui/menu`. */
function readLinuxMenuSources(pluginRoot) {
	const read = (file) => fs.readFileSync(path.join(pluginRoot, file), 'utf8');
	const sources = { [LINUX_MENU_ROOT]: read(LINUX_MENU_ROOT) };
	for (const token of scriptTokens(sources[LINUX_MENU_ROOT], '.lua')) {
		const file = token.kind === 'string' ? partFile(token.value) : null;
		if (file && !Object.hasOwn(sources, file)) sources[file] = read(file);
	}
	return sources;
}

/** The recomposed root text; throws with the refusal reason. */
function linuxMenuRootSource(pluginRoot) {
	const composed = composeLinuxMenuRoot(readLinuxMenuSources(pluginRoot));
	if (!composed.ok) throw new Error('Linux menu root refused: ' + composed.reason);
	return composed.source;
}

/**
 * Reads one driver source file; the Linux tray root comes back composed with its parts.
 * Gates that read files by path use it so a moved builder is still read where they look.
 * @param {string} file absolute or relative path of any file
 * @returns {string}
 */
function readSourceFile(file) {
	const resolved = path.resolve(file);
	const suffix = path.sep + path.join(...LINUX_MENU_ROOT.split('/'));
	return resolved.endsWith(suffix)
		? linuxMenuRootSource(resolved.slice(0, -suffix.length))
		: fs.readFileSync(resolved, 'utf8');
}

module.exports = {
	LINUX_MENU_ROOT,
	composeLinuxMenuRoot,
	readLinuxMenuSources,
	linuxMenuRootSource,
	readSourceFile
};
