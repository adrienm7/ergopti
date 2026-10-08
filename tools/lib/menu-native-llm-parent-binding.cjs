// A finite source obligation for the actual macOS completed outer IA parent.
// This is necessary source evidence, not proof of physical native execution.
'use strict';
const { scriptTokens } = require('./script-source.cjs');
const { isDeepStrictEqual } = require('node:util');

function nativeLlmParentPublication(source, builderSource, definition, topLevel, platform) {
	if (platform !== 'hs' || typeof source !== 'string' || typeof builderSource !== 'string') return false;
	if (!isDeepStrictEqual(definition, [{ type: 'group', id: 'llm_parent_content',
		i18n: 'menu.llm.title', checked_when: ['llm_parent_enabled'], platforms: ['hs'], unavailable: 'hide' }])) return false;
	if (!Array.isArray(topLevel) || topLevel.filter((row) => row.id === 'llm' &&
		(!row.platforms || row.platforms.includes('hs'))).length !== 1) return false;
	const lex = (text) => {
		const tokens = scriptTokens(text, '.lua'), scopes = [], stack = [], closes = new Map();
		let awaitingDo = 0;
		for (let at = 0; at < tokens.length; at++) {
			const token = tokens[at]; scopes[at] = stack.length;
			// A closing Lua label is followed by structural code, not a method name.
			// Actual Builder.load_top_level ends its native loop after ::continue::.
			const afterLabel = tokens[at - 1]?.value === ':' && tokens[at - 2]?.value === ':' &&
				tokens[at - 3]?.kind === 'identifier' && tokens[at - 4]?.value === ':' && tokens[at - 5]?.value === ':';
			if (token.kind !== 'identifier' || (['.', ':'].includes(tokens[at - 1]?.value) && !afterLabel)) continue;
			if (['function', 'if', 'for', 'while', 'repeat'].includes(token.value)) {
				stack.push({ word: token.value, at });
				if (['for', 'while'].includes(token.value)) awaitingDo++;
			} else if (token.value === 'do') {
				if (awaitingDo) awaitingDo--; else stack.push({ word: 'do', at });
			} else if (['end', 'until'].includes(token.value)) {
				const block = stack.pop();
				if (!block || (token.value === 'until') !== (block.word === 'repeat')) return null;
				closes.set(block.at, at);
			}
		}
		return stack.length ? null : { text, tokens, scopes, closes };
	};
	const positions = (unit, statement) => {
		if (!unit) return [];
		const wanted = scriptTokens(statement, '.lua'), found = [];
		for (let at = 0; at < unit.tokens.length; at++) {
			if (['.', ':'].includes(unit.tokens[at - 1]?.value)) continue;
			if (wanted.every((token, offset) => {
				const actual = unit.tokens[at + offset];
				return actual?.kind === token.kind && actual.value === token.value &&
					(token.kind !== 'string' || unit.text.slice(actual.start, actual.end) === statement.slice(token.start, token.end));
			})) found.push(at);
		}
		return found;
	};
	const rootPositions = (unit, text) => positions(unit, text).filter((at) => unit.scopes[at] === 0);
	const body = (unit, signature) => {
		const found = rootPositions(unit, signature), count = scriptTokens(signature, '.lua').length;
		if (found.length !== 1) return null;
		const start = found[0], functionAt = unit.tokens.findIndex((token, at) =>
			at >= start && at < start + count && token.value === 'function');
		const end = unit.closes.get(functionAt);
		if (end === undefined) return null;
		return lex(unit.text.slice(unit.tokens[start + count - 1].end, unit.tokens[end].start));
	};
	const one = (unit, text) => positions(unit, text).length === 1;
	const whole = lex(source), builder = lex(builderSource);
	if (!whole || !builder || rootPositions(builder, 'local ManifestMenu = require("infra.manifest_menu")').length !== 1 ||
		rootPositions(builder, 'ManifestMenu =').length !== 1 || rootPositions(whole, 'local ManifestMenu = require("infra.manifest_menu")').length !== 1 ||
		rootPositions(whole, 'ManifestMenu =').length !== 1 || positions(whole, 'local require').length ||
		positions(whole, 'require =').length) return false;
	const create = body(whole, 'local function create_menu(deps)'), actualCreate = body(whole, 'function M.create(deps)');
	const build = body(create, 'local function build_item()');
	if (!create || !actualCreate || !build || !one(create, 'local state = deps.state') ||
		positions(create, 'local function build_item').length !== 1 || positions(create, 'build_item =').length !== 1 ||
		!one(create, 'build_item = build_item,') || !one(actualCreate, 'local ok, result = xpcall(create_menu, debug.traceback, deps)') ||
		rootPositions(build, 'local ManifestMenu').length || rootPositions(build, 'ManifestMenu =').length ||
		rootPositions(build, 'local main_menu = {}').length !== 1 || positions(build, 'main_menu =').length !== 2) return false;
	const child = 'main_menu = ManifestMenu.build("llm_menu", "LLM", handlers, group_builders, render_ctx, list_providers) or {}';
	const parent = 'return ManifestMenu.group_row("llm_native_parent", "llm_parent_content", main_menu, { llm_parent_enabled = function() return state.llm_enabled or nil end, })';
	const childAt = positions(build, child), parentAt = rootPositions(build, parent);
	if (childAt.length !== 1 || parentAt.length !== 1 || childAt[0] >= parentAt[0] ||
		!one(build, 'local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")') ||
		!one(build, 'if ok_mm and type(ManifestMenu.build) == "function" then') ||
		positions(build, 'ManifestMenu.group_row').length !== 1 || positions(build, 'llm_parent_enabled =').length !== 1 ||
		!one(build, 'llm_toggle = toggle_action,') || !one(build, 'llm_enabled = function() return state.llm_enabled == true end,')) return false;
	// Completed parent publication is the actual build_item terminal expression.
	const parentTokens = scriptTokens(parent, '.lua');
	if (parentAt[0] + parentTokens.length !== build.tokens.length) return false;
	const loadManifest = body(builder, 'local function load_manifest()');
	const loadTop = body(builder, 'local function load_top_level()');
	const rootRead = lex('return ManifestMenu.get_root()');
	if (!loadManifest || !loadTop || !rootRead ||
		!isDeepStrictEqual(loadManifest.tokens.map((token) => [token.kind, token.value]),
			rootRead.tokens.map((token) => [token.kind, token.value])) ||
		positions(builder, 'load_manifest =').length || positions(builder, 'load_top_level =').length ||
		positions(builder, 'local require').length || positions(builder, 'require =').length ||
		rootPositions(loadTop, 'local data = load_manifest()').length !== 1 || positions(loadTop, 'data =').length !== 1 ||
		rootPositions(loadTop, 'for _, entry in ipairs(data.top_level) do').length !== 1 ||
		!one(loadTop, '::continue::') ||
		!one(loadTop, 'table.insert(result, { id = entry.id, greyed_when_paused = entry.greyed_when_paused == true })')) return false;
	const generate = body(builder, 'function M.generate(ctx, menu_mods, actions)');
	const llmRoute = body(generate, '["llm"] = function()');
	if (!generate || rootPositions(generate, 'local ManifestMenu').length || rootPositions(generate, 'ManifestMenu =').length) return false;
	if (!generate || !llmRoute || !one(llmRoute, 'local ok_b, llm_item = pcall(ctx.llm_handler.build_item)') ||
		!one(llmRoute, 'return llm_item and { llm_item } or {}') ||
		!one(generate, 'for _, entry in ipairs(load_top_level()) do') ||
		!one(generate, 'for _, row in ipairs(builders[id]() or {}) do') ||
		!one(generate, 'table.insert(items, row)') ||
		!one(generate, 'local rendered = ManifestMenu.render_rows(items, "top_level")') ||
		rootPositions(generate, 'return rendered').length !== 1) return false;
	return true;
}
module.exports = { nativeLlmParentPublication };
