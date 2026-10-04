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
		-- The category choices live in a private config.toml the real writer owns.
		local choice_path = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
			.. "/ergopti_priority_choices_" .. os.time() .. "_" .. math.random(100000, 999999) .. ".toml"
		assert(assert(io.open(choice_path, "w")):close())

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
					if persisted == nil then return nil, "fixture source absent", 2 end
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
			assert(config._set_config_file_for_test(choice_path))
			local engine = Engine.new()
			config.init(engine, "/virtual/catalogue.toml")
			config.load_all()
			helpers.assert_true(config.set_categories_sections({ "first", "second" }, true))
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
			assert(restarted._set_config_file_for_test(choice_path))
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

			helpers.assert_eq(restarted.set_override("first", nil, "priority", 100), true)
			local extension_category = require("hotstrings.extensions").category_key("sample-pack", "second")
			local category_values = { delay = 1.25, color = "#123456", show_tooltip = true, priority = 90 }
			local section_values = { delay = 2.5, color = "#abcdef", show_tooltip = false, priority = 120 }
			for _, category in ipairs({ "second", extension_category }) do
				for field, value in pairs(category_values) do
					helpers.assert_eq(restarted.set_override(category, nil, field, value), true)
				end
				for field, value in pairs(section_values) do
					helpers.assert_eq(restarted.set_override(category, "main", field, value), true)
				end
			end
			helpers.assert_eq(winner(restarted_engine), "SECOND")
			helpers.assert_contains(persisted, "[second.main]")
			helpers.assert_contains(persisted, '["' .. extension_category .. '".main]')

			package.loaded["modules.hotstrings.hotstrings_config"] = nil
			restarted = require("modules.hotstrings.hotstrings_config")
			assert(restarted._set_config_file_for_test(choice_path))
			restarted_engine = Engine.new()
			restarted.init(restarted_engine, "/virtual/catalogue.toml")
			restarted.load_all()
			for _, category in ipairs({ "second", extension_category }) do
				helpers.assert_eq(restarted.get_user_override(category), category_values,
					category .. " category fields must survive restart")
				helpers.assert_eq(restarted.get_user_override(category, "main"), section_values,
					category .. " section fields must survive restart")
				for field, value in pairs(category_values) do
					helpers.assert_eq(restarted.resolve(category)[field], value)
				end
				for field, value in pairs(section_values) do
					helpers.assert_eq(restarted.resolve(category, "main")[field], value)
				end
			end
			helpers.assert_eq(winner(restarted_engine), "SECOND",
				"persisted section priority must beat the competing category priority")
			helpers.assert_eq(restarted.clear_override("second", "main", "priority"), true)
			helpers.assert_eq(winner(restarted_engine), "FIRST",
				"clearing section priority must restore the lower category priority")
			helpers.assert_eq(restarted.clear_override("first", nil), true)
			helpers.assert_eq(restarted.clear_override("second", nil), true)
			helpers.assert_eq(restarted.clear_override(extension_category, nil), true)

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
				assert(restarted._set_config_file_for_test(choice_path))
				restarted_engine = Engine.new()
				restarted.init(restarted_engine, "/virtual/catalogue.toml")
				restarted.load_all()
				helpers.assert_nil(restarted.get_user_override("second", section).delay,
					"cleared delay must stay cleared after restart")
				helpers.assert_eq(restarted.resolve("second", section).delay, restarted.get_global_delay())
				helpers.assert_eq(restarted.get_user_override("second").color, remaining_color)
				helpers.assert_eq(restarted.get_user_override("second", "other").delay, remaining_sibling,
					"surviving sibling override must remain after clear and restart")
				helpers.assert_eq(restarted.get_user_override("first").delay, 3.5)
			end
		end, debug.traceback)

		io.open = previous_open
		os.rename = previous_rename
		os.remove = previous_remove
		os.remove(choice_path)
		os.remove(choice_path .. ".tmp")
		Loader.load_catalogue = previous_load_catalogue
		package.loaded["adapters.storage"] = previous_storage
		package.loaded["adapters.shell_runner"] = previous_shell
		package.loaded["infra.config_paths"] = previous_paths
		package.loaded["modules.hotstrings.hotstrings_config"] = previous_config
		if not ok then error(failure, 0) end
	end)
