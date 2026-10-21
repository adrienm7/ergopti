--- tests/unit/modules/llm/agent/consent/test_local_model_postclose_authority.lua

--- ==============================================================================
--- MODULE: Agent Model Repair Consent Authority
--- DESCRIPTION:
--- Drives the real agent, local model listing, answer surface and install offer.
--- A manual failure closes its own surface before asking for consent; that new
--- revision must remain owned through native cleanup and the modal Download.
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

--- Keeps the complete real requester and every native callback in one scope.
--- @param scenario function Receives the real agent world.
local function with_agent(scenario)
	helpers.with_fresh_modules(OWNED, function()
		Scope.run(function()
			local world = World.build_world({ system2 = "local" })
			world.alert_answer = "first"
			scenario(world)
		end)
	end)
end

--- Starts the real missing-model lookup without completing its HTTP listing.
--- @param world table Agent world.
local function start_lookup(world)
	helpers.assert_true(World.trigger(world, "llm_agent_selection"))
	helpers.assert_eq(#world.gets, 1, "the original model listing must be pending")
	helpers.assert_eq(#world.posts, 0)
end

--- Changes only the prediction owner, leaving the agent run generation intact.
--- @param world table Agent world.
--- @param change string Reset or replacement.
local function revoke_surface(world, change)
	local before = world.engine.current_request_revision()
	if change == "reset" then helpers.assert_true(world.engine.reset())
	else helpers.assert_type(world.engine.open_answer_surface("successor owner"), "number") end
	helpers.assert_true(world.engine.current_request_revision() ~= before, "the exact surface owner must change")
end

helpers.describe("agent repair consent retains its post-close owner", function()
	helpers.it("downloads a missing model after its own successful surface closure", function()
		with_agent(function(world)
			start_lookup(world)
			local request_revision = world.engine.current_request_revision()
			local dialog = require("infra.dialog_util")
			local native_alert = dialog.block_alert
			dialog.block_alert = function(...)
				helpers.assert_true(world.engine.current_request_revision() ~= request_revision,
					"the original failed surface must close before native consent")
				return native_alert(...)
			end
			World.list_local_models(world, {})
			helpers.assert_eq(#world.alerts, 1)
			helpers.assert_eq(#world.installs, 1)
			helpers.assert_eq(world.installs[1].model, World.CONFIG.default_models["local"])
			helpers.assert_eq(#world.posts, 0)
		end)
	end)

	for _, change in ipairs({ "reset", "replacement" }) do
		helpers.it("refuses Download after prediction " .. change .. " during the native dialog", function()
			with_agent(function(world)
				start_lookup(world)
				local dialog = require("infra.dialog_util")
				local native_alert = dialog.block_alert
				dialog.block_alert = function(...)
					revoke_surface(world, change)
					return native_alert(...)
				end
				World.list_local_models(world, {})
				helpers.assert_eq(#world.alerts, 1, "the actual Download prompt must have opened")
				helpers.assert_eq(#world.installs, 0, "a revoked post-close owner cannot install a model")
			end)
		end)

		helpers.it("does not ask for repair after prediction " .. change .. " during model listing", function()
			with_agent(function(world)
				start_lookup(world)
				revoke_surface(world, change)
				World.list_local_models(world, {})
				helpers.assert_eq(#world.alerts, 0)
				helpers.assert_eq(#world.installs, 0)
				helpers.assert_eq(#world.posts, 0)
			end)
		end)
	end

	helpers.it("refuses consent when native surface cleanup is not acknowledged", function()
		with_agent(function(world)
			start_lookup(world)
			local hides = 0
			local function refused() hides = hides + 1; return false end
			local tooltip = require("ui.tooltip")
			tooltip.hide_forced_silent, tooltip.hide_forced, tooltip.hide = refused, refused, refused
			World.list_local_models(world, {})
			helpers.assert_true(hides > 0, "the real reset must attempt native surface cleanup")
			helpers.assert_eq(#world.alerts, 0, "failed close cannot publish repair consent")
			helpers.assert_eq(#world.installs, 0)
		end)
	end)

	helpers.it("preserves a successor opened reentrantly during native surface cleanup", function()
		with_agent(function(world)
			start_lookup(world)
			local successor
			local tooltip = require("ui.tooltip")
			tooltip.hide_forced_silent = function()
				successor = world.engine.open_answer_surface("reentrant successor")
				helpers.assert_type(successor, "number")
				return true
			end
			World.list_local_models(world, {})
			helpers.assert_type(successor, "number", "native cleanup must actually create the successor")
			helpers.assert_eq(world.engine.current_request_revision(), successor)
			helpers.assert_eq(#world.alerts, 0)
			helpers.assert_eq(#world.installs, 0)
		end)
	end)
end)
