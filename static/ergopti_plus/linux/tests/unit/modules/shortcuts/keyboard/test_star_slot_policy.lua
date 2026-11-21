--- tests/unit/modules/shortcuts/keyboard/test_star_slot_policy.lua

--- ==============================================================================
--- MODULE: The ★ Key's Slot Policy Tests
--- DESCRIPTION:
--- Replays the shared ★ key slot corpus (meta_star, Super+★ here), the
--- explicit-assignment contract, and the evidence this driver gathers for it:
--- what each grabbed key types at its base level, never the magic key.
--- ==============================================================================

local helpers = require("tests.helpers")
require("tests.lua.layouts.star_slot_contract")(helpers, require("core.text.engine.json"),
	helpers.driver_root() .. "/../_shared", "linux")
require("tests.lua.layouts.keyboard_assignment_contract")(helpers)

--- Runs fn with a fake native capture reporting `rows` for the probed keys.
local function with_capture(rows, fn)
	local saved_capture = package.loaded["adapters.xkb_capture"]
	local saved_source = package.loaded["modules.shortcuts.star_key_source"]
	local state = { generation = 4 }
	package.loaded["adapters.xkb_capture"] = {
		source_generation = function() return state.generation end,
		direct_sources = function() return rows end,
	}
	package.loaded["modules.shortcuts.star_key_source"] = nil
	local Source = require("modules.shortcuts.star_key_source")
	local ok, err = pcall(fn, Source, state)
	package.loaded["adapters.xkb_capture"] = saved_capture
	package.loaded["modules.shortcuts.star_key_source"] = saved_source
	if not ok then error(err, 0) end
end

helpers.describe("★ key slot: native evidence", function()
	helpers.it("(star-slot) reports what each key types, so the policy finds the real ★", function()
		with_capture({ { code = 46, text = "★", direct = true, dead = false },
			{ code = 40, text = "ù", direct = true, dead = false } }, function(Source)
			local source = Source.source()
			helpers.assert_eq(source.status, "ready")
			local Policy = require("shortcuts.engine.star_slot_core")
			local selected, reason = Policy.select_source(source, Source.known_codes())
			helpers.assert_eq(reason, nil)
			helpers.assert_eq(selected.native_code, 46)
			helpers.assert_eq(selected.code, "KeyC")
		end)
	end)
	helpers.it("(star-slot) a layout whose keys type no ★ has no source, whatever the magic key", function()
		with_capture({ { code = 40, text = "ù", direct = true, dead = false } }, function(Source)
			local _, reason = require("shortcuts.engine.star_slot_core").select_source(Source.source(), Source.known_codes())
			helpers.assert_eq(reason, "source_missing")
		end)
	end)
	helpers.it("(star-slot) a key a tap owner holds is no direct source", function()
		with_capture({ { code = 46, text = "★", direct = true, dead = false } }, function(Source)
			Source.init({ direct_source_admitted = function(code) return code ~= 46 end })
			local _, reason = require("shortcuts.engine.star_slot_core").select_source(Source.source(), Source.known_codes())
			helpers.assert_eq(reason, "source_requires_modifiers")
		end)
	end)
	helpers.it("(star-slot) a group switch changes the evidence generation", function()
		with_capture({ { code = 46, text = "★", direct = true, dead = false } }, function(Source, state)
			local first = Source.source().generation
			helpers.assert_eq(Source.source().generation, first)
			state.generation = 5
			helpers.assert_true(Source.source().generation ~= first)
		end)
	end)
end)
