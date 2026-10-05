--- tests/unit/infra/test_personal_file_adoption_native.lua

--- ==============================================================================
--- MODULE: Native Personal File Gate Contract
--- DESCRIPTION:
--- Drives the real catalogue, engine, canonical writer and physical source cohort.
--- Independent literal identities prove per-file live and preview isolation.
--- ==============================================================================

local helpers = require("tests.helpers")
local Shell = require("adapters.shell_runner")
local Config = require("modules.hotstrings.hotstrings_config")
local Choices = require("tests.support.hotstring_choices")

--- Owns independent source, settings and override files for one native observation.
--- @param choices string Canonical starting configuration bytes.
--- @param body function
--- @param overrides string|nil Exact legacy override bytes.
local function fixture(choices, body, overrides)
	local root = os.tmpname(); os.remove(root)
	assert(Shell.run("mkdir -p " .. Shell.quote(root .. "/hot/a")))
	local definitions = {
		{ relative = "a__b.toml", id = "personal-file:615f5f622e746f6d6c", trigger = "flatx", output = "Flat" },
		{ relative = "a/b.toml", id = "personal-file:61:622e746f6d6c", trigger = "nestedx", output = "Nested" },
		{ relative = "words.old.toml", id = "personal-file:776f7264732e6f6c642e746f6d6c", trigger = "dottedx", output = "Dotted" },
	}
	for _, item in ipairs(definitions) do
		item.path = root .. "/hot/" .. item.relative
		local file = assert(io.open(item.path, "w"))
		assert(file:write('[probe]\n"' .. item.trigger .. '" = { output = "' .. item.output
			.. '", auto_expand = true, is_word = false, is_case_sensitive = true, is_case_sensitive_strict = true }\n'))
		assert(file:close())
	end
	local engine = require("hotstring_engine").new()
	Config._set_override_config_dir_for_test(root)
	if overrides then
		local file = assert(io.open(root .. "/hotstrings_overrides.toml", "w"))
		assert(file:write(overrides)); assert(file:close())
	end
	local ok, detail = pcall(function()
		Choices.with_file(Config, choices, function(path)
			assert(Config.init(engine, root .. "/hot", nil))
			local function match(trigger)
				engine:reset(); local result
				for char in trigger:gmatch(".") do result = engine:on_char(char) end
				return result
			end
			body({ root = root, definitions = definitions, engine = engine, config = Config,
				path = path, match = match, read = function() return Choices.read(path) end })
		end)
	end)
	for _, item in ipairs(definitions) do os.remove(item.path) end
	os.remove(root .. "/hot/a"); os.remove(root .. "/hot"); os.remove(root .. "/hotstrings_overrides.toml"); os.remove(root)
	if not ok then error(detail, 0) end
end

