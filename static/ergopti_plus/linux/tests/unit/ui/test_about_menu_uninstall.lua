--- tests/unit/ui/test_about_menu_uninstall.lua

--- ==============================================================================
--- MODULE: Uninstall Closes The Version / Updates Submenu (Linux tray)
--- DESCRIPTION:
--- « Désinstaller Ergopti » sat at the bottom of Configuration, between the
--- rows that tune the configuration, where removing the application read as
--- one more setting. It now closes the Version / Updates submenu, set apart by
--- a separator, next to the build it removes; it keeps its label key and runs
--- the same transaction (ui/menu/uninstall.lua), which quits the daemon through
--- ctx.on_quit. Startup sits immediately above it, outside Configuration.
--- Built through the real tray builder and renderer.
---
--- On a local version run from source there is nothing to remove: the row
--- stays in place, greyed like every row greyed with a reason, « Désinstaller
--- Ergopti… — Version locale (depuis les sources) » (the head of the
--- manifest's disabled_reason_key), with nothing to run, and a click that
--- still reaches the action does nothing.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The head of a translated reason, cut as the renderers cut it: the text
--- before its first colon, ASCII or full-width.
local function reason_head(text)
	local cut = nil
	for _, mark in ipairs({ ":", "\239\188\154" }) do
		local at = text:find(mark, 1, true)
		if at and (cut == nil or at < cut) then cut = at end
	end
	return ((cut and text:sub(1, cut - 1) or text):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- The submenu of the top-level row whose title is the translation of `key`.
local function submenu_of(items, key)
	local label = require("infra.i18n").get(key)
	for _, item in ipairs(items) do
		if item.title == label then return item.menu end
	end
	return nil
end

--- Builds the tray with the uninstall transaction replaced by a recorder.
--- @param quits table Counts ctx.on_quit calls.
--- @param source_run boolean|nil What the installed-build owner answers (false by default).
--- @return table items, table runs, function restore
local function build(quits, source_run, startup, paused)
	local runs = {}
	startup = startup or { enabled = false, toggles = 0, changes = 0 }
	local previous_startup = package.loaded["ui.menu.start_at_login"]
	package.loaded["ui.menu.start_at_login"] = {
		enabled = function() return startup.enabled end,
		toggle = function()
			startup.toggles = startup.toggles + 1
			startup.enabled = not startup.enabled
			return true
		end,
	}
	local previous = package.loaded["ui.menu.uninstall"]
	package.loaded["ui.menu.uninstall"] = { run = function(opts) runs[#runs + 1] = opts end }
	-- The suite runs from a checkout, which is a source run: each case says.
	local Installation = require("infra.installation")
	local real_is_source_run = Installation.is_source_run
	Installation.is_source_run = function() return source_run == true end
	local function restore()
		package.loaded["ui.menu.uninstall"] = previous
		package.loaded["ui.menu.start_at_login"] = previous_startup
		Installation.is_source_run = real_is_source_run
	end
	local mb = helpers.load_module("ui.menu.menu_builder")
	local ctx = {
		_version = "9.9.9",
		paused = paused == true,
		on_quit = function() quits.count = quits.count + 1 end,
		on_menu_changed = function() startup.changes = startup.changes + 1 end,
	}
	local ok, items = pcall(mb.build, ctx)
	if not ok then
		restore()
		error(items, 0)
	end
	return items, runs, restore, function() return mb.build(ctx) end
end

helpers.describe("tray (linux): Uninstall closes the Version / Updates submenu", function()
	helpers.it("is the last About row, after a separator, and runs the uninstall transaction", function()
		local quits = { count = 0 }
		local items, runs, restore = build(quits)
		local ok, err = pcall(function()
			local i18n = require("infra.i18n")
			local rows = submenu_of(items, "menu.about.title")
			helpers.assert_true(type(rows) == "table" and #rows >= 3, "the tray must carry the About submenu")
			local last = rows[#rows]
			helpers.assert_eq(last.title, i18n.get("menu.global.uninstall"), "Uninstall closes the submenu")
			helpers.assert_eq(rows[#rows - 1].title, i18n.get("menu.global.start_at_login"), "startup immediately precedes Uninstall")
			helpers.assert_eq(rows[#rows - 2].title, "-", "a separator sets the installation group apart")
			helpers.assert_true(last.disabled ~= true, "Uninstall stays live")
			local fn = last.fn or last.action
			helpers.assert_eq(type(fn), "function", "Uninstall carries its handler")
			helpers.assert_eq(#runs, 0, "building the menu must not start the transaction")
			fn()
			helpers.assert_eq(#runs, 1, "the row starts the uninstall transaction once")
			helpers.assert_eq(runs[1].title, i18n.get("menu.global.uninstall"), "under its own label")
			helpers.assert_eq(type(runs[1].confirm), "function", "the transaction asks before removing")
			runs[1].quit()
			helpers.assert_eq(quits.count, 1, "the transaction quits through the daemon's own quit")
		end)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("is greyed on a source run, naming why, at the same place", function()
		local items, _, restore = build({ count = 0 }, true)
		local ok, err = pcall(function()
			local i18n = require("infra.i18n")
			local rows = submenu_of(items, "menu.about.title")
			helpers.assert_true(type(rows) == "table" and #rows >= 3, "the tray must carry the About submenu")
			local last = rows[#rows]
			local head = reason_head(i18n.get("menu.about.source_run_reason"))
			helpers.assert_true(head ~= "" and head ~= "menu.about.source_run_reason", "the reason is translated")
			helpers.assert_eq(last.title, i18n.get("menu.global.uninstall") .. " — " .. head,
				"the row names why in the menu itself, as every greyed row with a reason")
			helpers.assert_eq(last.disabled, true, "a source run greys Uninstall")
			helpers.assert_true(last.fn == nil, "with nothing to run")
			helpers.assert_eq(rows[#rows - 1].title, i18n.get("menu.global.start_at_login"), "at the same place, below startup")
		end)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("does nothing when a click reaches the action on a source run", function()
		local Uninstall = helpers.load_module("ui.menu.uninstall")
		local calls = { commands = 0, failures = 0, quits = 0 }
		local launched = Uninstall.run({
			root = "/checkout/static/ergopti_plus/linux",
			version_source = "local",
			title = "t", confirmation = "c", failure = "f",
			run = function() calls.commands = calls.commands + 1; return true end,
			confirm = function() return true end,
			fail = function() calls.failures = calls.failures + 1 end,
			quit = function() calls.quits = calls.quits + 1 end,
		})
		helpers.assert_eq(launched, false)
		helpers.assert_eq(calls.commands, 0, "no removal command")
		helpers.assert_eq(calls.failures, 0, "no failure dialog")
		helpers.assert_eq(calls.quits, 0, "the daemon keeps running")
	end)

	helpers.it("is drawn once in the whole tray, never in Configuration", function()
		local items, _, restore = build({ count = 0 })
		local ok, err = pcall(function()
			local i18n = require("infra.i18n")
			local label = i18n.get("menu.global.uninstall")
			local rows = submenu_of(items, "menu.configuration.title")
			helpers.assert_true(type(rows) == "table", "the tray must carry the Configuration submenu")
			for _, row in ipairs(rows) do
				helpers.assert_true(row.title ~= label, "Configuration no longer offers Uninstall")
				helpers.assert_true(row.title ~= i18n.get("menu.global.start_at_login"), "Configuration no longer offers startup")
			end
			helpers.assert_true(rows[#rows].title ~= "-", "Configuration ends on a row, not a separator")
			local found = 0
			for _, item in ipairs(items) do
				for _, row in ipairs(type(item.menu) == "table" and item.menu or {}) do
					if row.title == label then found = found + 1 end
				end
			end
			helpers.assert_eq(found, 1, "Uninstall is drawn once in the tray")
		end)
		restore()
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("tray (linux): startup keeps its native owner", function()
	for _, paused in ipairs({ false, true }) do
		for _, enabled in ipairs({ false, true }) do
			helpers.it("reads and toggles startup without resuming keyboard features (paused=" .. tostring(paused)
				.. ", enabled=" .. tostring(enabled) .. ")", function()
				local state = { enabled = enabled, toggles = 0, changes = 0 }
				local items, _, restore, rebuild = build({ count = 0 }, false, state, paused)
				local ok, err = pcall(function()
					local i18n = require("infra.i18n")
					local rows = submenu_of(items, "menu.about.title")
					helpers.assert_true(type(rows) == "table" and #rows >= 3, "the About submenu must be drawn")
					local startup = rows[#rows - 1]
					helpers.assert_eq(startup.title, i18n.get("menu.global.start_at_login"))
					helpers.assert_eq(startup.checked, enabled, "the native owner supplies its state")
					helpers.assert_true(startup.disabled ~= true, "keyboard pause leaves startup available")
					helpers.assert_eq(state.toggles, 0, "building the menu never changes startup")
					helpers.assert_eq(type(startup.fn), "function", "the row retains its startup callback")
					startup.fn()
					helpers.assert_eq(state.toggles, 1, "one click invokes the native owner once")
					helpers.assert_eq(state.changes, 1, "the native owner's result refreshes the tray")
					local updated = submenu_of(rebuild(), "menu.about.title")
					helpers.assert_eq(updated[#updated - 1].checked, not enabled, "a rebuild reads the acknowledged state")
				end)
				restore()
				if not ok then error(err, 0) end
			end)
		end
	end
end)


--- The genuine About producer owns its actual finished child and shared parent.
local function about_parent_corpus()
	local file = assert(io.open(helpers.driver_root() .. "/../_shared/tests/corpus/menus/linux_about_parent.json", "rb"))
	local result = assert(require("json").decode(assert(file:read("*a"))))
	assert(file:close())
	return result
end

--- Uses actual physical locale bytes and the actual registered menu/renderer owner.
--- Native version, startup and transaction boundaries record effects only.
local function with_about_parent(code, options, body)
	options = options or {}
	local names = { "ui.menu.menu_builder", "infra.manifest_menu", "infra.i18n", "infra.version",
		"infra.installation", "ui.menu.start_at_login", "ui.menu.uninstall" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	local ok, detail = xpcall(function()
		local file = assert(io.open(helpers.driver_root() .. "/../_shared/data/locales/" .. code .. ".json", "rb"))
		local labels = assert(require("json").decode(assert(file:read("*a"))))
		assert(file:close())
		package.loaded["infra.i18n"] = {
			get = function(key) return labels[key] or key end,
			section = function(key) return labels[key] or key end,
		}
		local renderer = require("infra.manifest_menu")
		local root, parent, quit = renderer.get_root()
		for _, row in ipairs(root.top_level) do
			if row.id == "about" then helpers.assert_nil(parent); parent = row end
			if row.id == "quit" and type(row.platforms) == "table" then
				for _, platform in ipairs(row.platforms) do if platform == "linux" then quit = row end end
			end
		end
		helpers.assert_type(parent, "table", "the actual canonical About owner exists")
		helpers.assert_type(quit, "table", "the actual native Quit owner exists")
		root.top_level = { parent, quit }
		local state = { versions = 0, startup_reads = 0, toggles = 0, changed = 0,
			quits = 0, pages = {}, removals = {}, enabled = true }
		package.loaded["infra.version"] = { VERSION = "local", LOCAL = "local", identity = function()
			state.versions = state.versions + 1
			if options.reenter then options.reenter(root, parent, state) end
			return { kind = "release", version = "9.9.9", commit = "frozen123" }
		end }
		package.loaded["infra.installation"] = { is_source_run = function() return options.source_run == true end }
		package.loaded["ui.menu.start_at_login"] = {
			enabled = function() state.startup_reads = state.startup_reads + 1; return state.enabled end,
			toggle = function() state.toggles = state.toggles + 1; state.enabled = not state.enabled; return true end,
		}
		package.loaded["ui.menu.uninstall"] = { run = function(opts)
			state.removals[#state.removals + 1] = opts
			return "native removal result"
		end }
		local actual_build = renderer.build
		renderer.build = function(...)
			local rows = actual_build(...)
			if select(1, ...) == "about_menu" then state.finished_child = rows end
			return rows
		end
		local builder = require("ui.menu.menu_builder")
		local ctx = { _version = "9.9.9", paused = options.paused == true,
			on_quit = function() state.quits = state.quits + 1; return "native quit result" end,
			on_menu_changed = function() state.changed = state.changed + 1; return "native redraw result" end,
			webview = { show = function(page) state.pages[#state.pages + 1] = page; return "native page result" end },
		}
		if options.before then options.before(root, parent, state) end
		local function rebuild() return builder.build(ctx) end
		body(rebuild(), state, labels, root, parent, rebuild)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(detail, 0) end
end

local function about_parent_at(items, title)
	for _, row in ipairs(items) do if row.title == title then return row end end
	return nil
end

helpers.describe("Linux actual About whole parent", function()
	for _, code in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja", "ko",
		"nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
		helpers.it("preserves independent parent captions and complete children " .. code .. " (linux-about-parent)", function()
			local hand = about_parent_corpus().locales[code]
			for _, paused in ipairs({ false, true }) do
				with_about_parent(code, { paused = paused }, function(items, state)
					local parent = about_parent_at(items, hand.about_parent)
					helpers.assert_type(parent, "table")
					helpers.assert_nil(parent.fn)
					helpers.assert_nil(parent.disabled, "About remains available while keyboard features are paused")
					helpers.assert_nil(parent.checked)
					helpers.assert_eq(#parent.menu, 7, "complete prior About order without an updater")
					helpers.assert_eq(parent.menu[2].title, "-")
					helpers.assert_eq(parent.menu[3].title, hand.changelog)
					helpers.assert_eq(parent.menu[4].title, hand.releases_page)
					helpers.assert_eq(parent.menu[5].title, "-")
					helpers.assert_eq(parent.menu[6].title, hand.startup)
					helpers.assert_eq(parent.menu[7].title, hand.uninstall)
					helpers.assert_eq(parent.menu[6].checked, true)
					helpers.assert_eq(state.toggles, 0)
					helpers.assert_eq(#state.pages, 0)
					helpers.assert_eq(#state.removals, 0)
					helpers.assert_eq(state.changed, 0)
					helpers.assert_eq(state.quits, 0)
				end)
			end
		end)
	end

	helpers.it("reads the actual parent caption instead of repeating the native key (linux-about-parent)", function()
		with_about_parent("fr", { before = function(_, parent) parent.i18n = "menu.configuration.title" end },
			function(items, _, labels)
				helpers.assert_type(about_parent_at(items, labels["menu.configuration.title"]), "table")
				helpers.assert_nil(about_parent_at(items, about_parent_corpus().locales.fr.about_parent))
			end)
	end)

	helpers.it("retains the genuine completed child by identity (linux-about-parent)", function()
		with_about_parent("en", nil, function(items, state)
			local parent = about_parent_at(items, about_parent_corpus().locales.en.about_parent)
			helpers.assert_true(rawequal(parent.menu, state.finished_child))
		end)
	end)

	for name, mutate in pairs({
		wrong_type = function(_, parent) parent.type = "command" end,
		forbidden_prefix = function(_, parent) parent.label_prefix = "native decoration" end,
		empty_caption = function(_, parent) parent.i18n = "" end,
		duplicate_parent = function(root, parent) table.insert(root.top_level, 1, parent) end,
		missing_children = function(root) root.about_menu = nil end,
		empty_children = function(root) root.about_menu = {} end,
	}) do
		helpers.it("refuses incomplete actual source " .. name .. " before native readers (linux-about-parent)", function()
			with_about_parent("en", { before = mutate }, function(items, state)
				helpers.assert_nil(about_parent_at(items, about_parent_corpus().locales.en.about_parent))
				helpers.assert_eq(state.versions, 0)
				helpers.assert_eq(state.startup_reads, 0)
				helpers.assert_eq(state.toggles, 0)
				helpers.assert_eq(#state.removals, 0)
			end)
		end)
	end

	helpers.it("honors actual native platform hiding (linux-about-parent)", function()
		with_about_parent("en", { before = function(_, parent)
			parent.platforms = { "hs" }; parent.unavailable = "hide"
		end }, function(items, state)
			helpers.assert_nil(about_parent_at(items, about_parent_corpus().locales.en.about_parent))
			helpers.assert_eq(state.versions, 0)
		end)
	end)

	for name, mutate in pairs({
		caption_changed = function(_, parent) parent.i18n = "menu.configuration.title" end,
		parent_replaced = function(root, parent)
			local replacement = {}; for key, value in pairs(parent) do replacement[key] = value end
			root.top_level[1] = replacement
		end,
		top_replaced = function(root) root.top_level = { root.top_level[1], root.top_level[2] } end,
		child_section_replaced = function(root)
			local replacement = {}; for index, row in ipairs(root.about_menu) do replacement[index] = row end
			root.about_menu = replacement
		end,
	}) do
		helpers.it("refuses source reentry " .. name .. " after real version data read (linux-about-parent)", function()
			with_about_parent("en", { reenter = mutate }, function(items, state, labels)
				helpers.assert_nil(about_parent_at(items, about_parent_corpus().locales.en.about_parent))
				helpers.assert_nil(about_parent_at(items, labels["menu.configuration.title"]))
				helpers.assert_eq(state.versions, 1)
				helpers.assert_eq(state.toggles, 0)
				helpers.assert_eq(#state.removals, 0)
			end)
		end)
	end

	helpers.it("preserves native startup and changelog callbacks and their original results (linux-about-parent)", function()
		with_about_parent("en", nil, function(items, state, _, _, _, rebuild)
			local hand = about_parent_corpus().locales.en
			local parent = assert(about_parent_at(items, hand.about_parent))
			helpers.assert_nil(parent.menu[3].fn())
			helpers.assert_eq(state.pages, { "changelog" })
			helpers.assert_nil(parent.menu[6].fn())
			helpers.assert_eq(state.toggles, 1)
			helpers.assert_eq(state.changed, 1)
			helpers.assert_eq(about_parent_at(rebuild(), hand.about_parent).menu[6].checked, false)
		end)
	end)

	helpers.it("preserves the genuine uninstall option and daemon quit callback (linux-about-parent)", function()
		with_about_parent("en", nil, function(items, state, labels)
			local row = assert(about_parent_at(items, about_parent_corpus().locales.en.about_parent)).menu[7]
			helpers.assert_nil(row.fn())
			helpers.assert_eq(#state.removals, 1)
			helpers.assert_eq(state.removals[1].title, labels["menu.global.uninstall"])
			helpers.assert_type(state.removals[1].confirm, "function")
			helpers.assert_type(state.removals[1].fail, "function")
			helpers.assert_nil(state.removals[1].quit())
			helpers.assert_eq(state.quits, 1)
		end)
	end)

	helpers.it("preserves source-run uninstall refusal without native effects (linux-about-parent)", function()
		with_about_parent("en", { source_run = true }, function(items, state)
			local row = assert(about_parent_at(items, about_parent_corpus().locales.en.about_parent)).menu[7]
			helpers.assert_eq(row.disabled, true)
			helpers.assert_nil(row.fn)
			helpers.assert_eq(#state.removals, 0)
			helpers.assert_eq(state.quits, 0)
		end)
	end)
end)
