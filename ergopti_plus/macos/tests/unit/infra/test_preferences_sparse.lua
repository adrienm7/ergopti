--- tests/unit/infra/test_preferences_sparse.lua

local helpers = require("tests.helpers")
local codec = require("toml_codec")

helpers.describe("sparse preference transactions", function()
	helpers.it("saves a real neutral module snapshot without adding enabled overrides", function()
		helpers.with_fresh_modules({ "infra.preferences", "adapters.file_system", "modules.keylogger.kc_bridge" }, function()
			local source = '[future]\nkeep = 99\n'
			package.loaded["modules.keylogger.kc_bridge"] = { init = function() return true end }
			local modules = {}
			for key, name in pairs({ keymap = "keymap", dyn_hot_mod = "dynamic_hotstrings",
				shortcuts_mod = "shortcuts", gestures = "gestures", keylogger = "keylogger" }) do
				modules[key] = helpers.load_with_stubs("modules." .. name)
			end
			package.loaded["adapters.file_system"] = {
				read_with_status = function() return source, "ok" end,
				write = function() error("publication must retain its source precondition") end,
				write_if_unchanged = function(_, content, expected)
					helpers.assert_eq(expected.content, source)
					source = content
					return true
				end,
			}
			local prefs = helpers.load_with_stubs("infra.preferences")
			prefs.load("/sparse/full-neutral.toml")
			local state = prefs.build_initial_state({}, {}, modules)
			helpers.assert_eq(prefs.save("/sparse/full-neutral.toml", state, {}, modules), true)
			local decoded = codec.decode(source)
			helpers.assert_eq(decoded.shortcuts and decoded.shortcuts.keys and decoded.shortcuts.keys.tap_keys, nil,
				"the tap dispatcher is derived from assignments and has no saved preference")
			for _, category in ipairs({ "gestures", "shortcuts", "metrics", "hotstrings" }) do
				helpers.assert_eq(decoded[category] and decoded[category].enabled, nil)
			end
			helpers.assert_eq(decoded.future.keep, 99)
			helpers.assert_eq(decoded.gestures and decoded.gestures.tap_2, nil)
			helpers.assert_eq(decoded.hotstrings and decoded.hotstrings.repeat_key_enabled, nil)
			helpers.assert_eq(decoded.shortcuts and decoded.shortcuts.keys and decoded.shortcuts.keys.cmd_star, nil)
		end)
	end)

	helpers.it("does not reinterpret unknown gesture fields as live action assignments", function()
		-- No action catalogue: this case is about field shape, not retirement.
		helpers.with_fresh_modules({ "infra.preferences", "adapters.file_system", "modules.gestures.actions" }, function()
			package.loaded["adapters.file_system"] = {
				read_with_status = function()
					return '[gestures]\ntap_2 = "copy"\nfuture = 17\n[gestures.expert]\nvalue = "keep"\n', "ok"
				end,
			}
			local state, status = helpers.load_with_stubs("infra.preferences").load("/sparse/unknown.toml")
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(state.gesture_actions.tap_2, "copy")
			helpers.assert_eq(state.gesture_actions.future, nil)
			helpers.assert_eq(state.gesture_actions.value, nil)
		end)
	end)

	helpers.it("deletes neutral leaves and preserves unknown nested data in one publication", function()
		helpers.with_fresh_modules({ "infra.preferences", "adapters.file_system" }, function()
			local source = "[gestures]\nenabled = true\nfuture = 17\n[gestures.expert]\nvalue = 'keep'\n"
			local writes = 0
			package.loaded["adapters.file_system"] = {
				read_with_status = function() return source, "ok" end,
				write = function() error("unguarded publication") end,
				write_if_unchanged = function(_, content, expected)
					helpers.assert_eq(expected.content, source)
					writes = writes + 1
					source = content
					return true
				end,
			}
			local prefs = helpers.load_with_stubs("infra.preferences")
			prefs.load("/sparse/config.toml")
			local ok, persisted, runtime = prefs.save("/sparse/config.toml", { gestures = false }, {}, {})
			helpers.assert_eq(ok, true)
			helpers.assert_eq(writes, 1)
			local decoded = codec.decode(source)
			helpers.assert_eq(decoded.gestures.enabled, nil, "neutral must explicitly delete a previous override")
			helpers.assert_eq(decoded.gestures.future, 17)
			helpers.assert_eq(decoded.gestures.expert.value, "keep")
			helpers.assert_eq(persisted.gestures, false)
			helpers.assert_eq(runtime.gestures, false)
		end)
	end)
end)
