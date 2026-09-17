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
		local previous_shell = package.loaded["adapters.shell_runner"]
		local previous_storage = package.loaded["adapters.storage"]
		local previous_load_catalogue = Loader.load_catalogue
		local previous_open = io.open
		local previous_rename = os.rename
		local previous_remove = os.remove
		local override_path = "/virtual-home/.config/ergopti/hotstrings_overrides.toml"
		local temporary_path = override_path .. ".tmp"
		local persisted = nil
		local staged = nil
		local fail_writes = false
		local fail_rename = false
		local created_config_dir = false

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
			package.loaded["adapters.storage"] = require("tests.fakes").storage()
			package.loaded["infra.config_paths"] = {
				config = function() return "/virtual-home/.config/ergopti" end,
			}
			package.loaded["adapters.shell_runner"] = {
				quote = function(value) return "'" .. value .. "'" end,
				run = function(command)
					created_config_dir = command
						== "mkdir -p '/virtual-home/.config/ergopti' 2>/dev/null"
					return created_config_dir
				end,
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
					if fail_rename then return nil, "injected rename failure" end
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
			helpers.assert_true(created_config_dir,
				"override persistence must create the effective config directory")
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

			helpers.assert_eq(restarted.clear_override("second", nil, "priority"), true)
			helpers.assert_eq(winner(restarted_engine), "FIRST",
				"clearing priority must restore the registration-order tiebreak")

			for _, scope in ipairs({ "category", "section", "category field", "section field" }) do
				local section = scope:find("section", 1, true) and "main" or nil
				local field = scope:find("field", 1, true) and "delay" or nil
				helpers.assert_eq(restarted.set_override("second", nil, "color", "#123456"), true)
				helpers.assert_eq(restarted.set_override("second", section, "delay", 1.5), true)
				helpers.assert_eq(restarted.set_override("second", "other", "delay", 2.5), true)
				helpers.assert_eq(restarted.set_override("first", nil, "delay", 3.5), true)
				local before = restarted.get_user_override("second", section)
				local cached = restarted.resolve("second", section)
				local durable = persisted
				helpers.assert_eq(cached.delay, 1.5)

				for _, failure_mode in ipairs({ "open", "rename" }) do
					fail_writes = failure_mode == "open"
					fail_rename = failure_mode == "rename"
					helpers.assert_eq(restarted.clear_override("second", section, field), false,
						scope .. " must report " .. failure_mode .. " failure")
					helpers.assert_eq(restarted.get_user_override("second", section), before,
						"failed clears must retain live overrides")
					helpers.assert_true(restarted.resolve("second", section) == cached,
						"failed clears must retain the resolver cache")
					helpers.assert_eq(persisted, durable, "failed clears must retain durable TOML")
				end
				fail_writes = false
				fail_rename = false
				helpers.assert_eq(restarted.clear_override("second", section, field), true, scope)
				helpers.assert_nil(restarted.get_user_override("second", section).delay)
				helpers.assert_eq(restarted.resolve("second", section).delay, restarted.get_global_delay())
				helpers.assert_true(persisted ~= durable, "successful clears must change durable TOML")
				local remaining_color = scope ~= "category" and "#123456" or nil
				local remaining_sibling = scope ~= "category" and 2.5 or nil
				helpers.assert_eq(restarted.get_user_override("second").color, remaining_color)
				helpers.assert_eq(restarted.get_user_override("second", "other").delay, remaining_sibling)
				helpers.assert_eq(restarted.get_user_override("first").delay, 3.5)
				if remaining_sibling then
					helpers.assert_contains(persisted, "[second.other]\ndelay = 2.5",
						"clearing another scope must preserve the serialized sibling")
				end

				package.loaded["modules.hotstrings.hotstrings_config"] = nil
				restarted = require("modules.hotstrings.hotstrings_config")
				restarted_engine = Engine.new()
				restarted.init(restarted_engine, "/virtual/catalogue.toml")
				restarted.load_all()
				helpers.assert_nil(restarted.get_user_override("second", section).delay,
					"cleared delay must stay cleared after restart")
				helpers.assert_eq(restarted.resolve("second", section).delay, restarted.get_global_delay())
				helpers.assert_eq(restarted.get_user_override("second").color, remaining_color)
				helpers.assert_eq(restarted.get_user_override("first").delay, 3.5)
			end
		end, debug.traceback)

		io.open = previous_open
		os.rename = previous_rename
		os.remove = previous_remove
		Loader.load_catalogue = previous_load_catalogue
		package.loaded["adapters.storage"] = previous_storage
		package.loaded["adapters.shell_runner"] = previous_shell
		package.loaded["infra.config_paths"] = previous_paths
		package.loaded["modules.hotstrings.hotstrings_config"] = previous_config
		if not ok then error(failure, 0) end
	end)
end)
