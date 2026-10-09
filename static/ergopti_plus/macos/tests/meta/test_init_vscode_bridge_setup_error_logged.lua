--- tests/meta/test_init_vscode_bridge_setup_error_logged.lua

--- ==============================================================================
--- MODULE: Startup Without Retired VS Code Bridge
--- DESCRIPTION:
--- Executes the real bounded menu-ready startup slice over declared inert ports.
--- Bridge absence cannot abort UI progress; a refused menubar remains fatal.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Evaluates only the menu-ready source slice, never the driver entrypoint.
--- @param available boolean Whether the recording menu commits.
--- @return boolean ok
--- @return table facts
local function startup_slice(available)
	local source = helpers.read_driver_source("local function has_common_hotstring_groups")
	helpers.assert_type(source, "string")
	local start = source:find('Boot.stage("UI: menu.start (menubar + state sync + engines + LLM handler)")', 1, true)
	local finish = source:find('Boot.stage("File watchers armed")', start or 1, true)
	helpers.assert_true(start ~= nil and finish ~= nil and finish > start, "real startup boundaries must be present")
	local slice = source:sub(start, finish + #'Boot.stage("File watchers armed")' - 1)
	helpers.assert_true(#slice > 0, "source extraction cannot pass vacuously")
	local facts = { bridge_calls = 0, menu_calls = 0, marks = {}, stages = {} }
	local logger = {}
	for _, level in ipairs({ "debug", "error", "info" }) do logger[level] = function() end end
	local env = {
		Boot = { stage = function(name) facts.stages[#facts.stages + 1] = name end,
			mark = function(name) facts.marks[#facts.marks + 1] = name end },
		Logger = logger, LOG = "controlled-init", config_paths = { get = function() return "/owned" end },
		ExtensionPacks = { catalogue = function() return {} end },
		menu = { start = function() facts.menu_calls = facts.menu_calls + 1; return available and {} or nil end },
		package = { loaded = {} },
		require = function(name)
			helpers.assert_eq(name, "infra.vscode_bridge")
			facts.bridge_calls = facts.bridge_calls + 1
			error("retired feature must not load or install")
		end,
	}
	setmetatable(env, { __index = _G })
	local chunk = assert(load(slice, "@owned-menu-startup-slice", "t", env))
	local ok = pcall(chunk)
	return ok, facts
end

helpers.describe("startup without retired VS Code bridge", function()
	helpers.it("commits normal menu readiness with zero bridge activation", function()
		local ok, facts = startup_slice(true)
		helpers.assert_true(ok, "the existing UI can progress without the retired feature")
		helpers.assert_eq(facts.menu_calls, 1)
		helpers.assert_eq(facts.bridge_calls, 0)
		helpers.assert_eq(facts.marks[#facts.marks], "UI: menu ready")
		helpers.assert_eq(facts.stages[#facts.stages], "File watchers armed")
	end)
	helpers.it("still refuses UI readiness when the actual menu does not commit", function()
		local ok, facts = startup_slice(false)
		helpers.assert_eq(ok, false)
		helpers.assert_eq(facts.menu_calls, 1)
		helpers.assert_eq(facts.bridge_calls, 0)
		helpers.assert_eq(#facts.marks, 0)
	end)
end)
