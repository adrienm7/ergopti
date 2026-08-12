--- tests/unit/modules/dynamic_hotstrings/test_personal_info_trigger_char_sync.lua

--- ==============================================================================
--- MODULE: Regression — the @-tag engine must follow the live magic key
--- DESCRIPTION:
--- personal_info's trigger was read once at boot from personal_info.toml, whose
--- loader always returns its own DEFAULT_CONFIG value, and the module exposed no
--- setter. dynamic_hotstrings proxied set_trigger_char straight to RulesEngine,
--- so the live sync in menu_state reached the date/prefix engine and never the
--- @-tag one.
---
--- ROOT CAUSE ENCODED:
--- The sibling defect was already found and fixed for RulesEngine. The proxy that
--- carried that fix names ONE of a pair, so the @-tag engine kept listening for a
--- key the user had stopped typing — while its preview provider, which derives
--- its answer from the keymap buffer and carries no trigger of its own, went on
--- advertising the expansion. That is the tooltip promising what the engine can
--- no longer deliver.
---
--- Both cases drive the REAL interceptor registered by the real module, so a fix
--- that only renames a field cannot satisfy them.
--- ==============================================================================

local helpers = require("tests.helpers")
local NBSP = string.char(0xC2, 0xA0)

-- Deliberately not "★": every assertion here is about the module listening to the
-- keymap rather than to its own TOML default.
local BOOT_TRIGGER  = "µ"
local LIVE_TRIGGER  = "§"
local STALE_TRIGGER = "★"


--- A fake keymap exposing what both engines consume, capturing EVERY registered
--- interceptor rather than only the last: this module registers one and its
--- sibling registers another, and the bug lives in the first.
--- @param custom_trigger string What get_trigger_char() reports.
--- @return table Fake keymap with an `interceptors` list.
local function make_fake_keymap(custom_trigger, preview_fence)
	local interceptors = {}
	return {
		get_trigger_char          = function() return custom_trigger end,
		is_section_enabled        = function() return true end,
		is_group_enabled          = function() return true end,
		register_lua_group        = function() end,
		set_post_load_hook        = function() end,
		set_group_context         = function() end,
		sort_mappings             = function() end,
		add                       = function() end,
		inject_dynamic            = function() return true end,
		register_interceptor      = function(fn) interceptors[#interceptors + 1] = fn end,
		register_preview_provider = function() end,
		invalidate_hotstring_preview = preview_fence or function() return true end,
		interceptors              = interceptors,
	}
end


--- Builds a fake keyDown event reporting one character.
--- @param char string
--- @return table
local function make_key_event(char)
	return {
		getFlags      = function() return { cmd = false, ctrl = false } end,
		getKeyCode    = function() return 0 end,
		getCharacters = function() return char end,
	}
end


--- Boots the whole dynamic-hotstrings core against a fake keymap.
--- @param trigger string The magic key the fake keymap reports.
--- @return table DynHot, table keymap
local function boot(trigger, preview_fence)
	package.loaded["modules.dynamic_hotstrings"]               = nil
	package.loaded["modules.dynamic_hotstrings.rules_engine"]  = nil
	package.loaded["modules.dynamic_hotstrings.personal_info"] = nil
	local DynHot = helpers.load_with_stubs("modules.dynamic_hotstrings")
	local km     = make_fake_keymap(trigger, preview_fence)
	-- A scratch path so no personal_info.toml is materialised into the real tree.
	DynHot.start("", km, os.tmpname())
	DynHot.enable()
	return DynHot, km
end


--- Feeds "@e<trigger>" to the @-tag interceptor and returns its verdict.
--- @param km table The fake keymap holding the captured interceptors.
--- @param trigger string The character to fire with.
--- @return string|nil The interceptor's return value for the trigger keystroke.
local function feed_at_combo(km, trigger)
	local interceptor = km.interceptors[1]
	helpers.assert_type(interceptor, "function", "personal_info must register an interceptor")
	interceptor(make_key_event("@"), "")
	interceptor(make_key_event("e"), "@")
	return interceptor(make_key_event(trigger), "@e")
end




-- ==================================================================
-- ==================================================================
-- ======= 1/ The boot trigger comes from the keymap ================
-- ==================================================================
-- ==================================================================

helpers.describe("personal_info: the @-tag engine boots on the keymap's magic key", function()

	helpers.it("fires on the keymap's trigger, not on personal_info.toml's default", function()
		local _, km = boot(BOOT_TRIGGER)
		helpers.assert_eq(feed_at_combo(km, BOOT_TRIGGER), "consume",
			"the @-tag engine must listen to the user's configured magic key; reading it from "
			.. "personal_info.toml leaves the engine deaf on any non-default key")
	end)

	helpers.it("does not fire on the stale default once the keymap reports another key", function()
		local _, km = boot(BOOT_TRIGGER)
		helpers.assert_eq(feed_at_combo(km, STALE_TRIGGER), nil,
			"the personal_info.toml default must have no special power once the magic key differs")
	end)

end)




-- ==================================================================
-- ==================================================================
-- ======= 2/ A live magic-key change reaches BOTH engines ==========
-- ==================================================================
-- ==================================================================

helpers.describe("dynamic_hotstrings.set_trigger_char: both engines follow, not just one", function()

	helpers.it("the @-tag engine fires on the new key after a live change", function()
		local DynHot, km = boot(BOOT_TRIGGER)
		helpers.assert_true(DynHot.set_trigger_char(LIVE_TRIGGER))
		helpers.assert_eq(feed_at_combo(km, LIVE_TRIGGER), "consume",
			"menu_state's live sync must reach the @-tag engine; a proxy aliased to one engine "
			.. "of a pair delivers half the fix")
	end)

	helpers.it("and stops firing on the key it was booted with", function()
		local DynHot, km = boot(BOOT_TRIGGER)
		helpers.assert_true(DynHot.set_trigger_char(LIVE_TRIGGER))
		helpers.assert_eq(feed_at_combo(km, BOOT_TRIGGER), nil,
			"the superseded key must go silent, otherwise two keys expand at once")
	end)

	helpers.it("rejects an invalid trigger instead of silently blanking the engine", function()
		local DynHot, km = boot(BOOT_TRIGGER)
		helpers.assert_eq(DynHot.set_trigger_char(nil), false)
		helpers.assert_eq(feed_at_combo(km, BOOT_TRIGGER), "consume",
			"a rejected setter call must leave the previous trigger intact — failing open to "
			.. "an empty trigger would disable the engine with no diagnostic")
	end)

	helpers.it("keeps both engines on the old key when preview revocation fails", function()
		local DynHot, km = boot(BOOT_TRIGGER, function() return false end)
		helpers.assert_eq(DynHot.set_trigger_char(LIVE_TRIGGER), false,
			"the paired mutation must reject a rules-engine fence failure")
		helpers.assert_eq(feed_at_combo(km, LIVE_TRIGGER), nil,
			"personal info must not advance alone to the new key")
		helpers.assert_eq(feed_at_combo(km, BOOT_TRIGGER), "consume",
			"the previously committed key must remain live in personal info")
	end)

	helpers.it("accepts the French composite event for a punctuation magic key", function()
		local _, km = boot(":")
		helpers.assert_eq(feed_at_combo(km, NBSP .. ":"), "consume",
			"the @-tag engine must accept the layout's single NBSP+colon keyDown payload")
	end)

end)
