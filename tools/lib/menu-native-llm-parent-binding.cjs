// A finite source obligation for the actual macOS completed outer IA parent.
// This is necessary source evidence, not proof of physical native execution.
'use strict';
const { scriptTokens } = require('./script-source.cjs');
const { isDeepStrictEqual } = require('node:util');

function nativeLlmParentPublication(source, builderSource, definition, topLevel, platform) {
	if (platform !== 'hs' || typeof source !== 'string' || typeof builderSource !== 'string')
		return false;
	const hsParent = {
		type: 'group',
		id: 'llm_parent_content',
		i18n: 'menu.llm.title',
		checked_when: ['llm_parent_enabled'],
		platforms: ['hs'],
		unavailable: 'hide'
	};
	if (!isDeepStrictEqual(definition, [hsParent])) return false;
	if (
		!Array.isArray(topLevel) ||
		topLevel.filter((row) => row.id === 'llm' && (!row.platforms || row.platforms.includes('hs')))
			.length !== 1
	)
		return false;
	const { lex, positions, rootPositions, body, one } = luaPublicationParser();
	const whole = lex(source),
		builder = lex(builderSource);
	if (
		!whole ||
		!builder ||
		rootPositions(builder, 'local ManifestMenu = require("infra.manifest_menu")').length !== 1 ||
		rootPositions(builder, 'ManifestMenu =').length !== 1 ||
		rootPositions(whole, 'local ManifestMenu = require("infra.manifest_menu")').length !== 1 ||
		rootPositions(whole, 'ManifestMenu =').length !== 1 ||
		positions(whole, 'local require').length ||
		positions(whole, 'require =').length
	)
		return false;
	const create = body(whole, 'local function create_menu(deps)'),
		actualCreate = body(whole, 'function M.create(deps)');
	const build = body(create, 'local function build_item()');
	if (
		!create ||
		!actualCreate ||
		!build ||
		!one(create, 'local state = deps.state') ||
		positions(create, 'local function build_item').length !== 1 ||
		positions(create, 'build_item =').length !== 1 ||
		!one(create, 'build_item = build_item,') ||
		!one(actualCreate, 'local ok, result = xpcall(create_menu, debug.traceback, deps)') ||
		rootPositions(build, 'local ManifestMenu').length ||
		rootPositions(build, 'ManifestMenu =').length ||
		rootPositions(build, 'local main_menu = {}').length !== 1 ||
		positions(build, 'main_menu =').length !== 2
	)
		return false;
	const child =
		'main_menu = ManifestMenu.build("llm_menu", "LLM", handlers, group_builders, render_ctx, list_providers) or {}';
	const parent =
		'return ManifestMenu.group_row("llm_native_parent", "llm_parent_content", main_menu, { llm_parent_enabled = function() return state.llm_enabled or nil end, })';
	const childAt = positions(build, child),
		parentAt = rootPositions(build, parent);
	if (
		childAt.length !== 1 ||
		parentAt.length !== 1 ||
		childAt[0] >= parentAt[0] ||
		!one(build, 'local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")') ||
		!one(build, 'if ok_mm and type(ManifestMenu.build) == "function" then') ||
		positions(build, 'ManifestMenu.group_row').length !== 1 ||
		positions(build, 'llm_parent_enabled =').length !== 1 ||
		!one(build, 'llm_toggle = toggle_action,') ||
		!one(build, 'llm_enabled = function() return state.llm_enabled == true end,')
	)
		return false;
	// Completed parent publication is the actual build_item terminal expression.
	const parentTokens = scriptTokens(parent, '.lua');
	if (parentAt[0] + parentTokens.length !== build.tokens.length) return false;
	const loadManifest = body(builder, 'local function load_manifest()');
	const loadTop = body(builder, 'local function load_top_level()');
	const rootRead = lex('return ManifestMenu.get_root()');
	if (
		!loadManifest ||
		!loadTop ||
		!rootRead ||
		!isDeepStrictEqual(
			loadManifest.tokens.map((token) => [token.kind, token.value]),
			rootRead.tokens.map((token) => [token.kind, token.value])
		) ||
		positions(builder, 'load_manifest =').length ||
		positions(builder, 'load_top_level =').length ||
		positions(builder, 'local require').length ||
		positions(builder, 'require =').length ||
		!(
			(rootPositions(loadTop, 'local data = load_manifest()').length === 1 &&
				positions(loadTop, 'data =').length === 1 &&
				rootPositions(loadTop, 'for _, entry in ipairs(data.top_level) do').length === 1) ||
			(rootPositions(loadTop, 'local receive, declared = separator_factory()').length === 1 &&
				positions(loadTop, 'declared =').length === 1 &&
				rootPositions(loadTop, 'for _, entry in ipairs(declared) do').length === 1 &&
				declaredFacadeOwner(builder, { lex, positions, rootPositions, body }))
		) ||
		!one(loadTop, '::continue::') ||
		!nativeTopLevelProjection(loadTop, lex)
	)
		return false;
	const generate = body(builder, 'function M.generate(ctx, menu_mods, actions)');
	const llmRoute = body(generate, '["llm"] = function()');
	if (
		!generate ||
		rootPositions(generate, 'local ManifestMenu').length ||
		rootPositions(generate, 'ManifestMenu =').length
	)
		return false;
	if (
		!generate ||
		!llmRoute ||
		!one(llmRoute, 'local ok_b, llm_item = pcall(ctx.llm_handler.build_item)') ||
		!one(llmRoute, 'return llm_item and { llm_item } or {}') ||
		!one(generate, 'for _, entry in ipairs(load_top_level()) do') ||
		!(
			one(generate, 'for _, row in ipairs(builders[id]() or {}) do') ||
			declaredChildrenPublication(generate, builder, { lex, positions, rootPositions, body, one })
		) ||
		!one(generate, 'table.insert(items, row)') ||
		!(
			one(generate, 'local rendered = ManifestMenu.render_rows(items, "top_level")') ||
			declaredChildrenPublication(generate, builder, { lex, positions, rootPositions, body, one })
		) ||
		rootPositions(generate, 'return rendered').length !== 1
	)
		return false;
	return true;
}

/** The actual declared native root retains its original facade, source and renderer cohort. */
function declaredMacTopLevelPublication(builderSource) {
	if (typeof builderSource !== 'string') return false;
	const parser = luaPublicationParser();
	const { lex, positions, rootPositions, body } = parser;
	const builder = lex(builderSource);
	if (
		!builder ||
		rootPositions(builder, 'local ManifestMenu = require("infra.manifest_menu")').length !== 1 ||
		rootPositions(builder, 'ManifestMenu =').length !== 1 ||
		positions(builder, 'local require').length ||
		positions(builder, 'require =').length ||
		positions(builder, 'load_manifest =').length ||
		positions(builder, 'load_top_level =').length
	)
		return false;
	const loadRoot = body(builder, 'local function load_manifest()');
	const loadTop = body(builder, 'local function load_top_level()');
	const generate = body(builder, 'function M.generate(ctx, menu_mods, actions)');
	const rootRead = lex('return ManifestMenu.get_root()');
	return !!(
		loadRoot &&
		loadTop &&
		generate &&
		rootRead &&
		isDeepStrictEqual(
			loadRoot.tokens.map((t) => [t.kind, t.value]),
			rootRead.tokens.map((t) => [t.kind, t.value])
		) &&
		rootPositions(loadTop, 'local receive, declared = separator_factory()').length === 1 &&
		positions(loadTop, 'declared =').length === 1 &&
		rootPositions(loadTop, 'for _, entry in ipairs(declared) do').length === 1 &&
		nativeTopLevelProjection(loadTop, lex) &&
		declaredChildrenPublication(generate, builder, parser)
	);
}

const DECLARED_NATIVE_FACADE_LOCALS = {
	separator_modules: 'package.loaded',
	separator_factory:
		'type(ManifestMenu) == "table" and rawget(ManifestMenu, "top_level_separator_receiver")',
	separator_render: 'type(ManifestMenu) == "table" and rawget(ManifestMenu, "render_rows")',
	separator_array: 'type(ManifestMenu) == "table" and rawget(ManifestMenu, "get_array")',
	separator_root: 'type(ManifestMenu) == "table" and rawget(ManifestMenu, "get_root")'
};

const LINUX_HEADER_VERSION_SOURCE =
	'local function _version_text(version)\n\tlocal v = tostring(version)\n\tif v:match("^%d") then return "v" .. v end\n\treturn v\nend';
const LINUX_HEADER_LOCALS = {
	header_template: 'type(ManifestMenu) == "table" and rawget(ManifestMenu, "template_rows")',
	header_command: 'type(ManifestMenu) == "table" and rawget(ManifestMenu, "command_row")'
};
const LINUX_HEADER_FACADE_SOURCE =
	'local function header_facade_current()\n\treturn separator_facade_current()\n\t\tand type(header_template) == "function" and rawget(ManifestMenu, "template_rows") == header_template\n\t\tand type(header_command) == "function" and rawget(ManifestMenu, "command_row") == header_command\nend';
const LINUX_HEADER_BUILDER_SOURCE =
	'local function _build_header(ctx)\n\tif not header_facade_current() then return nil end\n\tlocal root = separator_root()\n\tif not header_facade_current() or type(root) ~= "table" or getmetatable(root) ~= nil then return nil end\n\tlocal active = separator_array("linux_tray_active_header")\n\tif not header_facade_current() or getmetatable(root) ~= nil then return nil end\n\tlocal paused = separator_array("linux_tray_paused_header")\n\tif not header_facade_current() or type(root) ~= "table" or getmetatable(root) ~= nil then return nil end\n\tlocal captured = {}\n\tlocal projected, projected_fields\n\tfor key, rows in next, { linux_tray_active_header = active, linux_tray_paused_header = paused } do\n\t\tif type(rows) ~= "table" or getmetatable(rows) ~= nil or rawget(root, key) ~= rows then return nil end\n\t\tfor index in next, rows do if index ~= 1 then return nil end end\n\t\tlocal record = rawget(rows, 1)\n\t\tif type(record) ~= "table" or getmetatable(record) ~= nil then return nil end\n\t\tlocal fields = {}\n\t\tfor name, value in next, record do\n\t\t\tif name ~= "type" and name ~= "id" and name ~= "i18n" and name ~= "caption_getter"\n\t\t\t\tand name ~= "caption_layout" and name ~= "caption_joiner" and name ~= "platforms"\n\t\t\t\tand name ~= "unavailable" then return nil end\n\t\t\tfields[name] = value\n\t\tend\n\t\tlocal expected_kind = key == "linux_tray_active_header" and "label" or "command"\n\t\tlocal expected_id = key == "linux_tray_active_header" and "linux_tray_active_header" or "linux_tray_resume"\n\t\tif rawget(record, "type") ~= expected_kind or rawget(record, "id") ~= expected_id\n\t\t\tor type(rawget(record, "i18n")) ~= "string" or rawget(record, "i18n") == ""\n\t\t\tor rawget(record, "caption_getter") ~= "linux_tray_version"\n\t\t\tor rawget(record, "caption_layout") ~= "prefix" or rawget(record, "caption_joiner") ~= " \u2014 "\n\t\t\tor rawget(record, "unavailable") ~= "hide" then return nil end\n\t\tlocal platforms = rawget(record, "platforms")\n\t\tif type(platforms) ~= "table" or getmetatable(platforms) ~= nil\n\t\t\tor rawget(platforms, 1) ~= "linux" then return nil end\n\t\tfor index in next, platforms do if index ~= 1 then return nil end end\n\t\tcaptured[key] = { rows = rows, record = record, fields = fields, platforms = platforms }\n\tend\n\tif captured.linux_tray_active_header == nil or captured.linux_tray_paused_header == nil then return nil end\n\n\tlocal function current()\n\t\tif not header_facade_current() or separator_root() ~= root or getmetatable(root) ~= nil then return false end\n\t\tfor key, snapshot in next, captured do\n\t\t\tlocal rows, record, platforms = snapshot.rows, snapshot.record, snapshot.platforms\n\t\t\tif not header_facade_current() or separator_array(key) ~= rows or rawget(root, key) ~= rows\n\t\t\t\tor getmetatable(rows) ~= nil or rawget(rows, 1) ~= record or getmetatable(record) ~= nil\n\t\t\t\tor rawget(record, "platforms") ~= platforms or getmetatable(platforms) ~= nil\n\t\t\t\tor rawget(platforms, 1) ~= "linux" then return false end\n\t\t\tfor index in next, rows do if index ~= 1 then return false end end\n\t\t\tfor index in next, platforms do if index ~= 1 then return false end end\n\t\t\tfor name, value in next, snapshot.fields do if rawget(record, name) ~= value then return false end end\n\t\t\tfor name in next, record do if snapshot.fields[name] == nil then return false end end\n\t\tend\n\t\tif projected ~= nil then\n\t\t\tif getmetatable(projected) ~= nil then return false end\n\t\t\tfor name, value in next, projected_fields do if rawget(projected, name) ~= value then return false end end\n\t\t\tfor name in next, projected do if projected_fields[name] == nil then return false end end\n\t\tend\n\t\treturn header_facade_current()\n\tend\n\n\tlocal version = _version_text(ctx._version or Version.VERSION)\n\tlocal is_paused = ctx.paused == true\n\tif not current() then return nil end\n\tlocal ok, rows = pcall(function()\n\t\tif is_paused then\n\t\t\treturn ManifestMenu.template_rows("linux_tray_paused_header", { ["linux_tray_resume"] = function()\n\t\t\t\tif type(ctx.on_toggle_pause) ~= "function" then\n\t\t\t\t\tLogger.error(LOG, "Paused title row: ctx.on_toggle_pause is absent \u2014 the script stays paused.")\n\t\t\t\t\treturn\n\t\t\t\tend\n\t\t\t\tctx.on_toggle_pause()\n\t\t\tend },\n\t\t\t\t{ ["linux_tray_version"] = function() return version end }, {})\n\t\tend\n\t\treturn ManifestMenu.template_rows("linux_tray_active_header", {},\n\t\t\t{ ["linux_tray_version"] = function() return version end }, {})\n\tend)\n\tif not ok or not current() or type(rows) ~= "table" or getmetatable(rows) ~= nil then return nil end\n\tfor index in next, rows do if index ~= 1 then return nil end end\n\tlocal row = rawget(rows, 1)\n\tif type(row) ~= "table" or getmetatable(row) ~= nil or type(rawget(row, "label")) ~= "string"\n\t\tor rawget(row, "label") == "" then return nil end\n\tfor name in next, row do\n\t\tif name ~= "label" and (is_paused and name ~= "action" or not is_paused and name ~= "disabled") then return nil end\n\tend\n\tif is_paused then\n\t\tif type(rawget(row, "action")) ~= "function" then return nil end\n\telseif rawget(row, "disabled") ~= true then return nil end\n\tprojected, projected_fields = row, {}\n\tfor name, value in next, row do projected_fields[name] = value end\n\tif not current() then return nil end\n\treturn row, current\nend\n';

/** The two genuine header templates retain their actual source and callback receiving chain. */
function declaredLinuxHeaderOwner(unit) {
	if (!unit) return false;
	const { lex, positions, rootPositions, body } = luaPublicationParser();
	const fragments = Object.entries(LINUX_HEADER_LOCALS).map(
		([name, value]) => 'local ' + name + ' = ' + value
	);
	fragments.push(
		LINUX_HEADER_VERSION_SOURCE,
		LINUX_HEADER_FACADE_SOURCE,
		LINUX_HEADER_BUILDER_SOURCE
	);
	const allowed = new Set();
	for (const fragment of fragments) {
		const found = positions(unit, fragment);
		if (found.length !== 1) return false;
		const wanted = scriptTokens(fragment, '.lua');
		for (let offset = 0; offset < wanted.length; offset++) allowed.add(found[0] + offset);
	}
	for (const [signature, expected] of [
		['local function _version_text(version)', LINUX_HEADER_VERSION_SOURCE],
		['local function header_facade_current()', LINUX_HEADER_FACADE_SOURCE],
		['local function _build_header(ctx)', LINUX_HEADER_BUILDER_SOURCE]
	]) {
		const actual = body(unit, signature),
			pinned = body(lex(expected), signature);
		if (
			rootPositions(unit, signature).length !== 1 ||
			!actual ||
			!pinned ||
			!isDeepStrictEqual(
				actual.tokens.map((t) => [t.kind, t.value]),
				pinned.tokens.map((t) => [t.kind, t.value])
			)
		)
			return false;
	}
	const call = positions(unit, 'local header, header_current = _build_header(ctx)');
	if (call.length !== 1) return false;
	const callTokens = scriptTokens('local header, header_current = _build_header(ctx)', '.lua');
	for (let offset = 0; offset < callTokens.length; offset++) allowed.add(call[0] + offset);
	const protectedNames = new Set([
		...Object.keys(LINUX_HEADER_LOCALS),
		'header_facade_current',
		'_build_header',
		'_version_text'
	]);
	for (let index = 0; index < unit.tokens.length; index++)
		if (
			unit.tokens[index].kind === 'identifier' &&
			protectedNames.has(unit.tokens[index].value) &&
			!allowed.has(index)
		)
			return false;
	return true;
}

/** The actual imported raw facade and its named functions retain custody of root projection. */
function declaredFacadeOwner(builder, parser) {
	const { lex, positions, rootPositions, body } = parser;
	for (const [name, expression] of [
		['separator_modules', 'package.loaded'],
		[
			'separator_factory',
			'type(ManifestMenu) == "table" and rawget(ManifestMenu, "top_level_separator_receiver")'
		],
		['separator_render', 'type(ManifestMenu) == "table" and rawget(ManifestMenu, "render_rows")'],
		['separator_array', 'type(ManifestMenu) == "table" and rawget(ManifestMenu, "get_array")'],
		['separator_root', 'type(ManifestMenu) == "table" and rawget(ManifestMenu, "get_root")']
	])
		if (
			rootPositions(builder, 'local ' + name + ' = ' + expression).length !== 1 ||
			positions(builder, name + ' =').length !== 1
		)
			return false;
	const actual = body(builder, 'local function separator_facade_current()');
	const expected = lex(`
		return type(ManifestMenu) == "table" and getmetatable(ManifestMenu) == nil
			and rawget(package, "loaded") == separator_modules
			and rawget(separator_modules, "infra.manifest_menu") == ManifestMenu
			and type(separator_factory) == "function" and rawget(ManifestMenu, "top_level_separator_receiver") == separator_factory
			and type(separator_render) == "function" and rawget(ManifestMenu, "render_rows") == separator_render
			and type(separator_array) == "function" and rawget(ManifestMenu, "get_array") == separator_array
			and type(separator_root) == "function" and rawget(ManifestMenu, "get_root") == separator_root
	`);
	return (
		actual &&
		expected &&
		rootPositions(builder, 'local function separator_facade_current()').length === 1 &&
		positions(builder, 'separator_facade_current =').length === 0 &&
		isDeepStrictEqual(
			actual.tokens.map((t) => [t.kind, t.value]),
			expected.tokens.map((t) => [t.kind, t.value])
		)
	);
}

