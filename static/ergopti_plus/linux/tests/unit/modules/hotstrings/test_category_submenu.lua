--- tests/unit/modules/hotstrings/test_category_submenu.lua

--- ==============================================================================
--- MODULE: Category Submenus
--- DESCRIPTION:
--- What a hotstring category looks like in the tray, and what its rows do.
---
--- WHY THIS IS ROUGHLY FOUR FIFTHS OF THE MENU:
--- On the other two drivers a category is a submenu: a gate, a way to open its
--- file, and a checkbox per section with the number of entries behind it. On
--- Linux it was ONE line showing the file's own stem with a tick — so the
--- sections, the counts, the localised name and the file were all unreachable,
--- and the menu's category half was the part that did not exist rather than the
--- part that was untranslated.
---
--- WHAT THE COUNTS ARE FOR:
--- A section with three entries and one with nine hundred are the same row
--- without them, and the second is the one a user disables when autocorrection
--- fights them.
---
--- WHY DISABLED AND NOT HIDDEN:
--- Sections under a switched-off category are greyed. A row that disappears
--- reads as a bug, and the user still needs to see what they get back when they
--- switch the category on.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A config module standing in for hotstrings_config, recording what it is asked.
--- @param opts table { enabled = boolean, sections_enabled = table }
--- @return table config, table log
local function fake_config(opts)
	opts = opts or {}
	local log = { toggled = {}, sections = {}, bulk = {} }
	local enabled = opts.enabled ~= false
	local section_state = opts.sections_enabled or {}

	return {
		get_groups = function() return { "rolls" } end,
		is_group_enabled = function(id) return id == "rolls" and enabled or false end,
		toggle_group = function(id) log.toggled[#log.toggled + 1] = id end,
		is_section_enabled = function(_, section)
			if not enabled then return false end
			if section_state[section] == nil then return true end
			return section_state[section]
		end,
		toggle_section = function(id, section)
			log.sections[#log.sections + 1] = id .. "." .. section
			return true
		end,
		set_category_scope_enabled = function(ids, on)
			log.bulk[#log.bulk + 1] = table.concat(ids, ",") .. "=" .. tostring(on)
			return true
		end,
		get_category = function(id)
			if id ~= "rolls" then return nil end
			return {
				id = "rolls",
				path = "/home/u/.config/ergopti/hotstrings/rolls.toml",
				description = { en = "Rolls", fr = "Roulements" },
				sections_order = { "hc", "sx" },
				sections = { hc = { count = 12 }, sx = { count = 3 } },
				count = 15,
				-- Rolls come from the Ergopti layout extension, whose submenu lists them.
				extension = { id = "ergopti", name = "Ergopti" },
			}
		end,
		reload = function() end,
	}, log
end

--- Builds the menu and returns the rolls category row.
--- @param config table
--- @param ctx_extra table|nil
--- @return table|nil row
local function rolls_row(config, ctx_extra)
	local mb = helpers.load_module("ui.menu.menu_builder")
	local ctx = { config = config, _version = "9.9.9" }
	for k, v in pairs(ctx_extra or {}) do ctx[k] = v end

	local found = nil
	local function search(list)
		for _, item in ipairs(list or {}) do
			if type(item.title) == "string"
				and (item.title:find("Rolls", 1, true) or item.title:find("Roulements", 1, true))
				and type(item.menu) == "table" then
				found = item
				return
			end
			if type(item.menu) == "table" then
				search(item.menu)
				if found then return end
			end
		end
	end
	search(mb.build(ctx))
	return found
end





-- =================================================================
-- =================================================================
-- ======= 1/ The category row itself ==============================
-- =================================================================
-- =================================================================

helpers.describe("category submenu: the row that opens it", function()

	helpers.it("shows the localised name, not the file stem", function()
		local row = rolls_row((fake_config({})))
		helpers.assert_true(row ~= nil, "the category must appear in the menu at all")
		helpers.assert_true(row.title:find("Rolls", 1, true) ~= nil
			or row.title:find("Roulements", 1, true) ~= nil,
			"the packs carry a description in 21 locales and the menu printed the "
				.. "stem — 'distancesreduction' rather than 'Réduction des distances', "
				.. "in every language; got: " .. tostring(row.title))
	end)

	helpers.it("shows how many hotstrings it holds", function()
		local row = rolls_row((fake_config({})))
		helpers.assert_true(row.title:find("15", 1, true) ~= nil,
			"a category is chosen by size as much as by name; got: " .. tostring(row.title))
	end)

	helpers.it("reflects its enabled state as a checkmark", function()
		helpers.assert_eq(rolls_row((fake_config({ enabled = true }))).checked, true, "on")
		helpers.assert_eq(rolls_row((fake_config({ enabled = false }))).checked, false, "off")
	end)

	helpers.it("is a submenu, not a single toggle", function()
		local row = rolls_row((fake_config({})))
		helpers.assert_true(#row.menu >= 4,
			"a gate, a file, the bulk rows and one row per section; a single line "
				.. "cannot express any of it")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 2/ What the rows inside do ==============================
-- =================================================================
-- =================================================================

helpers.describe("category submenu: its rows", function()

	for _, enabled in ipairs({ true, false }) do
		helpers.it("offers the explicit category scope command " .. tostring(enabled), function()
			local config, log = fake_config({})
			local row = rolls_row(config)
			local i18n = require("infra.i18n")
			helpers.assert_eq(row.menu[1].title, i18n.get("menu.hotstrings.scope_enable_all"))
			helpers.assert_eq(row.menu[2].title, i18n.get("menu.hotstrings.scope_disable_all"))
			helpers.assert_nil(row.menu[enabled and 1 or 2].checked)
			row.menu[enabled and 1 or 2].fn()
			helpers.assert_eq(log.bulk, { "rolls=" .. tostring(enabled) },
				"one click selects only the category the user opened")
			helpers.assert_eq(log.toggled, {}, "the previous gate toggle cannot run as a second mutation")
		end)
	end

	for _, enabled in ipairs({ true, false }) do
		for _, outcome in ipairs({ "true", "false", "nil", "throw" }) do
			helpers.it("category command reports owner outcome " .. outcome .. " for " .. tostring(enabled), function()
				local config = fake_config({})
				local requested = {}
				config.set_category_scope_enabled = function(ids, on)
					requested[#requested + 1] = { ids = ids, enabled = on }
					if outcome == "throw" then error("category owner fixture refused") end
					if outcome == "nil" then return nil end
					return outcome == "true"
				end
				local execute, modal = os.execute, require("ui.modal")
				local run, asked, modals = modal.run, {}, 0
				modal.run = function(callback) modals = modals + 1; return callback() end
				local called, result = pcall(function()
					local row = rolls_row(config)
					os.execute = function(command)
						if command:find("zenity", 1, true) then asked[#asked + 1] = command; return 0 end
						return execute(command)
					end
					return row.menu[enabled and 1 or 2].fn()
				end)
				os.execute, modal.run = execute, run
				helpers.assert_true(called, "a category click contains a throwing owner: " .. tostring(result))
				helpers.assert_eq(requested, { { ids = { "rolls" }, enabled = enabled } })
				helpers.assert_eq(result, outcome == "true", "only exact true acknowledges the owner")
				local notices = outcome == "true" and 0 or 1
				helpers.assert_eq(#asked, notices, "each refused transaction surfaces one visible failure")
				helpers.assert_eq(modals, notices, "the failure dialog uses the keyboard-release boundary")
				if notices > 0 then
					helpers.assert_true(asked[1]:find("--error", 1, true) ~= nil)
					helpers.assert_true(asked[1]:find("--text=" .. require("adapters.shell_runner").quote(
						require("infra.i18n").get("dialog.bulk_toggle.save_failed")), 1, true) ~= nil, "the refusal is localized")
				end
			end)
		end
	end

	helpers.it("offers the category's own file, at the path the loader resolved", function()
		local config = fake_config({})
		local opened = {}
		local row = rolls_row(config, { on_open_file = function(p) opened[#opened + 1] = p end })
		for _, item in ipairs(row.menu) do
			if type(item.title) == "string" and item.title:lower():find("open") then item.fn() end
			if type(item.title) == "string" and item.title:lower():find("ouvrir") then item.fn() end
		end
		helpers.assert_eq(opened, { "/home/u/.config/ergopti/hotstrings/rolls.toml" },
			"finding a pack by hand means knowing whether it came from the bundle or "
				.. "the user's own directory, which is exactly what the loader resolved")
	end)

	helpers.it("lists every section with its entry count", function()
		local row = rolls_row((fake_config({})))
		local titles = {}
		for _, item in ipairs(row.menu) do
			if type(item.title) == "string" then titles[#titles + 1] = item.title end
		end
		local joined = table.concat(titles, " | ")
		helpers.assert_true(joined:find("hc (12)", 1, true) ~= nil,
			"the section and how many entries it holds: " .. joined)
		helpers.assert_true(joined:find("sx (3)", 1, true) ~= nil,
			"and the next one: " .. joined)
	end)

	helpers.it("lists the sections in the order the file declares", function()
		local row = rolls_row((fake_config({})))
		local hc_at, sx_at
		for i, item in ipairs(row.menu) do
			if type(item.title) == "string" then
				if item.title:find("hc (", 1, true) then hc_at = i end
				if item.title:find("sx (", 1, true) then sx_at = i end
			end
		end
		helpers.assert_true(hc_at ~= nil and sx_at ~= nil and hc_at < sx_at,
			"sections_order groups related rolls together; sorting them alphabetically "
				.. "would scatter them")
	end)

	helpers.it("toggles the section the user clicked", function()
		local config, log = fake_config({})
		local row = rolls_row(config)
		for _, item in ipairs(row.menu) do
			if type(item.title) == "string" and item.title:find("sx (", 1, true) then item.fn() end
		end
		helpers.assert_eq(log.sections, { "rolls.sx" },
			"named, so a menu with two sections cannot toggle the wrong one")
	end)

	helpers.it("checks a section that is on and unchecks one that is off", function()
		local row = rolls_row((fake_config({ sections_enabled = { hc = true, sx = false } })))
		for _, item in ipairs(row.menu) do
			if type(item.title) == "string" and item.title:find("hc (", 1, true) then
				helpers.assert_eq(item.checked, true, "hc is on")
			end
			if type(item.title) == "string" and item.title:find("sx (", 1, true) then
				helpers.assert_eq(item.checked, false, "and sx is off")
			end
		end
	end)


end)





-- =================================================================
-- =================================================================
-- ======= 3/ A switched-off category ==============================
-- =================================================================
-- =================================================================

helpers.describe("category submenu: when the category is off", function()

	helpers.it("greys its sections rather than hiding them", function()
		local row = rolls_row((fake_config({ enabled = false })))
		local seen = 0
		for _, item in ipairs(row.menu) do
			-- A section row is "<name> (<count>)" and nothing else. Matched by shape
			-- rather than by " (" so the gate row — whose localised label ends in a
			-- parenthesised hint — is not mistaken for one.
			if type(item.title) == "string" and item.title:match("^%S+ %(%d+%)$") then
				seen = seen + 1
				helpers.assert_eq(item.disabled, true,
					"a row that disappears reads as a bug, and the user still needs to "
						.. "see what they get back when they switch the category on")
			end
		end
		helpers.assert_true(seen >= 2, "both sections must still be listed; saw " .. seen)
	end)

	helpers.it("leaves the gate itself clickable", function()
		local config, log = fake_config({ enabled = false })
		local row = rolls_row(config)
		helpers.assert_true(not row.menu[1].disabled,
			"greying the gate too would make a disabled category impossible to "
				.. "re-enable from the menu that disabled it")
		row.menu[1].fn()
		helpers.assert_eq(log.bulk, { "rolls=true" }, "and it must still act")
	end)

end)

helpers.describe("personal category scope parity", function()
	for _, enabled in ipairs({ true, false }) do
		for _, posture in ipairs({ true, false }) do
			helpers.it("personal command " .. tostring(enabled) .. " behind gate " .. tostring(posture), function()
				local config, log = fake_config({ enabled = posture })
				local category = config.get_category("rolls")
				category.id, category.path = "personal", "/user/hotstrings/personal.toml"
				category.description, category.extension = { en = "Personal fixture", fr = "Personal fixture" }, nil
				config.get_groups = function() return { "personal" } end
				config.get_category = function(id) if id == "personal" then return category end end
				config.is_group_enabled = function(id) return id == "personal" and posture end
				local mb = helpers.load_module("ui.menu.menu_builder")
				local captured = nil
				local function find(rows)
					for _, row in ipairs(rows or {}) do
						if type(row.title) == "string" and row.title:find("Personal fixture", 1, true) then
							captured = row
						end
						find(row.menu)
					end
				end
				find(mb.build({ config = config, _version = "9.9.9", paused = false }))
				helpers.assert_true(captured ~= nil, "the actual personal provider must render its category")
				local i18n = require("infra.i18n")
				helpers.assert_eq(captured.menu[1].title, i18n.get("menu.hotstrings.scope_enable_all"))
				helpers.assert_eq(captured.menu[2].title, i18n.get("menu.hotstrings.scope_disable_all"))
				helpers.assert_nil(captured.menu[enabled and 1 or 2].checked)
				helpers.assert_eq(captured.menu[enabled and 1 or 2].fn(), true)
				helpers.assert_eq(log.bulk, { "personal=" .. tostring(enabled) })
				helpers.assert_eq(log.toggled, {}, "the independent engine/group toggles do not run")
			end)
		end
	end
end)


--- Runs an actual shared renderer over an independently changed command label.
--- @param body function Real native-provider observations and assertions.
local function with_file_command(body, change_label)
	local saved = package.loaded["infra.manifest_menu"]
	local ok, err = xpcall(function()
		local path = require("infra.paths").shared("modules/menu/menu_manifest.json")
		local native_captions = require("infra.i18n")
		local renderer = assert(require("menu.renderer").new({
			platform = "linux", manifest_path = function() return path end,
			json_decode = function(bytes)
				local document = require("json").decode(bytes)
				if change_label then document.hotstring_file_commands[1].i18n = "fixture.category.file.command" end
				return document
			end,
			i18n = { get = function(key)
				-- The counted parent and full-tray header require genuine translated captions;
				-- the file-command assertions retain their independent key labels.
				if key == "menu.hotstrings.title" or key == "menu.builder.active_brand"
					or key == "menu.builder.title_paused" then return native_captions.get(key) end
				return key
			end, section = function(key) return key end },
			logger = require("logger.shim"),
		}))
		package.loaded["infra.manifest_menu"] = renderer
		body()
	end, debug.traceback)
	package.loaded["infra.manifest_menu"] = saved
	package.loaded["ui.menu.menu_builder"] = nil
	if not ok then error(err, 0) end
end

helpers.describe("shared category file command", function()
	helpers.it("shared category file: consumes the actual declared label", function()
		with_file_command(function()
			local row = rolls_row((fake_config({})), { on_open_file = function() return true end })
			helpers.assert_eq(row.menu[3].title, "fixture.category.file.command")
		end, true)
	end)
	for _, receipt in ipairs({ "true", "false", "nil" }) do
		helpers.it("shared category file: keeps the captured source and opening receipt " .. receipt .. " while paused", function()
			with_file_command(function()
				local config = fake_config({ enabled = false })
				local category = config.get_category("rolls")
				config.get_category = function() return category end
				local opened, saves = {}, 0
				local row = rolls_row(config, {
					is_paused = function() return true end,
					save_prefs = function() saves = saves + 1 end,
					on_open_file = function(path)
						opened[#opened + 1] = path
						if receipt == "nil" then return nil end
						return receipt == "true"
					end,
				})
				local command = row.menu[3]
				helpers.assert_eq(command.title, "menu.hotstrings.open_file")
				helpers.assert_true(command.disabled ~= true, "file configuration stays available under pause")
				local original = category.path
				category.path = "/foreign/replaced.toml"
				local result = command.fn()
				if receipt == "nil" then helpers.assert_nil(result)
				else helpers.assert_eq(result, receipt == "true") end
				helpers.assert_eq(opened, { original }, "the actual opening owner receives the loader's captured source")
				helpers.assert_eq(saves, 0, "opening never enters a settings writer")
			end)
		end)
	end
	helpers.it("shared category file: refuses a held callback after its actual opening owner is withdrawn", function()
		with_file_command(function()
			local calls = 0
			local ctx = { on_open_file = function() calls = calls + 1; return true end }
			local mb = helpers.load_module("ui.menu.menu_builder")
			ctx.config = fake_config({})
			local function find(rows)
				for _, row in ipairs(rows or {}) do
					if row.title == "menu.hotstrings.open_file" then return row end
					local child = find(row.menu)
					if child then return child end
				end
			end
			local command = find(mb.build(ctx))
			helpers.assert_true(command ~= nil)
			ctx.on_open_file = nil
			helpers.assert_eq(command.fn(), false)
			helpers.assert_eq(calls, 0)
			local disabled = find(mb.build(ctx))
			helpers.assert_eq(disabled.disabled, true)
		end)
	end)
	helpers.it("shared category file: keeps absent category paths out of the native provider", function()
		with_file_command(function()
			local config = fake_config({})
			local category = config.get_category("rolls")
			category.path = nil
			config.get_category = function() return category end
			local row = rolls_row(config)
			for _, item in ipairs(row.menu) do
				helpers.assert_true(item.title ~= "menu.hotstrings.open_file")
			end
			helpers.assert_true(#row.menu > 2, "the remaining category and section commands still render")
		end)
	end)
end)

helpers.describe("category section callbacks: exact publication acknowledgement", function()
	local function section_action(config)
		local row = assert(rolls_row(config), "the actual category provider must remain visible")
		for _, item in ipairs(row.menu) do
			if type(item.title) == "string" and item.title:find("hc (", 1, true) then return item.fn end
		end
		error("the native hc section row was not rendered")
	end
	local function observe_click(action)
		local execute, modal = os.execute, require("ui.modal")
		local run, notices, releases = modal.run, {}, 0
		modal.run = function(callback) releases = releases + 1; return callback() end
		os.execute = function(command)
			if command:find("zenity", 1, true) then notices[#notices + 1] = command; return 0 end
			return execute(command)
		end
		local called, result = pcall(action)
		os.execute, modal.run = execute, run
		return called, result, notices, releases
	end
	for _, outcome in ipairs({ "true", "false", "nil", "number", "text", "throw", "missing" }) do
		helpers.it("contains the section owner receipt " .. outcome, function()
			local config, log = fake_config({})
			local asked = {}
			if outcome == "missing" then config.toggle_section = nil
			else config.toggle_section = function(id, name)
				asked[#asked + 1] = { id, name }
				if outcome == "throw" then error("inert native section refusal") end
				if outcome == "nil" then return nil end
				if outcome == "number" then return 2 end
				if outcome == "text" then return "true" end
				return outcome == "true"
			end end
			local called, result, notices, releases = observe_click(section_action(config))
			helpers.assert_true(called, "a section click contains a refused or throwing owner")
			helpers.assert_eq(#notices, outcome == "true" and 0 or 1, "a refused owner has a visible failure instead of a silent click")
			helpers.assert_eq(result, outcome == "true", "only the exact boolean true acknowledges publication")
			helpers.assert_eq(asked, outcome == "missing" and {} or { { "rolls", "hc" } })
			helpers.assert_eq(releases, #notices, "the visible refusal releases the keyboard before its modal")
			helpers.assert_eq(log.toggled, {}, "the category gate remains independently owned")
			if #notices > 0 then
				helpers.assert_true(notices[1]:find("--error", 1, true) ~= nil)
				helpers.assert_true(notices[1]:find(require("adapters.shell_runner").quote(
					require("infra.i18n").get("dialog.bulk_toggle.save_failed")), 1, true) ~= nil)
			end
		end)
	end

	local function with_real_section_owner(body)
		local directory = os.tmpname()
		assert(os.remove(directory))
		directory = directory .. "-ergopti-section-ack"
		local quote = require("adapters.shell_runner").quote
		assert(require("adapters.shell_runner").run("mkdir -p " .. quote(directory)) == true)
		local path = directory .. "/config.toml"
		local original = '# independently written future preferences\n[hotstrings]\ngroups = { rolls = true, foreign = true }\n'
			.. '[hotstrings.modules.rolls]\nhc = true\nsx = false\n[future]\nlabel = "kept"\n'
		local fh = assert(io.open(path, "wb"));assert(fh:write(original));assert(fh:close())
		local loaded = {}
		for name, value in pairs(package.loaded) do loaded[name] = value end
		local Terminators = require("modules.hotstrings.terminator_settings")
		local catalogue = Terminators.snapshot()
		local ok, err = pcall(function()
			package.loaded["modules.hotstrings.hotstrings_config"] = nil
			package.loaded["modules.hotstrings.loader"] = nil
			local paths = {}
			for key, value in pairs(require("infra.paths")) do paths[key] = value end
			-- The private fixture has no external installed layout roots.
			paths.extension_roots = function() return {} end
			package.loaded["infra.paths"] = paths
			local loader = require("modules.hotstrings.loader")
			local native_find = loader.find_toml_files
			package.loaded["modules.hotstrings.loader"] = {
				find_toml_files = native_find, list_subdirs = function() return {} end,
				read_file = function() return nil end,
				load_catalogue = function()
					return { committed = true, errors = 0, categories = {
						rolls = { id = "rolls", path = directory .. "/rolls.toml", count = 1,
							description = { en = "Rolls", fr = "Roulements" },
							extension = { id = "ergopti", name = "Ergopti" },
							sections_order = { "hc", "sx" }, sections = { hc = { count = 1 }, sx = { count = 0 } } },
					}, mappings = { { trigger = "hq", replacement = "section-result", group = "rolls", section = "hc", auto_expand = true } } }
				end,
			}
			local config, engine = require("modules.hotstrings.hotstrings_config"), require("hotstring_engine").new()
			local changed = 0
			assert(config._set_config_file_for_test(path))
			assert(config.init(engine, directory, function() changed = changed + 1 end))
			local _, loaded = config.load_all();assert(loaded)
			body({ config = config, engine = engine, path = path, original = original,
				changed = function() return changed end })
		end)
		local restored = Terminators.restore_configuration(catalogue)
		for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
		for name, value in pairs(loaded) do package.loaded[name] = value end
		local removed = require("adapters.shell_runner").run("rm -rf " .. quote(directory))
		assert(restored, "the exact delimiter catalogue is restored")
		assert(removed == true, "the owned private fixture is retired")
		if not ok then error(err, 0) end
	end
	local function read(path)
		local fh = assert(io.open(path, "rb"));local data = fh:read("*a");assert(fh:close());return data
	end
	local function section_fires(engine)
		engine:reset();engine:on_char("h");local result = engine:on_char("q")
		return result ~= nil and result.replacement == "section-result"
	end
	for _, outcome in ipairs({ "false", "nil", "number", "throw" }) do
		helpers.it("reports a real canonical section publication refusal " .. outcome .. " without repainting", function()
			with_real_section_owner(function(c)
				helpers.assert_true(section_fires(c.engine), "the original actual engine mapping fires")
				local action = section_action(c.config)
				local rename, publications = os.rename, 0
				os.rename = function(from, to)
					if from == c.path .. ".tmp" and to == c.path then
						publications = publications + 1
						if outcome == "throw" then error("inert owned publication refusal") end
						if outcome == "nil" then return nil, "inert owned publication refusal" end
						if outcome == "number" then return 2 end
						return false, "inert owned publication refusal"
					end
					return rename(from, to)
				end
				local called, result, notices, releases = observe_click(action)
				os.rename = rename
				helpers.assert_true(called)
				helpers.assert_eq(publications, 1, "the actual conditional writer attempted its owned staging publication")
				helpers.assert_eq(#notices, 1, "the actual refused publication is visible to the user")
				helpers.assert_eq(result, false)
				helpers.assert_eq(c.changed(), 0, "no success notification/repaint is published")
				helpers.assert_eq(read(c.path), c.original, "every independent source byte survives the refused write")
				helpers.assert_true(c.config.is_section_checked("rolls", "hc"))
				helpers.assert_true(section_fires(c.engine), "the actual engine is compensated after failed persistence")
				helpers.assert_eq(#notices, 1)
				helpers.assert_eq(releases, 1)
			end)
		end)
	end
	helpers.it("acknowledges the real section publication and refreshes only after durable success", function()
		with_real_section_owner(function(c)
			local called, result, notices, releases = observe_click(section_action(c.config))
			helpers.assert_true(called)
			helpers.assert_eq(result, true)
			helpers.assert_eq(c.changed(), 1)
			helpers.assert_true(c.config.refresh_choices(), "a real disk reload accepts the committed choice")
			helpers.assert_eq(c.changed(), 2, "the separate reload owns its own publication notification")
			helpers.assert_eq(c.config.is_section_checked("rolls", "hc"), false)
			helpers.assert_eq(section_fires(c.engine), false)
			local source = read(c.path)
			helpers.assert_true(source:find('label = "kept"', 1, true) ~= nil)
			helpers.assert_true(source:find('foreign = true', 1, true) ~= nil)
			helpers.assert_eq(#notices, 0)
			helpers.assert_eq(releases, 0)
		end)
	end)
end)

helpers.describe("extension-bound section callbacks: exact publication acknowledgement", function()
	local function section_action(config)
		local category = config.get_category("rolls")
		category.extension = nil
		category.sections.hc.extension = { id = "ergopti", name = "Ergopti" }
		local getter = config.get_category
		config.get_category = function(id) if id == "rolls" then return category end; return getter(id) end
		local mb = helpers.load_module("ui.menu.menu_builder")
		local label = string.format(require("infra.i18n").get("menu.extensions.hotstrings_of"), "Ergopti")
		local found
		local function find(rows)
			for _, row in ipairs(rows or {}) do
				if row.title == label then found = row end
				if type(row.menu) == "table" then find(row.menu) end
			end
		end
		find(mb.build({ config = config, _version = "9.9.9" }))
		assert(found, "the actual owning extension submenu must be present")
		for _, row in ipairs(found.menu or {}) do
			if type(row.title) == "string" and row.title:find("hc (", 1, true) then return row.fn end
		end
		error("the extension provider did not draw the direct bound hc section")
	end
	local function observe_click(action)
		local execute, modal = os.execute, require("ui.modal")
		local run, notices, releases = modal.run, {}, 0
		modal.run = function(callback) releases = releases + 1; return callback() end
		os.execute = function(command)
			if command:find("zenity", 1, true) then notices[#notices + 1] = command; return 0 end
			return execute(command)
		end
		local called, result = pcall(action)
		os.execute, modal.run = execute, run
		return called, result, notices, releases
	end
	for _, outcome in ipairs({ "true", "false", "nil", "number", "text", "throw", "missing" }) do
		helpers.it("contains the bound section owner receipt " .. outcome, function()
			local config, log = fake_config({})
			local asked = {}
			if outcome == "missing" then config.toggle_section = nil
			else config.toggle_section = function(id, name)
				asked[#asked + 1] = { id, name }
				if outcome == "throw" then error("inert native section refusal") end
				if outcome == "nil" then return nil end
				if outcome == "number" then return 2 end
				if outcome == "text" then return "true" end
				return outcome == "true"
			end end
			local called, result, notices, releases = observe_click(section_action(config))
			helpers.assert_true(called, "a section click contains a refused or throwing owner")
			helpers.assert_eq(#notices, outcome == "true" and 0 or 1, "a refused owner has a visible failure instead of a silent click")
			helpers.assert_eq(result, outcome == "true", "only the exact boolean true acknowledges publication")
			helpers.assert_eq(asked, outcome == "missing" and {} or { { "rolls", "hc" } })
			helpers.assert_eq(releases, #notices, "the visible refusal releases the keyboard before its modal")
			helpers.assert_eq(log.toggled, {}, "the category gate remains independently owned")
			if #notices > 0 then
				helpers.assert_true(notices[1]:find("--error", 1, true) ~= nil)
				helpers.assert_true(notices[1]:find(require("adapters.shell_runner").quote(
					require("infra.i18n").get("dialog.bulk_toggle.save_failed")), 1, true) ~= nil)
			end
		end)
	end

	local function with_real_section_owner(body)
		local directory = os.tmpname()
		assert(os.remove(directory))
		directory = directory .. "-ergopti-section-ack"
		local quote = require("adapters.shell_runner").quote
		assert(require("adapters.shell_runner").run("mkdir -p " .. quote(directory)) == true)
		local path = directory .. "/config.toml"
		local original = '# independently written future preferences\n[hotstrings]\ngroups = { rolls = true, foreign = true }\n'
			.. '[hotstrings.modules.rolls]\nhc = true\nsx = false\n[future]\nlabel = "kept"\n'
		local fh = assert(io.open(path, "wb"));assert(fh:write(original));assert(fh:close())
		local loaded = {}
		for name, value in pairs(package.loaded) do loaded[name] = value end
		local Terminators = require("modules.hotstrings.terminator_settings")
		local catalogue = Terminators.snapshot()
		local ok, err = pcall(function()
			package.loaded["modules.hotstrings.hotstrings_config"] = nil
			package.loaded["modules.hotstrings.loader"] = nil
			local paths = {}
			for key, value in pairs(require("infra.paths")) do paths[key] = value end
			-- The private fixture has no external installed layout roots.
			paths.extension_roots = function() return {} end
			package.loaded["infra.paths"] = paths
			local loader = require("modules.hotstrings.loader")
			local native_find = loader.find_toml_files
			package.loaded["modules.hotstrings.loader"] = {
				find_toml_files = native_find, list_subdirs = function() return {} end,
				read_file = function() return nil end,
				load_catalogue = function()
					return { committed = true, errors = 0, categories = {
						rolls = { id = "rolls", path = directory .. "/rolls.toml", count = 1,
							description = { en = "Rolls", fr = "Roulements" },
							extension = { id = "ergopti", name = "Ergopti" },
							sections_order = { "hc", "sx" }, sections = { hc = { count = 1 }, sx = { count = 0 } } },
					}, mappings = { { trigger = "hq", replacement = "section-result", group = "rolls", section = "hc", auto_expand = true } } }
				end,
			}
			local config, engine = require("modules.hotstrings.hotstrings_config"), require("hotstring_engine").new()
			local changed = 0
			assert(config._set_config_file_for_test(path))
			assert(config.init(engine, directory, function() changed = changed + 1 end))
			local _, loaded = config.load_all();assert(loaded)
			body({ config = config, engine = engine, path = path, original = original,
				changed = function() return changed end })
		end)
		local restored = Terminators.restore_configuration(catalogue)
		for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
		for name, value in pairs(loaded) do package.loaded[name] = value end
		local removed = require("adapters.shell_runner").run("rm -rf " .. quote(directory))
		assert(restored, "the exact delimiter catalogue is restored")
		assert(removed == true, "the owned private fixture is retired")
		if not ok then error(err, 0) end
	end
	local function read(path)
		local fh = assert(io.open(path, "rb"));local data = fh:read("*a");assert(fh:close());return data
	end
	local function section_fires(engine)
		engine:reset();engine:on_char("h");local result = engine:on_char("q")
		return result ~= nil and result.replacement == "section-result"
	end
	for _, outcome in ipairs({ "false", "nil", "number", "throw" }) do
		helpers.it("reports a real bound canonical section publication refusal " .. outcome .. " without repainting", function()
			with_real_section_owner(function(c)
				helpers.assert_true(section_fires(c.engine), "the original actual engine mapping fires")
				local action = section_action(c.config)
				local rename, publications = os.rename, 0
				os.rename = function(from, to)
					if from == c.path .. ".tmp" and to == c.path then
						publications = publications + 1
						if outcome == "throw" then error("inert owned publication refusal") end
						if outcome == "nil" then return nil, "inert owned publication refusal" end
						if outcome == "number" then return 2 end
						return false, "inert owned publication refusal"
					end
					return rename(from, to)
				end
				local called, result, notices, releases = observe_click(action)
				os.rename = rename
				helpers.assert_true(called)
				helpers.assert_eq(publications, 1, "the actual conditional writer attempted its owned staging publication")
				helpers.assert_eq(#notices, 1, "the actual refused publication is visible to the user")
				helpers.assert_eq(result, false)
				helpers.assert_eq(c.changed(), 0, "no success notification/repaint is published")
				helpers.assert_eq(read(c.path), c.original, "every independent source byte survives the refused write")
				helpers.assert_true(c.config.is_section_checked("rolls", "hc"))
				helpers.assert_true(section_fires(c.engine), "the actual engine is compensated after failed persistence")
				helpers.assert_eq(#notices, 1)
				helpers.assert_eq(releases, 1)
			end)
		end)
	end
	helpers.it("acknowledges the real bound section publication and refreshes only after durable success", function()
		with_real_section_owner(function(c)
			local called, result, notices, releases = observe_click(section_action(c.config))
			helpers.assert_true(called)
			helpers.assert_eq(result, true)
			helpers.assert_eq(c.changed(), 1)
			helpers.assert_true(c.config.refresh_choices(), "a real disk reload accepts the committed choice")
			helpers.assert_eq(c.changed(), 2, "the separate reload owns its own publication notification")
			helpers.assert_eq(c.config.is_section_checked("rolls", "hc"), false)
			helpers.assert_eq(section_fires(c.engine), false)
			local source = read(c.path)
			helpers.assert_true(source:find('label = "kept"', 1, true) ~= nil)
			helpers.assert_true(source:find('foreign = true', 1, true) ~= nil)
			helpers.assert_eq(#notices, 0)
			helpers.assert_eq(releases, 0)
		end)
	end)
end)

helpers.describe("extension category gates: one acknowledged batch", function()
	local function gate_action(config, enabled, changed)
		local mb = helpers.load_module("ui.menu.menu_builder")
		local label = require("infra.i18n").get(enabled and "menu.hotstrings.check_all" or "menu.hotstrings.uncheck_all")
		local extension = string.format(require("infra.i18n").get("menu.extensions.hotstrings_of"), "Ergopti")
		local found
		local function find(rows)
			for _, row in ipairs(rows or {}) do
				if row.title == extension then found = row end
				if type(row.menu) == "table" then find(row.menu) end
			end
		end
		find(mb.build({ config = config, _version = "9.9.9", on_menu_changed = changed }))
		assert(found, "the native owning extension submenu is present")
		for _, row in ipairs(found.menu or {}) do if row.title == label then return row.fn end end
		error("the native extension gate command was not rendered")
	end
	local function observe_click(action)
		local execute, modal = os.execute, require("ui.modal")
		local run, notices, releases = modal.run, {}, 0
		modal.run = function(callback) releases = releases + 1; return callback() end
		os.execute = function(command)
			if command:find("zenity", 1, true) then notices[#notices + 1] = command; return 0 end
			return execute(command)
		end
		local called, result = pcall(action)
		os.execute, modal.run = execute, run
		return called, result, notices, releases
	end
	local function with_real_gate_owner(initial, body)
		local directory = os.tmpname()
		assert(os.remove(directory))
		directory = directory .. "-ergopti-gate-batch"
		local quote = require("adapters.shell_runner").quote
		assert(require("adapters.shell_runner").run("mkdir -p " .. quote(directory)) == true)
		local path = directory .. "/config.toml"
		local state = initial and "true" or "false"
		local sections = '[hotstrings.modules.rolls]\nhc = true\nsx = false\n[hotstrings.modules.sfbsreduction]\ncomma = true\n[hotstrings.modules.foreign]\nfx = true\n'
		local foreign = '[future]\nlabel = "kept" # independent foreign comment\nnested = { flag = true, values = ["a", "b"] }\n'
		local original = '# independently written future preferences\n[hotstrings]\ngroups = { rolls = '
			.. state .. ', sfbsreduction = ' .. state .. ', foreign = true }\n' .. sections .. foreign
		local fh = assert(io.open(path, "wb"));assert(fh:write(original));assert(fh:close())
		local loaded = {}
		for name, value in pairs(package.loaded) do loaded[name] = value end
		local Terminators = require("modules.hotstrings.terminator_settings")
		local catalogue = Terminators.snapshot()
		local ok, err = pcall(function()
			package.loaded["modules.hotstrings.hotstrings_config"] = nil
			package.loaded["modules.hotstrings.loader"] = nil
			local paths = {}
			for key, value in pairs(require("infra.paths")) do paths[key] = value end
			-- The private fixture has no external installed layout roots.
			paths.extension_roots = function() return {} end
			package.loaded["infra.paths"] = paths
			local loader = require("modules.hotstrings.loader")
			local native_find = loader.find_toml_files
			package.loaded["modules.hotstrings.loader"] = {
				find_toml_files = native_find, list_subdirs = function() return {} end,
				read_file = function() return nil end,
				load_catalogue = function()
					return { committed = true, errors = 0, categories = {
						rolls = { id = "rolls", path = directory .. "/rolls.toml", count = 1,
							description = { en = "Rolls", fr = "Roulements" },
							extension = { id = "ergopti", name = "Ergopti" },
							sections_order = { "hc", "sx" }, sections = { hc = { count = 1 }, sx = { count = 0 } } },
						sfbsreduction = { id = "sfbsreduction", path = directory .. "/sfbs.toml", count = 1,
							description = { en = "SFB", fr = "SFB" }, extension = { id = "ergopti", name = "Ergopti" },
							sections_order = { "comma" }, sections = { comma = { count = 1 } } },
						foreign = { id = "foreign", path = directory .. "/foreign.toml", count = 1,
							description = { en = "Foreign", fr = "Foreign" },
							sections_order = { "fx" }, sections = { fx = { count = 1 } } },
					}, mappings = {
						{ trigger = "hq", replacement = "section-result", group = "rolls", section = "hc", auto_expand = true },
						{ trigger = "qw", replacement = "sfbs-result", group = "sfbsreduction", section = "comma", auto_expand = true },
						{ trigger = "xy", replacement = "foreign-result", group = "foreign", section = "fx", auto_expand = true },
					} }
				end,
			}
			local config, engine = require("modules.hotstrings.hotstrings_config"), require("hotstring_engine").new()
			local changed = 0
			assert(config._set_config_file_for_test(path))
			assert(config.init(engine, directory, function() changed = changed + 1 end))
			local _, loaded = config.load_all();assert(loaded)
			body({ config = config, engine = engine, path = path, original = original,
				changed = function() return changed end, sections = sections, foreign = foreign })
		end)
		local restored = Terminators.restore_configuration(catalogue)
		for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
		for name, value in pairs(loaded) do package.loaded[name] = value end
		local removed = require("adapters.shell_runner").run("rm -rf " .. quote(directory))
		assert(restored, "the exact delimiter catalogue is restored")
		assert(removed == true, "the owned private fixture is retired")
		if not ok then error(err, 0) end
	end
	local function read(path)
		local fh = assert(io.open(path, "rb"));local data = fh:read("*a");assert(fh:close());return data
	end
	local function fires(engine, trigger, replacement)
		engine:reset();engine:on_char(trigger:sub(1, 1));local result = engine:on_char(trigger:sub(2, 2))
		return result ~= nil and result.replacement == replacement
	end

	for _, outcome in ipairs({ "true", "false", "nil", "number", "text", "throw", "missing" }) do
		helpers.it("requires the exact extension gate batch receipt " .. outcome, function()
			local config = fake_config({})
			local asked, toggles, redraws = {}, 0, 0
			config.toggle_group = function() toggles = toggles + 1; return true end
			if outcome ~= "missing" then config.set_extension_sections_enabled = function(ids, bound, enabled)
				helpers.assert_eq(bound, {}, "the gate-only fixture has no bound sections")
				asked[#asked + 1] = { ids = ids, enabled = enabled }
				if outcome == "throw" then error("inert batch owner refusal") end
				if outcome == "nil" then return nil end
				if outcome == "number" then return 2 end
				if outcome == "text" then return "true" end
				return outcome == "true"
			end end
			local called, result, notices, released = observe_click(gate_action(config, false, function() redraws = redraws + 1 end))
			helpers.assert_true(called)
			helpers.assert_eq(toggles, 0, "the native command never commits one pack at a time")
			helpers.assert_eq(asked, outcome == "missing" and {} or { { ids = { "rolls" }, enabled = false } })
			helpers.assert_eq(#notices, outcome == "true" and 0 or 1)
			helpers.assert_eq(result, outcome == "true")
			helpers.assert_eq(redraws, outcome == "true" and 1 or 0)
			helpers.assert_eq(released, #notices)
		end)
	end
	for _, enabled in ipairs({ true, false }) do
		helpers.it("publishes both extension gates once with no partial second-failure state " .. tostring(enabled), function()
			with_real_gate_owner(not enabled, function(c)
				local rename, attempts, redraws = os.rename, 0, 0
				os.rename = function(from, to)
					if from == c.path .. ".tmp" and to == c.path then
						attempts = attempts + 1
						if attempts == 2 then return false, "inert second publication refusal" end
					end
					return rename(from, to)
				end
				local called, result, notices = observe_click(gate_action(c.config, enabled, function() redraws = redraws + 1 end))
				os.rename = rename
				helpers.assert_true(called)
				helpers.assert_eq(c.config.is_group_enabled("rolls"), enabled, "both captured categories must commit together; writes=" .. attempts .. ", rolls=" .. tostring(c.config.is_group_enabled("rolls")) .. ", sfbs=" .. tostring(c.config.is_group_enabled("sfbsreduction")))
				helpers.assert_eq(c.config.is_group_enabled("sfbsreduction"), enabled, "a refused second write cannot leave a mixed extension state")
				helpers.assert_eq(fires(c.engine, "hq", "section-result"), enabled)
				helpers.assert_eq(fires(c.engine, "qw", "sfbs-result"), enabled)
				helpers.assert_eq(attempts, 1, "one actual canonical publication commits the whole extension")
				helpers.assert_eq(result, true)
				helpers.assert_eq(c.changed(), 1)
				helpers.assert_eq(redraws, 1)
				helpers.assert_eq(#notices, 0)
				local source = read(c.path)
				helpers.assert_true(source:find(c.sections, 1, true) ~= nil, "every individual section choice remains byte-identical")
				helpers.assert_true(source:find(c.foreign, 1, true) ~= nil, "independent future records, comments and nested values survive")
				helpers.assert_true(c.config.is_group_enabled("foreign"))
				helpers.assert_true(fires(c.engine, "xy", "foreign-result"))
				helpers.assert_true(c.config.refresh_choices(), "the real owner reloads both gates from the committed file")
				helpers.assert_eq(c.config.is_group_enabled("rolls"), enabled)
				helpers.assert_eq(c.config.is_group_enabled("sfbsreduction"), enabled)
				helpers.assert_eq(c.config.is_section_checked("rolls", "sx"), false)
			end)
		end)
		for _, outcome in ipairs({ "false", "nil", "number", "throw" }) do
			helpers.it("compensates the actual extension gate batch refusal " .. outcome .. " " .. tostring(enabled), function()
				with_real_gate_owner(not enabled, function(c)
					local rename, attempts, redraws = os.rename, 0, 0
					os.rename = function(from, to)
						if from == c.path .. ".tmp" and to == c.path then
							attempts = attempts + 1
							if outcome == "throw" then error("inert batch publication refusal") end
							if outcome == "nil" then return nil, "inert batch publication refusal" end
							if outcome == "number" then return 2 end
							return false, "inert batch publication refusal"
						end
						return rename(from, to)
					end
					local called, result, notices, released = observe_click(gate_action(c.config, enabled, function() redraws = redraws + 1 end))
					os.rename = rename
					helpers.assert_true(called)
					helpers.assert_eq(attempts, 1)
					helpers.assert_eq(read(c.path), c.original, "the entire original source survives refused atomic publication")
					helpers.assert_eq(c.config.is_group_enabled("rolls"), not enabled)
					helpers.assert_eq(c.config.is_group_enabled("sfbsreduction"), not enabled)
					helpers.assert_eq(fires(c.engine, "hq", "section-result"), not enabled)
					helpers.assert_eq(fires(c.engine, "qw", "sfbs-result"), not enabled)
					helpers.assert_true(fires(c.engine, "xy", "foreign-result"))
					helpers.assert_eq(c.changed(), 0)
					helpers.assert_eq(redraws, 0, "refusal cannot publish an optimistic repaint")
					helpers.assert_eq(#notices, 1)
					helpers.assert_eq(released, 1)
					helpers.assert_eq(result, false)
				end)
			end)
		end
	end
	for _, request in ipairs({
		{ name = "unknown", targets = { "rolls", "absent" }, enabled = true },
		{ name = "duplicate", targets = { "rolls", "rolls" }, enabled = true },
		{ name = "sparse", targets = { [2] = "rolls" }, enabled = true },
		{ name = "empty", targets = {}, enabled = true },
		{ name = "nonboolean", targets = { "rolls" }, enabled = 2 },
	}) do
		helpers.it("refuses an invalid actual gate scope before effects " .. request.name, function()
			with_real_gate_owner(true, function(c)
				local result = c.config.set_category_gates_enabled(request.targets, request.enabled)
				helpers.assert_eq(result, false)
				helpers.assert_eq(c.changed(), 0)
				helpers.assert_eq(read(c.path), c.original)
				helpers.assert_true(fires(c.engine, "hq", "section-result"))
				helpers.assert_true(fires(c.engine, "qw", "sfbs-result"))
			end)
		end)
	end
	helpers.it("keeps a real pending configuration scope as the only mutation owner", function()
		with_real_gate_owner(true, function(c)
			local owner = {}
			helpers.assert_true(c.config.acquire(owner))
			local redraws = 0
			local called, result, notices = observe_click(gate_action(c.config, false, function() redraws = redraws + 1 end))
			local released = c.config.release(owner)
			helpers.assert_true(released)
			helpers.assert_true(called)
			helpers.assert_eq(result, false)
			helpers.assert_eq(redraws, 0)
			helpers.assert_eq(c.changed(), 0)
			helpers.assert_eq(read(c.path), c.original)
			helpers.assert_true(fires(c.engine, "hq", "section-result"))
			helpers.assert_true(fires(c.engine, "qw", "sfbs-result"))
			helpers.assert_eq(#notices, 1)
		end)
	end)

end)

helpers.describe("hotstring delay rows: durable owner acknowledgement", function()
	local function delay_action(config, kind, changed)
		local builder = helpers.load_module("ui.menu.menu_builder")
		local ctx = { config = config, _version = "9.9.9", paused = false, on_menu_changed = changed }
		local key = kind == "global" and "menu.hotstrings.tooltip_default" or "menu.hotstrings.delay_magic_key"
		local title = require("infra.i18n").get(key) .. " : "
		local found
		local function find(rows)
			for _, row in ipairs(rows or {}) do
				if type(row.title) == "string" and row.title:sub(1, #title) == title then found = row.fn end
				if row.menu then find(row.menu) end
			end
		end
		find(builder.build(ctx))
		assert(type(found) == "function", "the actual translated delay provider row is present")
		return found
	end
	local function observe(action, answer, before_return)
		local prompt, modal = require("ui.text_prompt"), require("ui.modal")
		local ask, run, execute = prompt.ask, modal.run, os.execute
		local asks, notices, releases = {}, {}, 0
		prompt.ask = function(...)
			asks[#asks + 1] = { ... }
			if before_return then before_return() end
			return answer
		end
		modal.run = function(callback) releases = releases + 1;return callback() end
		os.execute = function(command)
			if command:find("zenity", 1, true) then notices[#notices + 1] = command;return 0 end
			return execute(command)
		end
		local called, result = pcall(action)
		prompt.ask, modal.run, os.execute = ask, run, execute
		assert(prompt.ask == ask and modal.run == run and os.execute == execute, "every held modal transport is restored before assertions")
		return called, result, asks, notices, releases
	end
	local function receipt_config(kind, outcome)
		local calls = {}
		local function setter(...)
			calls[#calls + 1] = { n = select("#", ...), ... }
			if outcome == "throw" then error("inert durable delay refusal") end
			if outcome == "nil" then return nil end
			if outcome == "number" then return 2 end
			if outcome == "text" then return "true" end
			return outcome == "true"
		end
		local config = fake_config({})
		config.get_global_delay = function() return 0.4 end
		config.resolve = function() return { delay = 0.3 } end
		if outcome ~= "missing" then
			if kind == "global" then config.set_global_delay = setter else config.set_override = setter end
		end
		return config, calls
	end
	for _, kind in ipairs({ "global", "category" }) do
		for _, outcome in ipairs({ "true", "false", "nil", "number", "text", "throw", "missing" }) do
			helpers.it(kind .. " delay contains exact native setter receipt " .. outcome, function()
				local config, calls = receipt_config(kind, outcome)
				local changed = 0
				local called, result, asks, notices, releases = observe(delay_action(config, kind,
					function() changed = changed + 1 end), "900")
				helpers.assert_true(called, "the actual provider contains a native setter refusal")
				helpers.assert_eq(result, outcome == "true", "only the durable boolean true acknowledges the click")
				helpers.assert_eq(changed, outcome == "true" and 1 or 0, "refusal cannot repaint a success")
				helpers.assert_eq(#asks, 1)
				helpers.assert_eq(asks[1][3], kind == "global" and "400" or "300", "the existing milliseconds prompt remains intact")
				helpers.assert_eq(#calls, outcome == "missing" and 0 or 1)
				if #calls > 0 then
					helpers.assert_eq(calls[1].n, kind == "global" and 1 or 4)
					helpers.assert_eq(calls[1][kind == "global" and 1 or 4], 0.9)
					if kind == "category" then
						helpers.assert_eq(calls[1][1], "magickey");helpers.assert_eq(calls[1][2], nil);helpers.assert_eq(calls[1][3], "delay")
					end
				end
				helpers.assert_eq(#notices, outcome == "true" and 0 or 1)
				helpers.assert_eq(releases, #notices)
				if #notices > 0 then
					helpers.assert_true(notices[1]:find(require("adapters.shell_runner").quote(
						require("infra.i18n").get("dialog.bulk_toggle.save_failed")), 1, true) ~= nil)
				end
			end)
		end
		for _, raw in ipairs({ "cancel", "-1", "1.5", "not a delay" }) do
			helpers.it(kind .. " delay preserves cancellation and invalid input " .. raw, function()
				local config, calls = receipt_config(kind, "true")
				local changed = 0
				local answer = raw
				if raw == "cancel" then answer = nil end
				local called, result, asks, notices = observe(delay_action(config, kind,
					function() changed = changed + 1 end), answer)
				helpers.assert_true(called);helpers.assert_eq(result, nil)
				helpers.assert_eq(#calls, 0);helpers.assert_eq(changed, 0);helpers.assert_eq(#asks, 1)
				helpers.assert_eq(#notices, raw == "cancel" and 0 or 1)
			end)
		end
	end

	local function read(path)
		local file = assert(io.open(path, "rb"));local content = file:read("*a");assert(file:close());return content
	end
	local function write(path, content)
		local file = assert(io.open(path, "wb"));assert(file:write(content));assert(file:close())
	end
	local function with_native_owner(body)
		local directory = os.tmpname();assert(os.remove(directory));directory = directory .. "-ergopti-delay-ack"
		local quote = require("adapters.shell_runner").quote
		assert(require("adapters.shell_runner").run("mkdir -p " .. quote(directory)) == true)
		local path, config_path = directory .. "/hotstrings_overrides.toml", directory .. "/config.toml"
		local foreign = '[future]\nlabel = "independent" # unrelated future comment\nnested = { values = [2, 7], on = true }\n'
		local original = '# hand-written delay preferences\n[_global]\ndelay = 0.4\n[magickey]\ndelay = 0.3\n' .. foreign
		write(path, original);write(config_path, '[future]\nuser = "kept"\n')
		local loaded = {};for name, value in pairs(package.loaded) do loaded[name] = value end
		local called, err = pcall(function()
			package.loaded["modules.hotstrings.hotstrings_config"] = nil
			local config = require("modules.hotstrings.hotstrings_config")
			assert(config._set_config_file_for_test(config_path))
			assert(config._set_override_config_dir_for_test(directory))
			assert(config.init(require("hotstring_engine").new(), directory))
			config._set_categories_for_test({ magickey = { delay = 0.3 } })
			body({ config = config, path = path, config_path = config_path, original = original, foreign = foreign })
		end)
		for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
		for name, value in pairs(loaded) do package.loaded[name] = value end
		local removed = require("adapters.shell_runner").run("rm -rf " .. quote(directory))
		assert(removed == true, "only the owned private directory is retired")
		if not called then error(err, 0) end
	end
	for _, kind in ipairs({ "global", "category" }) do
		for _, outcome in ipairs({ "false", "nil", "number", "throw" }) do
			helpers.it(kind .. " delay actual override refusal preserves source and permits an acknowledged retry " .. outcome, function()
				with_native_owner(function(c)
					local changed = 0
					local action = delay_action(c.config, kind, function() changed = changed + 1 end)
					local rename, writes = os.rename, 0
					os.rename = function(from, to)
						if from == c.path .. ".tmp" and to == c.path then
							writes = writes + 1
							if outcome == "throw" then error("inert owned delay publication refusal") end
							if outcome == "nil" then return nil, "inert refusal" end
							if outcome == "number" then return 2 end
							return false, "inert refusal"
						end
						return rename(from, to)
					end
					local called, result, asks, notices, releases = observe(action, "900")
					os.rename = rename
					print(string.format("DELAY_REFUSAL kind=%s outcome=%s called=%s result=%s refresh=%d writes=%d source_same=%s",
						kind, outcome, tostring(called), tostring(result), changed, writes, tostring(read(c.path) == c.original)))
					helpers.assert_eq(changed, 0, "a refused actual override publication cannot refresh the menu")
					helpers.assert_true(called);helpers.assert_eq(result, false)
					helpers.assert_eq(writes, 1, "the actual leaf writer attempted precisely its owned publication")
					helpers.assert_eq(changed, 0);helpers.assert_eq(read(c.path), c.original)
					helpers.assert_eq(c.config.get_global_delay(), 0.4);helpers.assert_eq(c.config.resolve("magickey", nil).delay, 0.3)
					helpers.assert_eq(#asks, 1);helpers.assert_eq(#notices, 1);helpers.assert_eq(releases, 1)
					local retry, committed, _, retry_notices = observe(action, "900")
					helpers.assert_true(retry);helpers.assert_eq(committed, true);helpers.assert_eq(changed, 1);helpers.assert_eq(#retry_notices, 0)
					local disk = read(c.path)
					helpers.assert_true(disk:find(c.foreign, 1, true) ~= nil, "unknown nested data and comments retain their exact bytes")
					helpers.assert_eq(read(c.config_path), '[future]\nuser = "kept"\n', "the unrelated canonical config was never written")
					local decoded = require("toml_codec").decode(disk)
					helpers.assert_eq(decoded[kind == "global" and "_global" or "magickey"].delay, 0.9)
					assert(c.config.init(require("hotstring_engine").new(), c.path:match("^(.*)/")))
					helpers.assert_eq(kind == "global" and c.config.get_global_delay() or c.config.resolve("magickey", nil).delay, 0.9,
						"a real disk reload agrees with the acknowledged value")
				end)
			end)
		end
		helpers.it(kind .. " delay refuses a foreign source written while the prompt is held", function()
			with_native_owner(function(c)
				local changed = 0
				local action = delay_action(c.config, kind, function() changed = changed + 1 end)
				local foreign = c.original .. '# another owner changed the physical source\n'
				local called, result, _, notices = observe(action, "900", function() write(c.path, foreign) end)
				helpers.assert_true(called);helpers.assert_eq(result, false);helpers.assert_eq(changed, 0)
				helpers.assert_eq(read(c.path), foreign, "the captured canonical override source refuses a stale write")
				helpers.assert_eq(c.config.get_global_delay(), 0.4);helpers.assert_eq(c.config.resolve("magickey", nil).delay, 0.3)
				helpers.assert_eq(#notices, 1)
			end)
		end)
	end
end)


helpers.describe("category fixture process status: actual normalized owner", function()
	for _, abi in ipairs({ "numeric", "compat52" }) do
		helpers.it("keeps real directory/write/cleanup acknowledgement under " .. abi, function()
			local previous = package.loaded["adapters.shell_runner"]
			local shell = helpers.load_module("adapters.shell_runner")
			local execute = os.execute
			local directory = os.tmpname();assert(os.remove(directory));directory = directory .. "-section-abi"
			local seen = { calls = 0 }
			os.execute = function(command)
				seen.calls = seen.calls + 1
				local code, kind, status = execute(command)
				if code == 0 or (code == true and kind == "exit" and status == 0) then
					if abi == "numeric" then return 0 end
					return true, "exit", 0
				end
				return code, kind, status
			end
			local called, issue = pcall(function()
				seen.mkdir = shell.run("mkdir -p " .. shell.quote(directory))
				local file = assert(io.open(directory .. "/physical", "wb"))
				assert(file:write("independent physical bytes"));assert(file:close())
				file = assert(io.open(directory .. "/physical", "rb"))
				seen.bytes = file:read("*a");assert(file:close())
				seen.failed_process = shell.run("sh -c 'exit 1'")
				seen.cleanup = shell.run("rm -rf " .. shell.quote(directory))
				seen.absent = io.open(directory .. "/physical", "rb") == nil
			end)
			os.execute = execute
			package.loaded["adapters.shell_runner"] = previous
			-- Cleanup is physical even if an earlier candidate acknowledgement refused.
			if not seen.absent then shell.run("rm -rf " .. shell.quote(directory)) end
			helpers.assert_true(called, issue)
			helpers.assert_eq(seen.calls, 3, "the real process boundary, not a retained _test_runner, owns every command")
			helpers.assert_eq(seen.mkdir, true)
			helpers.assert_eq(seen.bytes, "independent physical bytes")
			helpers.assert_eq(seen.failed_process, false)
			helpers.assert_eq(seen.cleanup, true)
			helpers.assert_eq(seen.absent, true)
		end)
	end
	for _, outcome in ipairs({ "false", "nil", "number", "text", "throw" }) do
		helpers.it("does not acknowledge the real failed process with receipt " .. outcome, function()
			local previous = package.loaded["adapters.shell_runner"]
			local shell = helpers.load_module("adapters.shell_runner")
			local execute, seen = os.execute, {}
			os.execute = function(command)
				seen.calls = (seen.calls or 0) + 1
				seen.native = { execute(command) }
				if outcome == "nil" then return nil, "exit", 1 end
				if outcome == "number" then return 2 end
				if outcome == "text" then return "true" end
				if outcome == "throw" then error("inert process receipt refusal") end
				return false, "exit", 1
			end
			local called, result = pcall(shell.run, "sh -c 'exit 1'")
			os.execute = execute
			package.loaded["adapters.shell_runner"] = previous
			helpers.assert_true(called)
			helpers.assert_eq(seen.calls, 1, "the refusal still executed the actual independent failed child")
			helpers.assert_true(seen.native[1] ~= 0 and seen.native[1] ~= true)
			helpers.assert_eq(result, false)
		end)
	end
end)
