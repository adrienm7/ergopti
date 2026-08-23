--- tests/unit/ui/menu/menu_llm/test_trigger_profile_owner_gate.lua

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"infra.logger",
	"modules.llm",
	"chord",
	"adapters.hotkey_registrar",
	"ui.menu.shortcut_utils",
	"ui.menu.menu_llm.trigger_orchestrator",
}

local function with_fixture(body)
	local saved = {}
	for _, name in ipairs(OWNED_MODULES) do saved[name] = package.loaded[name] end
	local ok, err = xpcall(function()
		local profile = "basic"
		local set_plan = {}
		local set_calls = {}
		local prediction_calls = 0
		local trigger_mode = "success"

		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["modules.llm"] = {
			BUILTIN_PROFILES = {
				{id = "basic", label = "Basic"},
				{id = "advanced", label = "Advanced"},
			},
			set_active_profile = function(profile_id)
				set_calls[#set_calls + 1] = profile_id
				local mode = table.remove(set_plan, 1) or "success"
				if mode == "mutate_false" then profile = profile_id; return false end
				if mode == "mutate_nil" then profile = profile_id; return nil end
				if mode == "mutate_throw" then profile = profile_id; error("profile setter refusal", 0) end
				if mode == "false" then return false end
				if mode == "nil" then return nil end
				if mode == "throw" then error("profile setter refusal", 0) end
				profile = profile_id
				return true
			end,
		}
		package.loaded["chord"] = {}
		package.loaded["adapters.hotkey_registrar"] = {}
		package.loaded["ui.menu.shortcut_utils"] = {}
		package.loaded["ui.menu.menu_llm.trigger_orchestrator"] = nil

		local orchestrator = require("ui.menu.menu_llm.trigger_orchestrator").new({
			state = {
				llm_active_profile = "basic",
				llm_user_profiles = {},
			},
			keymap = {
				reset_predictions = function() return true end,
				trigger_prediction = function()
					prediction_calls = prediction_calls + 1
					if trigger_mode == "throw" then error("prediction refusal", 0) end
				end,
			},
			save_prefs = function() return true end,
			update_menu = function() return true end,
			get_startup_silence = function() return false end,
			get_trigger_hk = function() return nil end,
			set_trigger_hk = function() end,
			get_profile_hks = function() return {} end,
			set_profile_hk = function() end,
		})

		body({
			get_profile = function() return profile end,
			get_prediction_calls = function() return prediction_calls end,
			get_set_calls = function() return set_calls end,
			orchestrator = orchestrator,
			plan_set = function(plan)
				set_plan = {}
				for index, mode in ipairs(plan) do set_plan[index] = mode end
			end,
			set_trigger_mode = function(mode) trigger_mode = mode end,
		})
	end, debug.traceback)
	for _, name in ipairs(OWNED_MODULES) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

helpers.describe("profile-trigger exact owner gate", function()
	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("does not trigger when candidate activation returns " .. mode, function()
			with_fixture(function(fixture)
				fixture.plan_set({mode, "success"})
				helpers.assert_eq(
					fixture.orchestrator.trigger_prediction_with_profile("advanced"), false)
				helpers.assert_eq(fixture.get_prediction_calls(), 0)
				helpers.assert_eq(fixture.get_profile(), "basic")
				local calls = fixture.get_set_calls()
				helpers.assert_eq(calls[1], "advanced")
				helpers.assert_eq(calls[2], "basic")
			end)
		end)
	end

	for _, mode in ipairs({"mutate_false", "mutate_nil", "mutate_throw"}) do
		helpers.it("retries an exact rollback debt after " .. mode, function()
			with_fixture(function(fixture)
				fixture.plan_set({mode, "false"})
				helpers.assert_eq(
					fixture.orchestrator.trigger_prediction_with_profile("advanced"), false)
				helpers.assert_eq(fixture.get_prediction_calls(), 0)
				helpers.assert_eq(fixture.get_profile(), "advanced")

				fixture.plan_set({"success", "success", "success"})
				helpers.assert_true(
					fixture.orchestrator.trigger_prediction_with_profile("advanced"))
				helpers.assert_eq(fixture.get_prediction_calls(), 1)
				helpers.assert_eq(fixture.get_profile(), "basic")
			end)
		end)
	end

	helpers.it("restores the prior profile when prediction raises", function()
		with_fixture(function(fixture)
			fixture.plan_set({"success", "success"})
			fixture.set_trigger_mode("throw")
			helpers.assert_eq(
				fixture.orchestrator.trigger_prediction_with_profile("advanced"), false)
			helpers.assert_eq(fixture.get_prediction_calls(), 1)
			helpers.assert_eq(fixture.get_profile(), "basic")
		end)
	end)

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("retains and retries restoration after " .. mode, function()
			with_fixture(function(fixture)
				fixture.plan_set({"success", mode})
				helpers.assert_eq(
					fixture.orchestrator.trigger_prediction_with_profile("advanced"), false)
				helpers.assert_eq(fixture.get_profile(), "advanced")
				helpers.assert_eq(fixture.get_prediction_calls(), 1)

				fixture.plan_set({"success", "success", "success"})
				helpers.assert_true(
					fixture.orchestrator.trigger_prediction_with_profile("advanced"))
				helpers.assert_eq(fixture.get_profile(), "basic")
				helpers.assert_eq(fixture.get_prediction_calls(), 2)
			end)
		end)
	end
end)