/** Children finish before the retained render owner, with the actual cohort checked on both sides. */
function declaredChildrenPublication(generate, builder, parser) {
	const { one, positions } = parser;
	return (
		declaredFacadeOwner(builder, parser) &&
		one(
			generate,
			`local children = builders[id]() or {}
			if not separator_facade_current() or not _top_level_separator_receiver("current") then return {} end
			for _, row in ipairs(children) do`
		) &&
		positions(generate, 'children =').length === 1 &&
		one(
			generate,
			`if not separator_facade_current() or type(_top_level_separator_receiver) ~= "function"
			or not _top_level_separator_receiver("current") then return {} end
		local rendered = separator_render(items, "top_level")
		if not separator_facade_current() or not _top_level_separator_receiver("current") then return {} end`
		) &&
		parser.rootPositions(generate, 'rendered =').length === 1 &&
		positions(generate, 'rendered =').every(
			(at) =>
				generate.scopes[at] === 0 ||
				(generate.tokens[at - 1]?.value === 'local' &&
					[...generate.closes].some(
						([start, end]) =>
							start < at &&
							at < end &&
							generate.tokens[start]?.kind === 'identifier' &&
							generate.tokens[start]?.value === 'function'
					))
		) &&
		one(
			generate,
			`if not separator_facade_current() or not _top_level_separator_receiver("current") then return {} end
		return rendered`
		)
	);
}

/** Exact executable bodies for the retained historical and disabled-row projections.
 * This finite owner policy accepts formatting/comments, not arbitrary Lua rewrites.
 * Checking the whole body binds the actual append to its source, filters and cache.
 */
function nativeTopLevelProjection(unit, lex) {
	if (!unit) return false;
	const current = `
	if _top_level_cache then return _top_level_cache end
	local data = load_manifest()
	if not data or type(data.top_level) ~= "table" then
		Logger.error(LOG, "Failed to load top_level from manifest — the tray has no row.")
		return {}
	end
	local result = {}
	for _, entry in ipairs(data.top_level) do
		if type(entry) ~= "table" or type(entry.id) ~= "string" then goto continue end
		if type(entry.platforms) == "table" then
			local for_hs = false
			for _, p in ipairs(entry.platforms) do
				if p == "hs" then for_hs = true; break end
			end
			if not for_hs then goto continue end
		end
		local projected = { id = entry.id, greyed_when_paused = entry.greyed_when_paused == true }
		if entry.disabled == true then
			projected.disabled, projected.i18n, projected.reason_key = true, entry.i18n, entry.reason_key
		end
		table.insert(result, projected)
		::continue::
	end
	Logger.debug(LOG, "Top level loaded from manifest (%d item(s)).", #result)
	_top_level_cache = result
	return _top_level_cache`;
	const historical = current.replace(
		`		local projected = { id = entry.id, greyed_when_paused = entry.greyed_when_paused == true }
		if entry.disabled == true then
			projected.disabled, projected.i18n, projected.reason_key = true, entry.i18n, entry.reason_key
		end
		table.insert(result, projected)`,
		`		table.insert(result, { id = entry.id, greyed_when_paused = entry.greyed_when_paused == true })`
	);
	const declared = `
	if not separator_facade_current() then return {} end
	if _top_level_cache then
		if type(_top_level_separator_receiver) ~= "function" or not _top_level_separator_receiver("current") then return {} end
		return _top_level_cache
	end
	_top_level_separator_receiver = nil
	local receive, declared = separator_factory()
	if not separator_facade_current() then return {} end
	if not receive or type(declared) ~= "table" then
		Logger.error(LOG, "Failed to load top_level from manifest — the tray has no row.")
		return {}
	end
	local result = {}
	for _, entry in ipairs(declared) do
		if type(entry) ~= "table" or type(entry.id) ~= "string" then goto continue end
		if type(entry.platforms) == "table" then
			local for_hs = false
			for _, p in ipairs(entry.platforms) do
				if p == "hs" then for_hs = true; break end
			end
			if not for_hs then goto continue end
		end
		local projected = { id = entry.id, greyed_when_paused = entry.greyed_when_paused == true, declared_entry = entry }
		if entry.disabled == true then
			projected.disabled, projected.i18n, projected.reason_key = true, entry.i18n, entry.reason_key
		end
		table.insert(result, projected)
		::continue::
	end
	if not separator_facade_current() or not receive("current") then return {} end
	Logger.debug(LOG, "Top level loaded from manifest (%d item(s)).", #result)
	_top_level_cache, _top_level_separator_receiver = result, receive
	return _top_level_cache`;
	// Retain the prior direct append obligation on this captured declaration,
	// including the exact canonical record needed by the separator receiver.
	const declaredHistorical = declared.replace(
		`		local projected = { id = entry.id, greyed_when_paused = entry.greyed_when_paused == true, declared_entry = entry }
		if entry.disabled == true then
			projected.disabled, projected.i18n, projected.reason_key = true, entry.i18n, entry.reason_key
		end
		table.insert(result, projected)`,
		`		table.insert(result, { id = entry.id, greyed_when_paused = entry.greyed_when_paused == true, declared_entry = entry })`
	);
	const shape = (value) => value.tokens.map((token) => [token.kind, token.value]);
	return [historical, current, declared, declaredHistorical].some((text) => {
		const expected = lex(text);
		return expected && isDeepStrictEqual(shape(unit), shape(expected));
	});
}

