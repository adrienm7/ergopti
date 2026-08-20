--- tests/unit/modules/hotstrings/test_dynamic_unicode_suffix.lua

--- ==============================================================================
--- MODULE: Dynamic Hotstring Unicode Suffix Deletion
--- DESCRIPTION:
--- Proves that the Linux injector receives screen-codepoint counts rather than
--- Lua byte lengths for public dynamic rules.
--- ==============================================================================

local helpers = require("tests.helpers")


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
		local saved_manager = package.loaded["modules.dynamic_hotstrings.manager"]
		local saved_engine = package.loaded["dynamic_hotstrings"]
		local saved_injector = package.loaded["modules.hotstrings.injector"]
		package.loaded["modules.dynamic_hotstrings.manager"] = nil
		package.loaded["dynamic_hotstrings"] = nil

		local captured = nil
		package.loaded["modules.hotstrings.injector"] = {
			inject = function(count, text)
				captured = { count = count, text = text }
				return true
			end,
		}

		local ok, err = xpcall(function()
			local manager = require("modules.dynamic_hotstrings.manager")
			manager.init({
				trigger_char = "\\",
				personal_info_path = "/definitely/missing/personal_info.toml",
			})
			manager.set_enabled(true)
			local engine = require("dynamic_hotstrings")
			helpers.assert_true(engine.add_rule("été", "date", function() return "X" end))

			local fired, event = manager.on_trigger("zzété\\", "\\")
			helpers.assert_true(fired == true)
			helpers.assert_not_nil(captured)
			helpers.assert_eq(captured.count, 4,
				"three suffix codepoints plus one trigger codepoint must be deleted")
			helpers.assert_eq(event.backspace_count, 4)
			helpers.assert_eq(apply_replacement("zzété\\", captured.count, captured.text), "zzX",
				"the two preceding screen characters must survive the expansion")
		end, debug.traceback)

		package.loaded["modules.hotstrings.injector"] = saved_injector
		package.loaded["dynamic_hotstrings"] = saved_engine
		package.loaded["modules.dynamic_hotstrings.manager"] = saved_manager
		if not ok then error(err, 0) end
	end)
end)

