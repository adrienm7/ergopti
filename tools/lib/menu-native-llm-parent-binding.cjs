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
		rootPositions(loadTop, 'local data = load_manifest()').length !== 1 ||
		positions(loadTop, 'data =').length !== 1 ||
		rootPositions(loadTop, 'for _, entry in ipairs(data.top_level) do').length !== 1 ||
		!one(loadTop, '::continue::') ||
		!one(
			loadTop,
			'table.insert(result, { id = entry.id, greyed_when_paused = entry.greyed_when_paused == true })'
		)
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
		!one(generate, 'for _, row in ipairs(builders[id]() or {}) do') ||
		!one(generate, 'table.insert(items, row)') ||
		!one(generate, 'local rendered = ManifestMenu.render_rows(items, "top_level")') ||
		rootPositions(generate, 'return rendered').length !== 1
	)
		return false;
	return true;
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
	const { positions, rootPositions } = luaPublicationParser();
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
		if (optionPorts.has(at)) continue;
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
						require: 1,
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
		'llm_ctx.state_getters["llm_toggle_ready"] = function() return type(llm.toggle) == "function" and ctx.paused ~= true end',
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

/** Admits the small executable tray/caller call grammar, including diagnostics, without wildcard calls. */
function closedPublicationCalls(unit, role) {
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
					render_rows: 1
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

/** Requires each executable outer branch/loop to be a declared publication/refusal route. */
function closedNativeControl(unit, role) {
	if (!unit || !closedNativeReads(unit, role === 'tray')) return false;
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
	if (['tray', 'agentCaller'].includes(role) && !closedPublicationCalls(unit, role)) return false;
	if (role === 'tray') {
		const conditions = [
			'if type(row) == "table" then',
			'if id == "---" then',
			'if not build then',
			'elseif _row_is_for_linux(row) then',
			'elseif id == "quit" then',
			'elseif ctx.paused == true and row.greyed_when_paused == true then'
		];
		if (
			positions(unit, 'if').length !== 6 ||
			positions(unit, 'elseif').length !== 3 ||
			positions(unit, 'return').length !== 3 ||
			conditions.some((text) => positions(unit, text).length !== 1) ||
			positions(unit, 'rows [').length !== 6 ||
			positions(unit, 'rows [ # rows + 1 ] =').length !== 6 ||
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
	if (
		!tray ||
		!caller ||
		!closedNativeControl(tray, 'tray') ||
		!one(tray, '["' + kind + '"] = _build_' + kind + ',') ||
		positions(builder, '_build_' + kind + ' =').length ||
		!one(tray, 'local declared = ManifestMenu and ManifestMenu.get_array("top_level") or {}') ||
		!one(tray, 'for _, row in ipairs(declared) do') ||
		!one(tray, 'local build = builders[id]') ||
		!one(tray, 'rows[#rows + 1] = build(ctx)') ||
		!one(tray, 'rows[#rows + 1] = _grey_for_pause(build(ctx))') ||
		!one(tray, 'return ManifestMenu.render_rows(rows, "top_level")')
	)
		return false;
	const terminal = (unit, statement) => {
		const starts = rootPositions(unit, statement);
		return (
			starts.length === 1 &&
			starts[0] + scriptTokens(statement, '.lua').length === unit.tokens.length
		);
	};
	if (!terminal(tray, 'return ManifestMenu.render_rows(rows, "top_level")')) return false;
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
						'if type(llm.toggle) ~= "function" then return false end if llm.toggle then llm.toggle(ctx.on_menu_changed) end if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end'
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

module.exports = { nativeLlmParentPublication, nativeLinuxAiParentPublication };
