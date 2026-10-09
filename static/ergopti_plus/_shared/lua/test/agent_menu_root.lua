--- test/agent_menu_root.lua

--- ==============================================================================
--- MODULE: Agent-Only Root Presentation Behavior Contract
--- DESCRIPTION:
--- Executes the genuine composition and macOS projection blocks over inert rows.
--- An omitted disabled branch must admit the Agent builder and fail this contract.
--- ==============================================================================

local M = {}

local function between(body, first, last)
	local start_at = assert(body:find(first, 1, true), first)
	local finish_at = assert(body:find(last, start_at + #first, true), last)
	return body:sub(start_at, finish_at - 1)
end

--- Verifies the actual root's gate while neighboring actions remain executable.
--- @param helpers table Existing assertion owner.
--- @param platform string hs or linux.
--- @param source string Complete actual root builder source.
--- @param top_level table Actual canonical top-level declarations.
function M.assert_disabled_root(helpers, platform, source, top_level)
	assert(platform == "hs" or platform == "linux", "a known root consumer is required")
	assert(type(source) == "string" and source ~= "", "actual source must exist")
	local manifest = { top_level = top_level }
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
	local rows = {}
	for _, row in ipairs(manifest.top_level) do
		if row.id == "agent" or row.id == "llm" or row.id == "quit" then rows[#rows + 1] = row end
	end
	local result
	if platform == "hs" then
		local body = source
		local loader = between(body, "local function load_top_level()", "--- Invalidates locale-dependent caches")
		local loaded = assert(load("local _top_level_cache; local function load_manifest() return manifest end\n"
			.. loader .. "\nreturn load_top_level", "@actual-macos-loader", "t",
			{ manifest = { top_level = rows }, type = type, ipairs = ipairs, table = table,
				Logger = { debug = function() end, error = function() end } }))()
		local loop = between(body, "\tlocal items = {}\n\tfor _, entry in ipairs(load_top_level()) do", "\n\t-- Everything above collected row DATA")
		local wrapped = {}
		for id, builder in pairs(builders) do wrapped[id] = function() return { builder() } end end
		result = assert(load(loop .. "\nreturn items", "@actual-macos-composition", "t",
			{ load_top_level = loaded, builders = wrapped, ctx = { paused = false },
				type = type, ipairs = ipairs, table = table, tostring = tostring,
				i18n = { get = function(key) return key end }, Logger = { error = function() end } }))()
	else
		local body = source
		local loop = between(body, "\tlocal quit_row = nil\n", "\n\tif not (ManifestMenu and type(ManifestMenu.render_rows)")
		result = assert(load(loop .. "\nreturn rows", "@actual-linux-composition", "t",
			{ declared = rows, rows = {}, builders = builders, ctx = { paused = false },
				type = type, ipairs = ipairs, tostring = tostring,
				_row_is_for_linux = function() return true end,
				i18n_safe = function(key) return key end, Logger = { error = function() end } }))()
	end
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