end)


helpers.describe("hotstring override leaf ownership", function()
	local function with_owner(content, action, before_init)
		local root = assert(os.tmpname())
		assert(os.remove(root))
		local made = os.execute("mkdir -p '" .. root .. "'")
		assert(made == true or made == 0)
		local path = root .. "/hotstrings_overrides.toml"
		local choices = root .. "/config.toml"
		local function write(value)
			local handle = assert(io.open(path, "w"))
			assert(handle:write(value))
			assert(handle:close())
		end
		local function read()
			local handle = assert(io.open(path, "r"))
			local value = assert(handle:read("*a"))
			assert(handle:close())
			return value
		end
		if content ~= nil then write(content) end
		assert(assert(io.open(choices, "w")):close())
		local old_config = package.loaded["modules.hotstrings.hotstrings_config"]
		local old_open, old_rename, old_remove = io.open, os.rename, os.remove
		local old_shell = package.loaded["adapters.shell_runner"]
		local ok, failure = xpcall(function()
			package.loaded["adapters.shell_runner"] = nil
			package.loaded["modules.hotstrings.hotstrings_config"] = nil
			local config = require("modules.hotstrings.hotstrings_config")
			assert(config._set_override_config_dir_for_test(root))
			assert(config._set_config_file_for_test(choices))
			if before_init then before_init(path) end
			local changes = 0
			assert(config.init(nil, "/fixture/catalogue.toml", function() changes = changes + 1 end))
			action(config, path, read, write, function() return changes end)
		end, debug.traceback)
		io.open, os.rename, os.remove = old_open, old_rename, old_remove
		package.loaded["modules.hotstrings.hotstrings_config"] = old_config
		package.loaded["adapters.shell_runner"] = old_shell
		os.remove(path .. ".tmp")
		os.remove(path)
		os.remove(choices)
		os.remove(root)
		if not ok then error(failure, 0) end
	end

	local source = table.concat({
		"# Keep this user's introduction.",
		'["ext:future:pack"."literal.section"]',
		'future = { enabled = false, note = "keep me" }',
		"delay = 1.25",
		'color = "#abcdef"',
		"show_tooltip = false",
		"priority = 90",
		"# Keep this section comment.",
		"[unrelated]",
		'future = ["one", "two"]',
		"delay = 2.5",
		"",
	}, "\n")

	helpers.it("preserves unknown records and comments through public set and field clear", function()
		with_owner(source, function(config, _, read)
			helpers.assert_true(config.set_override("ext:future:pack", "literal.section", "delay", 3.5))
			local changed = source:gsub("delay = 1.25", "delay = 3.5")
			helpers.assert_eq(read(), changed)
			helpers.assert_true(config.clear_override("ext:future:pack", "literal.section", "color"))
			helpers.assert_eq(read(), changed:gsub('color = "#abcdef"\n', ""))
			helpers.assert_eq(config.get_user_override("ext:future:pack", "literal.section").delay, 3.5)
			helpers.assert_eq(config.get_user_override("unrelated").delay, 2.5)
		end)
	end)

	helpers.it("clears only known leaves of a section and category", function()
		for _, section in ipairs({ "literal.section", false }) do
			with_owner(source, function(config, _, read)
				helpers.assert_true(config.clear_override("ext:future:pack", section or nil))
				local expected = source:gsub("delay = 1.25\n", ""):gsub('color = "#abcdef"\n', "")
					:gsub("show_tooltip = false\n", ""):gsub("priority = 90\n", "")
				helpers.assert_eq(read(), expected)
				helpers.assert_nil(config.get_user_override("ext:future:pack", "literal.section").delay)
			end)
		end
	end)

	helpers.it("refuses stale loaded bytes before changing RAM or cached resolutions", function()
		with_owner(source, function(config, _, read, write, changes)
			local cached = config.resolve("ext:future:pack", "literal.section")
			local foreign = source .. "# A foreign edit.\n"
			write(foreign)
			helpers.assert_eq(config.set_override("ext:future:pack", "literal.section", "delay", 4), false)
			helpers.assert_eq(config.clear_override("ext:future:pack", "literal.section"), false)
			helpers.assert_eq(read(), foreign)
			helpers.assert_true(config.resolve("ext:future:pack", "literal.section") == cached)
			helpers.assert_eq(changes(), 0)
		end)
	end)

	helpers.it("rechecks source after staging before acknowledging a public change", function()
		with_owner(source, function(config, path, read, write, changes)
			local cached = config.resolve("ext:future:pack", "literal.section")
			local old_open = io.open
			local foreign = source .. "# Edit after staging.\n"
			io.open = function(name, mode)
				local handle, detail, code = old_open(name, mode)
				if name ~= path .. ".tmp" or mode ~= "w" or not handle then return handle, detail, code end
				return {
					write = function(_, value) return handle:write(value) end,
					close = function()
						local closed = handle:close()
						write(foreign)
						return closed
					end,
				}
			end
			local committed = config.set_override("ext:future:pack", "literal.section", "delay", 4)
			io.open = old_open
			helpers.assert_eq(committed, false)
			helpers.assert_eq(read(), foreign)
			helpers.assert_true(config.resolve("ext:future:pack", "literal.section") == cached)
			helpers.assert_eq(changes(), 0)
		end)
	end)

	helpers.it("distinguishes unreadable source from proven absence and malformed source", function()
		for _, kind in ipairs({ "read_error", "malformed", "absent" }) do
			local bytes = kind == "malformed" and "[broken\n" or (kind == "read_error" and source or nil)
			local old_open = io.open
			with_owner(bytes, function(config, path, read, _, changes)
				io.open = old_open
				if kind == "absent" then
					helpers.assert_true(config.clear_override("fresh", nil))
					local handle, _, code = io.open(path, "r")
					helpers.assert_nil(handle, "an empty clear retains proven absence")
					helpers.assert_eq(code, 2)
				end
				local committed = config.set_override("fresh", nil, "delay", 2)
				helpers.assert_eq(committed, kind == "absent")
				helpers.assert_eq(changes(), kind == "absent" and 1 or 0)
				if kind ~= "absent" then helpers.assert_eq(read(), bytes) end
			end, function(path)
				if kind == "read_error" then
					io.open = function(name, mode)
						if name == path and mode == "r" then return nil, "owned permission refusal", 13 end
						return old_open(name, mode)
					end
				end
			end)
		end
	end)

	helpers.it("keeps no-op source identity and refuses unaddressable owned inline changes", function()
		with_owner(source, function(config, path, read, _, changes)
			local renames = 0
			local old_rename = os.rename
			os.rename = function(from, to)
				if to == path then renames = renames + 1 end
				return old_rename(from, to)
			end
			local committed = config.set_override("ext:future:pack", "literal.section", "delay", 1.25)
			os.rename = old_rename
			helpers.assert_true(committed)
			helpers.assert_eq(read(), source)
			helpers.assert_eq(renames, 0, "an unchanged file must retain its inode")
			helpers.assert_eq(changes(), 1)
		end)
		with_owner('second = { delay = 2.5, future = "keep" }\n', function(config, _, read)
			helpers.assert_eq(config.set_override("second", nil, "delay", 4), false)
			helpers.assert_eq(read(), 'second = { delay = 2.5, future = "keep" }\n')
			helpers.assert_eq(config.get_user_override("second").delay, 2.5)
		end)
	end)

	helpers.it("requires strict stage and publication receipts before invalidating RAM", function()
		for _, fault in ipairs({ "open", "write_nil", "write_false", "write_throw", "close", "rename" }) do
			with_owner(source, function(config, path, read, _, changes)
				local cached = config.resolve("ext:future:pack", "literal.section")
				local old_open, old_rename = io.open, os.rename
				io.open = function(name, mode)
					if name ~= path .. ".tmp" or mode ~= "w" then return old_open(name, mode) end
					if fault == "open" then return nil, "owned open refusal" end
					local handle = assert(old_open(name, mode))
					return {
						write = function(_, value)
							if fault == "write_nil" then return nil end
							if fault == "write_false" then return false end
							if fault == "write_throw" then error("owned write refusal") end
							return handle:write(value)
						end,
						close = function()
							local closed = handle:close()
							if fault == "close" then return false end
							return closed
						end,
					}
				end
				os.rename = function(from, to)
					if to == path and fault == "rename" then return false, "owned rename refusal" end
					return old_rename(from, to)
				end
				local committed = config.set_override("ext:future:pack", "literal.section", "delay", 4)
				io.open, os.rename = old_open, old_rename
				helpers.assert_eq(committed, false, fault)
				helpers.assert_eq(read(), source, fault)
				helpers.assert_true(config.resolve("ext:future:pack", "literal.section") == cached, fault)
				helpers.assert_eq(changes(), 0, fault)
			end)
		end
	end)

	helpers.it("keeps source authority across held scope publication and exact restoration", function()
		with_owner(source, function(config, path, read)
			local writer = require("toml_codec.writer")
			local original = config.configuration_snapshot()
			local owner = {}
			local candidate = source:gsub("delay = 1.25", "delay = 8.5")
			-- The scope's runtime catalogue port is controlled; both file boundaries
			-- and all public leaf operations still use the actual writer.
			config.load_all = function() return {}, true end
			helpers.assert_true(config.acquire(owner))
			helpers.assert_true(config.apply_configuration(owner, {}, candidate, { status = "ok", content = candidate }))
			helpers.assert_eq(config.set_override("ext:future:pack", "literal.section", "delay", 4), false)
			helpers.assert_true(writer.publish_if_unchanged(path, candidate, nil, original.override_source))
			helpers.assert_true(config.release(owner))
			helpers.assert_true(config.set_override("ext:future:pack", "literal.section", "delay", 9.5))
			helpers.assert_eq(read(), source:gsub("delay = 1.25", "delay = 9.5"))
			local applied = config.configuration_snapshot()
			helpers.assert_true(config.acquire(owner))
			helpers.assert_true(writer.publish_if_unchanged(path, source, nil, applied.override_source))
			helpers.assert_true(config.restore_configuration(owner, original))
			helpers.assert_true(config.release(owner))
			helpers.assert_true(config.set_override("ext:future:pack", "literal.section", "delay", 2.5))
			helpers.assert_eq(read(), source:gsub("delay = 1.25", "delay = 2.5"))
		end)
	end)

	helpers.it("retains the actual absent or present-empty scope target before ordinary setters", function()
		for _, content in ipairs({ false, "" }) do
			local initial = content
			if content == false then initial = nil end
			with_owner(initial, function(config, path, read)
				local owner = {}
				local participant = require("config_scope_file").new({ path = path,
					backup_path = path .. ".backup", remove = os.remove })
				config.load_all = function() return {}, true end
				helpers.assert_true(participant.prepare({}))
				local target = participant.target()
				helpers.assert_eq(target.status, content == false and "absent" or "ok")
				helpers.assert_true(config.acquire(owner))
				helpers.assert_true(config.apply_configuration(owner, {}, participant.candidate(), target))
				helpers.assert_true(participant.publish())
				helpers.assert_true(config.release(owner))
				helpers.assert_eq(config.configuration_snapshot().override_source.status, target.status)
				helpers.assert_true(config.set_override("fresh", nil, "delay", 2.5))
				helpers.assert_contains(read(), "delay = 2.5")
			end)
		end
	end)
end)
