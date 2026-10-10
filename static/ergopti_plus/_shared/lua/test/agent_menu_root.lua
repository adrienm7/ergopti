--- _shared/lua/test/agent_menu_root.lua

--- ==============================================================================
--- MODULE: Agent-Only Root Presentation Behavior Contract
--- DESCRIPTION:
--- Executes the genuine composition and macOS projection blocks over inert rows.
--- An omitted disabled branch must admit the Agent builder and fail this contract.
--- ==============================================================================

local M = {}

-- Both supported Linux ABIs compile the same unchanged native source and retain
-- explicit return arity; LuaJIT uses the Lua 5.1 compiler/environment API.
local unpack_values = table.unpack or unpack
local function pack_values(...)
	return {n = select("#", ...), ...}
end

local function compile_source(text, name, environment)
	if type(loadstring) == "function" then
		local chunk, reason = loadstring(text, name)
		if not chunk then return nil, reason end
		return setfenv(chunk, environment)
	end
	return load(text, name, "t", environment)
end

local function between(body, first, last)
	local start_at = assert(body:find(first, 1, true), first)
	local finish_at = assert(body:find(last, start_at + #first, true), last)
	return body:sub(start_at, finish_at - 1)
end

--- Supplies the actual shared boundary owner and its complete canonical source.
--- The old actor expectations remain independent of this source dependency.
local function with_boundary_owner(helpers, platform, source, top_level, body)
	local renderer = assert(require("menu.renderer").new({platform = platform,
		manifest_path = function() return require("infra.paths").shared("modules/menu/menu_manifest.json") end,
		json_decode = require("json").decode,
		i18n = {get = function(key) return key end, section = function(key) return key end},
		logger = {error = function() end, warn = function() end}}))
	helpers.assert_eq(renderer.get_root().top_level, top_level,
		"the native source excerpt consumes the same complete canonical input as the original actor contract")
	local start = assert(source:find("local separator_modules = package.loaded", 1, true))
	local finish = assert(source:find("\nend\n", start, true)) + #"\nend\n" - 1
	local imported = source:sub(start, finish)
	local modules, previous = package.loaded, rawget(package.loaded, "infra.manifest_menu")
	local outcome = pack_values(xpcall(function()
		rawset(modules, "infra.manifest_menu", renderer)
		-- Compile the unchanged actual import/custody function, not a ready stub.
		local current, factory = assert(compile_source("local ManifestMenu = actual_renderer\n" .. imported
			.. "\nreturn separator_facade_current, separator_factory", "@actual-boundary-facade",
			{actual_renderer = renderer, package = package, rawget = rawget, type = type, getmetatable = getmetatable}))()
		helpers.assert_true(current(), "the actual imported native facade is admitted")
		return body(renderer, current, factory)
	end, debug.traceback))
	rawset(modules, "infra.manifest_menu", previous)
	helpers.assert_true(rawequal(rawget(modules, "infra.manifest_menu"), previous), "the exact prior native facade is restored")
	if not outcome[1] then error(outcome[2], 0) end
	return unpack_values(outcome, 2, outcome.n)
end

--- Verifies the actual root's gate while neighboring actions remain executable.
--- @param helpers table Existing assertion owner.
--- @param platform string hs or linux.
--- @param source string Complete actual root builder source.
--- @param top_level table Actual canonical top-level declarations.
function M.assert_disabled_root(helpers, platform, source, top_level)
	assert(platform == "hs" or platform == "linux", "a known root consumer is required")
	assert(type(source) == "string" and source ~= "", "actual source must exist")
	local function check(label, condition) helpers.assert_true(condition == true, label) end
	local calls = { agent = 0, llm = 0, provider = 0, prediction = 0, model = 0 }
	local llm = { label = "predictions", items = {} }
	for _, id in ipairs({ "provider", "prediction", "model" }) do
		llm.items[#llm.items + 1] = { label = id, action = function() calls[id] = calls[id] + 1 end }
	end
	local builders = {
		agent = function() calls.agent = calls.agent + 1; return { label = "agent", items = {
			{ label = "agent_action", action = function() error("agent must not execute") end } } } end,
		llm = function() calls.llm = calls.llm + 1; return llm end,
		quit = function() return { label = "quit", action = function() return true end } end,
	}
	local result = with_boundary_owner(helpers, platform, source, top_level, function(renderer, current, factory)
		if platform == "hs" then
			local loader = between(source, "local function load_top_level()", "--- Invalidates locale-dependent caches")
			local loop = between(source, "\tlocal items = {}\n\tfor _, entry in ipairs(load_top_level()) do", "\n\t-- Everything above collected row DATA")
			local wrapped = {}
			for id, builder in pairs(builders) do wrapped[id] = function() return {builder()} end end
			return assert(compile_source("local _top_level_cache; local _top_level_separator_receiver\n"
				.. loader .. "\n" .. loop .. "\nreturn items", "@actual-macos-composition", {
					separator_facade_current = current, separator_factory = factory, builders = wrapped,
					ctx = {paused = false}, type = type, ipairs = ipairs, table = table, tostring = tostring,
					i18n = {get = function(key) return key end}, Logger = {debug = function() end, error = function() end}}))()
		end
		-- The actor begins after the header. Its independent caption oracle stays
		-- unchanged; only the exact native pre-render extraction boundary moved.
		local terminal = "\n\tif not separator_facade_current() or not receive_separator(\"current\") then"
		if not source:find(terminal, 1, true) then
			terminal = "\n\tif not separator_facade_current() or not receive_separator(\"current\") or not header_current() then"
		end
		local loop = between(source, "\tlocal quit_row = nil\n", terminal)
		local first = assert(source:find("local function _row_is_for_linux(row)", 1, true))
		local last = assert(source:find("\nend\n", first, true)) + #"\nend\n" - 1
		local native_platform = source:sub(first, last)
		local receive, declared = factory()
		helpers.assert_type(receive, "function"); helpers.assert_true(rawequal(declared, renderer.get_array("top_level")))
		return assert(compile_source(native_platform .. "\n" .. loop .. "\nreturn rows", "@actual-linux-composition", {
			declared = declared, rows = {}, builders = builders, ctx = {paused = false},
			separator_facade_current = current, receive_separator = receive,
			type = type, ipairs = ipairs, tostring = tostring, i18n_safe = function(key) return key end,
			Logger = {error = function() end}}))()
	end)

	local disabled, neighbor
	for _, row in ipairs(result) do
		if row.label == "menu.agent.title" then disabled = row end
		if row.label == "predictions" then neighbor = row end
	end
	check(platform .. " agent disabled with exact reason", disabled and disabled.disabled == true
		and disabled.disabled_reason_key == "menu.agent.not_ready")
	check(platform .. " agent exposes no action or descendants", disabled and disabled.action == nil
		and disabled.fn == nil and disabled.items == nil and disabled.submenu == nil)
	check(platform .. " agent builder never executes", calls.agent == 0)
	check(platform .. " prediction subtree identity preserved", neighbor == llm and calls.llm == 1)
	if neighbor then for _, row in ipairs(neighbor.items) do row.action() end end
	check(platform .. " providers predictions models remain available", calls.provider == 1
		and calls.prediction == 1 and calls.model == 1)
end

return M
