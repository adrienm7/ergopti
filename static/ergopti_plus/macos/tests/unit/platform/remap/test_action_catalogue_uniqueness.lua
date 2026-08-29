--- tests/unit/platform/remap/test_action_catalogue_uniqueness.lua

--- ==============================================================================
--- MODULE: Karabiner action catalogue uniqueness regression
--- DESCRIPTION:
--- Base and generated actions share one id namespace. A collision must reject the
--- whole catalogue before it is cached or consumed by the generator.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_config_fixture(callback)
	local previous_hs = rawget(_G, "hs")
	local previous_open = io.open
	local ok, err = xpcall(function()
		helpers.with_fresh_modules({
			"platform.remap.action_catalogue",
			"platform.remap.config",
			"platform.remap.defaults",
			"modules.keymap.layout",
			"modules.gestures.actions",
			"adapters.file_system",
			"infra.i18n",
			"infra.logger",
			"infra.paths",
			"infra.toml.codec",
			"hs",
			"tests.stubs.hs",
		}, function()
			local state = { collision = true, action_reads = 0 }
			local hs_stub = require("tests.stubs.hs")
			hs_stub.__reset()
			hs_stub.json.decode = function(raw)
				if raw == "actions" then
					state.action_reads = state.action_reads + 1
					if state.collision then
						return {{
							id = "ctrl_a",
							label = "Base collision",
							karabiner_to = {{key_code = "b"}},
						}}
					end
					return {{id = "base_only", label = "Base", karabiner_to = {}}}
				end
				if raw == "modifier-chords" then
					return {
						platforms = {macos = {modifiers = {{
							id = "ctrl",
							label = "Ctrl",
							karabiner = "left_control",
						}}}},
						keys = {{id = "a", label = "A", karabiner_key = "a"}},
					}
				end
				return nil
			end
			_G.hs = hs_stub
			package.loaded["hs"] = hs_stub
			package.loaded["platform.remap.defaults"] = {
				tap_hold_timeout_ms = 200,
				sticky_timeout_ms = 300,
				simultaneous_threshold_ms = 100,
				combo_symmetric = false,
			}
			package.loaded["modules.keymap.layout"] = {
				key_code_for_char = function(char) return char end,
			}
			package.loaded["modules.gestures.actions"] = {
				karabiner_aliases = function() return {} end,
			}
			package.loaded["adapters.file_system"] = {
				read_with_status = function() return nil, "absent" end,
			}
			package.loaded["infra.i18n"] = {
				get = function(key) return key end,
			}
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.paths"] = {
				shared = function() return "/fixture/modifier-chords.json" end,
			}
			package.loaded["infra.toml.codec"] = {
				decode = function() return {} end,
				encode = function() return "" end,
			}

			io.open = function(path, mode)
				if mode ~= "r" then return nil end
				local raw
				if path == "/fixture/actions.json" then raw = "actions" end
				if path == "/fixture/modifier-chords.json" then raw = "modifier-chords" end
				if not raw then return nil end
				return {
					read = function() return raw end,
					close = function() return true end,
				}
			end

			callback(require("platform.remap.config"), state)
		end)
	end, debug.traceback)
	io.open = previous_open
	_G.hs = previous_hs
	if not ok then error(err, 0) end
end

helpers.describe("Config.load_available_actions: one action id namespace", function()
	helpers.it("rejects a base action colliding with a generated modifier chord", function()
		with_config_fixture(function(Config, state)
			local actions, detail = Config.load_available_actions("/fixture/actions.json")
			helpers.assert_nil(actions,
				"a base/generated id collision must reject the complete catalogue")
			helpers.assert_type(detail, "string",
				"catalogue rejection must expose an actionable diagnostic")
			helpers.assert_true(detail:find("ctrl_a", 1, true) ~= nil,
				"the diagnostic must identify the duplicate id")

			state.collision = false
			local retry = Config.load_available_actions("/fixture/actions.json")
			helpers.assert_type(retry, "table",
				"an invalid catalogue must not poison the loader cache")
			helpers.assert_eq(state.action_reads, 2,
				"a corrected catalogue must be read again after rejection")
		end)
	end)
end)
