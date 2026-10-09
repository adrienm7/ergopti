// tools/lib/menu-native-root-binding.cjs

'use strict';

const { isDeepStrictEqual } = require('node:util');
const { scriptTokens } = require('./script-source.cjs');
const { nativeTemplateBinding } = require('./menu-template-binding.cjs');
const { nativeTopLevelProjection } = require('./menu-native-llm-parent-binding.cjs');

/** A finite physical Lua route check, not runtime authority or general data-flow analysis. */
function nativeBadgeRootComposition(sources, manifest, platform) {
	if (platform !== 'hs') return false;
	const declaration = {
		llm_download_shortcut_frame: [
			{
				type: 'command',
				id: 'llm_download_shortcut',
				i18n: 'menu.llm.show_download_window',
				platforms: ['hs'],
				unavailable: 'hide'
			}
		],
		macos_canvas_badge_root: [
			{
				type: 'native_content',
				id: 'badge',
				kind: 'image',
				platforms: ['hs'],
				unavailable: 'hide'
			},
			{
				type: 'native_content',
				id: 'boundary',
				kind: 'boundary',
				platforms: ['hs'],
				unavailable: 'hide'
			},
			{
				type: 'native_content',
				id: 'body',
				kind: 'rows',
				target: true,
				platforms: ['hs'],
				unavailable: 'hide'
			}
		],
		macos_download_root: [
			{
				type: 'native_content',
				id: 'download',
				kind: 'command',
				platforms: ['hs'],
				unavailable: 'hide'
			},
			{ type: '---', after: 'download', platforms: ['hs'], unavailable: 'hide' },
			{
				type: 'native_content',
				id: 'body',
				kind: 'rows',
				target: true,
				platforms: ['hs'],
				unavailable: 'hide'
			}
		],
		macos_canvas_badge_frame: [
			{
				type: 'include',
				section: 'macos_canvas_badge_paused',
				present_when: 'macos_badge_is_paused'
			},
			{
				type: 'include',
				section: 'macos_canvas_badge_active',
				present_when: 'macos_badge_is_active'
			},
			{ type: '---', platforms: ['hs'], unavailable: 'hide' }
		],
		macos_canvas_badge_paused: [
			{
				type: 'label',
				id: 'macos_badge_paused_caption',
				i18n: 'menu.builder.title_paused',
				platforms: ['hs'],
				unavailable: 'hide'
			}
		],
		macos_canvas_badge_active: [
			{
				type: 'label',
				id: 'macos_badge_active_caption',
				i18n: 'menu.builder.title',
				platforms: ['hs'],
				unavailable: 'hide'
			}
		]
	};
	if (!manifest || !Array.isArray(manifest.top_level) || manifest.top_level.length === 0)
		return false;
	if (!Object.entries(declaration).every(([key, rows]) => isDeepStrictEqual(manifest[key], rows)))
		return false;
	const init = sources?.['macos/ui/menu/init.lua'];
	const builder = sources?.['macos/ui/menu/builder.lua'];
	const badge = sources?.['macos/ui/menu/canvas_badge.lua'];
	const llm = sources?.['macos/ui/menu/menu_llm/init.lua'];
	if (
		![init, builder, badge, llm].every((source) => typeof source === 'string' && source.length > 0)
	)
		return false;

	function lex(source) {
		const tokens = scriptTokens(source, '.lua');
		const stack = [],
			depth = [],
			scopes = [],
			tables = [],
			tableStack = [],
			closes = new Map();
		let awaitingDo = 0;
		for (let index = 0; index < tokens.length; index++) {
			const token = tokens[index];
			depth[index] = stack.filter((block) => block.word === 'function').length;
			scopes[index] = stack.length;
			tables[index] = tableStack.at(-1);
			if (token.kind === 'symbol' && token.value === '{') tableStack.push(depth[index]);
			if (token.kind === 'symbol' && token.value === '}') tableStack.pop();
			if (token.kind !== 'identifier') continue;
			// A closing Lua label (::continue::) does not qualify the next keyword.
			if (
				tokens[index - 1]?.value === '.' ||
				(tokens[index - 1]?.value === ':' && tokens[index - 2]?.value !== ':')
			)
				continue;
			if (['function', 'if', 'for', 'while', 'repeat'].includes(token.value)) {
				stack.push({ word: token.value, index });
				if (['for', 'while'].includes(token.value)) awaitingDo++;
			} else if (token.value === 'do') {
				if (awaitingDo) awaitingDo--;
				else stack.push({ word: 'do', index });
			} else if (token.value === 'end' || token.value === 'until') {
				const block = stack.pop();
				if (!block || (token.value === 'until') !== (block.word === 'repeat')) return null;
				closes.set(block.index, index);
			}
		}
		return stack.length || tableStack.length
			? null
			: { source, tokens, depth, scopes, tables, closes };
	}
	function matches(unit, statement, functionDepth) {
		if (!unit) return [];
		const wanted = scriptTokens(statement, '.lua');
		const result = [];
		for (let start = 0; start < unit.tokens.length; start++) {
			if (functionDepth !== undefined && unit.depth[start] !== functionDepth) continue;
			if (['.', ':'].includes(unit.tokens[start - 1]?.value)) continue;
			if (
				wanted.every((token, offset) => {
					const actual = unit.tokens[start + offset];
					return (
						actual?.kind === token.kind &&
						actual.value === token.value &&
						(token.kind !== 'string' ||
							unit.source.slice(actual.start, actual.end) ===
								statement.slice(token.start, token.end))
					);
				})
			)
				result.push(start);
		}
		return result;
	}
	function body(source, signature) {
		const unit = lex(source),
			starts = matches(unit, signature);
		if (starts.length !== 1) return null;
		const start = starts[0],
			length = scriptTokens(signature, '.lua').length;
		if (unit.scopes[start] !== 0) return null;
		const functionAt = unit.tokens.findIndex(
			(token, index) => index >= start && index < start + length && token.value === 'function'
		);
		const end = unit.closes.get(functionAt);
		if (end === undefined) return null;
		let parameterEnd = functionAt + 1;
		while (parameterEnd < end && unit.tokens[parameterEnd].value !== '(') parameterEnd++;
		const parameterStart = parameterEnd;
		let parentheses = 1;
		for (parameterEnd++; parameterEnd < end && parentheses; parameterEnd++) {
			if (unit.tokens[parameterEnd].value === '(') parentheses++;
			if (unit.tokens[parameterEnd].value === ')') parentheses--;
		}
		if (parentheses) return null;
		const result = lex(source.slice(unit.tokens[parameterEnd - 1].end, unit.tokens[end].start));
		if (!result) return null;
		result.params = unit.tokens
			.slice(parameterStart + 1, parameterEnd - 1)
			.filter((token) => token.kind === 'identifier')
			.map((token) => token.value);
		return result;
	}
	function unique(unit, statement) {
		return matches(unit, statement, 0).length === 1;
	}
	function writes(unit, name) {
		if (!unit) return [];
		const found = new Set();
		for (let index = 0; index < unit.tokens.length; index++) {
			const token = unit.tokens[index];
			if (token.kind !== 'identifier') continue;
			if (['local', 'for'].includes(token.value)) {
				let at = index + 1;
				if (unit.tokens[at]?.value === 'function') at++;
				while (unit.tokens[at]?.kind === 'identifier') {
					if (unit.tokens[at].value === name) found.add(at);
					if (unit.tokens[at + 1]?.value !== ',') break;
					at += 2;
				}
			}
			if (token.value === 'function') {
				let at = index + 1;
				while (at < index + 7 && at < unit.tokens.length && unit.tokens[at].value !== '(') at++;
				if (unit.tokens[at]?.value === '(')
					for (at++; at < unit.tokens.length && unit.tokens[at].value !== ')'; at++)
						if (unit.tokens[at].kind === 'identifier' && unit.tokens[at].value === name)
							found.add(at);
			}
			if (token.value !== name || ['.', ':'].includes(unit.tokens[index - 1]?.value)) continue;
			if (
				unit.tables[index] === unit.depth[index] &&
				['{', ','].includes(unit.tokens[index - 1]?.value) &&
				unit.tokens[index + 1]?.value === '='
			)
				continue;
			let at = index + 1;
			while (at < unit.tokens.length) {
				if (
					['.', ':'].includes(unit.tokens[at]?.value) &&
					unit.tokens[at + 1]?.kind === 'identifier'
				)
					at += 2;
				else if (unit.tokens[at]?.value === '[') {
					let count = 1;
					for (at++; at < unit.tokens.length && count; at++) {
						if (unit.tokens[at].value === '[') count++;
						if (unit.tokens[at].value === ']') count--;
					}
					if (count) break;
				} else break;
			}
			// The first name in a reassignment list is still an overwritten binding.
			while (
				unit.tables[index] !== unit.depth[index] &&
				unit.tokens[at]?.value === ',' &&
				unit.tokens[at + 1]?.kind === 'identifier'
			) {
				at += 2;
				while (
					['.', ':'].includes(unit.tokens[at]?.value) &&
					unit.tokens[at + 1]?.kind === 'identifier'
				)
					at += 2;
			}
			if (unit.tokens[at]?.value === '=' && unit.tokens[at + 1]?.value !== '=') found.add(index);
		}
		return [...found];
	}
	function imported(source, name, module, owner) {
		const unit = lex(source);
		const imports = matches(unit, `local ${name} = require("${module}")`, 0).filter(
			(at) => unit.scopes[at] === 0
		);
		const assignments = writes(unit, name).filter((at) => unit.depth[at] === 0);
		return (
			imports.length === 1 &&
			assignments.length === 1 &&
			assignments[0] === imports[0] + 1 &&
			writes(owner, name).length === 0 &&
			!owner.params?.includes(name)
		);
	}
	function bindingWrites(unit, name) {
		if (!unit) return [];
		function scopeEnd(at) {
			const ends = [...unit.closes]
				.filter(([start, end]) => start < at && at < end)
				.map(([, end]) => end);
			return ends.length ? Math.min(...ends) : unit.tokens.length;
		}
		function innerBinding(at) {
			for (let start = 0; start <= at; start++) {
				const token = unit.tokens[start];
				if (token.kind !== 'identifier') continue;
				if (token.value === 'local' && unit.depth[start] > 0 && scopeEnd(start) > at) {
					let nameAt = start + 1;
					if (unit.tokens[nameAt]?.value === 'function') nameAt++;
					while (unit.tokens[nameAt]?.kind === 'identifier') {
						if (unit.tokens[nameAt].value === name && nameAt <= at) return true;
						if (unit.tokens[nameAt + 1]?.value !== ',') break;
						nameAt += 2;
					}
				}
				if (token.value === 'function' && unit.closes.get(start) > at) {
					let paramAt = start + 1;
					while (
						paramAt < start + 7 &&
						paramAt < unit.tokens.length &&
						unit.tokens[paramAt].value !== '('
					)
						paramAt++;
					if (unit.tokens[paramAt]?.value !== '(') continue;
					for (
						paramAt++;
						paramAt <= at && paramAt < unit.tokens.length && unit.tokens[paramAt].value !== ')';
						paramAt++
					)
						if (unit.tokens[paramAt].kind === 'identifier' && unit.tokens[paramAt].value === name)
							return true;
				}
			}
			return false;
		}
		// Child functions may use an unrelated local of the same name. Captured
		// writes to the outer binding still refuse, even in an uncalled child.
		return writes(unit, name).filter((at) => !innerBinding(at));
	}
	function soleBinding(unit, name, statement) {
		const starts = matches(unit, statement, 0),
			assignments = bindingWrites(unit, name);
		const offset = scriptTokens(statement, '.lua').findIndex(
			(token) => token.kind === 'identifier' && token.value === name
		);
		return (
			offset >= 0 &&
			starts.length === 1 &&
			assignments.length === 1 &&
			assignments[0] === starts[0] + offset
		);
	}
	function soleLocal(unit, name, statement) {
		return soleBinding(unit, name, statement);
	}
	const start = body(init, 'function M.start(');
	if (
		!start ||
		!unique(lex(init), 'local M = {}') ||
		!unique(lex(init), 'return M') ||
		matches(lex(init), 'M.start =').length ||
		matches(lex(init), 'M["start"] =').length ||
		matches(lex(init), "M['start'] =").length ||
		!unique(start, 'ctx.rebuild_menu_cache = rebuild_menu_cache')
	)
		return false;
	const rebuild = body(start.source, 'local function rebuild_menu_cache()');
	const generate = body(builder, 'function M.generate(ctx, menu_mods, actions)');
	const prepend = body(badge, 'function M.prepend_to(items, ctx, on_click)');
	const publish = body(start.source, 'push_static_menu = function(items)');
	const loadRoot = body(builder, 'local function load_manifest()');
	const loadTop = body(builder, 'local function load_top_level()');
	if (
		!rebuild ||
		!generate ||
		!prepend ||
		!publish ||
		!loadRoot ||
		!loadTop ||
		!soleLocal(lex(builder), 'load_manifest', 'local function load_manifest()') ||
		!soleLocal(lex(builder), 'load_top_level', 'local function load_top_level()') ||
		writes(generate, 'load_top_level').length ||
		writes(loadTop, 'load_manifest').length
	)
		return false;
	if (
		!imported(init, 'Builder', 'ui.menu.builder', start) ||
		!imported(init, 'TrayMenu', 'adapters.tray_menu', publish) ||
		!imported(init, 'TrayMenu', 'adapters.tray_menu', start) ||
		!imported(builder, 'CanvasBadge', 'ui.menu.canvas_badge', generate) ||
		!imported(builder, 'ManifestMenu', 'infra.manifest_menu', generate) ||
		!imported(badge, 'ManifestMenu', 'infra.manifest_menu', prepend) ||
		!imported(builder, 'ManifestMenu', 'infra.manifest_menu', loadRoot)
	)
		return false;
	if (
		!unique(loadRoot, 'return ManifestMenu.get_root()') ||
		!soleLocal(loadTop, 'data', 'local data = load_manifest()') ||
		!soleLocal(loadTop, 'result', 'local result = {}') ||
		!nativeTopLevelProjection(loadTop, lex) ||
		writes(loadTop, '_top_level_cache').length !== 1 ||
		writes(loadTop, '_top_level_cache')[0] !==
			matches(loadTop, '_top_level_cache = result', 0)[0] ||
		!unique(loadTop, 'for _, entry in ipairs(data.top_level) do') ||
		!unique(loadTop, 'if _top_level_cache then return _top_level_cache end') ||
		!unique(loadTop, '_top_level_cache = result return _top_level_cache') ||
		!soleLocal(generate, 'items', 'local items = {}') ||
		!unique(generate, 'table.insert(items, row)')
	)
		return false;
	for (const source of [builder, badge]) {
		const unit = lex(source);
		if (!soleLocal(unit, 'M', 'local M = {}') || !unique(unit, 'return M')) return false;
	}
	if (
		!soleLocal(publish, 'candidate', 'local candidate = items or _cached_menu_items') ||
		writes(publish, 'items').length ||
		!unique(publish, 'return TrayMenu.setMenu(candidate) == true')
	)
		return false;
	if (
		!soleBinding(
			rebuild,
			'items',
			'local ok_b, items = pcall(Builder.generate, ctx, menu_mods, actions)'
		) ||
		!soleBinding(
			rebuild,
			'ok_b',
			'local ok_b, items = pcall(Builder.generate, ctx, menu_mods, actions)'
		) ||
		!unique(rebuild, 'if ok_b and type(items) == "table" then') ||
		!unique(rebuild, 'push_static_menu(items)') ||
		!unique(rebuild, '_cached_menu_items = items')
	)
		return false;
	if (
		!unique(generate, 'for _, entry in ipairs(load_top_level()) do') ||
		!soleLocal(
			generate,
			'rendered',
			'local rendered = ManifestMenu.render_rows(items, "top_level")'
		) ||
		!unique(generate, 'pcall(CanvasBadge.prepend_to, rendered, ctx, function()') ||
		!unique(generate, 'return rendered')
	)
		return false;
	if (
		!soleLocal(lex(badge), 'hs', 'local hs = hs') ||
		writes(prepend, 'hs').length ||
		writes(prepend, 'items').length ||
		writes(prepend, 'on_click').length ||
		!soleLocal(prepend, 'paused', 'local paused = ctx and ctx.paused') ||
		!soleLocal(prepend, 'canvas_obj', 'local canvas_obj = hs.canvas.new({') ||
		!unique(
			prepend,
			'canvas_obj:appendElements(rect_elem, { type = "text", text = display_text,'
		) ||
		!soleLocal(
			prepend,
			'frame',
			'local frame = ManifestMenu.template_rows("macos_canvas_badge_frame", {}, {'
		) ||
		!soleLocal(prepend, 'display_text', 'local display_text = frame[1].label') ||
		!unique(
			prepend,
			'if type(frame) ~= "table" or #frame ~= 2 or type(frame[1].label) ~= "string" or frame[1].label == "" or frame[2].separator ~= true then'
		) ||
		!unique(
			prepend,
			'Logger.error(LOG, "Declared canvas badge presentation refused.") return false'
		) ||
		!soleLocal(
			prepend,
			'compose',
			'local compose = ManifestMenu.native_composition("macos_canvas_badge_root")'
		) ||
		!unique(
			prepend,
			'if type(compose) ~= "function" then Logger.error(LOG, "Declared canvas badge root composition refused.") return false end'
		) ||
		!unique(prepend, 'text = display_text') ||
		!soleLocal(prepend, 'img', 'local img = canvas_obj:imageFromCanvas()') ||
		!unique(prepend, 'canvas_obj:delete()') ||
		!soleLocal(prepend, 'badge', 'local badge = { title = "", image = img, fn = on_click, }') ||
		!soleLocal(prepend, 'boundary', 'local boundary = { title = frame[2].separator and "-" }') ||
		!unique(
			prepend,
			'if compose({ badge = { badge }, boundary = { boundary }, body = items }) ~= true then'
		) ||
		!soleLocal(
			generate,
			'compose_download',
			'local compose_download = ManifestMenu.native_composition("macos_download_root")'
		) ||
		!unique(
			generate,
			'if type(compose_download) ~= "function" or compose_download({ download = _dl_item and { _dl_item } or {}, body = rendered }) ~= true then'
		) ||
		!unique(generate, 'local _dl_item = nil') ||
		!unique(
			generate,
			'if type(ctx.llm_handler) == "table" and type(ctx.llm_handler.build_download_item) == "function" then'
		) ||
		!unique(generate, 'local ok_dl, dl_result = pcall(ctx.llm_handler.build_download_item)') ||
		!unique(generate, 'if ok_dl then _dl_item = dl_result') ||
		!unique(
			generate,
			'Logger.error(LOG, string.format("Error building LLM download item: %s.", tostring(dl_result)))'
		)
	)
		return false;
	for (const [key, expression] of [
		['macos_badge_is_paused', 'not not paused'],
		['macos_badge_is_active', 'not paused']
	]) {
		if (
			!unique(prepend, `["${key}"] = function() return ${expression} end`) ||
			!nativeTemplateBinding(
				prepend.source,
				'.lua',
				'macos_canvas_badge_frame',
				key,
				2,
				[{ src: prepend.source }],
				manifest,
				platform
			)
		)
			return false;
	}
	// The optional completed download is the actual exported native producer's result.
	const safeRequire = body(init, 'local function safe_require(module_id, label)');
	const create = body(llm, 'function M.create(deps)');
	const createMenu = body(llm, 'local function create_menu(deps)');
	const download = createMenu && body(createMenu.source, 'local function build_download_item()');
	if (
		!safeRequire ||
		!create ||
		!createMenu ||
		!download ||
		!soleBinding(safeRequire, 'mod_or_err', 'local ok, mod_or_err = pcall(require, module_id)') ||
		!unique(safeRequire, 'return mod_or_err') ||
		!unique(lex(init), 'llm = safe_require("ui.menu.menu_llm", "AI menu")') ||
		!soleBinding(start, 'res', 'local ok_h, res = pcall(menu_mods.llm.create, {') ||
		!unique(start, 'if ok_h then llm_handler = res') ||
		!unique(start, 'llm_handler = llm_handler,') ||
		matches(start, 'ctx.llm_handler =').length ||
		writes(start, 'llm_handler').length !== 2 ||
		!soleBinding(
			create,
			'result',
			'local ok, result = xpcall(create_menu, debug.traceback, deps)'
		) ||
		!unique(create, 'return type(result) == "table" and result or {}') ||
		!soleLocal(lex(llm), 'create_menu', 'local function create_menu(deps)') ||
		!unique(createMenu, 'build_download_item = build_download_item,') ||
		!imported(llm, 'ManifestMenu', 'infra.manifest_menu', download) ||
		!soleLocal(
			download,
			'rows',
			'local rows = ManifestMenu.template_rows("llm_download_shortcut_frame", {'
		) ||
		!unique(
			download,
			'if type(rows) ~= "table" or #rows ~= 1 or type(rows[1].action) ~= "function" then return nil end'
		) ||
		!soleLocal(download, 'row', 'local row = rows[1]') ||
		!unique(download, 'return { title = row.label, fn = row.action }') ||
		!soleBinding(
			generate,
			'dl_result',
			'local ok_dl, dl_result = pcall(ctx.llm_handler.build_download_item)'
		) ||
		!soleBinding(
			generate,
			'ok_dl',
			'local ok_dl, dl_result = pcall(ctx.llm_handler.build_download_item)'
		) ||
		writes(generate, '_dl_item').length !== 2
	)
		return false;

	// Ordering is part of this physical route: admission precedes native work;
	// capture precedes deletion, which precedes publication into the returned list.
	const position = (unit, statement) => matches(unit, statement, 0)[0];
	return (
		position(prepend, 'return false') < position(prepend, 'local display_text = frame[1].label') &&
		position(prepend, 'local display_text = frame[1].label') <
			position(prepend, 'for _, item in ipairs(items) do') &&
		position(prepend, 'for _, item in ipairs(items) do') <
			position(prepend, 'local canvas_obj = hs.canvas.new({') &&
		position(prepend, 'local canvas_obj = hs.canvas.new({') <
			position(prepend, 'canvas_obj:appendElements(') &&
		position(prepend, 'canvas_obj:appendElements(') <
			position(prepend, 'local img = canvas_obj:imageFromCanvas()') &&
		position(prepend, 'local img = canvas_obj:imageFromCanvas()') <
			position(prepend, 'canvas_obj:delete()') &&
		position(prepend, 'local compose = ManifestMenu.native_composition(') <
			position(prepend, 'local canvas_obj = hs.canvas.new({') &&
		position(prepend, 'canvas_obj:delete()') < position(prepend, 'local badge = {') &&
		position(prepend, 'local badge = {') < position(prepend, 'local boundary = {') &&
		position(prepend, 'local boundary = {') <
			position(
				prepend,
				'if compose({ badge = { badge }, boundary = { boundary }, body = items }) ~= true then'
			) &&
		position(generate, 'local rendered = ManifestMenu.render_rows(items, "top_level")') <
			position(generate, 'local compose_download = ManifestMenu.native_composition(') &&
		position(generate, 'local compose_download = ManifestMenu.native_composition(') <
			position(generate, 'pcall(CanvasBadge.prepend_to, rendered, ctx, function()') &&
		position(generate, 'local rendered = ManifestMenu.render_rows(items, "top_level")') <
			position(generate, 'pcall(CanvasBadge.prepend_to, rendered, ctx, function()') &&
		position(generate, 'pcall(CanvasBadge.prepend_to, rendered, ctx, function()') <
			position(generate, 'return rendered')
	);
}

module.exports = { nativeBadgeRootComposition };
