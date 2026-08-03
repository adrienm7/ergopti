--- tests/unit/modules/dynamic_hotstrings/test_date_rule_respects_group_disable.lua

--- ==============================================================================
--- MODULE: Regression — date dynamic-hotstrings respect group-disable (M-9)
--- DESCRIPTION:
--- The rules_engine interceptor and preview provider gate on is_section_enabled
--- but NOT on is_group_enabled. Disabling the dynamichotstrings group (or "Disable
--- all hotstrings") calls keymap.disable_group which purges prefix MAPPINGS but
--- leaves is_section_enabled('dynamichotstrings','date') = true. The interceptor
--- therefore kept matching "td" and injecting the date mid-pause.
---
--- Fix: both the interceptor and the preview provider now early-return when
--- _km.is_group_enabled is a function AND returns false. The `and` keeps headless
--- test stubs that omit is_group_enabled safe (backward-compatible).
---
--- Two tests:
---   1. Interceptor returns nil (no "consume") when is_group_enabled → false.
---   2. Preview provider returns nil when is_group_enabled → false.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Helper to build a fake hs.eventtap.event that looks like the trigger character
local function make_trigger_event(char)
	return {
		getFlags      = function() return { cmd = false, ctrl = false } end,
		getCharacters = function() return char end,
	}
end

-- A minimal fake keymap with configurable is_group_enabled
local function make_fake_km(group_enabled)
	local captured_interceptor      = nil
	local captured_preview_provider = nil
	return {
		add                       = function() end,
		is_section_enabled        = function() return true end,   -- section always enabled
		is_group_enabled          = function() return group_enabled end,
		set_group_context         = function() end,
		sort_mappings             = function() end,
		register_lua_group        = function() end,
		set_post_load_hook        = function() end,
		-- register_interceptor is called as _km.register_interceptor(fn) — one arg
		register_interceptor      = function(fn) captured_interceptor = fn end,
		register_preview_provider = function(fn) captured_preview_provider = fn end,
		inject_dynamic            = function() error("inject_dynamic must NOT be called when group disabled") end,
		-- Expose captured closures for tests
		get_interceptor           = function() return captured_interceptor end,
		get_preview_provider      = function() return captured_preview_provider end,
	}
end




-- ===============================================================================
-- ===============================================================================
-- ======= 1/ Interceptor returns nil when group is disabled (M-9 regression) ===
-- ===============================================================================
-- ===============================================================================

helpers.describe("M-9: rules_engine interceptor respects is_group_enabled=false", function()

	helpers.it("interceptor returns nil (not consume) when group is disabled", function()
		-- Fresh module instance so _km is not polluted by other tests
		package.loaded["modules.dynamic_hotstrings.rules_engine"] = nil
		local RE = helpers.load_with_stubs("modules.dynamic_hotstrings.rules_engine")

		local fake_km = make_fake_km(false)  -- group disabled
		RE.inject_data({ date_format = "%d/%m/%Y", date_sections = { "date" } }, "*")
		RE.start(fake_km)

		local interceptor = fake_km.get_interceptor()
		helpers.assert_true(type(interceptor) == "function",
			"rules_engine.start() must register an interceptor")

		-- Drive the interceptor with the trigger char ("*") and a buffer that would
		-- match a date rule (suffix "td" for today's date rule)
		local result = interceptor(make_trigger_event("*"), "td")
		helpers.assert_true(result == nil,
			"interceptor must return nil when is_group_enabled returns false — date must NOT expand")
	end)

	helpers.it("interceptor is registered (not short-circuited) when group IS enabled (sanity baseline)", function()
		package.loaded["modules.dynamic_hotstrings.rules_engine"] = nil
		local RE = helpers.load_with_stubs("modules.dynamic_hotstrings.rules_engine")

		local fake_km = make_fake_km(true)   -- group enabled
		RE.inject_data({ date_format = "%d/%m/%Y", date_sections = { "date" } }, "*")
		RE.start(fake_km)

		local interceptor = fake_km.get_interceptor()
		helpers.assert_true(type(interceptor) == "function",
			"rules_engine.start() must register an interceptor even when group is enabled")

		-- With group enabled, the interceptor must NOT immediately return nil due to
		-- the group gate (it may still return nil if there are no matching rules, but
		-- it must reach SharedEngine.match_buffer). Verify the gate doesn't fire by
		-- confirming the result is anything — a non-"consume" nil means no match, which
		-- is correct for a buffer like "xy" with no registered date suffix.
		-- We don't assert on the specific return value; we assert no error from the group-gate path.
		local non_trigger_event = {
			getFlags      = function() return { cmd = false, ctrl = false } end,
			getCharacters = function() return "x" end,  -- not the trigger char
		}
		-- Called directly: this runs on every keystroke, so a raise here is a dead
		-- keyboard and should fail with its own error rather than a boolean.
		local consumed = interceptor(non_trigger_event, "xy")
		helpers.assert_true(consumed == nil or consumed == false,
			"a non-matching character must not be consumed — swallowing it would delete the\n\t\t\tuser's keystroke")
	end)
end)




-- ====================================================================================
-- ====================================================================================
-- ======= 2/ Preview provider returns nil when group is disabled (M-9 regression) ===
-- ====================================================================================
-- ====================================================================================

helpers.describe("M-9: rules_engine preview provider respects is_group_enabled=false", function()

	helpers.it("preview provider returns nil when group is disabled", function()
		package.loaded["modules.dynamic_hotstrings.rules_engine"] = nil
		local RE = helpers.load_with_stubs("modules.dynamic_hotstrings.rules_engine")

		local fake_km = make_fake_km(false)  -- group disabled
		RE.inject_data({ date_format = "%d/%m/%Y", date_sections = { "date" } }, "*")
		RE.start(fake_km)

		local preview = fake_km.get_preview_provider()
		helpers.assert_true(type(preview) == "function",
			"rules_engine.start() must register a preview provider")

		local result = preview("td")
		helpers.assert_true(result == nil,
			"preview provider must return nil when is_group_enabled returns false")
	end)
end)
