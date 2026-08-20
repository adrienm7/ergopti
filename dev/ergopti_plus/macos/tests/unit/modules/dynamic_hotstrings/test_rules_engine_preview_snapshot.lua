--- tests/unit/modules/dynamic_hotstrings/test_rules_engine_preview_snapshot.lua

--- A resolver may read the clock or mutable state. The tooltip and interceptor
--- must share the exact result only after the renderer commits its opaque lease.

local helpers = require("tests.helpers")

local MAGIC = utf8.char(0x2605)
local NBSP = string.char(0xC2, 0xA0)

local function key_event(char)
	return {
		getFlags = function() return { cmd = false, ctrl = false } end,
		getCharacters = function() return char end,
	}
end

helpers.describe("dynamic rules consume the exact committed preview snapshot", function()
	helpers.it("does not invoke a mutable resolver twice for one visible action", function()
		package.loaded["dynamic_hotstrings"] = nil
		package.loaded["modules.dynamic_hotstrings.rules_engine"] = nil
		local RulesEngine = helpers.load_with_stubs("modules.dynamic_hotstrings.rules_engine")

		local interceptor
		local provider
		local visible_token = nil
		local revoke_allowed = true
		local injected = {}
		local fake_keymap = {
			is_group_enabled = function() return true end,
			is_section_enabled = function() return true end,
			register_lua_group = function() end,
			set_post_load_hook = function() end,
			register_interceptor = function(fn) interceptor = fn end,
			register_preview_provider = function(fn) provider = fn end,
			registry_transaction = function(_, mutation) return mutation() == true end,
			owns_visible_magic_action = function(token, buffer)
				return token == visible_token and buffer == "zz"
			end,
			invalidate_hotstring_preview = function() return revoke_allowed end,
			inject_dynamic = function(delete_count, result, _emitter, source, is_private)
				helpers.assert_eq(delete_count, 2)
				helpers.assert_eq(source, "dynamic")
				helpers.assert_eq(is_private, true)
				injected[#injected + 1] = result
				return true
			end,
		}

		local resolver_calls = 0
		local ok, err = xpcall(function()
			RulesEngine.start(fake_keymap)
			RulesEngine.add_rule("zz", "mutable", function()
				resolver_calls = resolver_calls + 1
				return "value-" .. resolver_calls
			end)
			helpers.assert_eq(type(interceptor), "function")
			helpers.assert_eq(type(provider), "function")

			local shown, token = provider("zz")
			helpers.assert_eq(shown, "value-1")
			helpers.assert_eq(type(token), "table")
			helpers.assert_eq(resolver_calls, 1)
			visible_token = token

			local consumed = interceptor(key_event(MAGIC), "zz", {
				chars = MAGIC,
				flags = { cmd = false, ctrl = false },
			})
			helpers.assert_eq(consumed, "consume")
			helpers.assert_eq(injected[1], shown,
				"the emitted value must be byte-identical to the committed row")
			helpers.assert_eq(resolver_calls, 1,
				"a committed action must consume its snapshot instead of resolving twice")

			local uncommitted, uncommitted_token = provider("zz")
			helpers.assert_eq(uncommitted, "value-2")
			helpers.assert_eq(type(uncommitted_token), "table")
			visible_token = nil
			consumed = interceptor(key_event(MAGIC), "zz", {
				chars = MAGIC,
				flags = { cmd = false, ctrl = false },
			})
			helpers.assert_eq(consumed, "consume")
			helpers.assert_eq(injected[2], "value-3",
				"a rejected render must not freeze a mutable resolver")
			helpers.assert_eq(resolver_calls, 3)

			helpers.assert_true(RulesEngine.set_trigger_char(":"))
			local composite_shown, composite_token = provider("zz")
			visible_token = composite_token
			consumed = interceptor(key_event(NBSP .. ":"), "zz", {
				chars = NBSP .. ":",
				flags = { cmd = false, ctrl = false },
			})
			helpers.assert_eq(consumed, "consume")
			helpers.assert_eq(injected[3], composite_shown)
			helpers.assert_eq(resolver_calls, 4,
				"composite spelling must not force a second mutable resolution")

			local retained_shown, retained_token = provider("zz")
			visible_token = retained_token
			revoke_allowed = false
			helpers.assert_eq(RulesEngine.set_trigger_char("a"), false,
				"a failed native revocation must abort the trigger mutation")
			consumed = interceptor(key_event(NBSP .. ":"), "zz", {
				chars = NBSP .. ":",
				flags = { cmd = false, ctrl = false },
			})
			helpers.assert_eq(consumed, "consume",
				"the old visible action must retain ownership after a refused mutation")
			helpers.assert_eq(injected[4], retained_shown)
			helpers.assert_eq(resolver_calls, 5)
			revoke_allowed = true
		end, debug.traceback)

		revoke_allowed = true
		RulesEngine.stop()
		if not ok then error(err, 0) end
	end)
end)

return true
