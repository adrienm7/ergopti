--- tests/unit/modules/llm/features/screen_answer/test_repair_consent.lua

--- ==============================================================================
--- MODULE: Screen Model Repair Consent Ownership
--- DESCRIPTION:
--- Runs the actual screen/Engine/local model offer pipeline across its deliberate
--- answer close and held native consent. The healthy repair remains functional;
--- a reset or successor cannot lend its authority to an older Download choice.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.llm.screen_answer_fixture")
local Scope = require("tests.support.modules.llm.selection_translation_scope")

local function with_world(scenario)
	return helpers.with_fresh_modules({ "modules.llm.screen_answer", "modules.llm.local_model_offer",
		"infra.dialog_util", "modules.shortcuts.script_control" }, function()
		return Scope.run(function() return scenario(Fixture.build_world()) end)
	end)
end

local function missing_model(world)
	helpers.assert_true(Fixture.trigger(world, "llm_screen_region", "local"))
	world.captures[#world.captures].on_image("image", "iVBORw0KGgoAAAANSUhEUg==")
	helpers.assert_eq(#world.local_gets, 1, "real local model preflight is pending")
	Fixture.list_local_models(world, {})
end

helpers.describe("screen missing-model repair retains its own consent revision", function()
	helpers.it("downloads after deliberately closing the current failed answer", function()
		with_world(function(world)
			missing_model(world)
			helpers.assert_eq(#world.alerts, 1)
			helpers.assert_eq(world.installs[1], world.flow.config().default_models["local"])
			helpers.assert_eq(#world.local_posts + #world.text_posts, 0)
		end)
	end)

	for _, change in ipairs({ "reset", "successor answer" }) do
		helpers.it("drops a missing-model reply after " .. change .. " before consent", function()
			with_world(function(world)
				helpers.assert_true(Fixture.trigger(world, "llm_screen_region", "local"))
				world.captures[1].on_image("image", "iVBORw0KGgoAAAANSUhEUg==")
				if change == "reset" then helpers.assert_true(world.engine.reset())
				else helpers.assert_not_nil(world.engine.open_answer_surface("new answer")) end
				Fixture.list_local_models(world, {})
				helpers.assert_eq(#world.alerts, 0, "retired failure must not open a repair dialog")
				helpers.assert_eq(#world.installs, 0)
			end)
		end)
	end


	helpers.it("does not borrow the successor created while closing its failed surface", function()
		with_world(function(world)
			local tooltip = require("ui.tooltip")
			local hide = tooltip.hide_forced_silent
			local replaced = false
			tooltip.hide_forced_silent = function(...)
				if not replaced then
					replaced = true
					helpers.assert_not_nil(world.engine.open_answer_surface("successor inside native hide"))
				end
				return hide(...)
			end
			missing_model(world)
			helpers.assert_true(replaced, "closing must cross the actual native surface port")
			helpers.assert_eq(#world.alerts, 0, "a failed close must not lend successor authority")
			helpers.assert_eq(#world.installs, 0)
		end)
	end)


	helpers.it("refuses repair when the failed surface cannot be cleaned up", function()
		with_world(function(world)
			helpers.assert_true(Fixture.trigger(world, "llm_screen_region", "local"))
			world.captures[1].on_image("image", "iVBORw0KGgoAAAANSUhEUg==")
			local tooltip = require("ui.tooltip")
			local hides = 0
			local function refuse_hide() hides = hides + 1; return false end
			tooltip.hide_forced_silent, tooltip.hide = refuse_hide, refuse_hide
			Fixture.list_local_models(world, {})
			helpers.assert_true(hides > 0, "real reset must attempt its native cleanup")
			helpers.assert_eq(#world.alerts, 0)
			helpers.assert_eq(#world.installs, 0)
		end)
	end)

	for _, change in ipairs({ "reset", "preview off", "successor answer", "paused" }) do
		helpers.it("refuses a Download after " .. change .. " inside the native dialog", function()
			with_world(function(world)
				local dialog = require("infra.dialog_util")
				local native_alert = dialog.block_alert
				local changed = false
				dialog.block_alert = function(...)
					changed = true
					if change == "reset" then helpers.assert_true(world.engine.reset())
					elseif change == "preview off" then helpers.assert_true(world.engine.set_preview_ai_enabled(false))
					elseif change == "successor answer" then
						helpers.assert_not_nil(world.engine.open_answer_surface("new answer"))
					else
						package.loaded["modules.shortcuts.script_control"] = { is_paused = function() return true end }
					end
					return native_alert(...)
				end
				missing_model(world)
				helpers.assert_true(changed, "the real consent dialog must have been reached")
				helpers.assert_eq(#world.alerts, 1)
				helpers.assert_eq(#world.installs, 0, "retired repair cannot use a later Download answer")
			end)
		end)
	end
end)
