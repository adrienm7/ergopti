--- tests/unit/hotstrings/engine/dynamic/rules_engine/test_date_rule_expansion_delay.lua

--- ==============================================================================
--- MODULE: Regression — the date hotstrings respect their expansion delay
--- DESCRIPTION:
--- Windows registers td★, dt★ and date★ with the dynamic family's
--- TimeActivationSeconds and Linux gates them through within_delay. The macOS
--- interceptor matched the buffer with no clock at all, so a magic key typed
--- long after the suffix still typed the date. The keymap now hands the
--- interceptor the gap since the preceding physical key and owns the verdict
--- (date-rule-delay).
--- ==============================================================================

local helpers = require("tests.helpers")

local MAGIC = utf8.char(0x2605)

local function key_event(char)
	return {
		getFlags = function() return { cmd = false, ctrl = false } end,
		getCharacters = function() return char end,
	}
end

--- Starts the rules engine on a fake keymap whose delay verdict is recorded.
--- @param allowed boolean What the keymap's delay verdict answers.
--- @return table fixture
local function start(allowed)
	package.loaded["hotstrings.engine.dynamic.core"] = nil
	package.loaded["hotstrings.engine.dynamic.rules_engine"] = nil
	local RulesEngine = helpers.load_with_stubs("hotstrings.engine.dynamic.rules_engine")
	local fixture = { engine = RulesEngine, asked = {} }
	local fake_keymap = {
		is_group_enabled = function() return true end,
		is_section_enabled = function() return true end,
		register_lua_group = function() end,
		set_post_load_hook = function() end,
		register_interceptor = function(fn) fixture.interceptor = fn end,
		register_preview_provider = function() end,
		registry_transaction = function(_, mutation) return mutation() == true end,
		invalidate_hotstring_preview = function() return true end,
		owns_visible_magic_action = function() return false end,
		dynamic_rule_within_delay = function(section, elapsed)
			fixture.asked[#fixture.asked + 1] = { section = section, elapsed = elapsed }
			return allowed
		end,
		inject_dynamic = function(delete_count, result)
			fixture.injection = { delete_count = delete_count, result = result }
			return true
		end,
	}
	helpers.assert_true(RulesEngine.start(fake_keymap))
	helpers.assert_true(RulesEngine.add_rule("qzd", "date", function() return "2026-11-11" end))
	return fixture
end

local function stop(fixture)
	fixture.engine.stop()
	package.loaded["hotstrings.engine.dynamic.core"] = nil
	package.loaded["hotstrings.engine.dynamic.rules_engine"] = nil
end

helpers.describe("dynamic date rules: expansion delay (date-rule-delay)", function()
	helpers.it("types no date once the magic key comes after the delay (date-rule-delay)", function()
		local fixture = start(false)
		local ok, err = xpcall(function()
			local verdict = fixture.interceptor(key_event(MAGIC), "qzd",
				{ chars = MAGIC, flags = { cmd = false, ctrl = false }, elapsed = 5 })
			helpers.assert_nil(verdict, "an expired date rule lets the magic key go on")
			helpers.assert_nil(fixture.injection, "and types nothing")
			helpers.assert_eq(fixture.asked, { { section = "date", elapsed = 5 } },
				"the keymap judged the rule's own section with the gap it measured")
		end, debug.traceback)
		stop(fixture)
		if not ok then error(err, 0) end
	end)

	helpers.it("types the date within the delay (date-rule-delay)", function()
		local fixture = start(true)
		local ok, err = xpcall(function()
			local verdict = fixture.interceptor(key_event(MAGIC), "qzd",
				{ chars = MAGIC, flags = { cmd = false, ctrl = false }, elapsed = 0.1 })
			helpers.assert_eq(verdict, "consume")
			helpers.assert_eq(fixture.injection, { delete_count = 3, result = "2026-11-11" })
		end, debug.traceback)
		stop(fixture)
		if not ok then error(err, 0) end
	end)

	helpers.it("measures the delay with the keymap's own dynamic family resolution (date-rule-delay)", function()
		local Keymap = helpers.load_with_stubs("hotstrings.engine.expander")
		helpers.assert_eq(Keymap.dynamic_rule_within_delay("date", 0), true, "an immediate magic key fires")
		helpers.assert_eq(Keymap.dynamic_rule_within_delay("date", 600), false, "ten minutes later it does not")
		helpers.assert_eq(Keymap.dynamic_rule_within_delay("date", nil), false, "an unknown gap fails closed")
	end)
end)

return true
