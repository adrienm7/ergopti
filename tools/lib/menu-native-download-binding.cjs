// tools/lib/menu-native-download-binding.cjs

/** Finite source evidence for the actual retained download renderer chain, never native authority. */
'use strict';
const { scriptTokens } = require('./script-source.cjs');

function lex(source) {
	if (typeof source !== 'string') return null;
	const tokens = scriptTokens(source, '.lua'),
		stack = [],
		depth = [],
		scopes = [],
		closes = new Map();
	let awaitingDo = 0;
	for (let at = 0; at < tokens.length; at++) {
		const token = tokens[at];
		depth[at] = stack.filter((block) => block.word === 'function').length;
		scopes[at] = stack.length;
		if (
			token.kind !== 'identifier' ||
			tokens[at - 1]?.value === '.' ||
			(tokens[at - 1]?.value === ':' && tokens[at - 2]?.value !== ':')
		)
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
	return stack.length ? null : { source, tokens, depth, scopes, closes };
}

function positions(unit, statement, depth) {
	if (!unit) return [];
	const wanted = scriptTokens(statement, '.lua'),
		found = [];
	for (let at = 0; at < unit.tokens.length; at++) {
		if (depth !== undefined && unit.depth[at] !== depth) continue;
		if (depth === 0 && unit.scopes[at] !== 0) continue;
		if (['.', ':'].includes(unit.tokens[at - 1]?.value)) continue;
		if (
			wanted.every((token, offset) => {
				const actual = unit.tokens[at + offset];
				return (
					actual?.kind === token.kind &&
					actual.value === token.value &&
					(token.kind !== 'string' ||
						unit.source.slice(actual.start, actual.end) === statement.slice(token.start, token.end))
				);
			})
		)
			found.push(at);
	}
	return found;
}

function body(unit, name) {
	const signature = `local function ${name}()`;
	const at = positions(unit, signature);
	if (at.length !== 1) return null;
	const functionAt = at[0] + 1,
		end = unit.closes.get(functionAt);
	if (end === undefined) return null;
	const last = at[0] + scriptTokens(signature, '.lua').length - 1;
	return lex(unit.source.slice(unit.tokens[last].end, unit.tokens[end].start));
}

/** Refuses reassignment, shadow declarations, parameter shadowing and member writes. */
function soleBindings(unit, names, count = 1) {
	for (const name of names) {
		const writes = new Set();
		for (let at = 0; at < unit.tokens.length; at++) {
			const token = unit.tokens[at];
			if (token.kind !== 'identifier') continue;
			if (token.value === 'local' || token.value === 'for') {
				let cursor = at + 1;
				if (unit.tokens[cursor]?.value === 'function') cursor++;
				while (unit.tokens[cursor]?.kind === 'identifier') {
					if (unit.tokens[cursor].value === name) writes.add(cursor);
					if (unit.tokens[cursor + 1]?.value !== ',') break;
					cursor += 2;
				}
			}
			if (token.value === 'function') {
				let cursor = at + 1;
				while (cursor < at + 8 && unit.tokens[cursor]?.value !== '(') cursor++;
				if (unit.tokens[cursor]?.value === '(')
					for (cursor++; cursor < unit.tokens.length && unit.tokens[cursor].value !== ')'; cursor++)
						if (unit.tokens[cursor].kind === 'identifier' && unit.tokens[cursor].value === name)
							return false;
			}
			if (token.value !== name || ['.', ':'].includes(unit.tokens[at - 1]?.value)) continue;
			let cursor = at + 1;
			while (unit.tokens[cursor]?.value === ',' && unit.tokens[cursor + 1]?.kind === 'identifier')
				cursor += 2;
			while (cursor < unit.tokens.length) {
				if (
					['.', ':'].includes(unit.tokens[cursor]?.value) &&
					unit.tokens[cursor + 1]?.kind === 'identifier'
				)
					cursor += 2;
				else if (
					unit.tokens[cursor]?.value === '[' &&
					!['fields', 'platform_fields'].includes(name)
				) {
					let brackets = 1;
					for (cursor++; cursor < unit.tokens.length && brackets; cursor++) {
						if (unit.tokens[cursor].value === '[') brackets++;
						if (unit.tokens[cursor].value === ']') brackets--;
					}
					if (brackets) return false;
				} else break;
			}
			if (unit.tokens[cursor]?.value === '=' && unit.tokens[cursor + 1]?.value !== '=')
				writes.add(at);
		}
		if (writes.size !== count) return false;
	}
	return true;
}

/** Only the actual captured factory -> rows -> renderer -> returned object can earn this evidence. */
function retainedNativeDownloadProjection(source, constructorBody = false) {
	const whole = lex(source);
	const unit = constructorBody ? whole : body(whole, 'build_download_item');
	if (!unit) return false;
	const one = (statement) => positions(unit, statement, 0).length === 1;
	const renderer = body(unit, 'renderer_live'),
		declared = body(unit, 'source_live');
	if (
		!renderer ||
		!declared ||
		!soleBindings(unit, [
			'renderer',
			'template_owner',
			'render_owner',
			'root_owner',
			'array_owner',
			'root',
			'source',
			'declaration',
			'fields',
			'platforms',
			'platform_fields',
			'rows',
			'row',
			'action',
			'label',
			'disabled',
			'rendered',
			'item',
			'renderer_live',
			'source_live'
		]) ||
		!soleBindings(unit, ['package', 'rawget', 'getmetatable', 'rawequal', 'type', 'next'], 0)
	)
		return false;
	const statements = [
		'local renderer = rawget(package.loaded, "infra.manifest_menu")',
		'if type(renderer) ~= "table" or getmetatable(renderer) ~= nil then return nil end',
		'local template_owner, render_owner = rawget(renderer, "template_rows"), rawget(renderer, "render_rows")',
		'local root_owner, array_owner = rawget(renderer, "get_root"), rawget(renderer, "get_array")',
		'if type(template_owner) ~= "function" or type(render_owner) ~= "function" or type(root_owner) ~= "function" or type(array_owner) ~= "function" then return nil end',
		'local root = root_owner()',
		'local source = array_owner("llm_download_shortcut_frame")',
		'if not renderer_live() or type(root) ~= "table" or getmetatable(root) ~= nil or type(source) ~= "table" or getmetatable(source) ~= nil or not rawequal(rawget(root, "llm_download_shortcut_frame"), source) or next(source) ~= 1 or next(source, 1) ~= nil then return nil end',
		'local declaration = rawget(source, 1)',
		'if type(declaration) ~= "table" or getmetatable(declaration) ~= nil then return nil end',
		'local fields, platforms, platform_fields = {}, rawget(declaration, "platforms"), {}',
		'if type(platforms) ~= "table" or getmetatable(platforms) ~= nil then return nil end',
		'for field, value in next, declaration do if type(field) ~= "string" or (field ~= "platforms" and type(value) ~= "string" and type(value) ~= "boolean" and type(value) ~= "number") then return nil end fields[field] = value end',
		'for field, value in next, platforms do if type(value) ~= "string" then return nil end platform_fields[field] = value end',
		'local rows = template_owner("llm_download_shortcut_frame", {',
		'if not source_live() or type(rows) ~= "table" or getmetatable(rows) ~= nil or next(rows) ~= 1 or next(rows, 1) ~= nil then return nil end',
		'local row = rawget(rows, 1)',
		'if type(row) ~= "table" or getmetatable(row) ~= nil or type(rawget(row, "action")) ~= "function" or type(rawget(row, "label")) ~= "string" or rawget(row, "label") == "" then return nil end',
		'local action, label, disabled = rawget(row, "action"), rawget(row, "label"), rawget(row, "disabled")',
		'local rendered = render_owner(rows, "llm_download_shortcut_frame")',
		'if not source_live() or type(rendered) ~= "table" or getmetatable(rendered) ~= nil or next(rendered) ~= 1 or next(rendered, 1) ~= nil then return nil end',
		'local item = rawget(rendered, 1)',
		'if type(item) ~= "table" or getmetatable(item) ~= nil or rawget(item, "title") ~= label or not rawequal(rawget(item, "fn"), action) or rawget(item, "disabled") ~= (disabled or nil) then return nil end',
		'for field in next, item do if field ~= "title" and field ~= "fn" and field ~= "disabled" then return nil end end',
		'return item'
	];
	for (const statement of statements) if (!one(statement)) return false;
	const rendererBody =
		'return rawequal(rawget(package.loaded, "infra.manifest_menu"), renderer) and getmetatable(renderer) == nil and rawequal(rawget(renderer, "template_rows"), template_owner) and rawequal(rawget(renderer, "render_rows"), render_owner) and rawequal(rawget(renderer, "get_root"), root_owner) and rawequal(rawget(renderer, "get_array"), array_owner)';
	if (
		JSON.stringify(renderer.tokens.map((t) => [t.kind, t.value])) !==
		JSON.stringify(scriptTokens(rendererBody, '.lua').map((t) => [t.kind, t.value]))
	)
		return false;
	const declarationBody = [
		'if not renderer_live() then return false end',
		'local current_root, current_source = root_owner(), array_owner("llm_download_shortcut_frame")',
		'if not renderer_live() or not rawequal(current_root, root) or not rawequal(current_source, source) or getmetatable(root) ~= nil or getmetatable(source) ~= nil or getmetatable(declaration) ~= nil or not rawequal(rawget(root, "llm_download_shortcut_frame"), source) or not rawequal(rawget(source, 1), declaration) or next(source) ~= 1 or next(source, 1) ~= nil or getmetatable(platforms) ~= nil then return false end',
		'for field, value in next, fields do if not rawequal(rawget(declaration, field), value) then return false end end',
		'for field in next, declaration do if rawget(fields, field) == nil then return false end end',
		'for field, value in next, platform_fields do if rawget(platforms, field) ~= value then return false end end',
		'for field in next, platforms do if rawget(platform_fields, field) == nil then return false end end',
		'return true'
	].join(' ');
	if (
		JSON.stringify(declared.tokens.map((t) => [t.kind, t.value])) !==
		JSON.stringify(scriptTokens(declarationBody, '.lua').map((t) => [t.kind, t.value]))
	)
		return false;
	const ordered = [
		'local renderer = rawget(',
		'local root = root_owner()',
		'local rows = template_owner(',
		'if not source_live() or type(rows)',
		'local action, label, disabled =',
		'local rendered = render_owner(',
		'if not source_live() or type(rendered)',
		'local item = rawget(rendered, 1)',
		'return item'
	];
	let previous = -1;
	for (const statement of ordered) {
		const found = positions(unit, statement, 0);
		if (found.length !== 1 || found[0] <= previous) return false;
		previous = found[0];
	}
	for (let at = 0; at < unit.tokens.length; at++) {
		if (
			unit.tokens[at].kind !== 'identifier' ||
			unit.tokens[at].value !== 'return' ||
			unit.depth[at] !== 0
		)
			continue;
		if (at === previous) continue;
		if (unit.tokens[at + 1]?.value !== 'nil' || unit.tokens[at + 2]?.value !== 'end') return false;
	}
	// A necessary finite receiving grammar: no extra executable statement can replace
	// captured containers or returned native objects between these reviewed operations.
	// Only the delayed callback body is opaque here; the existing typed reader owns it.
	let cursor = 0;
	const accept = (statement) => {
		const wanted = scriptTokens(statement, '.lua');
		if (
			!wanted.every((token, offset) => {
				const actual = unit.tokens[cursor + offset];
				return (
					actual?.kind === token.kind &&
					actual.value === token.value &&
					(token.kind !== 'string' ||
						unit.source.slice(actual.start, actual.end) === statement.slice(token.start, token.end))
				);
			})
		)
			return false;
		cursor += wanted.length;
		return true;
	};
	const receiving = [
		'local is_active = deps.active_tasks and (deps.active_tasks["download"] or deps.active_tasks["download_tail"] or deps.active_tasks["install"])',
		'if not is_active then return nil end',
		'local _dw = package.loaded["ui.download_window"]',
		...statements.slice(0, 5),
		`local function renderer_live() ${rendererBody} end`,
		...statements.slice(5, 14),
		`local function source_live() ${declarationBody} end`,
		null,
		...statements.slice(15)
	];
	for (const statement of receiving) {
		if (statement !== null) {
			if (!accept(statement)) return false;
			continue;
		}
		if (
			!accept(
				'local rows = template_owner("llm_download_shortcut_frame", { ["llm_download_shortcut"] = function()'
			)
		)
			return false;
		const callbackEnd = unit.closes.get(cursor - 3);
		if (callbackEnd === undefined) return false;
		cursor = callbackEnd + 1;
		if (!accept(', }, {}, {})')) return false;
	}
	return (
		cursor === unit.tokens.length &&
		previous + scriptTokens('return item', '.lua').length === unit.tokens.length
	);
}

/** Physical call offset from the same verified constructor, not an executable authority token. */
function retainedNativeDownloadTemplateCallOffset(source) {
	if (!retainedNativeDownloadProjection(source)) return -1;
	const whole = lex(source),
		signature = 'local function build_download_item()';
	const start = positions(whole, signature)[0];
	const bodyStart = whole.tokens[start + scriptTokens(signature, '.lua').length - 1].end;
	const unit = body(whole, 'build_download_item');
	const call = positions(unit, 'local rows = template_owner(', 0)[0] + 3;
	return bodyStart + unit.tokens[call].start;
}

module.exports = { retainedNativeDownloadProjection, retainedNativeDownloadTemplateCallOffset };
