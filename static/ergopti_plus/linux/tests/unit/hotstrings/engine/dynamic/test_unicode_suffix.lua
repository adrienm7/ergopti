--- tests/unit/hotstrings/engine/dynamic/test_unicode_suffix.lua

--- ==============================================================================
--- MODULE: Dynamic Hotstring Unicode Suffix Deletion
--- DESCRIPTION:
--- Proves that the Linux injector receives screen-codepoint counts rather than
--- Lua byte lengths for public dynamic rules.
--- ==============================================================================

local helpers = require("tests.helpers")
local restore_family_preferences = require("tests.support.dynamic_hotstrings_fixture").install()


--- Applies a captured codepoint deletion and replacement to simulated text.
--- @param text string Original screen text.
--- @param delete_count number Number of screen codepoints to remove.
--- @param replacement string Replacement text.
--- @return string result
local function apply_replacement(text, delete_count, replacement)
	local chars = {}
	for _, codepoint in utf8.codes(text) do chars[#chars + 1] = utf8.char(codepoint) end
	for _ = 1, delete_count do table.remove(chars) end
	return table.concat(chars) .. replacement
end


helpers.describe("dynamic hotstrings: Unicode suffix deletion", function()
	helpers.it("deletes a non-ASCII suffix by codepoint rather than byte", function()
		local saved_manager = package.loaded["hotstrings.engine.dynamic.manager"]
		local saved_engine = package.loaded["hotstrings.engine.dynamic.core"]
		local saved_injector = package.loaded["hotstrings.engine.injector"]
		package.loaded["hotstrings.engine.dynamic.manager"] = nil
		package.loaded["hotstrings.engine.dynamic.core"] = nil

		local captured = nil
		package.loaded["hotstrings.engine.injector"] = {
			inject = function(count, text)
				captured = { count = count, text = text }
				return { ok = true }
			end,
		}

		local ok, err = xpcall(function()
			local manager = require("hotstrings.engine.dynamic.manager")
			manager.init({
				trigger_char = "\\",
				personal_info_path = "/definitely/missing/personal_info.toml",
			})
			manager.set_enabled(true)
			local engine = require("hotstrings.engine.dynamic.core")
			helpers.assert_true(engine.add_rule("été", "date", function() return "X" end))

			local fired, event = require("tests.support.dynamic_hotstrings_fixture").trigger(manager, "zzété\\", "\\")
			helpers.assert_true(fired == true)
			helpers.assert_not_nil(captured)
			helpers.assert_eq(captured.count, 4,
				"three suffix codepoints plus one trigger codepoint must be deleted")
			helpers.assert_eq(event.backspace_count, 4)
			helpers.assert_eq(apply_replacement("zzété\\", captured.count, captured.text), "zzX",
				"the two preceding screen characters must survive the expansion")
		end, debug.traceback)

		package.loaded["hotstrings.engine.injector"] = saved_injector
		package.loaded["hotstrings.engine.dynamic.core"] = saved_engine
		package.loaded["hotstrings.engine.dynamic.manager"] = saved_manager
		if not ok then error(err, 0) end
	end)
end)

restore_family_preferences()
