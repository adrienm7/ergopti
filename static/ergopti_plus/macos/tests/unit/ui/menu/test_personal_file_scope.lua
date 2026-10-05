--- tests/unit/ui/menu/test_personal_file_scope.lua

--- ==============================================================================
--- MODULE: Descriptor-bound Personal File Commands
--- DESCRIPTION:
--- Exercises actual registry and canonical preference owners behind native file
--- menu callbacks. A shared legacy group is not an exclusive file capability.
--- ==============================================================================

local helpers = require("tests.helpers")
local PersonalFiles = require("hotstrings.personal_files")
local TextUtils = require("infra.text_utils")

--- Owns real source files, registry state and the conditional publication port.
--- @param collision boolean Whether two sources share one legacy group.
--- @param body function Receives the actual native-owner fixture.
local function with_fixture(collision, body)
	return helpers.with_stub_scope({
		"infra.preferences", "adapters.file_system", "adapters.storage", "infra.config_paths",
		"infra.notifications", "ui.menu.keymap_lifecycle", "modules.keymap.registry", "modules.keymap.registry_index",
		"modules.keymap.registry_groups", "ui.menu.menu_hotstrings_custom", "infra.personal_file_scope",
		"infra.personal_hotstrings",
	}, function()
		-- These fixtures own registered sources, not the boot scanner catalogue.
		-- Keep only its empty diagnostics port scoped; the real registry and
		-- conditional preference publisher remain the owners exercised below.
		package.loaded["infra.personal_hotstrings"] = {
			unavailable_directories = function() return {} end,
		}
		local root = os.tmpname(); os.remove(root)
		assert(os.execute("mkdir -p " .. TextUtils.shell_quote(root .. "/a")))
		local definitions = collision and {
			{ components = { "a__b.toml" }, name = "personal_ext_a__b", trigger = "fla", output = "Flat" },
			{ components = { "a", "b.toml" }, name = "personal_ext_a__b", trigger = "nst", output = "Nested" },
		} or {
			{ components = { "unique.toml" }, name = "personal_ext_unique", trigger = "unq", output = "Unique" },
			{ components = { "sibling.toml" }, name = "personal_ext_sibling", trigger = "sib", output = "Sibling" },
		}
		local files, names = {}, {}
		for _, entry in ipairs(definitions) do
			entry.path = root .. "/" .. table.concat(entry.components, "/")
			entry.personal_source = PersonalFiles.describe(entry.components)
			local file = assert(io.open(entry.path, "w"))
			assert(file:write('[probe]\n"' .. entry.trigger .. '" = { output = "' .. entry.output
				.. '", is_case_sensitive = true, is_case_sensitive_strict = true, priority = 73 }\n'))
			assert(file:close()); names[#names + 1] = entry.name
			files[#files + 1] = { name = entry.name, path = entry.path, personal_source = entry.personal_source }
		end
		local config = root .. "/config.toml"
		local disk, seeded = "[hotstrings.groups]\n", {}
		for _, name in ipairs(names) do
			if not seeded[name] then disk = disk .. name .. " = true\n"; seeded[name] = true end
		end
		disk = disk .. 'future_group = false\n[hotstrings.modules.future_group]\nunknown_section = true\n[future]\nkeep = "owned-unrelated-value"\n'
		local controls, observations = {}, { writes = 0, notices = {}, refreshes = 0, starts = 0 }
		local attributes = {}
		for index, entry in ipairs(definitions) do attributes[entry.path] = { mode = "file", dev = 1, ino = index } end
		local native_files = {
			path_status = function(path)
				local value = attributes[path]; return value and "present" or "absent", value
			end,
			read_with_status = function(path)
				if path == config then return disk, "ok" end
				local file = io.open(path, "r"); if not file then return nil, "absent" end
				local content = assert(file:read("*a")); assert(file:close()); return content, "ok"
			end,
			write_if_unchanged = function(path, content, expected)
				observations.writes = observations.writes + 1
				observations.expected = expected
				if controls.writer == "throw" then error("owned writer refusal") end
				if controls.writer == "false" then return false end
				if controls.writer == "nil" then return nil end
				if path ~= config or expected.status ~= "ok" or expected.content ~= disk then return false end
				disk = content; return true
			end,
		}
		package.loaded["adapters.file_system"] = native_files
		package.loaded["infra.config_paths"] = { get = function(key)
			if key == "PersonalHotstringsDir" then return controls.root or root end
		end }
		package.loaded["infra.notifications"] = { notify = function(...)
			observations.notices[#observations.notices + 1] = { ... }
		end }
		local R = helpers.load_with_stubs("modules.keymap.registry")
		local state = require("modules.keymap.state").new({ trigger_char = "★", expansion_delay = 0.4 }, {})
		assert(R.init(state))
		for _, entry in ipairs(definitions) do assert(R.load_toml(entry.name, entry.path, nil, entry.personal_source)) end
		R.start = function() observations.starts = observations.starts + 1; return true end
		local Preferences = require("infra.preferences")
		local saved, loaded = Preferences.load(config); assert(loaded == "ok")
		local menu_state = Preferences.build_initial_state(names, {}, {})
		Preferences.merge_saved_data(menu_state, saved)
		menu_state.keymap, menu_state.trigger_char, menu_state.future = false, "★", { keep = true }
		local ctx = { state = menu_state, paused = false, hotfiles = names, hotfile_paths = {},
			personal_files = files, personal_root = root, keymap = R,
			get_group_name = function(value) return value end, applyTriggerChar = function(value) return value end,
			updateMenu = function() observations.refreshes = observations.refreshes + 1 end,
			hotstring_editor = { open = function() end }, notify_feature = function() end }
		for _, entry in ipairs(definitions) do ctx.hotfile_paths[entry.name] = entry.path end
		ctx.save_prefs = function() return Preferences.save(config, ctx.state, names, { keymap = R }) end
		local Custom = helpers.load_with_stubs("ui.menu.menu_hotstrings_custom")
		local function commands()
			local result = {}
			local function walk(rows)
				for _, row in ipairs(rows or {}) do
					local child = row.menu or row.submenu or row.items
					if child and child[1] and child[1].title == "menu.hotstrings.scope_enable_all"
						and child[3] and child[3].title == "menu.hotstrings.open_file" then
						result[#result + 1] = { enable = child[1].fn, disable = child[2].fn, section = child[5].fn, row = row }
					end
					walk(child)
				end
			end
			walk({ Custom.build_custom(ctx, { group_counts = {} }) }); return result
		end
		local fixture = { root = root, records = definitions, state = state, R = R, ctx = ctx,
			controls = controls, observations = observations, attributes = attributes, commands = commands,
			native_files = native_files,
			content = function() return disk end, external = function(value) disk = value end }
		fixture.command = function(name)
			for _, command in ipairs(commands()) do
				if command.row.title:gsub(" %(%d+%)$", "") == name:gsub("^personal_ext_", "") then return command end
			end
			error("actual file command missing for " .. name)
		end
		fixture.mapping = function(name)
			for _, mapping in ipairs(state.mappings) do if mapping.group == name then return mapping end end
		end
		local ok, err = pcall(body, fixture)
		for _, entry in ipairs(definitions) do os.remove(entry.path) end
		os.remove(root .. "/a"); os.remove(root)
		if not ok then error(err, 0) end
	end)
end

helpers.describe("personal file callback admission", function()
	helpers.it("refuses the actual collided legacy owner before either source is removed", function()
		with_fixture(true, function(f)
			local commands = f.commands(); helpers.assert_eq(#commands, 2)
			helpers.assert_eq(#f.state.mappings, 2)
			local before, first, second = f.content(), f.state.mappings[1], f.state.mappings[2]
			local committed = commands[1].disable()
			helpers.assert_eq(committed, false, string.format(
				"one file cannot own the shared legacy group (registered before=2 after=%d, writes=%d)",
				#f.state.mappings, f.observations.writes))
			helpers.assert_eq(#f.state.mappings, 2, "both actual registered sources must remain live")
			helpers.assert_true(f.state.mappings[1] == first and f.state.mappings[2] == second)
			helpers.assert_eq(f.content(), before)
			helpers.assert_eq({ f.observations.writes, f.observations.refreshes }, { 0, 0 })
			helpers.assert_eq(#f.observations.notices, 1)
		end)
	end)
	for _, index in ipairs({ 1, 2 }) do
		for _, action in ipairs({ "enable", "disable", "section" }) do
			helpers.it("refuses collided source " .. index .. " " .. action .. " without activation or writes", function()
				with_fixture(true, function(f)
					local before = f.content()
					local first, second = f.state.mappings[1], f.state.mappings[2]
					helpers.assert_eq(f.commands()[index][action](), false)
					helpers.assert_eq(f.content(), before)
					helpers.assert_eq(#f.state.mappings, 2)
					helpers.assert_true(f.state.mappings[1] == first and f.state.mappings[2] == second)
					helpers.assert_eq({ f.observations.writes, f.observations.refreshes, f.observations.starts }, { 0, 0, 0 })
					helpers.assert_eq(#f.observations.notices, 1)
					helpers.assert_eq(f.ctx.state.keymap, false)
				end)
			end)
		end
	end

	helpers.it("commits one exclusive real group through canonical ACK and preserves all neighbors", function()
		with_fixture(false, function(f)
			local first, sibling = f.mapping("personal_ext_unique"), f.mapping("personal_ext_sibling")
			local before = f.content()
			helpers.assert_eq(f.command("personal_ext_sibling").disable(), true)
			helpers.assert_eq(#f.state.mappings, 1)
			helpers.assert_true(f.state.mappings[1] == first)
			helpers.assert_eq(f.R.is_group_enabled("personal_ext_unique"), true)
			helpers.assert_eq(f.R.is_group_enabled("personal_ext_sibling"), false)
			helpers.assert_eq(f.ctx.state.hotstrings, { personal_ext_unique = true, personal_ext_sibling = false })
			local parsed = require("toml_codec").decode(f.content())
			helpers.assert_eq(parsed.future.keep, "owned-unrelated-value")
			helpers.assert_eq(parsed.hotstrings.groups.future_group, false)
			helpers.assert_eq(parsed.hotstrings.modules.future_group.unknown_section, true)
			helpers.assert_eq(parsed.hotstrings.groups.personal_ext_unique, true)
			helpers.assert_nil(parsed.hotstrings.groups.personal_ext_sibling, "the actual manifest sparse default is absence")
			helpers.assert_nil(f.ctx.state.hotstrings.future_group, "unregistered choices never acquire runtime ownership")
			helpers.assert_eq(f.observations.expected.content, before)
			helpers.assert_eq({ f.observations.writes, f.observations.refreshes, f.observations.starts }, { 1, 1, 0 })
			helpers.assert_eq(#f.observations.notices, 0)
			helpers.assert_eq(f.ctx.state.keymap, false)
			helpers.assert_eq(f.ctx.paused, false)
			helpers.assert_eq(f.ctx.state.future, { keep = true })
			helpers.assert_true(sibling ~= first)
			helpers.assert_eq(f.command("personal_ext_sibling").enable(), true)
			helpers.assert_eq(#f.state.mappings, 2, "reenabling the real owner restores exactly one source")
			helpers.assert_true(f.mapping("personal_ext_unique") == first, "the unselected mapping retains its exact identity")
			helpers.assert_eq(sibling.repl, "Sibling", "the literal native replacement is independently owned")
			helpers.assert_eq(f.mapping("personal_ext_sibling").repl, "Sibling")
			helpers.assert_eq(f.R.is_group_enabled("personal_ext_sibling"), true)
			helpers.assert_eq({ f.observations.writes, f.observations.refreshes, f.observations.starts }, { 2, 2, 0 })
			local restored = require("toml_codec").decode(f.content())
			helpers.assert_eq(restored.hotstrings.groups.future_group, false)
			helpers.assert_eq(restored.hotstrings.modules.future_group.unknown_section, true)
		end)
	end)

	for _, refusal in ipairs({ "false", "nil", "throw" }) do
		helpers.it("restores exact mappings and canonical bytes after writer " .. refusal .. " then retries freshly", function()
			with_fixture(false, function(f)
				local before, first, second = f.content(), f.mapping("personal_ext_unique"), f.mapping("personal_ext_sibling")
				local held = f.command("personal_ext_sibling").disable
				f.controls.writer = refusal
				helpers.assert_eq(held(), false)
				helpers.assert_eq(f.content(), before)
				helpers.assert_eq(#f.state.mappings, 2)
				helpers.assert_true(f.mapping("personal_ext_unique") == first and f.mapping("personal_ext_sibling") == second)
				helpers.assert_eq(f.R.is_group_enabled("personal_ext_sibling"), true)
				helpers.assert_eq(f.ctx.state.hotstrings, { personal_ext_unique = true, personal_ext_sibling = true })
				helpers.assert_eq({ f.observations.writes, f.observations.refreshes, f.observations.starts }, { 1, 0, 0 })
				f.controls.writer = nil
				helpers.assert_eq(held(), false, "a replaced rollback owner invalidates the held callback")
				helpers.assert_eq(f.observations.writes, 1, "stale held binding never reaches the writer")
				helpers.assert_eq(f.command("personal_ext_sibling").disable(), true, "a newly rendered current owner may retry")
				helpers.assert_eq({ f.observations.writes, f.observations.refreshes, f.observations.starts }, { 2, 1, 0 })
				helpers.assert_eq(#f.state.mappings, 1)
				helpers.assert_true(f.state.mappings[1] == first)
			end)
		end)
	end

	for _, changed in ipairs({ "configured-root", "registered-owner", "physical-alias", "symlink", "read-refusal", "changed-route" }) do
		helpers.it("refuses held file bindings after " .. changed .. " before any scoped write", function()
			with_fixture(false, function(f)
				local held = f.command("personal_ext_sibling").disable
				if changed == "configured-root" then f.controls.root = f.root .. "/other"
				elseif changed == "registered-owner" then
					helpers.assert_true(f.R.load_toml(f.records[2].name, f.records[2].path, nil, f.records[2].personal_source))
				elseif changed == "physical-alias" then f.attributes[f.records[2].path].ino = 1
				elseif changed == "symlink" then f.attributes[f.records[2].path].mode = "link"
				elseif changed == "read-refusal" then f.native_files.read_with_status = function() return nil, "unsafe" end
				elseif changed == "changed-route" then f.ctx.personal_files[2].path = f.root .. "/other.toml" end
				local first, second, before = f.state.mappings[1], f.state.mappings[2], f.content()
				helpers.assert_eq(held(), false)
				helpers.assert_eq(f.content(), before)
				helpers.assert_eq(#f.state.mappings, 2)
				helpers.assert_true(f.state.mappings[1] == first and f.state.mappings[2] == second)
				helpers.assert_eq({ f.observations.writes, f.observations.refreshes, f.observations.starts }, { 0, 0, 0 })
				helpers.assert_eq(#f.observations.notices, 1)
			end)
		end)
	end

	helpers.it("refuses an external canonical replacement and preserves its exact bytes", function()
		with_fixture(false, function(f)
			local held = f.command("personal_ext_sibling").disable
			local external = '[future]\nkeep = "external-winner"\n'
			f.external(external)
			local first, second = f.state.mappings[1], f.state.mappings[2]
			helpers.assert_eq(held(), false)
			helpers.assert_eq(f.content(), external)
			helpers.assert_true(f.state.mappings[1] == first and f.state.mappings[2] == second)
			helpers.assert_eq(f.ctx.state.hotstrings.personal_ext_sibling, true)
			helpers.assert_eq(f.observations.refreshes, 0)
			helpers.assert_eq(f.observations.starts, 0)
		end)
	end)

end)
