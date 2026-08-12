--- tests/unit/modules/dynamic_hotstrings/test_rules_engine_trigger_char_sync.lua

--- ==============================================================================
--- MODULE: Regression — dynamic_hotstrings sources the trigger from keymap (F-HIGH-8)
--- DESCRIPTION:
--- dynamic_hotstrings/init.lua used to source the RulesEngine's "global" trigger
--- character from PersonalInfo.get_trigger_char() — itself just personal_info.toml's
--- own independent default — instead of keymap_module.get_trigger_char(), the real
--- user-configurable magic key backed by CoreState.magic_key. Changing the magic
--- key via the menu never reached RulesEngine, permanently orphaning every
--- date/prefix rule the moment a user customized it.
---
--- Fix: M.start() now sources the trigger from keymap_module.get_trigger_char(),
--- and a live RulesEngine.set_trigger_char(char) is wired into menu_state.lua's
--- sync so a later magic-key change also reaches this engine without a reload.
---
--- This test drives the REAL boot order (modules.dynamic_hotstrings.M.start) with
--- a fake keymap module whose get_trigger_char() returns a custom character, and
--- asserts the interceptor captured via register_interceptor fires on that custom
--- character, not the "★" default that personal_info.toml would have supplied.
--- ==============================================================================

local helpers = require("tests.helpers")
local NBSP = string.char(0xC2, 0xA0)

-- A fake keymap module exposing exactly what PersonalInfo.start / RulesEngine.start
-- consume, mirroring the shape used by test_date_rule_respects_group_disable.lua.
-- get_trigger_char() is the load-bearing addition: it returns a magic key distinct
-- from "★" so the test can prove RulesEngine listens to IT, not to personal_info.toml.
local function make_fake_keymap(custom_trigger)
	local captured_interceptor = nil
	local injected_count = 0
	return {
		get_trigger_char          = function() return custom_trigger end,
		is_section_enabled        = function() return true end,
		is_group_enabled          = function() return true end,
		register_lua_group        = function() end,
		set_post_load_hook        = function() end,
		set_group_context         = function() end,
		sort_mappings             = function() end,
		-- register_prefix_entries() registers the default personal-info phone/SSN/IBAN
		-- prefixes via _km.add() — a no-op here since this test only cares about the
		-- interceptor's trigger-char gate, not the registered mappings themselves.
		add                       = function() end,
		register_interceptor      = function(fn) captured_interceptor = fn end,
		register_preview_provider = function() end,
		get_interceptor           = function() return captured_interceptor end,
		inject_dynamic            = function(delete_count, replacement, emitter, source, is_private)
			helpers.assert_eq(delete_count, 2, "the matched 'td' suffix must delete two characters")
			helpers.assert_true(type(replacement) == "string" and replacement ~= "",
				"the date rule must resolve to non-empty text")
			helpers.assert_eq(type(emitter), "function")
			helpers.assert_eq(source, "dynamic")
			helpers.assert_eq(is_private, true)
			injected_count = injected_count + 1
			return true
		end,
		get_injected_count        = function() return injected_count end,
	}
end

--- Builds a fake hs.eventtap.event that reports the given character.
--- @param char string The character the event should report via getCharacters.
--- @return table Fake event.
local function make_key_event(char)
	return {
		getFlags      = function() return { cmd = false, ctrl = false } end,
		getCharacters = function() return char end,
	}
end




-- ==============================================================================================
-- ==============================================================================================
-- ======= 1/ dynamic_hotstrings.start sources the trigger from keymap (F-HIGH-8 fix) ==========
-- ==============================================================================================
-- ==============================================================================================

helpers.describe("dynamic_hotstrings.start: RulesEngine listens to keymap's trigger, not personal_info's (F-HIGH-8)", function()

	helpers.it("interceptor fires on the fake keymap's custom trigger char, not the personal_info.toml default '★'", function()
		-- Fresh module instances so no other test's captured interceptor/trigger leaks in.
		package.loaded["modules.dynamic_hotstrings"]             = nil
		package.loaded["modules.dynamic_hotstrings.rules_engine"] = nil
		package.loaded["modules.dynamic_hotstrings.personal_info"] = nil
		local DynHot = helpers.load_with_stubs("modules.dynamic_hotstrings")

		-- A scratch path with no [trigger_char] override, so PersonalInfo's own
		-- config load falls back to its DEFAULT_CONFIG.trigger_char = "★" — this
		-- is the wrong value the bug used to leak into RulesEngine.
		local scratch_toml = os.tmpname()

		local CUSTOM_TRIGGER = "%"
		local fake_km = make_fake_keymap(CUSTOM_TRIGGER)

		local ok, err = pcall(DynHot.start, "/tmp/", fake_km, scratch_toml)
		os.remove(scratch_toml)
		helpers.assert_true(ok, "dynamic_hotstrings.start must not raise with a fake keymap: " .. tostring(err))
		helpers.assert_nil(err, "and must report no error")

		local interceptor = fake_km.get_interceptor()
		helpers.assert_true(type(interceptor) == "function",
			"dynamic_hotstrings.start must register an interceptor via the keymap module")

		-- The "★" default must NOT fire the interceptor's trigger-char gate anymore —
		-- proving RulesEngine is no longer listening to personal_info.toml's value.
		local star_result = interceptor(make_key_event("★"), "td")
		helpers.assert_true(star_result == nil,
			"interceptor must NOT fire on the personal_info.toml default '★' once the keymap trigger differs")
		helpers.assert_eq(fake_km.get_injected_count(), 0,
			"the rejected trigger must not reach the replacement transaction")

		-- The keymap's custom trigger char DOES fire the gate (reaches match_buffer;
		-- returning "consume" for the registered "td" date rule proves the trigger
		-- comparison at rules_engine.lua's interceptor passed).
		local custom_result = interceptor(make_key_event(CUSTOM_TRIGGER), "td")
		helpers.assert_eq(custom_result, "consume",
			"interceptor must fire and consume on the keymap's custom trigger char")
		helpers.assert_eq(fake_km.get_injected_count(), 1,
			"the accepted trigger must execute exactly one replacement transaction")
	end)

	helpers.it("accepts the French composite event for a punctuation trigger", function()
		package.loaded["modules.dynamic_hotstrings"] = nil
		package.loaded["modules.dynamic_hotstrings.rules_engine"] = nil
		package.loaded["modules.dynamic_hotstrings.personal_info"] = nil
		local DynHot = helpers.load_with_stubs("modules.dynamic_hotstrings")
		local fake_km = make_fake_keymap(":")
		local scratch_toml = os.tmpname()
		DynHot.start("/tmp/", fake_km, scratch_toml)
		os.remove(scratch_toml)

		local result = fake_km.get_interceptor()(make_key_event(NBSP .. ":"), "td")
		helpers.assert_eq(result, "consume",
			"the date engine must accept the layout's single NBSP+colon keyDown payload")
		helpers.assert_eq(fake_km.get_injected_count(), 1)
	end)
end)
