--- tests/unit/modules/hotstrings/test_priority_override_collision.lua

--- Proves that a priority edit survives the complete Linux production path:
--- override serialization, catalogue reload, engine collision arbitration, and a
--- fresh config-module initialization.

local helpers = require("tests.helpers")

helpers.describe("hotstring priority overrides", function()
	helpers.it("change an exact-trigger winner immediately and after restart", function()
		local Loader = helpers.load_module("modules.hotstrings.loader")
		local Engine = helpers.load_module("modules.hotstrings.engine")
		local previous_config = package.loaded["modules.hotstrings.hotstrings_config"]
		local previous_paths = package.loaded["infra.config_paths"]
		local previous_load_catalogue = Loader.load_catalogue
		local previous_open = io.open
		local previous_rename = os.rename
		local previous_remove = os.remove
		local override_path = "/virtual-home/.config/ergopti/hotstrings_overrides.toml"
		local temporary_path = override_path .. ".tmp"
		local persisted = nil
		local staged = nil
		local fail_writes = false

		local function memory_handle(mode, commit)
			local chunks = {}
			return {
				read = function(_, format)
					if mode ~= "r" or format ~= "*a" then return nil end
					return persisted
				end,
				lines = function()
					local source = tostring(persisted or "") .. "\n"
					local offset = 1
					return function()
						if offset > #source then return nil end
						local newline = source:find("\n", offset, true)
						local line = source:sub(offset, newline - 1)
						offset = newline + 1
						return line
					end
				end,
				write = function(_, value)
					chunks[#chunks + 1] = tostring(value)
					return true
				end,
				close = function()
					if mode == "w" then commit(table.concat(chunks)) end
					return true
				end,
			}
		end

		local function catalogue()
			local function mapping(group, replacement)
				return {
					trigger = "same",
					replacement = replacement,
					auto_expand = true,
					priority = 10,
					_catalogue_priority = true,
					group = group,
					section = "main",
				}
			end
			return {
				committed = true,
				errors = 0,
				mappings = {
					mapping("first", "FIRST"),
					mapping("second", "SECOND"),
				},
				categories = {
					first = { sections = { main = {} } },
					second = { sections = { main = {} } },
				},
			}
		end

		local function winner(engine)
			engine:reset()
			engine:on_char("s")
			engine:on_char("a")
			engine:on_char("m")
			local match = engine:on_char("e")
			return match and match.replacement or nil
		end

		local ok, failure = xpcall(function()
			package.loaded["infra.config_paths"] = {
				home = function() return "/virtual-home" end,
			}
			io.open = function(path, mode)
				if path == override_path and mode == "r" then
					if persisted == nil then return nil end
					return memory_handle(mode, function() end)
				end
				if path == temporary_path and mode == "w" then
					if fail_writes then return nil end
					return memory_handle(mode, function(content) staged = content end)
				end
				return previous_open(path, mode)
			end
			os.rename = function(from, to)
				if from == temporary_path and to == override_path then
					persisted = staged
					staged = nil
					return true
				end
				return previous_rename(from, to)
			end
			os.remove = function(path)
				if path == temporary_path then staged = nil ; return true end
				return previous_remove(path)
			end
			Loader.load_catalogue = catalogue

			package.loaded["modules.hotstrings.hotstrings_config"] = nil
			local config = require("modules.hotstrings.hotstrings_config")
			local engine = Engine.new()
			config.init(engine, "/virtual/catalogue.toml")
			helpers.assert_eq(config.load_all(), 2,
				"both colliding mappings must reach the shared engine")
			helpers.assert_eq(winner(engine), "FIRST",
				"registration order is the final tiebreak before an override")

			fail_writes = true
			helpers.assert_eq(config.set_override("second", nil, "priority", 90), false)
			helpers.assert_eq(config.get_user_override("second", nil).priority, nil,
				"a failed save must not publish session-only priority state")
			helpers.assert_eq(winner(engine), "FIRST",
				"a failed save must not rebuild the engine from uncommitted state")
			fail_writes = false

			helpers.assert_eq(config.set_override("second", nil, "priority", 90), true)
			helpers.assert_eq(winner(engine), "SECOND",
				"a committed priority edit must reload the live collision table")
			helpers.assert_contains(persisted, "priority = 90",
				"priority must be serialized into the override TOML")

			package.loaded["modules.hotstrings.hotstrings_config"] = nil
			local restarted = require("modules.hotstrings.hotstrings_config")
			local restarted_engine = Engine.new()
			restarted.init(restarted_engine, "/virtual/catalogue.toml")
			restarted.load_all()
			helpers.assert_eq(restarted.get_user_override("second", nil).priority, 90,
				"a fresh module must parse the persisted priority")
			helpers.assert_eq(winner(restarted_engine), "SECOND",
				"the persisted priority must elect the same winner after restart")

			helpers.assert_eq(restarted.set_override("second", nil, "priority", nil), true)
			helpers.assert_eq(winner(restarted_engine), "FIRST",
				"clearing priority must restore the registration-order tiebreak")
		end, debug.traceback)

		io.open = previous_open
		os.rename = previous_rename
		os.remove = previous_remove
		Loader.load_catalogue = previous_load_catalogue
		package.loaded["infra.config_paths"] = previous_paths
		package.loaded["modules.hotstrings.hotstrings_config"] = previous_config
		if not ok then error(failure, 0) end
	end)
end)
