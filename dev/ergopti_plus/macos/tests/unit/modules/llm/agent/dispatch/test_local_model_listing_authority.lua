--- tests/unit/modules/llm/agent/dispatch/test_local_model_listing_authority.lua

--- ==============================================================================
--- MODULE: Agent Local Model Listing Authority
--- DESCRIPTION:
--- Compose the real Agent, prediction Engine and Ollama transport across a held
--- model listing. A late available model cannot authorize retired private input.
--- ==============================================================================

local helpers = require("tests.helpers")
local World = require("tests.support.agent_world")
local Scope = require("tests.support.modules.llm.selection_translation_scope")
require("logger")

local OWNED = {
	"modules.llm.agent_runner", "modules.llm.agent_learning", "modules.llm.agent_connectors",
	"llm.agent", "llm.agent_learning", "adapters.system_info", "infra.locale",
	"infra.dialog_util", "modules.llm.local_model_offer", "locale.core", "modules.shortcuts.script_control",
}

--- Keeps real requester callbacks and their native HTTP ports within one owner.
--- @param options table Agent backend settings.
--- @param scenario function Receives the real Agent world.
local function with_agent(options, scenario)
	helpers.with_fresh_modules(OWNED, function()
		Scope.run(function() scenario(World.build_world(options)) end)
	end)
end

local SYSTEMS = {
	{ name = "System 2", options = { system2 = "local" }, changes = { "current", "reset", "replacement", "pause" },
		start = function(world) return World.trigger(world, "llm_agent_selection") end },
	{ name = "System 1", options = { mode = "auto", system1 = "local" },
		changes = { "current", "runner reset", "off", "pause" },
		start = function(world)
			world.runner.observe_typing(World.SELECTION)
			World.settle(world)
			return true
		end },
}

helpers.describe("local Agent authority survives asynchronous model discovery", function()
	for _, system in ipairs(SYSTEMS) do
		for _, change in ipairs(system.changes) do
			helpers.it(system.name .. " holds its private dispatch after " .. change, function()
				with_agent(system.options, function(world)
					helpers.assert_true(system.start(world))
					helpers.assert_eq(#world.gets, 1, "the real local model listing must be pending")
					helpers.assert_true(world.gets[1].url:match("/api/tags$") ~= nil)
					helpers.assert_eq(#world.posts, 0)
					local revision = world.engine.current_request_revision()
					if change == "reset" then helpers.assert_true(world.engine.reset())
					elseif change == "replacement" then
						helpers.assert_type(world.engine.open_answer_surface("successor owner"), "number")
					elseif change == "runner reset" then world.runner.reset()
					elseif change == "off" then world.runner.set_mode("off")
					elseif change == "pause" then
						package.loaded["modules.shortcuts.script_control"] = { is_paused = function() return true end }
					end
					local expected_revision, expected_hides = world.engine.current_request_revision(), world.hides
					if change == "reset" or change == "replacement" then
						helpers.assert_true(expected_revision ~= revision, "prediction ownership must actually change")
					end
					helpers.assert_true(World.list_local_models(world, { World.CONFIG.default_models["local"] }))
					helpers.assert_eq(#world.posts, change == "current" and 1 or 0,
						"a late available model cannot authorize a retired private payload")
					if change == "current" then
						helpers.assert_true(world.posts[1].url:match("/api/chat$") ~= nil)
						helpers.assert_true(world.posts[1].body.messages[2].content:find(World.SELECTION, 1, true) ~= nil)
					end
					helpers.assert_eq(world.engine.current_request_revision(), expected_revision)
					helpers.assert_eq(world.hides, expected_hides, "retired dispatch must preserve the successor")
					helpers.assert_eq(#world.notices + #world.alerts + #world.installs, 0)
				end)
			end)
		end
	end
end)
