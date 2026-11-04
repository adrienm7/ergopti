--- tests/unit/modules/llm/agent/dispatch/test_tools_listing_ai_authority.lua

--- ==============================================================================
--- MODULE: Agent Tool Listing AI Authority
--- DESCRIPTION:
--- Compose the real Agent, connectors, shell runner and prediction engine over
--- a held native Shortcuts completion. The HTTP boundary captures dispatches;
--- no network request or user action is executed by this fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local World = require("tests.support.agent_world")
local Scope = require("tests.support.modules.llm.selection_translation_scope")
require("logger")

local OWNED = {
	"modules.llm.agent_runner", "modules.llm.agent_learning", "modules.llm.agent_connectors",
	"llm.agent", "llm.agent_learning", "adapters.system_info", "infra.locale",
	"infra.dialog_util", "modules.llm.local_model_offer", "locale.core", "modules.shortcuts.script_control",
	"modules.shortcuts.ai_actions",
}

--- Holds only the native process boundary, preserving the real connector API.
--- @param options table Agent settings.
--- @param scenario function Receives the world and exact listing completion.
local function with_pending_tools(options, scenario)
	helpers.with_fresh_modules(OWNED, function()
		Scope.run(function()
			local world = World.build_world(options)
			local native_new = _G.hs.task.new
			local pending = {}
			_G.hs.task.new = function(executable, callback, ...)
				local task = native_new(executable, callback, ...)
				if executable == "/usr/bin/shortcuts" then
					local args = ...
					helpers.assert_eq(args[1], "list")
					local running = true
					task.isRunning = function() return running end
					pending[#pending + 1] = function()
						running = false
						callback(0, "Mode focus\n", "")
						helpers.assert_nil(require("adapters.shell_runner")._active_tasks[task],
							"the exact native completion must release the real shell runner pin")
					end
				end
				return task
			end
			package.loaded["modules.llm.agent_connectors"] = nil
			require("modules.llm.agent_connectors")
			local function finish_listing()
				helpers.assert_eq(#pending, 1, "the native Shortcuts list must be the pending stage")
				pending[1]()
			end
			scenario(world, finish_listing)
		end)
	end)
end

helpers.describe("Agent authority across held native tool discovery", function()
	for _, reenable in ipairs({ false, true }) do
		helpers.it("revokes a pending tool-list action across AI off, reenable=" .. tostring(reenable)
			.. " (agent-tool-ai-epoch)", function()
			with_pending_tools({}, function(world, finish_listing)
				helpers.assert_true(world.runner.run_selection())
				helpers.assert_eq(#world.posts, 0)
				helpers.assert_eq(world.loadings, 0, "the action must still be waiting for tools")
				world.engine.set_llm_enabled(false)
				helpers.assert_eq(world.engine.get_llm_enabled(), false)
				if reenable then world.engine.set_llm_enabled(true) end
				finish_listing()
				helpers.assert_eq(#world.posts, 0, "late local tools cannot dispatch retired private input to HTTP")
				helpers.assert_eq(world.loadings, 0, "a retired action cannot create a new answer surface")
			end)
		end)

		helpers.it("revokes a pending local model list across AI off, reenable=" .. tostring(reenable)
			.. " (agent-tool-ai-epoch)", function()
			with_pending_tools({ system2 = "local" }, function(world, finish_listing)
				helpers.assert_true(world.runner.run_selection())
				finish_listing()
				helpers.assert_eq(#world.gets, 1, "the original model list must now be pending")
				world.engine.set_llm_enabled(false)
				if reenable then world.engine.set_llm_enabled(true) end
				helpers.assert_true(World.list_local_models(world, { World.CONFIG.default_models["local"] }))
				helpers.assert_eq(#world.posts, 0)
				helpers.assert_eq(#world.renders + #world.installs, 0)
			end)
		end)
	end

	for _, transition in ipairs({ "current", "replacement", "off-on replacement" }) do
		helpers.it("admits the " .. transition .. " action after the exact tools completion (agent-tool-ai-epoch)", function()
			with_pending_tools({}, function(world, finish_listing)
				helpers.assert_true(world.runner.run_selection())
				if transition ~= "current" then
					if transition == "off-on replacement" then
						world.engine.set_llm_enabled(false)
						world.engine.set_llm_enabled(true)
					end
					world.selection = "Successor fixture input"
					helpers.assert_true(world.runner.run_selection())
				end
				finish_listing()
				helpers.assert_eq(#world.posts, 1, "only one current action may reach the HTTP capture")
				local expected = transition == "current" and World.SELECTION or "Successor fixture input"
				helpers.assert_not_nil(world.posts[1].body.messages[2].content:find(expected, 1, true))
			end)
		end)
	end
end)
