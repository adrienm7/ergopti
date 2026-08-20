--- tests/unit/modules/dynamic_hotstrings/test_rules_engine_utf8_delete_count.lua

--- ==============================================================================
--- REGRESSION: dynamic suffix deletion is measured in codepoints (HS-006)
--- ==============================================================================

local helpers = require("tests.helpers")

local MAGIC = utf8.char(0x2605)

local function key_event(char)
	return {
		getFlags = function() return { cmd = false, ctrl = false } end,
		getCharacters = function() return char end,
	}
end

local function remove_codepoints(value, count)
	if count == 0 then return value end
	local offset = utf8.offset(value, -count)
	if not offset then return "" end
	return value:sub(1, offset - 1)
end

helpers.describe("dynamic UTF-8 delete count", function()
	helpers.it("dynamic UTF-8 delete count removes codepoints rather than bytes", function()
		package.loaded["dynamic_hotstrings"] = nil
		package.loaded["modules.dynamic_hotstrings.rules_engine"] = nil
		local RulesEngine = helpers.load_with_stubs("modules.dynamic_hotstrings.rules_engine")

		local interceptor
		local provider
		local visible_token
		local visible_buffer
		local injection
		local fake_keymap = {
			is_group_enabled = function() return true end,
			is_section_enabled = function() return true end,
			register_lua_group = function() end,
			set_post_load_hook = function() end,
			register_interceptor = function(fn) interceptor = fn end,
			register_preview_provider = function(fn) provider = fn end,
			registry_transaction = function(_, mutation) return mutation() == true end,
			invalidate_hotstring_preview = function() return true end,
			owns_visible_magic_action = function(token, buffer)
				return token == visible_token and buffer == visible_buffer
			end,
			inject_dynamic = function(delete_count, result, _emitter, source, is_private)
				injection = {
					delete_count = delete_count,
					result = result,
					source = source,
					is_private = is_private,
				}
				return true
			end,
		}

		local ok, err = xpcall(function()
			helpers.assert_true(RulesEngine.start(fake_keymap))
			helpers.assert_true(RulesEngine.add_rule("été", "date", function() return "X" end))
			visible_buffer = "zzété"
			local shown
			shown, visible_token = provider(visible_buffer)
			helpers.assert_eq(shown, "X")

			local consumed = interceptor(key_event(MAGIC), visible_buffer, {
				chars = MAGIC,
				flags = { cmd = false, ctrl = false },
			})
			helpers.assert_eq(consumed, "consume")
			helpers.assert_not_nil(injection)
			helpers.assert_eq(injection.delete_count, 3)
			helpers.assert_eq(injection.source, "dynamic")
			helpers.assert_eq(injection.is_private, true)
			local screen = remove_codepoints(visible_buffer, injection.delete_count)
				.. injection.result
			helpers.assert_eq(screen, "zzX")

			local malformed = string.char(0xC3)
			helpers.assert_eq(RulesEngine.add_rule(malformed, "date", function() return "Y" end),
				false, "registration must reject malformed UTF-8")
			helpers.assert_eq(RulesEngine.add_rule("", "date", function() return "Y" end),
				false, "registration must reject an empty suffix")

			local SharedEngine = require("dynamic_hotstrings")
			local live_rules = SharedEngine.get_rules()
			live_rules[#live_rules].suffix = malformed
			visible_buffer = "zz" .. malformed
			local malformed_row
			malformed_row, visible_token = provider(visible_buffer)
			helpers.assert_eq(malformed_row, "X",
				"the action-time guard must protect even a mutated live rule")
			injection = nil
			consumed = interceptor(key_event(MAGIC), visible_buffer, {
				chars = MAGIC,
				flags = { cmd = false, ctrl = false },
			})
			helpers.assert_eq(consumed, nil)
			helpers.assert_eq(injection, nil)
		end, debug.traceback)

		RulesEngine.stop()
		package.loaded["dynamic_hotstrings"] = nil
		package.loaded["modules.dynamic_hotstrings.rules_engine"] = nil
		if not ok then error(err, 0) end
	end)
end)

return true