/** Parses bounded executable Lua scopes; quoted/comment decoys never supply a body. */
function luaPublicationParser() {
	const lex = (text) => {
		const tokens = scriptTokens(text, '.lua'),
			scopes = [],
			stack = [],
			closes = new Map();
		let awaitingDo = 0;
		for (let at = 0; at < tokens.length; at++) {
			const token = tokens[at];
			scopes[at] = stack.length;
			// A closing Lua label is followed by structural code, not a method name.
			// Actual Builder.load_top_level ends its native loop after ::continue::.
			const afterLabel =
				tokens[at - 1]?.value === ':' &&
				tokens[at - 2]?.value === ':' &&
				tokens[at - 3]?.kind === 'identifier' &&
				tokens[at - 4]?.value === ':' &&
				tokens[at - 5]?.value === ':';
			if (
				token.kind !== 'identifier' ||
				(['.', ':'].includes(tokens[at - 1]?.value) && !afterLabel)
			)
				continue;
			if (['function', 'if', 'for', 'while', 'repeat'].includes(token.value)) {
				stack.push({ word: token.value, at });
				if (['for', 'while'].includes(token.value)) awaitingDo++;
			} else if (token.value === 'do') {
				if (awaitingDo) awaitingDo--;
				else stack.push({ word: 'do', at });
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
		const wanted = scriptTokens(statement, '.lua'),
			found = [];
		for (let at = 0; at < unit.tokens.length; at++) {
			if (['.', ':'].includes(unit.tokens[at - 1]?.value)) continue;
			if (
				wanted.every((token, offset) => {
					const actual = unit.tokens[at + offset];
					return (
						actual?.kind === token.kind &&
						actual.value === token.value &&
						(token.kind !== 'string' ||
							unit.text.slice(actual.start, actual.end) === statement.slice(token.start, token.end))
					);
				})
			)
				found.push(at);
		}
		return found;
	};
	const rootPositions = (unit, text) => positions(unit, text).filter((at) => unit.scopes[at] === 0);
	const body = (unit, signature) => {
		const found = rootPositions(unit, signature),
			count = scriptTokens(signature, '.lua').length;
		if (found.length !== 1) return null;
		const start = found[0],
			functionAt = unit.tokens.findIndex(
				(token, at) => at >= start && at < start + count && token.value === 'function'
			);
		const end = unit.closes.get(functionAt);
		if (end === undefined) return null;
		return lex(unit.text.slice(unit.tokens[start + count - 1].end, unit.tokens[end].start));
	};
	const one = (unit, text) => positions(unit, text).length === 1;
	return { lex, positions, rootPositions, body, one };
}

/** The admitted source/context/native snapshots and read-before-pure-check algorithm. */
const LINUX_AI_PARENT_ALGORITHM =
	'--- ui/menu/ai_parent.lua\n\n--- ==============================================================================\n--- MODULE: Linux AI Parent Source Admission\n--- DESCRIPTION:\n--- Binds the two AI parents to actual shared declarations around their finished\n--- native children, preserving the context, source and callback cohort.\n--- ==============================================================================\n\nlocal M = {}\n\nlocal declarations = {\n\tllm = { frame = "llm_native_parent_linux", id = "llm_parent_linux", child = "llm_menu" },\n\tagent = { frame = "agent_native_parent", id = "agent_parent_linux", child = "agent_menu" },\n}\n\n--- Captures plain source records and arrays without invoking metamethods.\n--- @param value table Source or completed child.\n--- @param seen table|nil Objects already captured.\n--- @return table|nil snapshot\nlocal function capture(value, seen, shallow)\n\tif type(value) ~= "table" or getmetatable(value) ~= nil then return nil end\n\tseen = seen or {}\n\tif seen[value] then return seen[value] end\n\tlocal snapshot = { object = value, fields = {}, children = {} }\n\tseen[value] = snapshot\n\tfor key, field in next, value do\n\t\tsnapshot.fields[key] = field\n\t\tif type(field) == "table" and not shallow then\n\t\t\tlocal child = capture(field, seen)\n\t\t\tif not child then return nil end\n\t\t\tsnapshot.children[key] = child\n\t\tend\n\tend\n\treturn snapshot\nend\n\n--- Rechecks direct source values and retained native callback identities.\n--- @param snapshot table\n--- @param seen table|nil Captures already checked.\n--- @return boolean\nlocal function unchanged(snapshot, seen)\n\tlocal value = snapshot.object\n\tif getmetatable(value) ~= nil then return false end\n\tseen = seen or {}\n\tif seen[snapshot] then return true end\n\tseen[snapshot] = true\n\tfor key, field in next, value do\n\t\tif not rawequal(field, rawget(snapshot.fields, key)) then return false end\n\tend\n\tfor key, field in next, snapshot.fields do\n\t\tif not rawequal(field, rawget(value, key)) then return false end\n\t\tif snapshot.children[key] and not unchanged(snapshot.children[key], seen) then return false end\n\tend\n\treturn true\nend\n\n--- Resolves only direct methods or a plain inherited renderer table, without foreign lookup.\n--- @param renderer table Actual shared renderer or a facade retaining its genuine owner.\n--- @param name string Method name.\n--- @return any method\nlocal function api_method(renderer, name)\n\tlocal direct = rawget(renderer, name)\n\tif direct ~= nil then return direct end\n\tlocal meta = getmetatable(renderer)\n\tif type(meta) ~= "table" or getmetatable(meta) ~= nil then return nil end\n\tfor key in next, meta do if key ~= "__index" then return nil end end\n\tlocal owner = rawget(meta, "__index")\n\tif type(owner) ~= "table" or getmetatable(owner) ~= nil then return nil end\n\treturn rawget(owner, name)\nend\n\n--- Captures the exact direct renderer facade and its plain inherited owner.\n--- @param renderer table\n--- @return table|nil snapshot\nlocal function capture_api(renderer)\n\tlocal meta = getmetatable(renderer)\n\tlocal owner\n\tif meta ~= nil then\n\t\tif type(meta) ~= "table" or getmetatable(meta) ~= nil then return nil end\n\t\tfor key in next, meta do if key ~= "__index" then return nil end end\n\t\towner = rawget(meta, "__index")\n\t\tif type(owner) ~= "table" or getmetatable(owner) ~= nil then return nil end\n\tend\n\tlocal fields = {}\n\tfor key, field in next, renderer do fields[key] = field end\n\treturn { object = renderer, fields = fields, meta = meta,\n\t\tmeta_snapshot = meta and capture(meta, nil, true),\n\t\towner_snapshot = owner and capture(owner, nil, true) }\nend\n\n--- Rechecks facade fields, metatable and inherited method owners by raw identity.\n--- @param snapshot table\n--- @return boolean\nlocal function unchanged_api(snapshot)\n\tif not rawequal(getmetatable(snapshot.object), snapshot.meta) then return false end\n\tfor key, field in next, snapshot.object do\n\t\tif not rawequal(field, rawget(snapshot.fields, key)) then return false end\n\tend\n\tfor key, field in next, snapshot.fields do\n\t\tif not rawequal(field, rawget(snapshot.object, key)) then return false end\n\tend\n\treturn (not snapshot.meta_snapshot or unchanged(snapshot.meta_snapshot))\n\t\tand (not snapshot.owner_snapshot or unchanged(snapshot.owner_snapshot))\nend\n\n--- Requires a nonempty dense array of direct records.\n--- @param value any\n--- @return boolean\nlocal function rows(value)\n\tif type(value) ~= "table" or getmetatable(value) ~= nil then return false end\n\tlocal count, maximum = 0, 0\n\tfor index, row in next, value do\n\t\tif type(index) ~= "number" or index % 1 ~= 0 or index < 1\n\t\t\tor type(row) ~= "table" or getmetatable(row) ~= nil then return false end\n\t\tcount, maximum = count + 1, math.max(maximum, index)\n\tend\n\treturn count > 0 and count == maximum\nend\n\n--- Reads native state without claiming an unreadable value is enabled.\n--- @param ticket table Captured native owners.\n--- @return boolean|nil\nlocal function enabled(ticket)\n\tif ticket.kind == "llm" then\n\t\tlocal getter = ticket.native and rawget(ticket.native, "is_enabled")\n\t\tif type(getter) ~= "function" then return nil end\n\t\tlocal ok, value = pcall(getter)\n\t\tif ok and type(value) == "boolean" then return value end\n\t\treturn nil\n\tend\n\tlocal getter = ticket.settings and rawget(ticket.settings, "get_mode")\n\tif type(getter) ~= "function" then return nil end\n\tlocal ok, value = pcall(getter)\n\tif not ok or (value ~= "off" and value ~= "action" and value ~= "auto") then return nil end\n\treturn value ~= "off"\nend\n\n--- Checks the current native pause reader without changing its owner.\n--- @param ctx table Actual menu context.\n--- @return boolean\nlocal function unpaused(ctx)\n\tif rawget(ctx, "paused") == true then return false end\n\tlocal getter = rawget(ctx, "is_paused")\n\tif getter == nil then return true end\n\tif type(getter) ~= "function" then return false end\n\tlocal ok, value = pcall(getter)\n\treturn ok and value == false\nend\n\n--- Captures the genuine source before either AI child starts building.\n--- @param renderer table|nil Actual shared renderer binding.\n--- @param kind string "llm" or "agent".\n--- @param ctx table Actual menu context.\n--- @param settings table|nil Actual AgentSettings owner for the agent.\n--- @return table|nil ticket\nfunction M.begin(renderer, kind, ctx, settings)\n\tlocal declaration = declarations[kind]\n\tif not declaration or type(renderer) ~= "table"\n\t\tor type(ctx) ~= "table" or getmetatable(ctx) ~= nil then return nil end\n\tlocal renderer_snapshot = capture_api(renderer)\n\tif not renderer_snapshot then return nil end\n\tfor _, method in ipairs({ "get_root", "group_row", "build", "render_rows", "template_rows" }) do\n\t\tif type(api_method(renderer, method)) ~= "function" then return nil end\n\tend\n\tlocal ok, root = pcall(api_method(renderer, "get_root"))\n\tif not ok or type(root) ~= "table" or getmetatable(root) ~= nil then return nil end\n\tlocal top, frame, child = rawget(root, "top_level"), rawget(root, declaration.frame), rawget(root, declaration.child)\n\tif not rows(top) or not rows(frame) or not rows(child) then return nil end\n\tlocal parent, position\n\tfor index, row in next, top do\n\t\tif rawget(row, "id") == kind then\n\t\t\tif position then return nil end\n\t\t\tposition = index\n\t\tend\n\tend\n\tfor _, row in next, frame do\n\t\tif rawget(row, "id") == declaration.id then\n\t\t\tif parent then return nil end\n\t\t\tparent = row\n\t\tend\n\tend\n\tif not position or not parent or rawget(parent, "type") ~= "group"\n\t\tor type(rawget(parent, "i18n")) ~= "string" or rawget(parent, "i18n") == "" then return nil end\n\tlocal platforms = rawget(parent, "platforms")\n\tif type(platforms) ~= "table" or getmetatable(platforms) ~= nil then return nil end\n\tlocal visible = false\n\tfor _, platform in next, platforms do\n\t\tif platform == "linux" then visible = true end\n\tend\n\tif not visible then return nil end\n\tlocal frame_snapshot, child_snapshot, top_snapshot = capture(frame), capture(child), capture(top)\n\tif not frame_snapshot or not child_snapshot or not top_snapshot then return nil end\n\tlocal snapshots = { frame_snapshot, child_snapshot, top_snapshot }\n\tlocal ticket = { renderer = renderer, root = root, top = top, frame = frame, child = child,\n\t\tposition = position, top_parent = top[position], declaration = declaration, kind = kind,\n\t\tctx = ctx, context = { llm = rawget(ctx, "llm"), paused = rawget(ctx, "paused"),\n\t\t\tis_paused = rawget(ctx, "is_paused"), changed = rawget(ctx, "on_menu_changed") },\n\t\tnative = rawget(ctx, "llm"), settings = settings, snapshots = snapshots, methods = {},\n\t\trenderer_snapshot = renderer_snapshot }\n\tfor _, method in ipairs({ "get_root", "group_row", "build", "render_rows", "template_rows" }) do\n\t\tticket.methods[method] = api_method(renderer, method)\n\tend\n\tif ticket.native ~= nil then\n\t\tticket.native_snapshot = capture(ticket.native, nil, true)\n\t\tif not ticket.native_snapshot then return nil end\n\tend\n\tif settings ~= nil then\n\t\tticket.settings_snapshot = capture(settings, nil, true)\n\t\tif not ticket.settings_snapshot then return nil end\n\tend\n\tticket.enabled = enabled(ticket)\n\treturn ticket\nend\n\n--- Rechecks the native and shared source cohort before and after projection.\n--- @param ticket table\n--- @return boolean\nlocal function current(ticket)\n\t-- Native state and source readers can withdraw the cohort while answering.\n\t-- Complete both reads before the final pure checks, including after projection.\n\tlocal current_enabled = enabled(ticket)\n\tlocal ok, root = pcall(ticket.methods.get_root)\n\tlocal renderer, ctx = ticket.renderer, ticket.ctx\n\tfor method, owner in next, ticket.methods do\n\t\tif not rawequal(api_method(renderer, method), owner) then return false end\n\tend\n\tif not ok or not rawequal(root, ticket.root) or not rawequal(rawget(root, "top_level"), ticket.top)\n\t\tor not rawequal(rawget(root, ticket.declaration.frame), ticket.frame)\n\t\tor not rawequal(rawget(root, ticket.declaration.child), ticket.child)\n\t\tor not rawequal(rawget(ticket.top, ticket.position), ticket.top_parent)\n\t\tor not rawequal(rawget(ctx, "llm"), ticket.context.llm)\n\t\tor not rawequal(rawget(ctx, "paused"), ticket.context.paused)\n\t\tor not rawequal(rawget(ctx, "is_paused"), ticket.context.is_paused)\n\t\tor not rawequal(rawget(ctx, "on_menu_changed"), ticket.context.changed) then return false end\n\tif not unchanged_api(ticket.renderer_snapshot) then return false end\n\tfor _, snapshot in ipairs(ticket.snapshots) do if not unchanged(snapshot) then return false end end\n\tif ticket.native_snapshot and not unchanged(ticket.native_snapshot) then return false end\n\tif ticket.settings_snapshot and not unchanged(ticket.settings_snapshot) then return false end\n\treturn current_enabled == ticket.enabled\nend\n\n--- Projects only a whole completed child with its original callbacks retained.\n--- @param ticket table|nil Captured genuine source and native owners.\n--- @param children table Finished native subtree.\n--- @return table|nil parent\nfunction M.finish(ticket, children)\n\tif not ticket or not rows(children) or not current(ticket) then return nil end\n\tlocal native_children = capture(children)\n\tif not native_children then return nil end\n\tlocal ready = ticket.enabled ~= nil and type(ticket.native) == "table"\n\t\tand unpaused(ticket.ctx)\n\tlocal getters = ticket.kind == "llm" and {\n\t\tllm_parent_enabled = function() return ticket.enabled end,\n\t\tllm_parent_ready = function() return ready end,\n\t} or {\n\t\tagent_parent_enabled = function() return ticket.enabled end,\n\t\tagent_parent_ready = function() return ready end,\n\t}\n\tlocal getter_snapshot = capture(getters)\n\tlocal row = ticket.methods.group_row(ticket.declaration.frame, ticket.declaration.id, children, getters)\n\tif not current(ticket) or not unchanged(native_children) or not unchanged(getter_snapshot)\n\t\tor type(row) ~= "table" or not rawequal(rawget(row, "submenu"), children) then return nil end\n\treturn row\nend\n\nreturn M\n';

/** Proves a Linux AI parent from its real declaration, whole producer and tray caller. */

/** Refuses executable module-root additions and replacement/escaped native exports. */
function closedModuleExport(unit, lex, rootPositions) {
	if (!unit) return false;
	const imports = {
		WindowTitles: 'window_titles',
		NumberRowPolicy: 'layout.number_row_policy',
		ParameterLabel: 'action_parameter_label',
		RowDialect: 'menu.row_dialect',
		Logger: 'logger.shim',
		Extensions: 'hotstrings.extensions',
		PersonalFiles: 'hotstrings.personal_files',
		PersonalFileMenu: 'menu.personal_files',
		Languages: 'hotstrings.languages',
		LocaleTable: '_generated.locale_table',
		MagicKey: 'modules.hotstrings.magic_key',
		MagicKeySourceRows: 'keymap.magic_key_source',
		PreviewSettings: 'modules.hotstrings.preview_settings',
		RepeatKey: 'modules.hotstrings.repeat_key',
		Modal: 'ui.modal',
		TextPrompt: 'ui.text_prompt',
		PrivacyPolicy: 'llm.trigger_policy',
		LlmBackendRows: 'ui.menu.llm_backend_rows',
		ProgrammableHotstrings: 'ui.menu.programmatic_hotstrings',
		ProgrammableMenuPolicy: 'menu.programmable_hotstrings',
		Version: 'infra.version',
		Installation: 'infra.installation',
		VersionLabel: 'updater.version_label',
		Schedule: 'updater.schedule',
		AgentSettings: 'modules.llm.agent_settings'
	};
	const constants = new Set(['M', 'LOG', 'MS_PER_SEC', 'PERSONAL_CATEGORY', 'ok_mm']);
	const tokens = unit.tokens,
		definitions = new Set(),
		locals = new Set();
	const take = (at, source) => {
		const wanted = scriptTokens(source, '.lua');
		return wanted.every(
			(token, n) => tokens[at + n]?.kind === token.kind && tokens[at + n]?.value === token.value
		)
			? at + wanted.length
			: null;
	};
	let at = 0,
		builds = 0;
	while (at < tokens.length) {
		const start = at;
		if (
			(tokens[at].value === 'local' && tokens[at + 1]?.value === 'function') ||
			tokens[at].value === 'function'
		) {
			const local = tokens[at].value === 'local',
				functionAt = at + (local ? 1 : 0);
			const name = tokens[functionAt + 1]?.value;
			const member =
				name === 'M' &&
				tokens[functionAt + 2]?.value === '.' &&
				tokens[functionAt + 3]?.value === 'build';
			if (!local && !member && name !== 'i18n_safe') return false;
			const owner = member ? 'M.build' : name;
			if (definitions.has(owner)) return false;
			definitions.add(owner);
			if (member) builds++;
			const close = unit.closes.get(functionAt);
			if (close === undefined) return false;
			at = close + 1;
		} else if (tokens[at].value === 'local') {
			const name = tokens[at + 1];
			if (name?.kind !== 'identifier' || locals.has(name.value)) return false;
			locals.add(name.value);
			if (name.value === 'ok_mm') {
				at = take(at, 'local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")');
			} else {
				if (Object.hasOwn(LINUX_HEADER_LOCALS, name.value)) {
					if (!declaredLinuxHeaderOwner(unit)) return false;
					at = take(at, 'local ' + name.value + ' = ' + LINUX_HEADER_LOCALS[name.value]);
					if (at === null) return false;
					continue;
				}
				if (Object.hasOwn(DECLARED_NATIVE_FACADE_LOCALS, name.value)) {
					if (!declaredFacadeOwner(unit, luaPublicationParser())) return false;
					at = take(at, 'local ' + name.value + ' = ' + DECLARED_NATIVE_FACADE_LOCALS[name.value]);
					if (at === null) return false;
					continue;
				}
				if (tokens[at + 2]?.value !== '=') return false;
				const value = tokens[at + 3];
				if (value?.value === 'require') {
					if (imports[name.value] !== tokens[at + 5]?.value) return false;
					if (
						tokens[at + 4]?.value !== '(' ||
						tokens[at + 5]?.kind !== 'string' ||
						tokens[at + 6]?.value !== ')'
					)
						return false;
					at += 7;
				} else if (value?.kind === 'string' && constants.has(name.value)) at += 4;
				else if (
					value?.kind === 'symbol' &&
					/^[0-9]$/.test(value.value) &&
					constants.has(name.value)
				) {
					at += 4;
					while (
						tokens[at]?.kind === 'symbol' &&
						/^[0-9]$/.test(tokens[at].value) &&
						tokens[at].start === tokens[at - 1].end
					)
						at++;
				} else if (value?.value === '{' && tokens[at + 4]?.value === '}' && name.value === 'M')
					at += 5;
				else return false;
			}
		} else if (tokens[at].value === 'if') {
			at = take(at, 'if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end');
		} else if (tokens[at].value === 'M') {
			at = take(at, 'M._about_update_rows = _about_update_rows');
		} else if (tokens[at].value === 'return') {
			at = take(at, 'return M');
			if (at !== tokens.length) return false;
		} else return false;
		if (at === null || at <= start) return false;
	}
	if (builds !== 1 || rootPositions(unit, 'return M').length !== 1) return false;
	// A module export may not be passed to a mutator, aliased, or accessed by computed key.
	for (let index = 0; index < tokens.length; index++) {
		if (tokens[index].kind !== 'identifier' || tokens[index].value !== 'M') continue;
		const before = tokens[index - 1]?.value,
			next = tokens[index + 1]?.value;
		if (before === 'local' && next === '=' && unit.scopes[index] === 0) continue;
		if (before === 'return' && index === tokens.length - 1) continue;
		if (before === 'function' && next === '.' && tokens[index + 2]?.value === 'build') continue;
		if (
			unit.scopes[index] === 0 &&
			next === '.' &&
			tokens[index + 2]?.value === '_about_update_rows' &&
			tokens[index + 3]?.value === '=' &&
			tokens[index + 4]?.value === '_about_update_rows'
		)
			continue;
		return false;
	}
	return true;
}

/** Rejects writes, lexical shadowing and escapes of the actual native API owners. */
function closedOwnerReferences(unit, names, bootGuard = false) {
	if (!unit) return false;
	const { positions } = luaPublicationParser();
	const boot = bootGuard
		? positions(unit, 'if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end')
		: [];
	if (bootGuard && boot.length !== 1) return false;
	for (let at = 0; at < unit.tokens.length; at++) {
		const t = unit.tokens[at];
		if (t.kind !== 'identifier' || !names.includes(t.value)) continue;
		const previous = unit.tokens[at - 1]?.value,
			next = unit.tokens[at + 1]?.value;
		if (
			previous === 'local' &&
			next === '=' &&
			unit.tokens[at + 2]?.value === 'require' &&
			unit.tokens[at + 3]?.value === '(' &&
			unit.tokens[at + 4]?.kind === 'string' &&
			unit.tokens[at + 5]?.value === ')'
		)
			continue;
		if (
			t.value === 'ManifestMenu' &&
			previous === ',' &&
			next === '=' &&
			unit.tokens[at - 2]?.value === 'ok_mm' &&
			unit.tokens[at - 3]?.value === 'local'
		)
			continue;
		if (
			t.value === 'ManifestMenu' &&
			next === '=' &&
			unit.tokens[at + 2]?.value === 'nil' &&
			boot.length === 1 &&
			at > boot[0] &&
			at < boot[0] + 16
		)
			continue;
		if (next === '.' && unit.tokens[at + 2]?.kind === 'identifier') {
			if (['=', '[', ':'].includes(unit.tokens[at + 3]?.value)) return false;
			continue;
		}
		// Plain port arguments are permitted only in the genuine NativeParent.begin call.
		if (
			t.value === 'ManifestMenu' &&
			previous === '(' &&
			unit.tokens[at - 2]?.value === 'begin' &&
			unit.tokens[at - 3]?.value === '.' &&
			unit.tokens[at - 4]?.value === 'NativeParent'
		)
			continue;
		if (
			t.value === 'AgentSettings' &&
			previous === ',' &&
			next === ')' &&
			unit.tokens
				.slice(at - 10, at)
				.map((token) => token.value)
				.join(' ') === 'NativeParent . begin ( ManifestMenu , agent , ctx ,'
		)
			continue;
		if (t.value === 'ManifestMenu' && previous === 'not' && ['then', 'or'].includes(next)) continue;
		if (t.value === 'ManifestMenu' && ['and', 'or'].includes(next)) continue;
		if (
			t.value === 'ManifestMenu' &&
			previous === '(' &&
			unit.tokens[at - 2]?.value === 'type' &&
			next === ')'
		)
			continue;
		return false;
	}
	return true;
}

/** Keeps sibling renderer ports under their existing lexical owners, without native-frame credit. */
function closedSiblingRendererBindings(unit) {
	const { positions, rootPositions, body } = luaPublicationParser();
	const imports = {
		NumberRowPolicy: 'layout.number_row_policy',
		MagicKeySourceRows: 'keymap.magic_key_source',
		ProgrammableMenuPolicy: 'menu.programmable_hotstrings',
		PersonalFileMenu: 'menu.personal_files'
	};
	for (const [name, module] of Object.entries(imports))
		if (rootPositions(unit, 'local ' + name + ' = require("' + module + '")').length !== 1)
			return false;
	const localPorts = [
		'magic_frame_snapshot',
		'magic_frame_current',
		'metrics_source',
		'configuration_source',
		'about_source',
		'debug_source'
	];
	if (!closedHelperReferences(unit, localPorts)) return false;
	const importedPorts = {
		native_rows: 'NumberRowPolicy',
		build_entry_rows: 'ProgrammableMenuPolicy',
		directory_unavailable: 'PersonalFileMenu'
	};
	const optionCalls = [
		'MagicKeySourceRows.menu_rows(Source.resolver(), { manifest = ManifestMenu',
		'PersonalFileMenu.build({ manifest = ManifestMenu',
		'PersonalFileMenu.apply_category_admission(rendered, { manifest = ManifestMenu',
		'require("ui.menu.key_combinations").build(ctx, { manifest = ManifestMenu'
	];
	const optionPorts = new Set();
	for (const pattern of optionCalls) {
		const wanted = scriptTokens(pattern, '.lua');
		for (const start of positions(unit, pattern)) optionPorts.add(start + wanted.length - 1);
	}
	const personalInfoAlias =
		require('./menu-native-personal-info-binding.cjs').retainedPersonalInfoManifestAliasOffset(
			unit.text
		);
	const rawFacadePorts = new Set();
	if (declaredFacadeOwner(unit, luaPublicationParser())) {
		for (const fragment of [
			...Object.entries(DECLARED_NATIVE_FACADE_LOCALS).map(
				([name, value]) => 'local ' + name + ' = ' + value
			),
			body(unit, 'local function separator_facade_current()').text
		]) {
			const wanted = scriptTokens(fragment, '.lua');
			const matches = positions(unit, fragment);
			if (matches.length !== 1) return false;
			for (const start of matches)
				for (let offset = 0; offset < wanted.length; offset++)
					if (wanted[offset].value === 'ManifestMenu') rawFacadePorts.add(start + offset);
		}
	}
	if (declaredLinuxHeaderOwner(unit)) {
		for (const fragment of [
			...Object.entries(LINUX_HEADER_LOCALS).map(
				([name, value]) => 'local ' + name + ' = ' + value
			),
			LINUX_HEADER_FACADE_SOURCE
		]) {
			const wanted = scriptTokens(fragment, '.lua'),
				found = positions(unit, fragment);
			if (found.length !== 1) return false;
			for (let offset = 0; offset < wanted.length; offset++)
				if (wanted[offset].value === 'ManifestMenu') rawFacadePorts.add(found[0] + offset);
		}
	}
	const boot = positions(
		unit,
		'if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end'
	);
	if (boot.length !== 1) return false;
	for (let at = 0; at < unit.tokens.length; at++) {
		const t = unit.tokens[at];
		if (t.kind !== 'identifier' || t.value !== 'ManifestMenu') continue;
		const before = unit.tokens[at - 1]?.value,
			next = unit.tokens[at + 1]?.value;
		if (
			before === 'local' &&
			next === '=' &&
			unit.tokens[at + 2]?.value === 'require' &&
			unit.tokens[at + 4]?.value === 'infra.manifest_menu'
		)
			continue;
		if (
			before === ',' &&
			next === '=' &&
			unit.tokens[at - 2]?.value === 'ok_mm' &&
			unit.tokens[at - 3]?.value === 'local'
		)
			continue;
		if (next === '=' && unit.tokens[at + 2]?.value === 'nil' && at > boot[0] && at < boot[0] + 16)
			continue;
		if (next === '.' && unit.tokens[at + 2]?.kind === 'identifier') {
			if (unit.tokens[at + 3]?.value === '=' && unit.tokens[at + 4]?.value !== '=') return false;
			continue;
		}
		if (before === '(' && unit.tokens[at - 2]?.value === 'type' && next === ')') continue;
		if ((before === 'not' && ['then', 'or'].includes(next)) || ['and', 'or'].includes(next))
			continue;
		if (optionPorts.has(at) || rawFacadePorts.has(at)) continue;
		if (personalInfoAlias >= 0 && unit.tokens[at].start === personalInfoAlias) continue;
		if (before === '(' && localPorts.includes(unit.tokens[at - 2]?.value)) continue;
		if (
			before === '(' &&
			unit.tokens[at - 3]?.value === '.' &&
			importedPorts[unit.tokens[at - 2]?.value] === unit.tokens[at - 4]?.value
		)
			continue;
		if (
			before === '(' &&
			unit.tokens[at - 2]?.value === 'begin' &&
			unit.tokens[at - 3]?.value === '.' &&
			unit.tokens[at - 4]?.value === 'NativeParent'
		)
			continue;
		return false;
	}
	return true;
}

/** Each reachable local dispatch helper retains its declaration and direct use ownership. */
function closedHelperReferences(unit, names) {
	if (!unit) return false;
	for (const name of names) {
		const { rootPositions } = luaPublicationParser();
		if (rootPositions(unit, 'local function ' + name + '(').length !== 1) return false;
		for (let at = 0; at < unit.tokens.length; at++) {
			const token = unit.tokens[at];
			if (token.kind !== 'identifier' || token.value !== name) continue;
			if (unit.tokens[at - 1]?.value === 'function' && unit.scopes[at] === 1) continue;
			if (unit.tokens[at + 1]?.value === '(' && unit.tokens[at - 1]?.value !== 'function') continue;
			if (
				['_build_llm', '_build_agent'].includes(name) &&
				unit.tokens[at - 1]?.value === '=' &&
				unit.tokens[at - 2]?.value === ']' &&
				unit.tokens[at - 3]?.value === name.slice(7) &&
				unit.tokens[at - 4]?.value === '[' &&
				unit.tokens[at + 1]?.value === ','
			)
				continue;
			return false;
		}
	}
	return true;
}

/** Reads a single direct builder table: duplicate dispatch keys and synthetic replacements refuse. */
function closedNativeDispatch(builder, tray) {
	const { rootPositions, positions } = luaPublicationParser();
	const starts = rootPositions(tray, 'local builders = {');
	if (starts.length !== 1) return false;
	let at = starts[0] + 4;
	const seen = new Map();
	while (tray.tokens[at]?.value !== '}') {
		if (
			tray.tokens[at]?.value !== '[' ||
			tray.tokens[at + 1]?.kind !== 'string' ||
			tray.tokens[at + 2]?.value !== ']' ||
			tray.tokens[at + 3]?.value !== '=' ||
			tray.tokens[at + 4]?.kind !== 'identifier' ||
			tray.tokens[at + 5]?.value !== ','
		)
			return false;
		const key = tray.tokens[at + 1].value,
			owner = tray.tokens[at + 4].value;
		if (seen.has(key) || rootPositions(builder, 'local function ' + owner + '(').length !== 1)
			return false;
		seen.set(key, owner);
		at += 6;
	}
	if (seen.get('llm') !== '_build_llm' || seen.get('agent') !== '_build_agent') return false;
	for (const route of [
		'rows[#rows + 1] = build(ctx) end',
		'rows[#rows + 1] = _grey_for_pause(build(ctx)) else',
		'quit_row = build(ctx) elseif ctx.paused == true'
	])
		if (positions(tray, route).length !== 1) return false;
	return true;
}

/** Keeps the acknowledged native command bound to the original refresh callback and system helpers. */
function closedChangedOwner(producer) {
	if (!producer) return false;
	const { positions } = luaPublicationParser();
	if (positions(producer, 'local function changed()').length !== 1) return false;
	const allowed = new Set();
	for (const pattern of [
		'local function changed()',
		'system_rows(system, dialogs, changed)',
		'disabled_app_rows(llm, dialogs, changed)',
		'changed()'
	]) {
		const wanted = scriptTokens(pattern, '.lua');
		for (const start of positions(producer, pattern))
			for (let n = 0; n < wanted.length; n++)
				if (wanted[n].value === 'changed') allowed.add(start + n);
	}
	return producer.tokens.every(
		(token, at) => token.kind !== 'identifier' || token.value !== 'changed' || allowed.has(at)
	);
}

/** Parses producer expressions/statements structurally; unsupported syntax refuses source admission. */
function luaProducerTree(source) {
	const raw = scriptTokens(source, '.lua'),
		tokens = [];
	for (let i = 0; i < raw.length; i++) {
		const t = raw[i];
		let value = t.value,
			end = t.end,
			kind = t.kind;
		if (t.kind === 'symbol' && /[0-9]/.test(t.value)) {
			const number = source
				.slice(t.start)
				.match(
					/^(?:0[xX][0-9a-fA-F]+(?:\.[0-9a-fA-F]*)?(?:[pP][+-]?\d+)?|\d+(?:\.(?!\.)\d*)?(?:[eE][+-]?\d+)?)/
				);
			if (!number) throw Error('Lua numeric grammar');
			value = number[0];
			end = t.start + value.length;
			kind = 'number';
			while (raw[i + 1]?.start < end) i++;
		} else if (t.kind === 'symbol') {
			for (const op of ['...', '==', '~=', '<=', '>=', '..', '//', '<<', '>>', '::'])
				if (source.startsWith(op, t.start)) {
					value = op;
					end = t.start + op.length;
					while (raw[i + 1]?.start < end) i++;
					break;
				}
		}
		tokens.push({ ...t, value, end, kind });
	}
	let at = 0;
	const peek = (v) =>
		v === undefined ? tokens[at] : tokens[at]?.kind !== 'string' && tokens[at]?.value === v;
	const take = (v) => {
		const t = tokens[at];
		if (!t || (v !== undefined && t.value !== v))
			throw Error('Lua expected ' + v + ' at ' + (t?.start ?? source.length));
		at++;
		return t;
	};
	const maybe = (v) => (peek(v) ? take(v) : null);
	const identifier = () => {
		const t = take();
		if (
			t.kind !== 'identifier' ||
			['end', 'then', 'else', 'elseif', 'do', 'until'].includes(t.value)
		)
			throw Error('Lua identifier');
		return { type: 'id', name: t.value, start: t.start, end: t.end };
	};
	const node = (type, start, data) => ({
		type,
		start,
		end: tokens[at - 1]?.end ?? start,
		...data
	});
	const precedence = {
		or: 1,
		and: 2,
		'<': 3,
		'>': 3,
		'<=': 3,
		'>=': 3,
		'~=': 3,
		'==': 3,
		'|': 4,
		'~': 5,
		'&': 6,
		'<<': 7,
		'>>': 7,
		'..': 8,
		'+': 9,
		'-': 9,
		'*': 10,
		'/': 10,
		'//': 10,
		'%': 10,
		'^': 12
	};
	function list() {
		const out = [expression()];
		while (maybe(',')) out.push(expression());
		return out;
	}
	function args() {
		if (maybe('(')) {
			const values = peek(')') ? [] : list();
			take(')');
			return values;
		}
		if (peek('{')) return [table()];
		if (peek()?.kind === 'string') return [primary()];
		throw Error('Lua call arguments');
	}
	function table() {
		const start = take('{').start,
			fields = [];
		while (!peek('}')) {
			let key = null,
				value;
			if (maybe('[')) {
				key = expression();
				take(']');
				take('=');
				value = expression();
			} else if (peek()?.kind === 'identifier' && tokens[at + 1]?.value === '=') {
				const id = identifier();
				key = { type: 'string', value: id.name, start: id.start, end: id.end };
				take('=');
				value = expression();
			} else value = expression();
			fields.push({ key, value });
			if (!maybe(',') && !maybe(';')) break;
		}
		take('}');
		return node('table', start, { fields });
	}
	function func(start) {
		take('(');
		const params = [];
		if (!peek(')')) {
			do {
				if (peek('...')) params.push(node('vararg', take('...').start, {}));
				else params.push(identifier());
			} while (maybe(','));
		}
		take(')');
		const body = block(['end']);
		take('end');
		return node('function', start, { params, body });
	}
	function primary() {
		const t = peek();
		if (!t) throw Error('Lua expression');
		if (t.kind === 'string') {
			take();
			return node('string', t.start, { value: t.value });
		}
		if (t.kind === 'number') {
			take();
			return node('number', t.start, { value: Number(t.value) });
		}
		if (['nil', 'true', 'false'].includes(t.value)) {
			take();
			return node('literal', t.start, {
				value: t.value === 'nil' ? null : t.value === 'true'
			});
		}
		if (maybe('function')) return func(t.start);
		if (peek('{')) return table();
		if (maybe('(')) {
			const e = expression();
			take(')');
			return e;
		}
		if (maybe('...')) return node('vararg', t.start, {});
		return identifier();
	}
	function expression(min = 0) {
		let left,
			start = peek()?.start;
		if (peek()?.kind !== 'string' && ['not', '#', '-', '~'].includes(peek()?.value)) {
			const op = take().value;
			left = node('unary', start, { op, value: expression(11) });
		} else left = primary();
		while (true) {
			if (maybe('.')) {
				left = node('field', left.start, {
					object: left,
					key: identifier().name
				});
				continue;
			}
			if (maybe('[')) {
				const key = expression();
				take(']');
				left = node('index', left.start, { object: left, key });
				continue;
			}
			if (maybe(':')) {
				const method = identifier().name;
				left = node('call', left.start, {
					callee: node('field', left.start, { object: left, key: method }),
					args: args(),
					method: true
				});
				continue;
			}
			if (peek('(') || peek('{') || peek()?.kind === 'string') {
				left = node('call', left.start, { callee: left, args: args() });
				continue;
			}
			const op = peek()?.kind === 'string' ? undefined : peek()?.value,
				p = precedence[op];
			if (p === undefined || p < min) break;
			take();
			left = node('binary', left.start, {
				op,
				left,
				right: expression(op === '^' || op === '..' ? p : p + 1)
			});
		}
		return left;
	}
	function statement() {
		const start = peek().start;
		if (maybe(';')) return node('empty', start, {});
		if (maybe('local')) {
			if (maybe('function')) {
				const name = identifier(),
					value = func(start);
				return node('local-function', start, { name, value });
			}
			const names = [identifier()];
			while (maybe(',')) names.push(identifier());
			const values = maybe('=') ? list() : [];
			return node('local', start, { names, values });
		}
		if (maybe('function')) {
			let target = identifier();
			while (maybe('.'))
				target = node('field', start, {
					object: target,
					key: identifier().name
				});
			if (maybe(':'))
				target = node('field', start, {
					object: target,
					key: identifier().name
				});
			return node('assign-function', start, { target, value: func(start) });
		}
		if (maybe('if')) {
			const branches = [];
			let test = expression();
			take('then');
			branches.push({ test, body: block(['elseif', 'else', 'end']) });
			while (maybe('elseif')) {
				test = expression();
				take('then');
				branches.push({ test, body: block(['elseif', 'else', 'end']) });
			}
			if (maybe('else')) branches.push({ test: null, body: block(['end']) });
			take('end');
			return node('if', start, { branches });
		}
		if (maybe('while')) {
			const test = expression();
			take('do');
			const body = block(['end']);
			take('end');
			return node('while', start, { test, body });
		}
		if (maybe('repeat')) {
			const body = block(['until']);
			take('until');
			return node('repeat', start, { body, test: expression() });
		}
		if (maybe('do')) {
			const body = block(['end']);
			take('end');
			return node('do', start, { body });
		}
		if (maybe('for')) {
			const names = [identifier()];
			let values,
				numeric = false;
			if (maybe('=')) {
				numeric = true;
				values = list();
			} else {
				while (maybe(',')) names.push(identifier());
				take('in');
				values = list();
			}
			take('do');
			const body = block(['end']);
			take('end');
			return node('for', start, { names, values, numeric, body });
		}
		if (maybe('return')) {
			const values =
				!peek() || ['end', 'else', 'elseif', 'until', ';'].includes(peek().value) ? [] : list();
			maybe(';');
			return node('return', start, { values });
		}
		if (maybe('break')) return node('break', start, {});
		if (maybe('goto')) return node('goto', start, { label: identifier() });
		if (maybe('::')) {
			const label = identifier();
			take('::');
			return node('label', start, { label });
		}
		const targets = [expression()];
		while (maybe(',')) targets.push(expression());
		if (maybe('=')) return node('assign', start, { targets, values: list() });
		if (targets.length !== 1 || targets[0].type !== 'call')
			throw Error('Lua statement at ' + start);
		return node('call-statement', start, { call: targets[0] });
	}
	function block(stops = []) {
		const out = [];
		while (peek() && !stops.includes(peek().value)) out.push(statement());
		return out;
	}
	const body = block();
	if (at !== tokens.length) throw Error('Lua unparsed owner');
	return { body, source };
}

/** Admits only the native producer's closed direct call grammar across executable control paths. */
function closedProducerCalls(unit, role) {
	if (!unit) return false;
	const expected =
		role === 'agent'
			? {
					require: 2,
					'NativeParent.begin': 1,
					ipairs: 1,
					'ManifestMenu.build': 1,
					'NativeParent.finish': 1
				}
			: role === 'llm'
				? {
						require: closedLlmReadOnlyToggle(unit) ? 2 : 1,
						'NativeParent.begin': 1,
						'ManifestMenu.template_rows': 1,
						'ManifestMenu.render_rows': 1,
						'NativeParent.finish': 2,
						pairs: 3,
						ipairs: 1,
						'ManifestMenu.build': 1
					}
				: null;
	if (!expected) return false;
	let tree;
	try {
		tree = luaProducerTree(unit.text);
	} catch {
		return false;
	}
	const found = {};
	const path = (node) =>
		node?.type === 'id'
			? node.name
			: node?.type === 'field' && path(node.object)
				? path(node.object) + '.' + node.key
				: null;
	function visit(node) {
		if (node === null || typeof node !== 'object') return true;
		if (Array.isArray(node)) return node.every(visit);
		// A function value is deferred; a call whose callee is that function is immediate and refused below.
		if (node.type === 'function') return true;
		if (['do', 'while', 'repeat', 'goto', 'label', 'break'].includes(node.type)) return false;
		if (node.type === 'call') {
			const owner = path(node.callee);
			if (node.method || owner === null || !Object.hasOwn(expected, owner)) return false;
			found[owner] = (found[owner] || 0) + 1;
		}
		return Object.entries(node).every(
			([key, value]) => ['start', 'end'].includes(key) || visit(value)
		);
	}
	if (!visit(tree.body) || !isDeepStrictEqual(found, expected)) return false;
	// The complete source still refuses context mutators in deferred callback values.
	for (let at = 0; at < unit.tokens.length; at++) {
		const token = unit.tokens[at];
		if (
			token.kind === 'identifier' &&
			['rawset', 'setmetatable', 'getfenv', 'setfenv', 'load', 'loadstring', 'dofile'].includes(
				token.value
			) &&
			!['.', ':'].includes(unit.tokens[at - 1]?.value)
		)
			return false;
	}
	return true;
}

/** The Agent's native context port is a literal record with one live callback per key.
 * Rejects last-key-wins overwrites, computed keys and expressions that retain a callback
 * body without constructing its registered command/getter table.
 */
function closedNativeContextRegistration(unit) {
	if (!unit) return false;
	let tree;
	try {
		tree = luaProducerTree(unit.text);
	} catch {
		return false;
	}
	const declarations = tree.body.filter(
		(node) => node.type === 'local' && node.names.some((id) => id.name === 'menu_ctx')
	);
	if (
		declarations.length !== 1 ||
		declarations[0].names.length !== 1 ||
		declarations[0].values.length !== 1
	)
		return false;
	function record(node, keys) {
		if (node?.type !== 'table' || node.fields.length !== keys.length) return null;
		const fields = new Map();
		for (const field of node.fields) {
			if (
				field.key?.type !== 'string' ||
				!keys.includes(field.key.value) ||
				fields.has(field.key.value)
			)
				return null;
			fields.set(field.key.value, field.value);
		}
		return fields.size === keys.length ? fields : null;
	}
	const context = record(declarations[0].values[0], ['commands', 'state_getters']);
	if (!context) return false;
	const commands = record(context.get('commands'), ['agent_mode']);
	const getters = record(context.get('state_getters'), ['llm.agent_mode', 'agent_mode_ready']);
	if (!commands || !getters) return false;
	const shape = (node) =>
		JSON.stringify(node, (key, value) => (['start', 'end'].includes(key) ? undefined : value));
	const expression = (source) => luaProducerTree('local registered = ' + source).body[0].values[0];
	return (
		shape(commands.get('agent_mode')) ===
			shape(
				expression(
					'function(id) if not llm or type(llm.set_agent_mode) ~= "function" then return false end local committed = llm.set_agent_mode(id) == true if committed then changed() end return committed end'
				)
			) &&
		shape(getters.get('llm.agent_mode')) === shape(expression('AgentSettings.get_mode')) &&
		shape(getters.get('agent_mode_ready')) ===
			shape(
				expression('function() return llm ~= nil and type(llm.set_agent_mode) == "function" end')
			)
	);
}

/** Native tickets and engine captures retain their single actual lexical binding.
 * Read-only field access keeps existing backend/native callbacks; bare values may pass
 * only to their declared owners. Unsupported aliases, nested shadows and writes refuse.
 */
function closedCapturedNativeOwners(unit, role) {
	if (!unit || !['llm', 'agent'].includes(role)) return false;
	let tree;
	try {
		tree = luaProducerTree(unit.text);
	} catch {
		return false;
	}
	// Executable producer root locals retain one binding through the final constructor call.
	const rootBindings = new Set();
	for (const statement of tree.body) {
		const declarations =
			statement.type === 'local'
				? statement.names
				: statement.type === 'local-function'
					? [statement.name]
					: [];
		for (const declaration of declarations) {
			if (rootBindings.has(declaration.name)) return false;
			rootBindings.add(declaration.name);
		}
	}
	if (
		tree.body.some(
			(statement) =>
				statement.type === 'assign' &&
				statement.targets.some((target) => target.type === 'id' && rootBindings.has(target.name))
		)
	)
		return false;
	const native = new Set(['ctx', 'llm', 'parent', 'NativeParent', 'ManifestMenu', 'AgentSettings']);
	const path = (node) =>
		node?.type === 'id'
			? node.name
			: node?.type === 'field' && path(node.object)
				? path(node.object) + '.' + node.key
				: null;
	const shape = (node) =>
		JSON.stringify(node, (key, value) => (['start', 'end'].includes(key) ? undefined : value));
	const captures = [
		'local parent = NativeParent.begin(ManifestMenu, "' +
			role +
			'", ctx' +
			(role === 'agent' ? ', AgentSettings)' : ')'),
		'local llm = ctx.llm',
		'local NativeParent = require("ui.menu.ai_parent")',
		...(role === 'agent' ? ['local ManifestMenu = require("infra.manifest_menu")'] : [])
	].map((source) => shape(luaProducerTree(source).body[0]));
	const permittedDeclarations = new Set();
	const permittedEngineReads = new Set();
	for (const wanted of captures) {
		const declarations = tree.body.filter((node) => shape(node) === wanted);
		if (declarations.length !== 1) return false;
		declarations[0].names.forEach((id) => permittedDeclarations.add(id));
		if (declarations[0].names[0]?.name === 'llm')
			permittedEngineReads.add(declarations[0].values[0]);
	}
	function visit(node, parent = null) {
		if (!node || typeof node !== 'object') return true;
		if (Array.isArray(node)) return node.every((child) => visit(child, parent));
		if (
			node.type === 'field' &&
			node.object?.type === 'id' &&
			node.object.name === 'ctx' &&
			node.key === 'llm' &&
			!permittedEngineReads.has(node)
		)
			return false;
		if (node.type === 'id' && native.has(node.name)) {
			if (permittedDeclarations.has(node)) return true;
			if (parent?.type === 'field' && parent.object === node) return true;
			if (
				parent?.type === 'unary' &&
				parent.op === 'not' &&
				['llm', 'parent', 'ManifestMenu'].includes(node.name)
			)
				return true;
			if (
				parent?.type === 'binary' &&
				parent.op === '~=' &&
				node.name === 'llm' &&
				parent.left === node &&
				parent.right?.type === 'literal' &&
				parent.right.value === null
			)
				return true;
			if (
				node.name === 'ManifestMenu' &&
				parent?.type === 'binary' &&
				['and', 'or'].includes(parent.op)
			)
				return true;
			if (parent?.type === 'call') {
				const owner = path(parent.callee),
					argument = parent.args.indexOf(node);
				if (node.name === 'ManifestMenu' && owner === 'NativeParent.begin' && argument === 0)
					return true;
				if (
					node.name === 'AgentSettings' &&
					role === 'agent' &&
					owner === 'NativeParent.begin' &&
					argument === 3
				)
					return true;
				if (node.name === 'parent' && owner === 'NativeParent.finish' && argument === 0)
					return true;
				if (
					node.name === 'ctx' &&
					((owner === 'NativeParent.begin' && argument === 2) ||
						(role === 'llm' && owner === 'pairs' && argument === 0) ||
						(role === 'llm' &&
							owner === 'ManifestMenu.build' &&
							argument === 4 &&
							parent.args[0]?.type === 'string' &&
							parent.args[0].value === 'llm_navigation_rows'))
				)
					return true;
				if (
					node.name === 'llm' &&
					argument === 0 &&
					((role === 'llm' && owner === 'LlmBackendRows.rows') ||
						(role === 'agent' && owner === 'disabled_app_rows'))
				)
					return true;
			}
			return false;
		}
		if (node.type === 'assign' || node.type === 'assign-function') {
			const targets = node.type === 'assign' ? node.targets : [node.target];
			const root = (target) =>
				['field', 'index'].includes(target?.type)
					? root(target.object)
					: target?.type === 'id'
						? target.name
						: null;
			if (targets.some((target) => native.has(root(target)))) return false;
		}
		for (const [key, value] of Object.entries(node)) {
			if (['start', 'end'].includes(key)) continue;
			if (!visit(value, node)) return false;
		}
		return true;
	}
	return visit(tree.body);
}

/** Retained child vectors have only the declared constructor, dense copy and final consumer uses.
 * This finite AST grammar deliberately refuses aliases, rebinding, indexed writes and shadowing.
 * Named native row fields are table keys, not lexical vector references. The subordinate
 * append helper's loop-local rendered binding has its own complete permitted statement.
 */
function closedCompletedChildFlow(unit, role) {
	if (!unit) return false;
	const names =
		role === 'agent' ? ['children'] : role === 'llm' ? ['items', 'rendered', 'status_rows'] : null;
	if (!names) return false;
	const statements =
		role === 'agent'
			? [
					'local children = ManifestMenu.build("agent_menu", "Agent", handlers, nil, menu_ctx, {})',
					'return NativeParent.finish(parent, children)'
				]
			: [
					'local items = {}',
					'local rendered = ManifestMenu and ManifestMenu.build("llm_menu", "LLM", dynamic_handlers, group_builders, llm_ctx, providers) or {}',
					'for _, row in ipairs(rendered) do items[#items + 1] = row end',
					'return NativeParent.finish(parent, items)',
					'local status_rows = ManifestMenu and ManifestMenu.template_rows("linux_llm_absent_rows", {}, {}, {})',
					'if not status_rows then return {} end',
					'return NativeParent.finish(parent, ManifestMenu.render_rows(status_rows, "linux_llm_absent_rows"))',
					'for _, rendered in ipairs(ManifestMenu.render_rows({ row }, id)) do target[#target + 1] = rendered end'
				];
	let tree, patterns;
	try {
		tree = luaProducerTree(unit.text);
		patterns = statements.map((source) => luaProducerTree(source).body[0]);
	} catch {
		return false;
	}
	const shape = (node) =>
		JSON.stringify(node, (key, value) => (['start', 'end'].includes(key) ? undefined : value));
	const wanted = patterns.map(shape),
		found = wanted.map(() => 0),
		permitted = new Set();
	function references(node, action) {
		if (!node || typeof node !== 'object') return;
		if (node.type === 'id' && names.includes(node.name)) action(node);
		for (const [key, value] of Object.entries(node)) {
			if (['start', 'end'].includes(key)) continue;
			if (Array.isArray(value)) value.forEach((child) => references(child, action));
			else references(value, action);
		}
	}
	function visit(node) {
		if (!node || typeof node !== 'object') return;
		const at = wanted.indexOf(shape(node));
		if (at >= 0) {
			found[at]++;
			references(node, (id) => permitted.add(id));
		}
		for (const [key, value] of Object.entries(node)) {
			if (['start', 'end'].includes(key)) continue;
			if (Array.isArray(value)) value.forEach(visit);
			else visit(value);
		}
	}
	visit(tree.body);
	if (!found.every((count) => count === 1)) return false;
	let valid = true;
	references(tree.body, (id) => {
		if (!permitted.has(id)) valid = false;
	});
	return valid;
}

/** The read-only toggle branch retains its exact preference owner, predicate and callback. */
function closedLlmReadOnlyToggle(caller) {
	if (!caller) return false;
	const { positions, rootPositions, body, lex } = luaPublicationParser();
	const fragments = [
		'local Preferences = require("infra.llm_preferences")',
		'local function toggle_ready() return type(llm.toggle) == "function" and ctx.paused ~= true and Preferences.admit() == true end',
		'llm_ctx.commands["llm_toggle"] = function() if not toggle_ready() then return false end if llm.toggle then llm.toggle(ctx.on_menu_changed) end if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end end',
		'llm_ctx.state_getters["llm_toggle_ready"] = toggle_ready'
	];
	const permitted = new Set(),
		starts = [];
	for (const fragment of fragments) {
		const found =
			starts.length === 0 ? rootPositions(caller, fragment) : positions(caller, fragment);
		if (found.length !== 1) return false;
		starts.push(found[0]);
		scriptTokens(fragment, '.lua').forEach((token, offset) => {
			if (token.kind === 'identifier' && ['Preferences', 'toggle_ready'].includes(token.value))
				permitted.add(found[0] + offset);
		});
	}
	if (
		!starts.every((start, index) => index === 0 || starts[index - 1] < start) ||
		rootPositions(caller, fragments[0]).length !== 1 ||
		rootPositions(caller, 'local function toggle_ready()').length !== 1
	)
		return false;
	const predicate = body(caller, 'local function toggle_ready()');
	const expected = lex(
		'return type(llm.toggle) == "function" and ctx.paused ~= true and Preferences.admit() == true'
	);
	if (
		!predicate ||
		!isDeepStrictEqual(
			predicate.tokens.map((t) => [t.kind, t.value]),
			expected.tokens.map((t) => [t.kind, t.value])
		)
	)
		return false;
	return caller.tokens.every(
		(token, at) =>
			token.kind !== 'identifier' ||
			!['Preferences', 'toggle_ready'].includes(token.value) ||
			// Earlier deferred helpers own independent preferences locals before this binding exists.
			(token.value === 'Preferences' && at < starts[0]) ||
			permitted.has(at)
	);
}

/** The LLM child context exposes only its genuine command/getter registrations and exact copy routes. */
function closedLlmContext(caller) {
	const { positions } = luaPublicationParser();
	const statements = [
		'local llm_ctx = {}',
		'llm_ctx.commands = {}',
		'llm_ctx.commands[key] = value',
		'llm_ctx.commands["scope_restore"] = function()',
		'llm_ctx.commands["llm_toggle"] = function()',
		'llm_ctx.state_getters = {}',
		'llm_ctx.state_getters[key] = value',
		'llm_ctx.state_getters["llm_enabled"] = function() return enabled end',
		closedLlmReadOnlyToggle(caller)
			? 'llm_ctx.state_getters["llm_toggle_ready"] = toggle_ready'
			: 'llm_ctx.state_getters["llm_toggle_ready"] = function() return type(llm.toggle) == "function" and ctx.paused ~= true end',
		'llm_ctx[key] = value',
		'ManifestMenu.build("llm_menu", "LLM", dynamic_handlers, group_builders, llm_ctx, providers)'
	];
	const allowed = new Set();
	for (const statement of statements) {
		const starts = positions(caller, statement);
		if (starts.length !== 1) return false;
		const wanted = scriptTokens(statement, '.lua');
		wanted.forEach((token, n) => {
			if (token.value === 'llm_ctx') allowed.add(starts[0] + n);
		});
	}
	return caller.tokens.every(
		(token, at) => token.kind !== 'identifier' || token.value !== 'llm_ctx' || allowed.has(at)
	);
}

/** Native context and constructor tickets are read-only throughout their reachable source bodies. */
function closedNativeReads(unit, allowContext = false) {
	if (!unit) return false;
	for (let at = 0; at < unit.tokens.length; at++) {
		const t = unit.tokens[at];
		if (t.kind !== 'identifier' || !['ctx', 'llm', 'parent'].includes(t.value)) continue;
		let end = at + 1;
		if (unit.tokens[end]?.value === '.') end += 2;
		if (unit.tokens[end]?.value === '[') {
			const closing = unit.tokens.findIndex((token, n) => n > end && token.value === ']');
			if (closing < 0) return false;
			end = closing + 1;
		}
		if (unit.tokens[end]?.value === '=' && unit.tokens[end + 1]?.value !== '=') {
			if (
				unit.tokens[at - 1]?.value !== 'local' ||
				!(['llm', 'parent'].includes(t.value) || (allowContext && t.value === 'ctx')) ||
				unit.scopes[at] !== 0
			)
				return false;
		}
	}
	return true;
}

/** The tray supports only its exact historical route or the adopted inert disabled row.
 * The current branch retains the same declared row and single native append before Quit;
 * its caption call retains the actual imported i18n helper, with no local replacement.
 */
function nativeLinuxDisabledTopLevelBranch(unit, builder) {
	if (!unit || !builder) return null;
	const { lex, positions, rootPositions, body, one } = luaPublicationParser();
	const prefix =
		'local build = builders[id] if not build then Logger.error(LOG, "No builder for top-level row \'%s\' — the entry is missing.", tostring(id))';
	const suffix = 'elseif id == "quit" then quit_row = build(ctx)';
	const disabled =
		'elseif row.disabled == true then rows[#rows + 1] = { label = i18n_safe(row.i18n), disabled = true, disabled_reason_key = row.reason_key }';
	const historical = one(unit, prefix + ' ' + suffix);
	const current = one(unit, prefix + ' ' + disabled + ' ' + suffix);
	if (historical === current) return null;
	// Every source-row use belongs to the actual declared loop and its retained fields.
	// Extra aliases, lexical shadows and indexed/field writes cannot supply metadata.
	const rowReads = [
		'for _, row in ipairs(declared) do',
		'if type(row) == "table" then',
		'local id = row.id',
		'elseif _row_is_for_linux(row) then',
		'elseif ctx.paused == true and row.greyed_when_paused == true then',
		...(current ? [disabled] : [])
	];
	const captured = new Set();
	for (const statement of rowReads) {
		const starts = positions(unit, statement);
		if (starts.length !== 1) return null;
		scriptTokens(statement, '.lua').forEach((token, n) => {
			if (token.kind === 'identifier' && token.value === 'row') captured.add(starts[0] + n);
		});
	}
	if (
		unit.tokens.some(
			(token, at) => token.kind === 'identifier' && token.value === 'row' && !captured.has(at)
		) ||
		positions(unit, 'id =').filter((at) => unit.tokens[at + 2]?.value !== '=').length !== 1
	)
		return null;
	if (historical) return 0;
	const caption = body(builder, 'function i18n_safe(key)');
	const expected = lex(
		'local ok, i18n = pcall(require, "infra.i18n") if ok and i18n and type(i18n.get) == "function" then local val = i18n.get(key) if val and val ~= key then return val end end return key'
	);
	const shape = (value) => value?.tokens.map((token) => [token.kind, token.value]);
	if (
		rootPositions(builder, 'function i18n_safe(key)').length !== 1 ||
		positions(builder, 'local i18n_safe').length ||
		positions(builder, 'i18n_safe =').length ||
		unit.tokens.filter((token) => token.kind === 'identifier' && token.value === 'i18n_safe')
			.length !== 1 ||
		!isDeepStrictEqual(shape(caption), shape(expected))
	)
		return null;
	return 1;
}

/** Admits the small executable tray/caller call grammar, including diagnostics, without wildcard calls. */
function closedPublicationCalls(unit, role, builder) {
	const disabled = role === 'tray' ? nativeLinuxDisabledTopLevelBranch(unit, builder) : 0;
	if (disabled === null) return false;
	const expected =
		role === 'tray'
			? {
					type: 3,
					_build_header: 1,
					get_array: 1,
					error: 4,
					ipairs: 1,
					_row_is_for_linux: 1,
					tostring: 1,
					build: 3,
					_grey_for_pause: 1,
					render_rows: 1,
					...(disabled === 1 ? { i18n_safe: 1 } : {})
				}
			: role === 'agentCaller'
				? {
						error: 1,
						require: 1,
						build: 1,
						ask: 1,
						zenity_plain: 2,
						show_error: 1
					}
				: null;
	if (!unit || !expected) return false;
	const found = {};
	for (let at = 0; at < unit.tokens.length; at++) {
		const t = unit.tokens[at];
		if (
			t.kind !== 'identifier' ||
			unit.tokens[at + 1]?.value !== '(' ||
			['function', 'not', 'and', 'or'].includes(t.value) ||
			unit.tokens[at - 1]?.value === 'function'
		)
			continue;
		found[t.value] = (found[t.value] || 0) + 1;
		if (t.value === 'error' && unit.tokens[at - 2]?.value !== 'Logger') return false;
		if (t.value === 'get_array' || t.value === 'render_rows') {
			if (unit.tokens[at - 2]?.value !== 'ManifestMenu') return false;
		}
		if (t.value === 'ask' && unit.tokens[at - 2]?.value !== 'TextPrompt') return false;
	}
	return isDeepStrictEqual(found, expected);
}

/** Closed declared Linux root protocol, with the same native handlers and Quit-last policy.
 * This additive executable template retains the historical direct-source branch below.
 * All native control paths, receiver checks, array identity and render output are mandatory;
 * comments/formatting are inert. It does not supply runtime or physical-input authority.
 */
function declaredLinuxNativeTray(unit, builder) {
	if (!unit || !builder || !declaredFacadeOwner(builder, luaPublicationParser())) return false;
	const { lex, body, rootPositions, positions } = luaPublicationParser();
	const expected = `
	if not separator_facade_current() then return {} end
	local ctx = type(ctx) == "table" and ctx or {}
	local rows = {}

	rows[#rows + 1] = _build_header(ctx)

	local builders = {
		["keyboard_layout"] = _build_layouts,
		["hotstrings"]      = _build_hotstrings,
		["llm"]             = _build_llm,
		["agent"]           = _build_agent,
		["metrics"]         = _build_metrics,
		["shortcuts"]       = _build_shortcuts,
		["tap_holds"]       = _build_tap_holds,
		["gestures"]        = _build_gestures,
		["configuration"]   = _build_configuration,
		["language"]        = _build_language,
		["about"]           = _build_about,
		["reload"]          = _build_reload,
		["quit"]            = _build_quit,
		["debug"]           = _build_debug,
	}

	if not separator_facade_current() then return {} end
	local declared = ManifestMenu.get_array("top_level")
	if not separator_facade_current() then return {} end
	local receive_separator, source_rows = separator_factory()
	if not separator_facade_current() or type(receive_separator) ~= "function"
		or type(declared) ~= "table" or not rawequal(declared, source_rows) then
		Logger.error(LOG, "The canonical top-level boundary source is unavailable.")
		return {}
	end
	if #declared == 0 then
		Logger.error(LOG, "The manifest declares no top-level row — the tray would be empty.")
		return {}
	end

	local quit_row = nil

	for _, row in ipairs(declared) do
		if not separator_facade_current() or not receive_separator("current") then return {} end
		if type(row) == "table" then
			local id = row.id
			if id == "---" then
				if _row_is_for_linux(row) then
					local boundary = receive_separator(row)
					if not boundary then return {} end
					rows[#rows + 1] = boundary
				end
			elseif _row_is_for_linux(row) then
				local build = builders[id]
				if not build then
					Logger.error(LOG, "No builder for top-level row '%s' — the entry is missing.", tostring(id))
				elseif row.disabled == true then
					rows[#rows + 1] = { label = i18n_safe(row.i18n), disabled = true,
						disabled_reason_key = row.reason_key }
				elseif id == "quit" then
					quit_row = build(ctx)
				elseif ctx.paused == true and row.greyed_when_paused == true then
					rows[#rows + 1] = _grey_for_pause(build(ctx))
				else
					rows[#rows + 1] = build(ctx)
				end
			end
		end
		if not separator_facade_current() or not receive_separator("current") then return {} end
	end

	if quit_row then
		local boundary = receive_separator("linux_quit_last")
		if not boundary then return {} end
		rows[#rows + 1] = boundary
		rows[#rows + 1] = quit_row
	else
		Logger.error(LOG, "The manifest declares no quit row for this driver — the tray cannot be closed.")
	end

	if not separator_facade_current() or not receive_separator("current") then return {} end
	local rendered = separator_render(rows, "top_level")
	if not separator_facade_current() or not receive_separator("current") then return {} end
	return rendered`;
	const headerExpected = expected
		.replace(
			'rows[#rows + 1] = _build_header(ctx)',
			'local header, header_current = _build_header(ctx) if not header or type(header_current) ~= "function" or not header_current() then return {} end rows[#rows + 1] = header'
		)
		.replace(
			'if not separator_facade_current() or not receive_separator("current") then return {} end\n\tlocal rendered = separator_render(rows, "top_level")\n\tif not separator_facade_current() or not receive_separator("current") then return {} end',
			'if not separator_facade_current() or not receive_separator("current") or not header_current() then return {} end\n\tlocal rendered = separator_render(rows, "top_level")\n\tif not separator_facade_current() or not receive_separator("current") or not header_current() then return {} end'
		);
	const shape = (value) => value?.tokens.map((t) => [t.kind, t.value]);
	// The original historical inert-row absence remains an independent supported route.
	const historical = expected.replace(
		/elseif row\.disabled == true then\s+rows\[#rows \+ 1\] = \{ label = i18n_safe\(row\.i18n\), disabled = true,\s+disabled_reason_key = row\.reason_key \}/,
		''
	);
	const headerHistorical = headerExpected.replace(
		/elseif row\.disabled == true then\s+rows\[#rows \+ 1\] = \{ label = i18n_safe\(row\.i18n\), disabled = true,\s+disabled_reason_key = row\.reason_key \}/,
		''
	);
	const headerProtocol =
		isDeepStrictEqual(shape(unit), shape(lex(headerExpected))) ||
		isDeepStrictEqual(shape(unit), shape(lex(headerHistorical)));
	if (headerProtocol && !declaredLinuxHeaderOwner(builder)) return false;
	if (
		!headerProtocol &&
		!isDeepStrictEqual(shape(unit), shape(lex(expected))) &&
		!isDeepStrictEqual(shape(unit), shape(lex(historical)))
	)
		return false;
	const caption = body(builder, 'function i18n_safe(key)');
	return (
		rootPositions(builder, 'function i18n_safe(key)').length === 1 &&
		!positions(builder, 'local i18n_safe').length &&
		!positions(builder, 'i18n_safe =').length &&
		isDeepStrictEqual(
			shape(caption),
			shape(
				lex(
					'local ok, i18n = pcall(require, "infra.i18n") if ok and i18n and type(i18n.get) == "function" then local val = i18n.get(key) if val and val ~= key then return val end end return key'
				)
			)
		)
	);
}

/** Requires each executable outer branch/loop to be a declared publication/refusal route. */
function closedNativeControl(unit, role, builder) {
	if (!unit || !closedNativeReads(unit, role === 'tray')) return false;
	if (role === 'tray' && declaredLinuxNativeTray(unit, builder)) return true;
	const { rootPositions, positions } = luaPublicationParser();
	for (const at of unit.closes.keys())
		if (['do', 'while', 'repeat'].includes(unit.tokens[at]?.value)) return false;
	const allowed = {
		agent: ['if not parent then return nil end'],
		llm: ['if not parent then return nil end', 'if not llm then'],
		agentCaller: ['if not ManifestMenu then'],
		tray: [
			'if #declared == 0 then',
			'if quit_row then',
			'if not (ManifestMenu and type(ManifestMenu.render_rows) == "function") then'
		]
	}[role];
	if (
		!allowed ||
		rootPositions(unit, 'if').length !== allowed.length ||
		allowed.some((statement) => rootPositions(unit, statement).length !== 1)
	)
		return false;
	if (
		rootPositions(unit, 'do').length ||
		rootPositions(unit, 'while').length ||
		rootPositions(unit, 'repeat').length ||
		rootPositions(unit, 'return').length !== 1
	)
		return false;
	const fors = rootPositions(unit, 'for');
	const expected =
		role === 'agent'
			? ['for _, system in ipairs({ "system1", "system2" }) do']
			: role === 'llm'
				? [
						'for key, value in pairs(ctx) do llm_ctx[key] = value end',
						'for key, value in pairs(ctx.commands or {}) do llm_ctx.commands[key] = value end',
						'for key, value in pairs(ctx.state_getters or {}) do llm_ctx.state_getters[key] = value end',
						'for _, row in ipairs(rendered) do items[#items + 1] = row end'
					]
				: role === 'tray'
					? ['for _, row in ipairs(declared) do']
					: [];
	if (
		fors.length !== expected.length ||
		expected.some((statement) => rootPositions(unit, statement).length !== 1)
	)
		return false;
	if (['tray', 'agentCaller'].includes(role) && !closedPublicationCalls(unit, role, builder))
		return false;
	if (role === 'tray') {
		const disabled = nativeLinuxDisabledTopLevelBranch(unit, builder);
		if (disabled === null) return false;
		const conditions = [
			'if type(row) == "table" then',
			'if id == "---" then',
			'if not build then',
			'elseif _row_is_for_linux(row) then',
			'elseif id == "quit" then',
			'elseif ctx.paused == true and row.greyed_when_paused == true then',
			...(disabled === 1 ? ['elseif row.disabled == true then'] : [])
		];
		if (
			positions(unit, 'if').length !== 6 ||
			positions(unit, 'elseif').length !== 3 + disabled ||
			positions(unit, 'return').length !== 3 ||
			conditions.some((text) => positions(unit, text).length !== 1) ||
			positions(unit, 'rows [').length !== 6 + disabled ||
			positions(unit, 'rows [ # rows + 1 ] =').length !== 6 + disabled ||
			positions(unit, 'build ( ctx )').length !== 3 ||
			positions(unit, 'ManifestMenu =').length
		)
			return false;
		if (
			positions(unit, 'local build =').length !== 1 ||
			positions(unit, 'build =').length !== 1 ||
			positions(unit, 'builders =').length !== 1 ||
			positions(unit, 'declared =').filter((at) => unit.tokens[at + 2]?.value !== '=').length !==
				1 ||
			positions(unit, 'rows =').length !== 1
		)
			return false;
	}
	return true;
}

function nativeLinuxAiParentPublication(sources, manifest, kind, platform) {
	if (
		platform !== 'linux' ||
		!['llm', 'agent'].includes(kind) ||
		!sources ||
		!manifest ||
		!Array.isArray(manifest.top_level)
	)
		return false;
	const { lex, positions, rootPositions, body, one } = luaPublicationParser();
	const tokenShape = (unit) =>
		unit?.tokens.map((token) => [
			token.kind,
			token.value,
			token.kind === 'string' ? unit.text.slice(token.start, token.end) : null
		]);
	const algorithm = lex(sources['linux/ui/menu/ai_parent.lua']);
	if (
		!algorithm ||
		!isDeepStrictEqual(tokenShape(algorithm), tokenShape(lex(LINUX_AI_PARENT_ALGORITHM)))
	)
		return false;
	const expectedParent = {
		type: 'group',
		id: kind + '_parent_linux',
		i18n: 'menu.' + kind + '.title',
		checked_when: [kind + '_parent_enabled'],
		disabled_when: [kind + '_parent_ready'],
		disabled_reason_key: 'menu.llm.unavailable',
		platforms: ['linux'],
		unavailable: 'hide'
	};
	const parentFrame = kind === 'llm' ? 'llm_native_parent_linux' : 'agent_native_parent';
	if (!isDeepStrictEqual(manifest[parentFrame], [expectedParent])) return false;
	const nativeTop = manifest.top_level.filter(
		(row) => row.id === kind && (!row.platforms || row.platforms.includes('linux'))
	);
	if (
		nativeTop.length !== 1 ||
		!Array.isArray(manifest[kind + '_menu']) ||
		manifest[kind + '_menu'].length === 0
	)
		return false;
	const builder = lex(sources['linux/ui/menu/menu_builder.lua']);
	const agent = lex(sources['linux/ui/menu/agent_rows.lua']);
	if (
		!builder ||
		!agent ||
		!one(builder, 'local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")') ||
		!one(agent, 'local AgentSettings = require("modules.llm.agent_settings")') ||
		positions(builder, 'local require').length ||
		positions(builder, 'require =').length ||
		positions(agent, 'local require').length ||
		positions(agent, 'require =').length ||
		positions(agent, 'AgentSettings =').length !== 1
	)
		return false;
	if (
		!closedModuleExport(builder, lex, rootPositions) ||
		!closedModuleExport(agent, lex, rootPositions) ||
		!closedSiblingRendererBindings(builder) ||
		!closedOwnerReferences(agent, ['ManifestMenu', 'AgentSettings']) ||
		!closedHelperReferences(builder, [
			'_build_llm',
			'_build_agent',
			'_grey_for_pause',
			'_row_is_for_linux'
		])
	)
		return false;
	const paused = body(builder, 'local function _grey_for_pause(row)');
	const visible = body(builder, 'local function _row_is_for_linux(row)');
	if (
		!isDeepStrictEqual(
			tokenShape(paused),
			tokenShape(
				lex(
					'if type(row) ~= "table" or row.separator then return row end row.disabled = true row.submenu = nil row.items = nil row.action = nil return row'
				)
			)
		) ||
		!isDeepStrictEqual(
			tokenShape(visible),
			tokenShape(
				lex(
					'if type(row.platforms) ~= "table" then return true end for _, p in ipairs(row.platforms) do if p == "linux" then return true end end return false'
				)
			)
		)
	)
		return false;
	const wholeAgentCaller = body(builder, 'local function _build_agent(ctx)');
	const wholeLlmCaller = body(builder, 'local function _build_llm(ctx)');
	const wholeAgentProducer = body(agent, 'function M.build(ctx, dialogs)');
	const wholeRefresh = body(wholeAgentProducer, 'local function changed()');
	if (
		!closedChangedOwner(wholeAgentProducer) ||
		!closedLlmContext(wholeLlmCaller) ||
		!closedHelperReferences(agent, ['system_rows', 'disabled_app_rows', 'append'])
	)
		return false;
	if (
		wholeAgentProducer.tokens.filter(
			(token) => token.kind === 'identifier' && token.value === 'menu_ctx'
		).length !== 2
	)
		return false;
	if (
		!one(
			wholeAgentProducer,
			'local parent = NativeParent.begin(ManifestMenu, "agent", ctx, AgentSettings) if not parent then return nil end'
		) ||
		!one(
			wholeAgentProducer,
			'local children = ManifestMenu.build("agent_menu", "Agent", handlers, nil, menu_ctx, {}) return NativeParent.finish(parent, children)'
		) ||
		!one(
			wholeLlmCaller,
			'local parent = NativeParent.begin(ManifestMenu, "llm", ctx) if not parent then return nil end'
		) ||
		!one(
			wholeLlmCaller,
			'local rendered = ManifestMenu and ManifestMenu.build("llm_menu", "LLM", dynamic_handlers, group_builders, llm_ctx, providers) or {} for _, row in ipairs(rendered) do items[#items + 1] = row end'
		)
	)
		return false;
	if (
		!closedNativeControl(wholeAgentCaller, 'agentCaller') ||
		!closedNativeControl(wholeLlmCaller, 'llm') ||
		!closedNativeControl(wholeAgentProducer, 'agent') ||
		!closedProducerCalls(wholeAgentProducer, 'agent') ||
		!closedProducerCalls(wholeLlmCaller, 'llm') ||
		!closedNativeContextRegistration(wholeAgentProducer) ||
		!closedCapturedNativeOwners(wholeAgentProducer, 'agent') ||
		!closedCapturedNativeOwners(wholeLlmCaller, 'llm') ||
		!closedCompletedChildFlow(wholeAgentProducer, 'agent') ||
		!closedCompletedChildFlow(wholeLlmCaller, 'llm') ||
		!closedOwnerReferences(wholeAgentProducer, ['NativeParent', 'ManifestMenu', 'AgentSettings']) ||
		!closedOwnerReferences(wholeLlmCaller, ['NativeParent', 'ManifestMenu']) ||
		!isDeepStrictEqual(
			tokenShape(wholeRefresh),
			tokenShape(lex('if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end'))
		)
	)
		return false;
	for (const unit of [builder, agent])
		for (const name of [
			'type',
			'ipairs',
			'pairs',
			'next',
			'rawget',
			'rawequal',
			'getmetatable',
			'package',
			'require'
		])
			if (
				positions(unit, 'local ' + name).length ||
				positions(unit, 'function ' + name + '(').length ||
				positions(unit, name + ' =').some(
					(at) =>
						unit.tokens[at + 2]?.value !== '=' && !['{', ','].includes(unit.tokens[at - 1]?.value)
				)
			)
				return false;
	const tray = body(builder, 'function M.build(ctx)');
	if (!closedNativeDispatch(builder, tray)) return false;
	const caller = body(builder, 'local function _build_' + kind + '(ctx)');
	const declaredTray = declaredLinuxNativeTray(tray, builder);
	if (
		!tray ||
		!caller ||
		!closedNativeControl(tray, 'tray', builder) ||
		!one(tray, '["' + kind + '"] = _build_' + kind + ',') ||
		positions(builder, '_build_' + kind + ' =').length ||
		!(
			one(tray, 'local declared = ManifestMenu and ManifestMenu.get_array("top_level") or {}') ||
			declaredTray
		) ||
		!one(tray, 'for _, row in ipairs(declared) do') ||
		!one(tray, 'local build = builders[id]') ||
		!one(tray, 'rows[#rows + 1] = build(ctx)') ||
		!one(tray, 'rows[#rows + 1] = _grey_for_pause(build(ctx))') ||
		!(one(tray, 'return ManifestMenu.render_rows(rows, "top_level")') || declaredTray)
	)
		return false;
	const terminal = (unit, statement) => {
		const starts = rootPositions(unit, statement);
		return (
			starts.length === 1 &&
			starts[0] + scriptTokens(statement, '.lua').length === unit.tokens.length
		);
	};
	if (!terminal(tray, 'return ManifestMenu.render_rows(rows, "top_level")') && !declaredTray)
		return false;
	if (kind === 'agent') {
		const producer = body(agent, 'function M.build(ctx, dialogs)');
		if (!closedNativeReads(producer)) return false;
		if (
			!closedNativeControl(caller, 'agentCaller') ||
			!closedOwnerReferences(producer, ['NativeParent', 'ManifestMenu', 'AgentSettings'])
		)
			return false;
		const acknowledgedRefresh = body(producer, 'local function changed()');
		if (
			!isDeepStrictEqual(
				tokenShape(acknowledgedRefresh),
				tokenShape(lex('if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end'))
			)
		)
			return false;
		if (
			!producer ||
			!closedNativeControl(producer, 'agent') ||
			!terminal(
				caller,
				'return require("ui.menu.agent_rows").build(ctx, { prompt = function(title, text, initial, hidden, choices) return TextPrompt.ask(title, zenity_plain(text), initial, hidden, choices) end, error = function(text) show_error(zenity_plain(text)) end, })'
			) ||
			!one(producer, 'local ManifestMenu = require("infra.manifest_menu")') ||
			!one(producer, 'local NativeParent = require("ui.menu.ai_parent")') ||
			positions(producer, 'NativeParent =').length !== 1 ||
			positions(producer, 'ManifestMenu =').length !== 1 ||
			!one(
				producer,
				'local parent = NativeParent.begin(ManifestMenu, "agent", ctx, AgentSettings)'
			) ||
			!one(producer, 'if not parent then return nil end') ||
			!one(producer, 'local committed = llm.set_agent_mode(id) == true') ||
			!one(producer, '["llm.agent_mode"] = AgentSettings.get_mode,') ||
			!one(
				producer,
				'local children = ManifestMenu.build("agent_menu", "Agent", handlers, nil, menu_ctx, {})'
			) ||
			positions(producer, 'children =').length !== 1 ||
			positions(producer, 'parent =').length !== 1 ||
			!terminal(producer, 'return NativeParent.finish(parent, children)')
		)
			return false;
		const nativeCommand = body(producer, 'agent_mode = function(id)');
		if (
			!isDeepStrictEqual(
				tokenShape(nativeCommand),
				tokenShape(
					lex(
						'if not llm or type(llm.set_agent_mode) ~= "function" then return false end local committed = llm.set_agent_mode(id) == true if committed then changed() end return committed'
					)
				)
			)
		)
			return false;
		const beginAt = positions(producer, 'NativeParent.begin')[0];
		const childAt = positions(producer, 'ManifestMenu.build')[0];
		if (beginAt === undefined || childAt === undefined || beginAt >= childAt) return false;
	} else {
		if (!closedOwnerReferences(caller, ['NativeParent', 'ManifestMenu'])) return false;
		if (
			!closedNativeControl(caller, 'llm') ||
			!one(caller, 'local NativeParent = require("ui.menu.ai_parent")') ||
			positions(caller, 'NativeParent =').length !== 1 ||
			!one(caller, 'local parent = NativeParent.begin(ManifestMenu, "llm", ctx)') ||
			!one(caller, 'if not parent then return nil end') ||
			!one(caller, 'local items = {}') ||
			rootPositions(caller, 'items =').length !== 1 ||
			positions(caller, 'parent =').length !== 1 ||
			!one(
				caller,
				'local rendered = ManifestMenu and ManifestMenu.build("llm_menu", "LLM", dynamic_handlers, group_builders, llm_ctx, providers) or {}'
			) ||
			!one(caller, 'for _, row in ipairs(rendered) do items[#items + 1] = row end') ||
			!one(caller, 'if llm.toggle then llm.toggle(ctx.on_menu_changed) end') ||
			!terminal(caller, 'return NativeParent.finish(parent, items)')
		)
			return false;
		const nativeCommand = body(caller, 'llm_ctx.commands["llm_toggle"] = function()');
		if (
			!isDeepStrictEqual(
				tokenShape(nativeCommand),
				tokenShape(
					lex(
						closedLlmReadOnlyToggle(caller)
							? 'if not toggle_ready() then return false end if llm.toggle then llm.toggle(ctx.on_menu_changed) end if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end'
							: 'if type(llm.toggle) ~= "function" then return false end if llm.toggle then llm.toggle(ctx.on_menu_changed) end if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end'
					)
				)
			)
		)
			return false;
		const beginAt = positions(caller, 'NativeParent.begin')[0];
		const childAt = positions(caller, 'ManifestMenu.build("llm_menu"')[0];
		if (beginAt === undefined || childAt === undefined || beginAt >= childAt) return false;
	}
	return true;
}

/** The actual Layout module completes its declared subtree before the canonical native parent receives it. */
function fixedNativeParentBindingEvents(unit, name) {
	const tokens = unit.tokens,
		depths = unit.scopes,
		tables = [],
		fields = new Set();
	for (let at = 0; at < tokens.length; at++) {
		if (tokens[at].kind === 'symbol' && tokens[at].value === '{') tables.push(depths[at]);
		else if (tokens[at].kind === 'symbol' && tokens[at].value === '}') tables.pop();
		// All immediate constructor identifiers are data expression reads,
		// including values before another field's comma/key/equals. Nested
		// function bodies have a deeper scope and retain binding admission.
		else if (tables.length && tables.at(-1) === depths[at] && tokens[at].kind === 'identifier')
			fields.add(at);
	}
	// After a tracked bare variable, parse the remaining Lua assignment lvalues.
	// Arguments, comparisons and data references cannot finish this grammar.
	const symbol = (at, value) => tokens[at]?.kind === 'symbol' && tokens[at].value === value;
	const balancedEnd = (start) => {
		const closing = { '(': ')', '[': ']', '{': '}' },
			stack = [];
		for (let at = start; at < tokens.length; at++) {
			if (tokens[at].kind !== 'symbol') continue;
			if (closing[tokens[at].value]) stack.push(closing[tokens[at].value]);
			else if ([')', ']', '}'].includes(tokens[at].value)) {
				if (stack.pop() !== tokens[at].value) return null;
				if (stack.length === 0) return at + 1;
			}
		}
		return null;
	};
	const lvalueEnd = (start) => {
		let at = start,
			assignable = false;
		const keywords = new Set([
			'and',
			'break',
			'do',
			'else',
			'elseif',
			'end',
			'false',
			'for',
			'function',
			'goto',
			'if',
			'in',
			'local',
			'nil',
			'not',
			'or',
			'repeat',
			'return',
			'then',
			'true',
			'until',
			'while'
		]);
		if (tokens[at]?.kind === 'identifier' && !keywords.has(tokens[at].value)) {
			at++;
			assignable = true;
		} else if (symbol(at, '(')) at = balancedEnd(at);
		else return null;
		if (at === null) return null;
		while (at < tokens.length) {
			if (symbol(at, '.')) {
				if (tokens[at + 1]?.kind !== 'identifier' || keywords.has(tokens[at + 1].value))
					return null;
				at += 2;
				assignable = true;
			} else if (symbol(at, '[')) {
				at = balancedEnd(at);
				if (at === null) return null;
				assignable = true;
			} else if (symbol(at, '(') || symbol(at, '{')) {
				at = balancedEnd(at);
				if (at === null) return null;
				assignable = false;
			} else if (tokens[at]?.kind === 'string') {
				at++;
				assignable = false;
			} else if (symbol(at, ':')) {
				if (tokens[at + 1]?.kind !== 'identifier' || keywords.has(tokens[at + 1].value))
					return null;
				at += 2;
				if (symbol(at, '(') || symbol(at, '{')) at = balancedEnd(at);
				else if (tokens[at]?.kind === 'string') at++;
				else return null;
				if (at === null) return null;
				assignable = false;
			} else break;
		}
		return assignable ? at : null;
	};
	const assignmentAfter = (start) => {
		let after = start + 1;
		while (symbol(after, ',')) {
			after = lvalueEnd(after + 1);
			if (after === null) return false;
		}
		return symbol(after, '=') && !symbol(after + 1, '=');
	};
	const events = new Map();
	const add = (at, kind) => {
		const event = events.get(at) || new Set();
		event.add(kind);
		events.set(at, event);
	};
	for (let at = 0; at < tokens.length; at++) {
		if (
			tokens[at].kind !== 'identifier' ||
			tokens[at].value !== name ||
			fields.has(at) ||
			['.', ':', '['].includes(tokens[at - 1]?.value)
		)
			continue;
		if (assignmentAfter(at)) add(at, 'assignment');
		let before = at - 1;
		while (tokens[before]?.value === ',' && tokens[before - 1]?.kind === 'identifier') before -= 2;
		if (tokens[before]?.value === 'local') add(at, 'local');
		if (tokens[at - 1]?.value === 'function' && tokens[at + 1]?.value === '(') add(at, 'function');
	}
	for (let at = 0; at < tokens.length; at++) {
		if (tokens[at].kind !== 'identifier' || ['.', ':'].includes(tokens[at - 1]?.value)) continue;
		if (tokens[at].value === 'function') {
			let opening = at + 1;
			while (tokens[opening] && tokens[opening].value !== '(') opening++;
			for (
				let parameter = opening + 1;
				tokens[parameter] && tokens[parameter].value !== ')';
				parameter++
			) {
				if (tokens[parameter].kind === 'identifier' && tokens[parameter].value === name)
					add(parameter, 'parameter');
			}
		} else if (tokens[at].value === 'for') {
			for (
				let variable = at + 1;
				tokens[variable] && !['=', 'in', 'do'].includes(tokens[variable].value);
				variable++
			) {
				if (tokens[variable].kind === 'identifier' && tokens[variable].value === name)
					add(variable, 'iterator');
			}
		}
	}
	return events;
}

function nativeMacLayoutTopLevelPublication(builderSource, layoutSource, manifest) {
	if (
		!manifest ||
		typeof manifest !== 'object' ||
		!Array.isArray(manifest.top_level) ||
		!require('./menu-native-layout-binding.cjs').nativeLayoutTemplatePublication(
			layoutSource,
			'layout_native_parent',
			manifest.layout_native_parent
		) ||
		!declaredMacTopLevelPublication(builderSource)
	)
		return false;
	const parents = manifest.top_level?.filter((row) => row.id === 'keyboard_layout');
	if (
		!isDeepStrictEqual(parents, [
			{
				type: 'group',
				id: 'keyboard_layout',
				i18n: 'menu.layout.title',
				rows: [],
				checked_when: ['layout_enabled'],
				greyed_when_paused: true
			}
		])
	)
		return false;
	const { lex, body, positions } = luaPublicationParser();
	const whole = lex(builderSource),
		generate = body(whole, 'function M.generate(ctx, menu_mods, actions)');
	const stage = body(generate, '["keyboard_layout"] = function()');
	const module = body(generate, 'local function module_rows(key, arg)');
	const expectedStage = lex(
		'\n\t\t\tlocal receive = ManifestMenu.group_receiver("top_level", "keyboard_layout")\n\t\t\tif not receive then return {} end\n\t\t\tlocal rows = module_rows("keyboard_layout")\n\t\t\tlocal original = #rows == 1 and rawget(rows, 1) or nil\n\t\t\tlocal submenu = type(original) == "table" and getmetatable(original) == nil\n\t\t\t\tand rawget(original, "submenu") or nil\n\t\t\tif type(submenu) ~= "table" then return {} end\n\t\t\t-- macOS owns a system input source, so the existing parent has no enable tick.\n\t\t\tlocal parent = receive(submenu, { layout_enabled = function() return nil end })\n\t\t\treturn parent and { parent } or {}\n\t\t'
	);
	const collector = body(generate, 'local function collect(label, fn, arg)');
	const expectedCollector = lex(
		'\t\tlocal rows = {}\n\t\tlocal result = Logger.build(LOG, label, fn, arg)\n\t\tif result then\n\t\t\tif type(result) == "table" and result[1] ~= nil then\n\t\t\t\t-- Result is a list (build_groups)\n\t\t\t\tfor _, it in ipairs(result) do rows[#rows + 1] = it end\n\t\t\telse\n\t\t\t\trows[#rows + 1] = result\n\t\t\tend\n\t\t\tLogger.debug(LOG, string.format("Component \'%s\' added successfully.", label))\n\t\telse\n\t\t\tLogger.warn(LOG, string.format("Component \'%s\' missing or in error \u2014 ignored.", label))\n\t\tend\n\t\treturn rows'
	);
	const expectedModule = lex(
		'local mod = menu_mods[key]\n\t\tif type(mod) ~= "table" or type(mod.build) ~= "function" then\n\t\t\tLogger.warn(LOG, "Menu module \'%s\' missing \u2014 its row is not drawn.", key)\n\t\t\treturn {}\n\t\tend\n\t\treturn collect(key .. ".build", mod.build, arg or ctx)'
	);
	const same = (a, b) =>
		!!a &&
		!!b &&
		isDeepStrictEqual(
			a.tokens.map((t) => [t.kind, t.value]),
			b.tokens.map((t) => [t.kind, t.value])
		);
	// The finished actual dispatch table and its adjacent loop are one receiving cohort.
	// Only its original local construction and the two real loop reads may mention it.
	const dispatchDeclaration = positions(generate, 'local builders = {');
	const dispatchCheck = positions(generate, 'elseif type(builders[id]) ~= "function" then');
	const dispatchCall = positions(generate, 'local children = builders[id]() or {}');
	const loop = positions(generate, 'for _, entry in ipairs(load_top_level()) do');
	const expectedDispatch = scriptTokens(
		'\tlocal builders = {\n\t\t["keyboard_layout"] = function()\n\t\t\tlocal receive = ManifestMenu.group_receiver("top_level", "keyboard_layout")\n\t\t\tif not receive then return {} end\n\t\t\tlocal rows = module_rows("keyboard_layout")\n\t\t\tlocal original = #rows == 1 and rawget(rows, 1) or nil\n\t\t\tlocal submenu = type(original) == "table" and getmetatable(original) == nil\n\t\t\t\tand rawget(original, "submenu") or nil\n\t\t\tif type(submenu) ~= "table" then return {} end\n\t\t\t-- macOS owns a system input source, so the existing parent has no enable tick.\n\t\t\tlocal parent = receive(submenu, { layout_enabled = function() return nil end })\n\t\t\treturn parent and { parent } or {}\n\t\tend,\n\t\t["hotstrings"]      = function() return build_hotstrings_rows(ctx, menu_mods) end,\n\t\t["llm"]             = function()\n\t\t\tif type(ctx.llm_handler) ~= "table" or type(ctx.llm_handler.build_item) ~= "function" then\n\t\t\t\tLogger.warn(LOG, "LLM handler missing or incomplete \u2014 AI component ignored.")\n\t\t\t\treturn {}\n\t\t\tend\n\t\t\tLogger.debug(LOG, "Building AI component\u2026")\n\t\t\tlocal ok_b, llm_item = pcall(ctx.llm_handler.build_item)\n\t\t\tif not ok_b then\n\t\t\t\tLogger.error(LOG, string.format("Error building AI component: %s.", tostring(llm_item)))\n\t\t\t\treturn {}\n\t\t\tend\n\t\t\tLogger.debug(LOG, "AI component added successfully.")\n\t\t\treturn llm_item and { llm_item } or {}\n\t\tend,\n\t\t["agent"]           = function()\n\t\t\t-- The AI agent\'s settings share the AI menu\'s transaction owner, so\n\t\t\t-- its handler builds this row too.\n\t\t\tif type(ctx.llm_handler) ~= "table" or type(ctx.llm_handler.build_agent_item) ~= "function" then\n\t\t\t\tLogger.warn(LOG, "LLM handler missing or incomplete \u2014 AI agent component ignored.")\n\t\t\t\treturn {}\n\t\t\tend\n\t\t\tlocal ok_b, agent_item = pcall(ctx.llm_handler.build_agent_item)\n\t\t\tif not ok_b then\n\t\t\t\tLogger.error(LOG, string.format("Error building the AI agent component: %s.", tostring(agent_item)))\n\t\t\t\treturn {}\n\t\t\tend\n\t\t\treturn agent_item and { agent_item } or {}\n\t\tend,\n\t\t["metrics"]         = function() return module_rows("keylogger") end,\n\t\t-- The shortcuts submodule surfaces the edit-shortcuts callback, so it gets\n\t\t-- the actions on top of the context.\n\t\t["shortcuts"]       = function()\n\t\t\treturn module_rows("shortcuts", setmetatable({ actions = actions }, { __index = ctx }))\n\t\tend,\n\t\t["tap_holds"]       = function() return module_rows("tap_holds") end,\n\t\t["gestures"]        = function() return module_rows("gestures") end,\n\t\t["apps"]            = function() return module_rows("apps") end,\n\t\t["configuration"]   = function()\n\t\t\tlocal root, top, section, parent, fields = configuration_source(ManifestMenu, "hs")\n\t\t\tif root == nil then return {} end\n\t\t\t-- Every row is `type = "command"` in the manifest: labels, order and\n\t\t\t-- the separators are declared, and this file supplies only what each\n\t\t\t-- row does. Read once, so the pause gate below can tell the rows apart\n\t\t\t-- by the handler they carry. The global scope\'s restore and clear open\n\t\t\t-- the menu, like every settings menu\'s.\n\t\t\tlocal restore = actions.reset_defaults\n\t\t\tlocal clear = actions.clear_to_system\n\t\t\tlocal clean = actions.clean_unused_keys\n\t\t\tlocal cfg_ctx = {}\n\t\t\tfor key, value in pairs(ctx or {}) do cfg_ctx[key] = value end\n\t\t\tcfg_ctx.commands = {\n\t\t\t\t["scope_restore"]       = restore,\n\t\t\t\t["scope_clear"]         = clear,\n\t\t\t\t["clean_unused_keys"]   = clean,\n\t\t\t\t["config_folder"]       = actions.open_paths,\n\t\t\t\t["setup_wizard"]        = actions.show_setup_wizard,\n\t\t\t}\n\t\t\tcfg_ctx.state_getters = {}\n\t\t\tfor key, value in pairs(ctx.state_getters or {}) do cfg_ctx.state_getters[key] = value end\n\t\t\t-- \u00ab Ergopti uses Karabiner \u00bb and \u00ab Remove Ergopti from Karabiner \u00bb\n\t\t\t-- need the remap owner; without it the renderer skips both rows.\n\t\t\tif type(ctx.karabiner) == "table" then\n\t\t\t\tlocal switch_commands, switch_getters = require("ui.menu.remap_switch")\n\t\t\t\t\t.rows(ctx.karabiner, ctx.updateMenu)\n\t\t\t\tfor id, fn in pairs(switch_commands) do cfg_ctx.commands[id] = fn end\n\t\t\t\tfor id, fn in pairs(switch_getters) do cfg_ctx.state_getters[id] = fn end\n\t\t\tend\n\t\t\t-- Pause owns the bindings axis for the whole pause window: pause_all()\n\t\t\t-- snapshots what was running and resume_all() restores that snapshot.\n\t\t\t-- A row that rewrites the configuration in between is either discarded\n\t\t\t-- on resume or breaks the \u00ab pause = tout \u00e9teint \u00bb invariant, so those\n\t\t\t-- three are greyed AND stripped of their handler: a disabled row whose\n\t\t\t-- fn survives still fires the moment the greying is rendered wrong\n\t\t\t-- somewhere else. The rows that only open a window stay live.\n\t\t\tlocal pause_gated = {}\n\t\t\t-- pairs, not ipairs: an unregistered command is nil, and ipairs would\n\t\t\t-- stop there and leave the rows after it ungated.\n\t\t\tfor _, fn in pairs({ restore = restore, clear = clear, clean = clean }) do\n\t\t\t\t-- An unregistered command draws no row, so it has nothing to gate.\n\t\t\t\tif type(fn) == "function" then pause_gated[fn] = true end\n\t\t\tend\n\t\t\tlocal rows = ManifestMenu.build("configuration_menu", "Configuration", nil, nil, cfg_ctx)\n\t\t\tif not configuration_dense(rows, true) then return {} end\n\t\t\tif ctx.paused then\n\t\t\t\tfor _, row in ipairs(rows) do\n\t\t\t\t\tif row.fn ~= nil and pause_gated[row.fn] then\n\t\t\t\t\t\trow.disabled = true\n\t\t\t\t\t\trow.fn = nil\n\t\t\t\t\tend\n\t\t\t\tend\n\t\t\tend\n\t\t\tlocal current_root, current_top, current_section, current_parent = configuration_source(ManifestMenu, "hs")\n\t\t\tif not rawequal(root, current_root) or not rawequal(top, current_top)\n\t\t\t\tor not rawequal(section, current_section) or not rawequal(parent, current_parent)\n\t\t\t\tor not configuration_parent_unchanged(parent, fields) then return {} end\n\t\t\tlocal row = ManifestMenu.group_row("top_level", "configuration", rows, cfg_ctx.state_getters)\n\t\t\treturn row and { row } or {}\n\t\tend,\n\t\t["language"]        = function()\n\t\t\t-- The locale rows reach the tray through the manifest\'s `language_menu`.\n\t\t\t-- They were the same twenty-one entries on every driver, from the same\n\t\t\t-- shared catalogue, and nothing described the menu holding them.\n\t\t\tif type(i18n.build_language_menu_items) ~= "function" then return {} end\n\t\t\tlocal ok_locales, locales = pcall(i18n.build_language_menu_items)\n\t\t\tif not ok_locales then return {} end\n\t\t\tlocal admitted = ManifestMenu.template_rows("language_menu", {}, {}, {\n\t\t\t\t["locales"] = function() return locales end,\n\t\t\t})\n\t\t\tif not admitted then return {} end\n\t\t\tlocal rendered = ManifestMenu.render_rows(admitted, "language_menu")\n\t\t\tlocal parent = ManifestMenu.group_row("top_level", "language", rendered, {})\n\t\t\treturn parent and { parent } or {}\n\t\tend,\n\t\t["about"]           = function()\n\t\t\tif type(menu_mods.about) ~= "table" or type(menu_mods.about.build) ~= "function" then\n\t\t\t\tLogger.warn(LOG, "About module missing \u2014 its row is not drawn.")\n\t\t\t\treturn {}\n\t\t\tend\n\t\t\t-- The actions carry startup and the uninstall transaction, whose row closes it.\n\t\t\tlocal ok_a, about_item = pcall(menu_mods.about.build, ctx, actions)\n\t\t\tif not ok_a then\n\t\t\t\tLogger.error(LOG, "Error building the About submenu: %s.", tostring(about_item))\n\t\t\t\treturn {}\n\t\t\tend\n\t\t\treturn about_item and { about_item } or {}\n\t\tend,\n\t\t["reload"]          = function()\n\t\t\tlocal row = ManifestMenu.command_row("top_level", "reload", { reload = actions.reload })\n\t\t\tif not row then return {} end\n\t\t\treturn { row }\n\t\tend,\n\t\t["quit"]            = function()\n\t\t\tlocal row = ManifestMenu.command_row("top_level", "quit", { quit = actions.quit })\n\t\t\tif not row then return {} end\n\t\t\treturn { row }\n\t\tend,\n\t\t["debug"]           = function()\n\t\t\tlocal root, top, section, parent, fields = debug_source(ManifestMenu, "hs")\n\t\t\tif root == nil then return {} end\n\t\t\t-- The manifest declares every row of this submenu and the shared\n\t\t\t-- renderer places them; this file supplies only what each one does.\n\t\t\tlocal active_level_name\n\t\t\tfor level, severity in pairs(Logger.LEVELS) do\n\t\t\t\tif Logger.current_level == severity then active_level_name = level; break end\n\t\t\tend\n\t\t\tlocal healthcheck = require("ui.healthcheck")\n\t\t\tlocal dbg_ctx = {}\n\t\t\tfor key, value in pairs(ctx or {}) do dbg_ctx[key] = value end\n\t\t\tdbg_ctx.commands = {\n\t\t\t\t["console"]        = actions.open_console,\n\t\t\t\t["log_level"]      = actions.set_log_level,\n\t\t\t\t["open_logs"]      = actions.open_logs,\n\t\t\t\t["open_today_log"] = actions.open_today_log,\n\t\t\t\t["open_error_log"] = actions.open_error_log,\n\t\t\t\t["healthcheck"]    = function() healthcheck.show_window({ state = ctx.state }) end,\n\t\t\t\t["report_bug"]      = function() require("ui.healthcheck.report").report_bug({ state = ctx.state }) end,\n\t\t\t\t["suggest_feature"] = function() require("ui.healthcheck.report").suggest_feature() end,\n\t\t\t\t["show_error_dialog"] = actions.toggle_error_dialog,\n\t\t\t}\n\t\t\tdbg_ctx.state_getters = {}\n\t\t\tfor key, value in pairs(ctx.state_getters or {}) do dbg_ctx.state_getters[key] = value end\n\t\t\tdbg_ctx.state_getters["script.log_level"] = function() return active_level_name end\n\t\t\tdbg_ctx.state_getters["error_dialog_enabled"] = function()\n\t\t\t\treturn require("ui.error_dialog").is_enabled()\n\t\t\tend\n\t\t\tlocal debug_items = ManifestMenu.build("debug_menu", "Debug", nil, nil, dbg_ctx, {})\n\t\t\tif not debug_dense(debug_items, true) then return {} end\n\t\t\tlocal current_root, current_top, current_section, current_parent = debug_source(ManifestMenu, "hs")\n\t\t\tif not rawequal(root, current_root) or not rawequal(top, current_top)\n\t\t\t\tor not rawequal(section, current_section) or not rawequal(parent, current_parent)\n\t\t\t\tor not debug_parent_unchanged(parent, fields) then return {} end\n\t\t\tlocal row = ManifestMenu.group_row("top_level", "debug", debug_items, dbg_ctx.state_getters)\n\t\t\treturn row and { row } or {}\n\t\tend,\n\t}\n\n\tlocal items = {}\n\tfor _, entry in ipairs(load_top_level()) do',
		'.lua'
	);
	// This second whole dispatch differs only in the authenticated Group5 configuration route.
	const expectedRecoveryDispatch = scriptTokens(
		'\tlocal builders = {\n\t\t["keyboard_layout"] = function()\n\t\t\tlocal receive = ManifestMenu.group_receiver("top_level", "keyboard_layout")\n\t\t\tif not receive then return {} end\n\t\t\tlocal rows = module_rows("keyboard_layout")\n\t\t\tlocal original = #rows == 1 and rawget(rows, 1) or nil\n\t\t\tlocal submenu = type(original) == "table" and getmetatable(original) == nil\n\t\t\t\tand rawget(original, "submenu") or nil\n\t\t\tif type(submenu) ~= "table" then return {} end\n\t\t\t-- macOS owns a system input source, so the existing parent has no enable tick.\n\t\t\tlocal parent = receive(submenu, { layout_enabled = function() return nil end })\n\t\t\treturn parent and { parent } or {}\n\t\tend,\n\t\t["hotstrings"]      = function() return build_hotstrings_rows(ctx, menu_mods) end,\n\t\t["llm"]             = function()\n\t\t\tif type(ctx.llm_handler) ~= "table" or type(ctx.llm_handler.build_item) ~= "function" then\n\t\t\t\tLogger.warn(LOG, "LLM handler missing or incomplete — AI component ignored.")\n\t\t\t\treturn {}\n\t\t\tend\n\t\t\tLogger.debug(LOG, "Building AI component…")\n\t\t\tlocal ok_b, llm_item = pcall(ctx.llm_handler.build_item)\n\t\t\tif not ok_b then\n\t\t\t\tLogger.error(LOG, string.format("Error building AI component: %s.", tostring(llm_item)))\n\t\t\t\treturn {}\n\t\t\tend\n\t\t\tLogger.debug(LOG, "AI component added successfully.")\n\t\t\treturn llm_item and { llm_item } or {}\n\t\tend,\n\t\t["agent"]           = function()\n\t\t\t-- The AI agent\'s settings share the AI menu\'s transaction owner, so\n\t\t\t-- its handler builds this row too.\n\t\t\tif type(ctx.llm_handler) ~= "table" or type(ctx.llm_handler.build_agent_item) ~= "function" then\n\t\t\t\tLogger.warn(LOG, "LLM handler missing or incomplete — AI agent component ignored.")\n\t\t\t\treturn {}\n\t\t\tend\n\t\t\tlocal ok_b, agent_item = pcall(ctx.llm_handler.build_agent_item)\n\t\t\tif not ok_b then\n\t\t\t\tLogger.error(LOG, string.format("Error building the AI agent component: %s.", tostring(agent_item)))\n\t\t\t\treturn {}\n\t\t\tend\n\t\t\treturn agent_item and { agent_item } or {}\n\t\tend,\n\t\t["metrics"]         = function() return module_rows("keylogger") end,\n\t\t-- The shortcuts submodule surfaces the edit-shortcuts callback, so it gets\n\t\t-- the actions on top of the context.\n\t\t["shortcuts"]       = function()\n\t\t\treturn module_rows("shortcuts", setmetatable({ actions = actions }, { __index = ctx }))\n\t\tend,\n\t\t["tap_holds"]       = function() return module_rows("tap_holds") end,\n\t\t["gestures"]        = function() return module_rows("gestures") end,\n\t\t["apps"]            = function() return module_rows("apps") end,\n\t\t["configuration"]   = function()\n\t\t\tlocal root, top, section, parent, fields = configuration_source(ManifestMenu, "hs")\n\t\t\tif root == nil then return {} end\n\t\t\t-- Every row is `type = "command"` in the manifest: labels, order and\n\t\t\t-- the separators are declared, and this file supplies only what each\n\t\t\t-- row does. Read once, so the pause gate below can tell the rows apart\n\t\t\t-- by the handler they carry. The global scope\'s restore and clear open\n\t\t\t-- the menu, like every settings menu\'s.\n\t\t\tlocal restore = actions.reset_defaults\n\t\t\tlocal clear = actions.clear_to_system\n\t\t\tlocal clean = actions.clean_unused_keys\n\t\t\tlocal cfg_ctx = {}\n\t\t\tfor key, value in pairs(ctx or {}) do cfg_ctx[key] = value end\n\t\t\tcfg_ctx.commands = {\n\t\t\t\t["scope_restore"]       = restore,\n\t\t\t\t["scope_clear"]         = clear,\n\t\t\t\t["clean_unused_keys"]   = clean,\n\t\t\t\t["config_folder"]       = actions.open_paths,\n\t\t\t\t["setup_wizard"]        = actions.show_setup_wizard,\n\t\t\t}\n\t\t\tcfg_ctx.state_getters = {}\n\t\t\tfor key, value in pairs(ctx.state_getters or {}) do cfg_ctx.state_getters[key] = value end\n\t\t\t-- « Ergopti uses Karabiner » and « Remove Ergopti from Karabiner »\n\t\t\t-- need the remap owner; without it the renderer skips both rows.\n\t\t\tlocal switch_providers = {}\n\t\t\tif type(ctx.karabiner) == "table" then\n\t\t\t\tlocal switch_commands, switch_getters, providers = require("ui.menu.remap_switch")\n\t\t\t\t\t.rows(ctx.karabiner, ctx.updateMenu, ctx.recover_shared_runtime, ctx.can_recover_shared_runtime)\n\t\t\t\tfor id, fn in pairs(switch_commands) do cfg_ctx.commands[id] = fn end\n\t\t\t\tfor id, fn in pairs(switch_getters) do cfg_ctx.state_getters[id] = fn end\n\t\t\t\tswitch_providers = providers\n\t\t\tend\n\t\t\t-- Pause owns the bindings axis for the whole pause window: pause_all()\n\t\t\t-- snapshots what was running and resume_all() restores that snapshot.\n\t\t\t-- A row that rewrites the configuration in between is either discarded\n\t\t\t-- on resume or breaks the « pause = tout éteint » invariant, so those\n\t\t\t-- three are greyed AND stripped of their handler: a disabled row whose\n\t\t\t-- fn survives still fires the moment the greying is rendered wrong\n\t\t\t-- somewhere else. The rows that only open a window stay live.\n\t\t\tlocal pause_gated = {}\n\t\t\t-- pairs, not ipairs: an unregistered command is nil, and ipairs would\n\t\t\t-- stop there and leave the rows after it ungated.\n\t\t\tfor _, fn in pairs({ restore = restore, clear = clear, clean = clean }) do\n\t\t\t\t-- An unregistered command draws no row, so it has nothing to gate.\n\t\t\t\tif type(fn) == "function" then pause_gated[fn] = true end\n\t\t\tend\n\t\t\tlocal rows = ManifestMenu.build("configuration_menu", "Configuration", nil, nil, cfg_ctx, switch_providers)\n\t\t\tif not configuration_dense(rows, true) then return {} end\n\t\t\tfor _, row in ipairs(rows) do\n\t\t\t\tif row.disabled == true then row.fn = nil end\n\t\t\tend\n\t\t\tif ctx.paused then\n\t\t\t\tfor _, row in ipairs(rows) do\n\t\t\t\t\tif row.fn ~= nil and pause_gated[row.fn] then\n\t\t\t\t\t\trow.disabled = true\n\t\t\t\t\t\trow.fn = nil\n\t\t\t\t\tend\n\t\t\t\tend\n\t\t\tend\n\t\t\tlocal current_root, current_top, current_section, current_parent = configuration_source(ManifestMenu, "hs")\n\t\t\tif not rawequal(root, current_root) or not rawequal(top, current_top)\n\t\t\t\tor not rawequal(section, current_section) or not rawequal(parent, current_parent)\n\t\t\t\tor not configuration_parent_unchanged(parent, fields) then return {} end\n\t\t\tlocal row = ManifestMenu.group_row("top_level", "configuration", rows, cfg_ctx.state_getters)\n\t\t\treturn row and { row } or {}\n\t\tend,\n\t\t["language"]        = function()\n\t\t\t-- The locale rows reach the tray through the manifest\'s `language_menu`.\n\t\t\t-- They were the same twenty-one entries on every driver, from the same\n\t\t\t-- shared catalogue, and nothing described the menu holding them.\n\t\t\tif type(i18n.build_language_menu_items) ~= "function" then return {} end\n\t\t\tlocal ok_locales, locales = pcall(i18n.build_language_menu_items)\n\t\t\tif not ok_locales then return {} end\n\t\t\tlocal admitted = ManifestMenu.template_rows("language_menu", {}, {}, {\n\t\t\t\t["locales"] = function() return locales end,\n\t\t\t})\n\t\t\tif not admitted then return {} end\n\t\t\tlocal rendered = ManifestMenu.render_rows(admitted, "language_menu")\n\t\t\tlocal parent = ManifestMenu.group_row("top_level", "language", rendered, {})\n\t\t\treturn parent and { parent } or {}\n\t\tend,\n\t\t["about"]           = function()\n\t\t\tif type(menu_mods.about) ~= "table" or type(menu_mods.about.build) ~= "function" then\n\t\t\t\tLogger.warn(LOG, "About module missing — its row is not drawn.")\n\t\t\t\treturn {}\n\t\t\tend\n\t\t\t-- The actions carry startup and the uninstall transaction, whose row closes it.\n\t\t\tlocal ok_a, about_item = pcall(menu_mods.about.build, ctx, actions)\n\t\t\tif not ok_a then\n\t\t\t\tLogger.error(LOG, "Error building the About submenu: %s.", tostring(about_item))\n\t\t\t\treturn {}\n\t\t\tend\n\t\t\treturn about_item and { about_item } or {}\n\t\tend,\n\t\t["reload"]          = function()\n\t\t\tlocal row = ManifestMenu.command_row("top_level", "reload", { reload = actions.reload })\n\t\t\tif not row then return {} end\n\t\t\treturn { row }\n\t\tend,\n\t\t["quit"]            = function()\n\t\t\tlocal row = ManifestMenu.command_row("top_level", "quit", { quit = actions.quit })\n\t\t\tif not row then return {} end\n\t\t\treturn { row }\n\t\tend,\n\t\t["debug"]           = function()\n\t\t\tlocal root, top, section, parent, fields = debug_source(ManifestMenu, "hs")\n\t\t\tif root == nil then return {} end\n\t\t\t-- The manifest declares every row of this submenu and the shared\n\t\t\t-- renderer places them; this file supplies only what each one does.\n\t\t\tlocal active_level_name\n\t\t\tfor level, severity in pairs(Logger.LEVELS) do\n\t\t\t\tif Logger.current_level == severity then active_level_name = level; break end\n\t\t\tend\n\t\t\tlocal healthcheck = require("ui.healthcheck")\n\t\t\tlocal dbg_ctx = {}\n\t\t\tfor key, value in pairs(ctx or {}) do dbg_ctx[key] = value end\n\t\t\tdbg_ctx.commands = {\n\t\t\t\t["console"]        = actions.open_console,\n\t\t\t\t["log_level"]      = actions.set_log_level,\n\t\t\t\t["open_logs"]      = actions.open_logs,\n\t\t\t\t["open_today_log"] = actions.open_today_log,\n\t\t\t\t["open_error_log"] = actions.open_error_log,\n\t\t\t\t["healthcheck"]    = function() healthcheck.show_window({ state = ctx.state }) end,\n\t\t\t\t["report_bug"]      = function() require("ui.healthcheck.report").report_bug({ state = ctx.state }) end,\n\t\t\t\t["suggest_feature"] = function() require("ui.healthcheck.report").suggest_feature() end,\n\t\t\t\t["show_error_dialog"] = actions.toggle_error_dialog,\n\t\t\t}\n\t\t\tdbg_ctx.state_getters = {}\n\t\t\tfor key, value in pairs(ctx.state_getters or {}) do dbg_ctx.state_getters[key] = value end\n\t\t\tdbg_ctx.state_getters["script.log_level"] = function() return active_level_name end\n\t\t\tdbg_ctx.state_getters["error_dialog_enabled"] = function()\n\t\t\t\treturn require("ui.error_dialog").is_enabled()\n\t\t\tend\n\t\t\tlocal debug_items = ManifestMenu.build("debug_menu", "Debug", nil, nil, dbg_ctx, {})\n\t\t\tif not debug_dense(debug_items, true) then return {} end\n\t\t\tlocal current_root, current_top, current_section, current_parent = debug_source(ManifestMenu, "hs")\n\t\t\tif not rawequal(root, current_root) or not rawequal(top, current_top)\n\t\t\t\tor not rawequal(section, current_section) or not rawequal(parent, current_parent)\n\t\t\t\tor not debug_parent_unchanged(parent, fields) then return {} end\n\t\t\tlocal row = ManifestMenu.group_row("top_level", "debug", debug_items, dbg_ctx.state_getters)\n\t\t\treturn row and { row } or {}\n\t\tend,\n\t}\n\n\tlocal items = {}\n\tfor _, entry in ipairs(load_top_level()) do',
		'.lua'
	);

	const allowedDispatchNames = new Set([
		dispatchDeclaration[0] + 1,
		dispatchCheck[0] + 3,
		dispatchCall[0] + 3
	]);
	if (
		dispatchDeclaration.length !== 1 ||
		dispatchCheck.length !== 1 ||
		dispatchCall.length !== 1 ||
		loop.length !== 1 ||
		![expectedDispatch, expectedRecoveryDispatch].some(
			(expected) =>
				dispatchDeclaration[0] + expected.length ===
					loop[0] + scriptTokens('for _, entry in ipairs(load_top_level()) do', '.lua').length &&
				isDeepStrictEqual(
					generate.tokens
						.slice(dispatchDeclaration[0], dispatchDeclaration[0] + expected.length)
						.map((t) => [t.kind, t.value]),
					expected.map((t) => [t.kind, t.value])
				)
		) ||
		generate.tokens.some(
			(token, at) =>
				token.kind === 'identifier' && token.value === 'builders' && !allowedDispatchNames.has(at)
		)
	)
		return false;
	const unwritten = (name) => {
		const definitions = positions(generate, 'local function ' + name + '(');
		const events = fixedNativeParentBindingEvents(generate, name);
		return (
			definitions.length === 1 &&
			events.size === 1 &&
			events.has(definitions[0] + 2) &&
			events.get(definitions[0] + 2).has('function')
		);
	};
	return (
		same(stage, expectedStage) &&
		same(module, expectedModule) &&
		same(collector, expectedCollector) &&
		unwritten('module_rows') &&
		unwritten('collect')
	);
}

/** The genuine missing-engine branch publishes its declared inert leaf through the actual tray root. */
function nativeLinuxTapHoldAbsentPublication(builderSource, manifest) {
	if (
		typeof builderSource !== 'string' ||
		!manifest ||
		typeof manifest !== 'object' ||
		!isDeepStrictEqual(manifest.linux_tap_holds_absent_parent, [
			{
				type: 'label',
				id: 'tap_holds_absent_parent',
				i18n: 'menu.tapholds.title',
				platforms: ['linux'],
				unavailable: 'hide'
			}
		]) ||
		!Array.isArray(manifest.top_level) ||
		manifest.top_level.filter((row) => row.id === 'tap_holds' && row.type === 'group').length !== 1
	)
		return false;
	const { lex, body, positions, rootPositions } = luaPublicationParser();
	const whole = lex(builderSource);
	if (
		!whole ||
		!closedModuleExport(whole, lex, rootPositions) ||
		!closedSiblingRendererBindings(whole)
	)
		return false;
	const root = body(whole, 'function M.build(ctx)');
	const stage = body(whole, 'local function _build_tap_holds(ctx)');
	const expected = lex(
		'local receive = ManifestMenu and ManifestMenu.group_receiver("top_level", "tap_holds")\n\tif not receive then return nil end\n\tlocal th = ctx.tap_holds\n\tif not th then\n\t\tlocal declared = ManifestMenu.template_rows("linux_tap_holds_absent_parent", {}, {}, {})\n\t\tif not declared or #declared ~= 1 then return nil end\n\t\treturn declared[1]\n\tend'
	);
	if (
		!stage ||
		!expected ||
		!declaredLinuxNativeTray(root, whole) ||
		positions(whole, '_build_tap_holds =').length ||
		stage.tokens.length < expected.tokens.length
	)
		return false;
	return expected.tokens.every(
		(token, at) => stage.tokens[at].kind === token.kind && stage.tokens[at].value === token.value
	);
}

/** Requires the actual exported Linux root and its closed captured-renderer protocol. */
function declaredLinuxTopLevelPublication(builderSource) {
	const { lex, body, rootPositions } = luaPublicationParser();
	let whole = lex(builderSource);
	if (!whole) return false;
	// A fresh, unused plain constructor only reads retained local values. It
	// cannot invoke, mutate or escape a renderer owner. Keep the entire native
	// publication protocol pinned after excluding this inert leading statement.
	const signature = 'function M.build(ctx)',
		build = rootPositions(whole, signature);
	if (build.length === 1) {
		const tokens = whole.tokens,
			symbol = (at, value) => tokens[at]?.kind === 'symbol' && tokens[at].value === value,
			start = build[0] + scriptTokens(signature, '.lua').length,
			reads = new Set(['separator_render', 'ManifestMenu', 'ctx']),
			keywords = new Set([
				'and',
				'break',
				'do',
				'else',
				'elseif',
				'end',
				'false',
				'for',
				'function',
				'goto',
				'if',
				'in',
				'local',
				'nil',
				'not',
				'or',
				'repeat',
				'return',
				'then',
				'true',
				'until',
				'while'
			]),
			name = tokens[start + 1];
		if (
			tokens[start]?.kind === 'identifier' &&
			tokens[start].value === 'local' &&
			name?.kind === 'identifier' &&
			name.value !== '_ENV' &&
			!keywords.has(name.value) &&
			!reads.has(name.value) &&
			symbol(start + 2, '=') &&
			symbol(start + 3, '{') &&
			tokens.filter((token) => token.kind === 'identifier' && token.value === name.value).length ===
				1
		) {
			let at = start + 4,
				fields = 0;
			while (!symbol(at, '}')) {
				if (tokens[at]?.kind === 'identifier' && symbol(at + 1, '=')) {
					if (keywords.has(tokens[at].value)) break;
					at += 2;
				}
				if (tokens[at]?.kind !== 'identifier' || !reads.has(tokens[at].value)) break;
				at++;
				fields++;
				if (symbol(at, ',') || symbol(at, ';')) at++;
				else if (!symbol(at, '}')) break;
			}
			if (fields > 0 && symbol(at, '}')) {
				const end = symbol(at + 1, ';') ? at + 1 : at;
				whole = lex(
					builderSource.slice(0, tokens[start].start) + builderSource.slice(tokens[end].end)
				);
			}
		}
	}
	return (
		!!whole &&
		closedModuleExport(whole, lex, rootPositions) &&
		closedSiblingRendererBindings(whole) &&
		declaredLinuxNativeTray(body(whole, signature), whole)
	);
}

/** The actual exported Linux root composes both guarded physical header frames. */
function nativeLinuxHeaderPublication(builderSource, manifest, platform) {
	if (platform !== 'linux' || typeof builderSource !== 'string') return false;
	// Snapshot only ordinary own data descriptors; native rawget/plain custody
	// cannot be supplied by getters, inherited fields or custom container methods.
	const ordinary = (value, array = false) => {
		if (!value || typeof value !== 'object' || Array.isArray(value) !== array) return null;
		const prototype = Object.getPrototypeOf(value);
		if (
			array ? prototype !== Array.prototype : prototype !== Object.prototype && prototype !== null
		)
			return null;
		const descriptors = Object.getOwnPropertyDescriptors(value),
			data = Object.create(null);
		for (const key of Reflect.ownKeys(descriptors)) {
			if (typeof key !== 'string' || !Object.hasOwn(descriptors[key], 'value')) return null;
			data[key] = descriptors[key].value;
		}
		if (array) {
			if (!Number.isSafeInteger(data.length) || data.length < 0) return null;
			if (Object.keys(data).length !== data.length + 1) return null;
			for (let index = 0; index < data.length; index++)
				if (!Object.hasOwn(data, String(index))) return null;
		}
		return data;
	};
	const root = ordinary(manifest);
	if (!root) return false;
	const topLevel = ordinary(root.top_level, true);
	if (!topLevel || topLevel.length === 0) return false;
	const records = new Set();
	for (let index = 0; index < topLevel.length; index++) {
		const record = ordinary(topLevel[index]);
		if (!record || typeof record.id !== 'string' || records.has(topLevel[index])) return false;
		records.add(topLevel[index]);
	}
	if (!declaredLinuxTopLevelPublication(builderSource)) return false;
	const { lex } = luaPublicationParser();
	if (!declaredLinuxHeaderOwner(lex(builderSource))) return false;
	for (const [section, type, id] of [
		['linux_tray_active_header', 'label', 'linux_tray_active_header'],
		['linux_tray_paused_header', 'command', 'linux_tray_resume']
	]) {
		const rows = ordinary(root[section], true);
		if (!rows || rows.length !== 1) return false;
		const row = ordinary(rows[0]);
		if (!row || typeof row.i18n !== 'string' || row.i18n === '') return false;
		const platforms = ordinary(row.platforms, true);
		if (!platforms || platforms.length !== 1 || platforms[0] !== 'linux') return false;
		if (
			!isDeepStrictEqual(
				{ ...row, platforms: [platforms[0]] },
				{
					type,
					id,
					i18n: row.i18n,
					caption_getter: 'linux_tray_version',
					caption_layout: 'prefix',
					caption_joiner: ' — ',
					platforms: ['linux'],
					unavailable: 'hide'
				}
			)
		)
			return false;
	}
	return true;
}

module.exports = {
	nativeLlmParentPublication,
	nativeLinuxAiParentPublication,
	nativeMacLayoutTopLevelPublication,
	nativeLinuxTapHoldAbsentPublication,
	nativeTopLevelProjection,
	declaredMacTopLevelPublication,
	declaredLinuxTopLevelPublication,
	nativeLinuxHeaderPublication
};
