--- tests/unit/modules/dynamic_hotstrings/test_start_transaction.lua

--- ==============================================================================
--- MODULE: Dynamic Hotstrings Root Start Transaction
--- DESCRIPTION:
--- Drives a late RulesEngine refusal and exception through the real orchestrator
--- and real PersonalInfo callbacks. A failed child must return false, revoke the
--- append-only sibling callbacks, and permit one clean retry. Root boot must stop
--- before publishing the dynamic group when that false terminal reaches init.lua.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =================================
-- =================================
-- ======= 1/ Test Fixture =========
-- =================================
-- =================================

local function event(char)
	return {
		getFlags = function() return { cmd = false, ctrl = false } end,
		getKeyCode = function() return 0 end,
		getCharacters = function() return char end,
	}
end

local function load_fixture(failure_mode)
	local controls = { failure_mode = failure_mode }
	local state = { interceptors = {}, providers = {}, rules_stops = 0 }
	local rules = {
		inject_data = function() return true end,
		refresh_personal_data = function(_, publisher) return publisher() end,
		start = function()
			if controls.failure_mode == "throw" then error("RULES_START_FAILURE") end
			if controls.failure_mode == "false" then return false end
			return true
		end,
		stop = function()
			state.rules_stops = state.rules_stops + 1
			return true
		end,
		set_trigger_char = function() return true end,
	}
	local keymap = {
		get_trigger_char = function() return "★" end,
		invalidate_hotstring_preview = function() return true end,
		classify_trigger = function() return false, false, false end,
		register_interceptor = function(callback)
			state.interceptors[#state.interceptors + 1] = callback
		end,
		register_preview_provider = function(callback)
			state.providers[#state.providers + 1] = callback
		end,
		inject_dynamic = function() return true end,
	}

	package.loaded["modules.dynamic_hotstrings"] = nil
	package.loaded["modules.dynamic_hotstrings.personal_info"] = nil
	package.loaded["modules.dynamic_hotstrings.rules_engine"] = rules
	local DynamicHotstrings = helpers.load_with_stubs("modules.dynamic_hotstrings")
	local config_path = os.tmpname()
	local config_file, config_err = io.open(config_path, "w")
	helpers.assert_not_nil(config_file,
		"the startup fixture must materialize its empty PersonalInfo TOML: " .. tostring(config_err))
	config_file:close()

	return {
		controls = controls,
		DynamicHotstrings = DynamicHotstrings,
		keymap = keymap,
		config_path = config_path,
		state = state,
	}
end





-- =========================================
-- =========================================
-- ======= 2/ Behavioral Regressions =======
-- =========================================
-- =========================================

helpers.describe("dynamic_hotstrings.start owns both child generations", function()
	for _, failure_mode in ipairs({ "false", "throw" }) do
		helpers.it("rolls PersonalInfo back when RulesEngine reports " .. failure_mode, function()
			local fixture = load_fixture(failure_mode)
			local ok, started = pcall(fixture.DynamicHotstrings.start,
				"", fixture.keymap, fixture.config_path)
			helpers.assert_true(ok, "child exceptions must become a visible false terminal")
			helpers.assert_eq(started, false)
			helpers.assert_eq(fixture.state.rules_stops, 1,
				"rollback must stop the failed rules child")

			local stale_interceptor = fixture.state.interceptors[1]
			local stale_provider = fixture.state.providers[1]
			helpers.assert_type(stale_interceptor, "function")
			helpers.assert_type(stale_provider, "function")
			helpers.assert_eq(stale_interceptor(event("@"), ""), nil,
				"the rolled-back personal interceptor must be inert")
			helpers.assert_eq(stale_provider("@e"), nil,
				"the rolled-back personal preview must be inert")

			fixture.controls.failure_mode = nil
			helpers.assert_true(fixture.DynamicHotstrings.start(
				"", fixture.keymap, fixture.config_path),
				"successful retry must publish an exact commit terminal")
			helpers.assert_true(fixture.DynamicHotstrings.start(
				"", fixture.keymap, fixture.config_path),
				"idempotent start must preserve the committed generation")
			helpers.assert_eq(fixture.DynamicHotstrings.start(
				"", {}, fixture.config_path), false,
				"a committed core must reject silent ownership transfer")
			helpers.assert_eq(stale_interceptor(event("@"), ""), nil,
				"retry must not reactivate the failed generation")
			helpers.assert_eq(stale_provider("@e"), nil,
				"retry must not reactivate the failed preview")

			local live_interceptor = fixture.state.interceptors[#fixture.state.interceptors]
			local live_provider = fixture.state.providers[#fixture.state.providers]
			live_interceptor(event("@"), "")
			live_interceptor(event("e"), "@")
			helpers.assert_type(live_provider("@e"), "string",
				"the retry generation must be the sole live provider")
			fixture.DynamicHotstrings.stop()
			helpers.assert_eq(live_provider("@e"), nil,
				"root stop must revoke the committed provider")
			os.remove(fixture.config_path)
		end)
	end

	helpers.it("fails root boot before publishing the dynamic hotfile", function()
		local source, err = helpers.read_driver_unit("local function has_common_hotstring_groups")
		helpers.assert_true(source ~= nil, "root init.lua must be unique: " .. tostring(err))
		local call_at = source:find("local dynamic_hotstrings_started = dynamic_hotstrings.start", 1, true)
		local check_at = source:find("if dynamic_hotstrings_started ~= true then", call_at or 1, true)
		local error_at = source:find('error("dynamic_hotstrings.start did not commit")', check_at or 1, true)
		local publish_at = source:find('table.insert(hotfiles, "dynamichotstrings")', call_at or 1, true)
		helpers.assert_true(call_at ~= nil and check_at ~= nil and error_at ~= nil and publish_at ~= nil)
		helpers.assert_true(call_at < check_at and check_at < error_at and error_at < publish_at,
			"boot must fail fast before claiming the dynamic group is available")
	end)
end)

return true