--- Builds the actual native menu while restoring every captured module dependency.
--- @param fixture_state table Physical source/configuration/engine fixture.
--- @param body function Rendered native row assertions.
local function with_native_menu(fixture_state, body)
	local loaded = {}; for name, value in pairs(package.loaded) do loaded[name] = value end
	local changed, opened = 0, {}
	local ok, detail = pcall(function()
		package.loaded["ui.menu.menu_builder"] = nil
		local Builder = require("ui.menu.menu_builder")
		local context = { config = fixture_state.config, _version = "9.9.9",
			on_menu_changed = function() changed = changed + 1 end,
			webview = { show = function(app) opened[#opened + 1] = app; return true end } }
		local function find(rows, prefix)
			for _, row in ipairs(rows or {}) do
				if type(row.title) == "string" and row.title:sub(1, #prefix) == prefix then return row end
				local nested = type(row.menu) == "table" and find(row.menu, prefix)
				if nested then return nested end
			end
		end
		body(function(prefix) return find(Builder.build(context), prefix) end,
			opened, function() return changed end)
	end)
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	if not ok then error(detail, 0) end
end

helpers.describe("native adopted personal file gates", function()
	helpers.it("102 native keeps empty personal sources reachable through actual file controls", function()
		fixture('', function(f)
			local item = f.definitions[2]
			local file = assert(io.open(item.path, "w")); assert(file:write('[_meta]\nshow_tooltip = true\n')); assert(file:close())
			local count, committed = f.config.load_all(); helpers.assert_eq(committed, true); helpers.assert_eq(count, 2)
			with_native_menu(f, function(render)
				local row = assert(render("a / b (0)"), "source discovery must not depend on mapping count")
				helpers.assert_eq(row.menu[1].disabled == true, false)
				helpers.assert_eq(type(row.menu[5].fn), "function")
				helpers.assert_eq(row.menu[5].fn(), true)
				helpers.assert_eq(f.config.resolve(item.id, nil).show_tooltip, false)
				helpers.assert_nil(f.match(item.trigger), "the source control cannot invent mappings for an empty file")
			end)
		end)
	end)
	helpers.it("102 native exposes actual unreadable personal files with disabled controls and no publication", function()
		fixture('', function(f)
			helpers.assert_eq(select(2, f.config.load_all()), true)
			local item = f.definitions[2]
			local file = assert(io.open(item.path)); local before = assert(file:read("*a")); assert(file:close())
			local preferences = f.read()
			assert(Shell.run("chmod 000 " .. Shell.quote(item.path)))
			local ok, detail = pcall(function()
				helpers.assert_nil(io.open(item.path, "r"), "actual file permissions must deny the native source read")
				helpers.assert_eq(f.config.personal_file_scope_binding(item.id).current(), false,
					"a retained provenance receipt cannot authorize an unreadable source")
				with_native_menu(f, function(render, opened, changed)
					local row = assert(render("a / b ("), "the unreadable captured source still has a diagnostic file row")
					for index = 1, 5 do
						helpers.assert_true(row.menu[index].disabled)
						if row.menu[index].fn then helpers.assert_eq(row.menu[index].fn(), false) end
					end
					helpers.assert_true(row.menu[6].disabled); helpers.assert_nil(row.menu[6].fn)
					helpers.assert_true(row.menu[7].disabled); helpers.assert_nil(row.menu[7].fn)
					helpers.assert_true(row.menu[8].disabled); helpers.assert_nil(row.menu[8].fn)
					helpers.assert_true(row.menu[6].title:find(require("infra.i18n").get("menu.hotstrings.personal_file_unavailable"):match("^[^:]+"), 1, true) ~= nil)
					helpers.assert_eq(f.read(), preferences); helpers.assert_eq(opened, {}); helpers.assert_eq(changed(), 0)
				end)
			end)
			assert(Shell.run("chmod 600 " .. Shell.quote(item.path)))
			file = assert(io.open(item.path)); helpers.assert_eq(file:read("*a"), before); assert(file:close())
			if not ok then error(detail, 0) end
		end)
	end)
	helpers.it("102 native renders five actual personal controls and preserves section choices through file gates", function()
		fixture('', function(f)
			helpers.assert_eq(select(2, f.config.load_all()), true)
			local item = f.definitions[2]
			helpers.assert_eq(f.config.toggle_section(item.id, "probe"), true)
			with_native_menu(f, function(render, opened, changed)
				local i18n = require("infra.i18n")
				local file = assert(render("a / b ("), "the actual personal file submenu must be reachable")
				for index, key in ipairs({ "menu.common.enabled", "hs_config.label_delay", "hs_config.label_priority",
					"hs_config.label_color", "hs_config.label_tooltip" }) do
					helpers.assert_eq(file.menu[index].title, i18n.get(key))
					helpers.assert_eq(type(file.menu[index].fn), "function", "each declared control has an actual callback")
					helpers.assert_eq(file.menu[index].disabled == true, false)
				end
				for index = 2, 4 do helpers.assert_eq(file.menu[index].fn(), true) end
				helpers.assert_eq(opened, { "hotstrings_config_window", "hotstrings_config_window", "hotstrings_config_window" })
				helpers.assert_eq(file.menu[1].fn(), true)
				helpers.assert_eq(f.config.is_group_enabled(item.id), false)
				helpers.assert_eq(render("a / b (").menu[1].fn(), true)
				helpers.assert_eq(f.config.is_group_enabled(item.id), true)
				helpers.assert_eq(f.config.is_section_enabled(item.id, "probe"), false,
					"a file gate must retain its independently disabled section")
				local before = f.config.resolve(item.id, nil).show_tooltip
				helpers.assert_eq(render("a / b (").menu[5].fn(), true)
				helpers.assert_eq(f.config.resolve(item.id, nil).show_tooltip, not before)
				helpers.assert_eq(changed(), 6)
				helpers.assert_eq(f.config.is_section_enabled(item.id, "probe"), false)
				local file_source = assert(io.open(item.path)); local bytes = assert(file_source:read("*a")); assert(file_source:close())
				helpers.assert_eq(require("toml_codec.codec").decode(bytes)._meta.show_tooltip, not before,
					"the tooltip menu ACK includes physical source publication")
			end)
		end)
	end)
	helpers.it("102 native disables only ambiguous metadata fields and refuses retained stale personal rows", function()
		fixture('', function(f)
			local item = f.definitions[2]
			local source = assert(io.open(item.path, "a")); assert(source:write('[_meta]\nDelay = 0.4 # retained case alias\n')); assert(source:close())
			helpers.assert_eq(select(2, f.config.load_all()), true)
			with_native_menu(f, function(render, opened, changed)
				local file = assert(render("a / b ("))
				helpers.assert_true(file.menu[2].disabled)
				helpers.assert_nil(file.menu[2].fn)
				helpers.assert_true(file.menu[2].title:find(require("infra.i18n").get("menu.hotstrings.personal_metadata_unavailable"), 1, true) ~= nil)
				helpers.assert_eq(file.menu[1].disabled == true, false, "the authoritative file gate remains usable")
				local read = assert(io.open(item.path)); local before = assert(read:read("*a")); assert(read:close())
				local alias = f.root .. "/hot/alias.toml"
				assert(Shell.run("ln " .. Shell.quote(item.path) .. " " .. Shell.quote(alias)))
				local accepted = file.menu[1].fn(); os.remove(alias)
				helpers.assert_eq(accepted, false, "an old rendered row cannot adopt a new physical alias cohort")
				helpers.assert_eq(f.config.is_group_enabled(item.id), true)
				helpers.assert_eq(opened, {}); helpers.assert_eq(changed(), 0)
				read = assert(io.open(item.path)); helpers.assert_eq(read:read("*a"), before); assert(read:close())
			end)
		end)
	end)
	helpers.it("102 native exposes skipped linked and depth-limited directories as actual read-only menu rows", function()
		fixture('', function(f)
			local limit = require("hotstrings.personal_files").additional_scan_max_depth
			local target, linked = f.root .. "/outside", f.root .. "/hot/linked"
			assert(Shell.run("mkdir " .. Shell.quote(target)))
			local excluded = assert(io.open(target .. "/outside.toml", "w")); assert(excluded:write('[probe]\n"excluded" = "Excluded"\n')); assert(excluded:close())
			assert(Shell.run("ln -s " .. Shell.quote(target) .. " " .. Shell.quote(linked)))
			helpers.assert_eq(require("modules.hotstrings.loader").unavailable_directories(linked, limit), {
				{ path = linked, label = "linked", reason = "linked-directory" },
			}, "a linked scan root is itself skipped without following its target")
			local parts = {}; for _ = 1, limit do parts[#parts + 1] = "deep" end
			local deep = f.root .. "/hot/" .. table.concat(parts, "/")
			assert(Shell.run("mkdir -p " .. Shell.quote(deep)))
			excluded = assert(io.open(deep .. "/excluded.toml", "w")); assert(excluded:write('[probe]\n"excluded" = "Excluded"\n')); assert(excluded:close())
			local ok, detail = pcall(function()
				local count, committed = f.config.load_all(); helpers.assert_eq(committed, true); helpers.assert_eq(count, 3)
				helpers.assert_eq(#f.config.personal_unavailable_directories(), 2)
				with_native_menu(f, function(render, opened, changed)
					for _, prefix in ipairs({ "linked", table.concat(parts, "/") }) do
						local folder = assert(render(prefix), "the actual skipped directory remains visible")
						helpers.assert_eq(#folder.menu, 1)
						helpers.assert_true(folder.menu[1].disabled); helpers.assert_nil(folder.menu[1].fn)
						helpers.assert_true(folder.menu[1].title:find(require("infra.i18n").get("menu.hotstrings.personal_directory_unavailable"):match("^[^:]+"), 1, true) ~= nil)
					end
					helpers.assert_nil(f.match("excluded"), "diagnostic discovery cannot activate linked or excluded child sources")
					helpers.assert_eq(opened, {}); helpers.assert_eq(changed(), 0)
				end)
			end)
			os.remove(linked); os.remove(target .. "/outside.toml"); os.remove(target)
			os.remove(deep .. "/excluded.toml")
			for index = limit, 1, -1 do os.remove(f.root .. "/hot/" .. table.concat(parts, "/", 1, index)) end
			if not ok then error(detail, 0) end
		end)
	end)
	helpers.it("102 native requires an acknowledged rendered page owner before metadata publication", function()
		fixture('', function(f)
			helpers.assert_eq(select(2, f.config.load_all()), true)
			local names = { "ui.webview_manager", "ui.hotstrings_config_window.bridge" }
			local previous = {}
			for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
			local epoch, accepted = 41, false
			package.loaded["ui.webview_manager"] = { current_epoch = function() return epoch end,
				eval_js = function() return accepted end }
			local ok, detail = pcall(function()
				local Bridge = require("ui.hotstrings_config_window.bridge")
				local state, item = { config = f.config }, f.definitions[2]
				local function source()
					local file = assert(io.open(item.path)); local bytes = assert(file:read("*a")); assert(file:close()); return bytes
				end
				local function edit(context)
					return Bridge.on_message({ action = "set_priority", category = item.id, section = "probe", priority = 63 }, state, context)
				end
				local original = source()
				helpers.assert_eq(Bridge.on_message("ready", state, { app_name = "hotstrings_config_window", epoch = 41 }), false)
				edit({ app_name = "hotstrings_config_window", epoch = 41 })
				helpers.assert_eq(source(), original, "a failed native render supplies no mutation owner")
				accepted = true
				helpers.assert_eq(Bridge.on_message("ready", state, { app_name = "hotstrings_config_window", epoch = 41 }), true)
				edit(nil); helpers.assert_eq(source(), original, "an unowned event cannot borrow the last rendered owner")
				epoch = 42
				edit({ app_name = "hotstrings_config_window", epoch = 41 })
				helpers.assert_eq(source(), original, "a retired native page cannot publish metadata")
				helpers.assert_eq(Bridge.on_message("ready", state, { app_name = "hotstrings_config_window", epoch = 42 }), true)
				edit({ app_name = "hotstrings_config_window", epoch = 42 })
				helpers.assert_eq(f.config.resolve(item.id, "probe").priority, 63)
			end)
			for _, name in ipairs(names) do package.loaded[name] = previous[name] end
			if not ok then error(detail, 0) end
		end)
	end)
	helpers.it("102 native refuses metadata from a rendered window after its source catalogue changes", function()
		fixture('', function(f)
			helpers.assert_eq(select(2, f.config.load_all()), true)
			local names = { "ui.webview_manager", "ui.hotstrings_config_window.bridge" }
			local previous = {}
			for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
			package.loaded["ui.webview_manager"] = { current_epoch = function() return 41 end, eval_js = function() return true end }
			local ok, detail = pcall(function()
				local Bridge = require("ui.hotstrings_config_window.bridge")
				local state = { config = f.config }
				helpers.assert_eq(Bridge.on_message("ready", state, { app_name = "hotstrings_config_window", epoch = 41 }), true)
				local item = f.definitions[2]
				local foreign = '[probe]\n"nestedx" = { output = "Foreign", auto_expand = true }\n'
				local file = assert(io.open(item.path, "w")); assert(file:write(foreign)); assert(file:close())
				helpers.assert_eq(select(2, f.config.load_all()), true)
				Bridge.on_message({ action = "set_priority", category = item.id, section = "probe", priority = 63 },
					state, { app_name = "hotstrings_config_window", epoch = 41 })
				file = assert(io.open(item.path)); local actual = assert(file:read("*a")); assert(file:close())
				helpers.assert_eq(actual, foreign, "an old rendered owner cannot publish into the new boot catalogue")
			end)
			for _, name in ipairs(names) do package.loaded[name] = previous[name] end
			if not ok then error(detail, 0) end
		end)
	end)
	helpers.it("102 native edits the actual canonical override owner and preserves its inactive legacy sibling", function()
		local id = "personal-file:61:622e746f6d6c"
		local old = '[b]\npriority = 41 # inactive legacy owner\nfuture = "legacy exact"\n'
		local source = old .. '["' .. id .. '"]\npriority = 52 # active canonical owner\nfuture = "canonical exact"\n'
		fixture('[hotstrings.groups]\n"' .. id .. '" = true\n', function(f)
			helpers.assert_eq(select(2, f.config.load_all()), true)
			helpers.assert_eq(f.config.resolve(id, "probe").priority, 52)
			helpers.assert_eq(f.config.set_override(id, nil, "priority", 63), true)
			helpers.assert_eq(f.config.resolve(id, "probe").priority, 63)
			local file = assert(io.open(f.root .. "/hotstrings_overrides.toml"))
			local actual = assert(file:read("*a")); assert(file:close())
			helpers.assert_true(actual:find(old, 1, true) ~= nil)
			helpers.assert_true(actual:find('future = "canonical exact"', 1, true) ~= nil)
			helpers.assert_nil(actual:find('priority = 52', 1, true))
			helpers.assert_eq(select(2, f.config.load_all()), true)
			helpers.assert_eq(f.config.resolve(id, "probe").priority, 63)
		end, source)
	end)
	helpers.it("102 native refuses a canonical section choice that would rename its stored case-distinct sibling", function()
		local source = '[hotstrings.modules."personal-file:61:622e746f6d6c"]\nteam = false # exact sibling choice\n'
		fixture(source, function(f)
			local item = f.definitions[2]
			local file = assert(io.open(item.path, "w"))
			assert(file:write('[[Team]]\n"nestedx" = { output = "Nested", auto_expand = true }\n[[team]]\n"siblingx" = { output = "Sibling", auto_expand = true }\n')); assert(file:close())
			helpers.assert_eq(select(2, f.config.load_all()), true)
			helpers.assert_eq(f.match(item.trigger).replacement, item.output)
			helpers.assert_nil(f.match("siblingx"))
			helpers.assert_eq(f.config.toggle_section(item.id, "Team"), false)
			helpers.assert_eq(f.read(), source)
			helpers.assert_eq(f.match(item.trigger).replacement, item.output)
			helpers.assert_nil(f.match("siblingx"))
		end)
	end)
	helpers.it("102 native refuses to overwrite a foreign engine generation during a gate inverse", function()
		local original = Config
		local loaded = package.loaded["modules.hotstrings.hotstrings_config"]
		local ok, detail = pcall(function()
			do
				package.loaded["modules.hotstrings.hotstrings_config"] = nil
				Config = require("modules.hotstrings.hotstrings_config")
				fixture('', function(f)
					local item, before = f.definitions[2], f.read()
					helpers.assert_eq(select(2, f.config.load_all()), true)
					local Writer, write = require("toml_codec.writer"), require("toml_codec.writer").batch_write
					Writer.batch_write = function(path, ...)
						if path == f.path then
							assert(f.engine:load_mappings({ { trigger = "foreignx", replacement = "Foreign",
								auto_expand = true, is_word = false, is_case_sensitive = true, is_case_sensitive_strict = true } }))
							return false, "foreign engine won before preferences refused"
						end
						return write(path, ...)
					end
					local tested, failure = pcall(function()
						helpers.assert_eq(f.config.disable_group(item.id), false)
						helpers.assert_eq(f.match("foreignx").replacement, "Foreign")
						helpers.assert_eq(f.config.retry_personal_gate_cleanup(), false)
						helpers.assert_nil(f.config.personal_file_scope_binding(item.id), "held gate debt is honestly unavailable")
						helpers.assert_eq(f.config.enable_group(item.id), false)
						helpers.assert_eq(f.match("foreignx").replacement, "Foreign")
						helpers.assert_eq(f.read(), before)
					end)
					Writer.batch_write = write
					if not tested then error(failure, 0) end
					-- Discard only this isolated fixture instance; no production debt
					-- release is claimed for an unowned foreign engine generation.
				end)
			end
		end)
		Config = original
		package.loaded["modules.hotstrings.hotstrings_config"] = loaded
		if not ok then error(detail, 0) end
	end)
	helpers.it("102 native reserves a symlinked primary target against an additional regular hardlink", function()
		fixture('', function(f)
			local lfs = require("lfs")
			local primary, target = f.root .. "/hot/personal_hotstrings.toml", f.root .. "/primary-target.bin"
			local bytes = '[probe]\n"primaryx" = { output = "Primary", auto_expand = true }\n'
			local file = assert(io.open(target, "w")); assert(file:write(bytes)); assert(file:close())
			assert(lfs.link(target, primary, true)); assert(os.remove(f.definitions[2].path))
			assert(lfs.link(target, f.definitions[2].path, false))
			local ok, detail = pcall(function()
				helpers.assert_eq(select(2, f.config.load_all()), true)
				helpers.assert_nil(f.config.personal_file_scope_binding(f.definitions[2].id))
				helpers.assert_eq(f.config.set_override(f.definitions[2].id, nil, "priority", 55), false)
				helpers.assert_not_nil(f.match(f.definitions[1].trigger))
				local source = assert(io.open(target)); helpers.assert_eq(source:read("*a"), bytes); assert(source:close())
				helpers.assert_eq(f.read(), '')
			end)
			os.remove(primary); os.remove(target)
			if not ok then error(detail, 0) end
		end)
	end)
	helpers.it("102 native restores its exact gate image after refused preferences and concurrent foreign source edit", function()
		fixture('', function(f)
			local item, before = f.definitions[2], f.read()
			helpers.assert_eq(select(2, f.config.load_all()), true)
			local Writer = require("toml_codec.writer")
			local write = Writer.batch_write
			Writer.batch_write = function(path, ...)
				if path == f.path then
					local file = assert(io.open(item.path, "w"))
					assert(file:write('[probe]\n"nestedx" = { output = "Foreign", auto_expand = true }\n')); assert(file:close())
					return false, "controlled preferences refusal"
				end
				return write(path, ...)
			end
			local ok, detail = pcall(function()
				helpers.assert_eq(f.config.disable_group(item.id), false)
				helpers.assert_eq(f.match(item.trigger).replacement, item.output,
					"rollback republishes the prior image without loading foreign source bytes")
				helpers.assert_eq(f.config.is_group_enabled(item.id), true)
				helpers.assert_eq(f.read(), before)
			end)
			Writer.batch_write = write
			if not ok then error(detail, 0) end
			helpers.assert_eq(select(2, f.config.load_all()), true)
			helpers.assert_eq(f.match(item.trigger).replacement, "Foreign", "only an explicit reload adopts foreign source bytes")
		end)
	end)
	helpers.it("102 native retains a refused gate inverse lease until the engine acknowledges its exact retry", function()
		fixture('', function(f)
			local item, before = f.definitions[2], f.read()
			helpers.assert_eq(select(2, f.config.load_all()), true)
			local Writer, write = require("toml_codec.writer"), require("toml_codec.writer").batch_write
			local load, inverse_pending = f.engine.load_mappings, false
			Writer.batch_write = function(path, ...)
				if path == f.path then inverse_pending = true; return false, "controlled preferences refusal" end
				return write(path, ...)
			end
			f.engine.load_mappings = function(engine, rows)
				if inverse_pending then return false end
				return load(engine, rows)
			end
			local ok, detail = pcall(function()
				helpers.assert_eq(f.config.disable_group(item.id), false)
				helpers.assert_nil(f.match(item.trigger), "unacknowledged inverse retains actual candidate posture")
				helpers.assert_eq(f.config.init(f.engine, f.root .. "/hot", nil), false)
				helpers.assert_eq(select(2, f.config.load_all()), false)
				helpers.assert_eq(f.config.enable_group(item.id), false)
				helpers.assert_eq(f.read(), before)
				inverse_pending = false
				helpers.assert_eq(f.config.retry_personal_gate_cleanup(), true)
				helpers.assert_eq(f.match(item.trigger).replacement, item.output)
				helpers.assert_eq(f.config.is_group_enabled(item.id), true)
			end)
			inverse_pending = false
			f.engine.load_mappings, Writer.batch_write = load, write
			f.config.retry_personal_gate_cleanup()
			if not ok then error(detail, 0) end
		end)
	end)
	for _, legacy in ipairs({
		{ name = "explicit false", choice_lines = 4, choices = '[hotstrings.groups]\nb = false # unchanged legacy group\n[hotstrings.modules.b]\nprobe = false # unchanged legacy section\n' },
		{ name = "section-only neutral false", choice_lines = 2, choices = '[hotstrings.modules.b]\nprobe = false # unchanged legacy section\n' },
		{ name = "override-only neutral false", choice_lines = 0, choices = '', overrides = '[b]\ndelay = 0.25 # unchanged legacy override\n' },
	}) do
		local sample = legacy
		helpers.it("102 native durably enables canonical gates over " .. sample.name, function()
			fixture(sample.choices .. '[future]\nkeep = "unchanged future"\n', function(f)
				local item = f.definitions[2]
				helpers.assert_eq(select(2, f.config.load_all()), true)
				helpers.assert_nil(f.match(item.trigger))
				helpers.assert_eq(f.config.is_group_enabled(item.id), false)
				helpers.assert_eq(f.config.set_category_scope_enabled({ item.id }, true), true)
				helpers.assert_eq(f.match(item.trigger).replacement, item.output)
				local content = f.read()
				local scanned_lines = 0
				for line in sample.choices:gmatch("[^\n]+\n") do
					scanned_lines = scanned_lines + 1
					helpers.assert_true(content:find(line, 1, true) ~= nil, "legacy source line remains byte-identical: " .. line)
				end
				helpers.assert_eq(scanned_lines, sample.choice_lines, "each independent legacy fixture has its expected source lines")
				local decoded = require("toml_codec").decode(content)
				helpers.assert_eq(decoded.hotstrings.groups[item.id], true)
				helpers.assert_eq(decoded.hotstrings.modules[item.id].probe, true)
				assert(f.config.init(f.engine, f.root .. "/hot", nil))
				helpers.assert_eq(select(2, f.config.load_all()), true)
				helpers.assert_eq(f.match(item.trigger).replacement, item.output)
				helpers.assert_eq(f.config.is_group_enabled(item.id), true)
				helpers.assert_eq(f.read(), content)
				if sample.overrides then
					local file = assert(io.open(f.root .. "/hotstrings_overrides.toml"))
					helpers.assert_eq(file:read("*a"), sample.overrides); assert(file:close())
				end
			end, sample.overrides)
		end)
	end
	helpers.it("102 native leaves unsupported quoted rule identities read-only", function()
		fixture('', function(f)
			local item = f.definitions[2]
			local file = assert(io.open(item.path, "w"))
			assert(file:write('[["quoted.team"]]\n"nestedx" = { output = "Nested", auto_expand = true }\n')); assert(file:close())
			helpers.assert_eq(select(2, f.config.load_all()), true)
			helpers.assert_nil(f.config.personal_file_scope_binding(item.id))
			helpers.assert_nil(f.match(item.trigger))
			helpers.assert_eq(f.config.set_override(item.id, nil, "priority", 40), false)
			helpers.assert_eq(f.read(), '')
		end)
	end)
	helpers.it("102 native persists literal dotted-section bulk choices without opening its sibling", function()
		fixture('[future]\nkeep = "exact unknown value"\n', function(f)
			local item = f.definitions[3]
			local file = assert(io.open(item.path, "w"))
			assert(file:write('[[dotted.team]]\n"dottedx" = { output = "Dotted", auto_expand = true }\n')); assert(file:close())
			helpers.assert_eq(select(2, f.config.load_all()), true)
			helpers.assert_not_nil(f.match(item.trigger))
			helpers.assert_eq(f.config.set_category_scope_enabled({ item.id }, false), true)
			helpers.assert_nil(f.match(item.trigger)); helpers.assert_not_nil(f.match(f.definitions[1].trigger))
			local document = require("toml_codec").decode(f.read())
			helpers.assert_eq(document.hotstrings.modules[item.id]["dotted.team"], false)
			helpers.assert_nil(document.hotstrings.modules[item.id].dotted)
			helpers.assert_eq(f.config.set_category_scope_enabled({ item.id }, true), true)
			helpers.assert_not_nil(f.match(item.trigger))
			helpers.assert_eq(f.config.toggle_section(item.id, "dotted.team"), true)
			helpers.assert_nil(f.match(item.trigger))
		end)
	end)
	helpers.it("102 native commits actual per-file and section metadata with live priority and retained gates", function()
		fixture('[future]\nkeep = "exact unknown value"\n', function(f)
			local competing = assert(io.open(f.definitions[1].path, "w"))
			assert(competing:write('[probe]\n"nestedx" = { output = "Competing", priority = 35, auto_expand = true }\n')); assert(competing:close())
			helpers.assert_eq(select(2, f.config.load_all()), true)
			local item = f.definitions[2]
			helpers.assert_eq(f.match(item.trigger).replacement, "Competing")
			local before = f.read()
			for _, row in ipairs({ { "delay", 0.2 }, { "color", "#aabbcc" }, { "show_tooltip", false }, { "priority", 43 } }) do
				helpers.assert_eq(f.config.set_override(item.id, nil, row[1], row[2]), true)
				helpers.assert_eq(f.config.resolve(item.id, "probe")[row[1]], row[2])
			end
			local file = assert(io.open(item.path)); local source = assert(file:read("*a")); assert(file:close())
			local parsed = require("toml_codec").decode(source)
			helpers.assert_eq(parsed._meta, { delay = 0.2, color = "#aabbcc", show_tooltip = false, priority = 43 })
			helpers.assert_eq(f.match(item.trigger).replacement, item.output)
			helpers.assert_eq(f.config.set_override(item.id, "probe", "priority", 62), true)
			helpers.assert_eq(f.config.resolve(item.id, "probe").priority, 62)
			helpers.assert_eq(f.match(item.trigger).replacement, item.output)
			helpers.assert_eq(f.config.disable_group(item.id), true)
			helpers.assert_eq(f.config.set_override(item.id, "probe", "delay", 0.1), true)
			helpers.assert_eq(f.match(item.trigger).replacement, "Competing"); helpers.assert_eq(f.config.is_group_enabled(item.id), false)
			helpers.assert_eq(f.config.enable_group(item.id), true)
			helpers.assert_eq(f.match(item.trigger).replacement, item.output)
			helpers.assert_eq(f.config.resolve(item.id, "probe").delay, 0.1)
			helpers.assert_eq(f.config.resolve(f.definitions[1].id, "probe").delay, 0)
			helpers.assert_true(f.read():find('keep = "exact unknown value"', 1, true) ~= nil)
			helpers.assert_true(before:find('keep = "exact unknown value"', 1, true) ~= nil)
		end)
	end)
	for _, acknowledgement in ipairs({ false, true }) do
		helpers.it("102 native keeps a foreign metadata generation after publisher acknowledgement " .. tostring(acknowledgement), function()
			local original, loaded = Config, package.loaded["modules.hotstrings.hotstrings_config"]
			package.loaded["modules.hotstrings.hotstrings_config"] = nil
			Config = require("modules.hotstrings.hotstrings_config")
			local tested, failure = pcall(function()
				fixture('', function(f)
					helpers.assert_eq(select(2, f.config.load_all()), true)
					local item, Writer = f.definitions[2], require("toml_codec.writer")
					local publish = Writer.publish_if_unchanged
					local function source()
						local file = assert(io.open(item.path)); local bytes = assert(file:read("*a")); assert(file:close()); return bytes
					end
					local before = source()
					Writer.publish_if_unchanged = function(path, ...)
						if path ~= item.path then return publish(path, ...) end
						if acknowledgement then assert(publish(path, ...) == true) end
						assert(f.engine:load_mappings({ { trigger = "foreignx", replacement = "Foreign",
							auto_expand = true, is_word = false, is_case_sensitive = true, is_case_sensitive_strict = true } }))
						return acknowledgement, "controlled foreign generation"
					end
					local ok, detail = pcall(function()
						helpers.assert_eq(f.config.set_override(item.id, nil, "priority", 77), false)
						helpers.assert_eq(f.match("foreignx").replacement, "Foreign")
						helpers.assert_eq(f.config.retry_personal_cleanup(), false)
						helpers.assert_nil(f.config.personal_file_scope_binding(item.id), "held metadata debt is honestly unavailable")
						helpers.assert_eq(f.config.set_override(item.id, nil, "priority", 63), false)
						helpers.assert_eq(f.match("foreignx").replacement, "Foreign")
						if acknowledgement then
							helpers.assert_true(source():find("priority = 77", 1, true) ~= nil,
								"the refused owner never inverses its source across a foreign runtime generation")
						else helpers.assert_eq(source(), before) end
					end)
					Writer.publish_if_unchanged = publish
					if not ok then error(detail, 0) end
				end)
			end)
			Config, package.loaded["modules.hotstrings.hotstrings_config"] = original, loaded
			if not tested then error(failure, 0) end
		end)
	end
	helpers.it("102 native refuses source publication and restores the exact previous engine image", function()
		fixture('[future]\nkeep = "exact unknown value"\n', function(f)
			helpers.assert_eq(select(2, f.config.load_all()), true)
			local item = f.definitions[2]
			local Writer = require("toml_codec.writer")
			local publish = Writer.publish_if_unchanged
			Writer.publish_if_unchanged = function(path, ...)
				if path == item.path then return false, "controlled source refusal" end
				return publish(path, ...)
			end
			local ok, detail = pcall(function()
				helpers.assert_eq(f.config.set_override(item.id, nil, "priority", 77), false)
				helpers.assert_eq(f.match(item.trigger).replacement, item.output)
				helpers.assert_eq(f.config.resolve(item.id, "probe").priority, 30)
			end)
			Writer.publish_if_unchanged = publish
			if not ok then error(detail, 0) end
			helpers.assert_eq(f.config.set_override(item.id, nil, "priority", 77), true)
			helpers.assert_eq(f.config.resolve(item.id, "probe").priority, 77)
			helpers.assert_eq(f.match(item.trigger).replacement, item.output)
		end)
	end)
	helpers.it("102 native activates distinct dotted and nested sources with exact live/preview identities", function()
		fixture('# retained neighbor\n[future]\nkeep = "exact unknown value"\n', function(f)
			local before = f.read()
			local count, committed = f.config.load_all()
			helpers.assert_eq(committed, true); helpers.assert_eq(count, 3)
			for _, item in ipairs(f.definitions) do
				local result = f.match(item.trigger)
				helpers.assert_not_nil(result); helpers.assert_eq(result.replacement, item.output)
				helpers.assert_eq(result.personal_source_id, item.id)
				local preview
				for _, row in ipairs(f.engine:candidates()) do if row.trigger == item.trigger then preview = row end end
				helpers.assert_not_nil(preview); helpers.assert_eq(preview.personal_source_id, item.id)
				helpers.assert_eq(preview.fires, true)
				helpers.assert_eq(f.config.resolve(item.id, "probe").delay, 0)
				helpers.assert_eq(f.config.resolve(item.id, "probe").priority, 30)
			end
			helpers.assert_eq(f.read(), before, "admission projects RAM without rewriting unknown configuration")
		end)
	end)
	helpers.it("102 native persists disabling one source and remains disabled after a genuine choices reload", function()
		fixture('# retained neighbor\n[future]\nkeep = "exact unknown value"\n', function(f)
			helpers.assert_eq(select(2, f.config.load_all()), true)
			local selected = f.definitions[2]
			helpers.assert_eq(f.config.set_category_scope_enabled({ selected.id }, false), true)
			helpers.assert_nil(f.match(selected.trigger))
			helpers.assert_not_nil(f.match(f.definitions[1].trigger))
			local document = require("toml_codec").decode(f.read())
			helpers.assert_eq(document.hotstrings.groups[selected.id], false)
			helpers.assert_eq(document.hotstrings.modules[selected.id].probe, false)
			helpers.assert_eq(document.future.keep, "exact unknown value")
			assert(f.config.init(f.engine, f.root .. "/hot", nil))
			helpers.assert_eq(select(2, f.config.load_all()), true)
			helpers.assert_nil(f.match(selected.trigger))
			helpers.assert_eq(f.config.set_category_scope_enabled({ selected.id }, true), true)
			helpers.assert_not_nil(f.match(selected.trigger))
		end)
	end)
	helpers.it("102 native refuses a held file owner after external source changes without settings publication", function()
		fixture('[future]\nkeep = "exact unknown value"\n', function(f)
			helpers.assert_eq(select(2, f.config.load_all()), true)
			local selected, before = f.definitions[2], f.read()
			local binding = assert(f.config.personal_file_scope_binding(selected.id))
			local file = assert(io.open(selected.path, "a")); assert(file:write("# external source edit\n")); assert(file:close())
			helpers.assert_eq(binding.current(), false)
			helpers.assert_eq(f.config.set_category_scope_enabled({ selected.id }, false), false)
			helpers.assert_eq(f.read(), before)
		end)
	end)
end)
