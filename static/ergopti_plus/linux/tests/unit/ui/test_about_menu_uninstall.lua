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
local table_unpack = table.unpack or unpack
local function packed(...) return { n = select("#", ...), ... } end

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
		command_available = function() return true end,
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
		-- Install the actual observer before the production renderer captures its translator.
		if type(options.caption_get) == "function" then
			local get = package.loaded["infra.i18n"].get
			package.loaded["infra.i18n"].get = function(key) return options.caption_get(key, get) end
		end
		local renderer = require("infra.manifest_menu")
		local root, parent, quit, boundary = renderer.get_root()
		for _, row in ipairs(root.top_level) do
			if row.id == "about" then helpers.assert_nil(parent); parent = row end
			local applicable = row.platforms == nil
			for _, platform in ipairs(row.platforms or {}) do
				if platform == "linux" then applicable = true end
			end
			if row.id == "---" and applicable then boundary = row end
			if row.id == "quit" and type(row.platforms) == "table" then
				for _, platform in ipairs(row.platforms) do if platform == "linux" then quit = row; break end end
				if quit then break end
			end
		end
		helpers.assert_type(parent, "table", "the actual canonical About owner exists")
		helpers.assert_type(quit, "table", "the actual native Quit owner exists")
		helpers.assert_type(boundary, "table", "the actual declared boundary precedes native Quit")
		root.top_level = { parent, boundary, quit }
		local state = { versions = 0, startup_reads = 0, toggles = 0, changed = 0,
			quits = 0, pages = {}, removals = {}, enabled = true }
		package.loaded["infra.version"] = { VERSION = "local", LOCAL = "local", identity = function()
			state.versions = state.versions + 1
			if options.reenter then options.reenter(root, parent, state) end
			return { kind = "release", version = "9.9.9", commit = "frozen123" }
		end }
		package.loaded["infra.installation"] = { is_source_run = function() return options.source_run == true end }
		package.loaded["ui.menu.start_at_login"] = {
			command_available = function() return options.startup_available ~= false end,
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

helpers.describe("Linux About startup command ownership", function()
	helpers.it("keeps a foreign startup command greyed without mutation (about-startup-command-owner)", function()
		with_about_parent("en", { startup_available = false }, function(items, state, labels)
			local parent = about_parent_at(items, labels["menu.about.title"])
			helpers.assert_type(parent, "table")
			local startup = parent.menu[#parent.menu - 1]
			helpers.assert_eq(startup.disabled, true)
			helpers.assert_nil(startup.fn)
			helpers.assert_eq(startup.title, labels["menu.global.start_at_login"] .. " — "
				.. reason_head(labels["menu.about.startup_other_command_reason"]))
			helpers.assert_eq(state.toggles, 0)
			helpers.assert_eq(state.changed, 0)
			helpers.assert_eq(#state.removals, 0)
		end)
	end)
end)


--- Restores only a field on this fixture's private cached source/renderer owner.
--- The original assertion error remains the pending error after exact restoration.
local function with_uninstall_caption_field(owner, key, replacement, body)
	local previous = rawget(owner, key)
	rawset(owner, key, replacement)
	local outcome = packed(pcall(body))
	rawset(owner, key, previous)
	if not outcome[1] then error(outcome[2], 0) end
	return table_unpack(outcome, 2, outcome.n)
end

--- Selects the actual original command, never an invented duplicate fixture row.
local function actual_uninstall_caption_source(root)
	local selected
	for _, item in ipairs(root.about_menu) do
		if item.id == "uninstall" then
			helpers.assert_nil(selected, "the original uninstall command is unique")
			selected = item
		end
	end
	helpers.assert_type(selected, "table", "the actual uninstall command exists")
	return selected
end

helpers.describe("Linux uninstall receives its actual late shared command caption", function()
	for _, code in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja", "ko",
		"nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
		helpers.it("hands the independent original caption to removal " .. code .. " (uninstall-declared-caption)", function()
			with_about_parent(code, nil, function(items, state)
				local hand = about_parent_corpus().locales[code]
				local parent = assert(about_parent_at(items, hand.about_parent))
				helpers.assert_nil(parent.menu[7].fn(), "the original callback does not expose the worker result")
				helpers.assert_eq(#state.removals, 1)
				helpers.assert_eq(state.removals[1].title, hand.uninstall)
				helpers.assert_eq(#state.removals, 1, "one actual native transaction receives the title")
			end)
		end)
	end

	helpers.it("reads the actual declared key instead of the original driver literal (uninstall-declared-caption)", function()
		with_about_parent("en", { before = function(root)
			actual_uninstall_caption_source(root).i18n = "menu.global.quit"
		end }, function(items, state, labels)
			local parent = assert(about_parent_at(items, about_parent_corpus().locales.en.about_parent))
			helpers.assert_eq(parent.menu[7].title, labels["menu.global.quit"])
			helpers.assert_nil(parent.menu[7].fn())
			helpers.assert_eq(#state.removals, 1)
			helpers.assert_eq(state.removals[1].title, labels["menu.global.quit"],
				"the genuine shared declaration is the caption authority")
		end)
	end)

	helpers.it("reads translation at the original click boundary (uninstall-declared-caption)", function()
		with_about_parent("en", nil, function(items, state, labels)
			local parent = assert(about_parent_at(items, about_parent_corpus().locales.en.about_parent))
			with_uninstall_caption_field(labels, "menu.global.uninstall", labels["menu.global.quit"], function()
				helpers.assert_nil(parent.menu[7].fn())
				helpers.assert_eq(state.removals[1].title, labels["menu.global.quit"])
			end)
		end)
	end)

	for _, mutation in ipairs({
		{ name = "withdrawn identity", key = "id", value = "retired_uninstall" },
		{ name = "wrong kind", key = "type", value = "group" },
		{ name = "changed caption", key = "i18n", value = "menu.global.quit" },
		{ name = "empty caption", key = "i18n", value = "" },
		{ name = "hidden command", key = "platforms", value = { "hs" } },
	}) do
		helpers.it("refuses the retained callback after " .. mutation.name .. " then repairs (uninstall-declared-caption)", function()
			with_about_parent("en", nil, function(items, state, _, root)
				local item = actual_uninstall_caption_source(root)
				local parent = assert(about_parent_at(items, about_parent_corpus().locales.en.about_parent))
				local action = parent.menu[7].fn
				with_uninstall_caption_field(item, mutation.key, mutation.value, function()
					helpers.assert_eq(action(), false)
					helpers.assert_eq(#state.removals, 0, "no transaction or confirmation is delegated")
					helpers.assert_eq(state.quits, 0)
				end)
				helpers.assert_nil(action())
				helpers.assert_eq(#state.removals, 1, "repair restores the same actual callback")
			end)
		end)
	end

	helpers.it("refuses a replaced translation owner without observing it (uninstall-declared-caption)", function()
		with_about_parent("en", nil, function(items, state)
			local parent = assert(about_parent_at(items, about_parent_corpus().locales.en.about_parent))
			local translator = package.loaded["infra.i18n"]
			local get = translator.get
			local hits = 0
			with_uninstall_caption_field(translator, "get", function(key)
				hits = hits + 1
				return get(key)
			end, function()
				helpers.assert_eq(parent.menu[7].fn(), false)
				helpers.assert_eq(hits, 0)
				helpers.assert_eq(#state.removals, 0)
			end)
			helpers.assert_nil(parent.menu[7].fn())
			helpers.assert_eq(#state.removals, 1)
		end)
	end)

	helpers.it("receives a caption without constructing an unused menu row (uninstall-declared-caption)", function()
		with_about_parent("en", nil, function(_, _, _, root)
			local renderer = package.loaded["infra.manifest_menu"]
			helpers.assert_type(renderer.command_caption_receiver, "function",
				"the actual shared receiver is required; the old producer must fail")
			local receive, current = renderer.command_caption_receiver("about_menu", "uninstall")
			helpers.assert_type(receive, "function")
			helpers.assert_type(current, "function")
			local hits = 0
			local function foreign() hits = hits + 1; error("unused row construction") end
			with_uninstall_caption_field(renderer, "command_row", foreign, function()
				with_uninstall_caption_field(renderer, "template_rows", foreign, function()
					with_uninstall_caption_field(renderer, "render_rows", foreign, function()
						helpers.assert_eq(current(), true)
						helpers.assert_eq(receive(), about_parent_corpus().locales.en.uninstall)
						helpers.assert_eq(hits, 0)
					end)
				end)
			end)
			helpers.assert_eq(actual_uninstall_caption_source(root).i18n, "menu.global.uninstall")
		end)
	end)
end)

--- Copies the actual source fields; no substitute command or caption is invented.
local function copy_uninstall_caption_source(item)
	local copy = {}
	for key, value in next, item do copy[key] = value end
	return copy
end

helpers.describe("Linux uninstall caption current source and native delivery boundary", function()
	helpers.it("refuses a duplicate visible command before caption admission (uninstall-declared-caption)", function()
		with_about_parent("en", { before = function(root)
			local item = actual_uninstall_caption_source(root)
			root.about_menu[#root.about_menu + 1] = copy_uninstall_caption_source(item)
		end }, function(_, state)
			local renderer = package.loaded["infra.manifest_menu"]
			helpers.assert_type(renderer.command_caption_receiver, "function")
			local receive, current = renderer.command_caption_receiver("about_menu", "uninstall")
			helpers.assert_nil(receive)
			helpers.assert_nil(current)
			helpers.assert_eq(#state.removals, 0)
		end)
	end)

	helpers.it("retires a retained callback when a duplicate visible owner appears then repairs (uninstall-declared-caption)", function()
		with_about_parent("en", nil, function(items, state, _, root)
			local item = actual_uninstall_caption_source(root)
			local action = assert(about_parent_at(items, about_parent_corpus().locales.en.about_parent)).menu[7].fn
			with_uninstall_caption_field(root.about_menu, #root.about_menu + 1, copy_uninstall_caption_source(item), function()
				helpers.assert_eq(action(), false)
				helpers.assert_eq(#state.removals, 0)
			end)
			helpers.assert_nil(action())
			helpers.assert_eq(#state.removals, 1)
		end)
	end)

	helpers.it("selects the real native-visible command rather than a hidden invalid sibling (uninstall-declared-caption)", function()
		with_about_parent("en", { before = function(root)
			local sibling = copy_uninstall_caption_source(actual_uninstall_caption_source(root))
			sibling.platforms, sibling.unavailable, sibling.type, sibling.i18n = { "hs" }, "hide", "group", ""
			root.about_menu[#root.about_menu + 1] = sibling
		end }, function(items, state)
			local hand = about_parent_corpus().locales.en
			local parent = assert(about_parent_at(items, hand.about_parent))
			helpers.assert_eq(#parent.menu, 7, "the hidden sibling does not become a native row")
			helpers.assert_eq(parent.menu[7].title, hand.uninstall)
			helpers.assert_nil(parent.menu[7].fn())
			helpers.assert_eq(#state.removals, 1)
			helpers.assert_eq(state.removals[1].title, hand.uninstall)
		end)
	end)

	for _, key in ipairs({ "menu.global.uninstall", "dialog.uninstall.confirm", "dialog.uninstall.failed" }) do
		helpers.it("refuses actual source reentry during " .. key .. " then repairs (uninstall-declared-caption)", function()
			local control = { armed = false, reads = 0 }
			with_about_parent("en", { caption_get = function(request, get)
				local value = get(request)
				if control.armed and request == key then
					control.reads = control.reads + 1
					control.item.i18n = "menu.global.quit"
				end
				return value
			end }, function(items, state, _, root)
				control.item = actual_uninstall_caption_source(root)
				local action = assert(about_parent_at(items, about_parent_corpus().locales.en.about_parent)).menu[7].fn
				control.armed = true
				with_uninstall_caption_field(control.item, "i18n", control.item.i18n, function()
					helpers.assert_eq(action(), false)
					helpers.assert_eq(control.reads, 1, "the genuine captured translator was reached")
					helpers.assert_eq(#state.removals, 0, "no native transaction observes stale option state")
					helpers.assert_eq(state.quits, 0)
				end)
				control.armed = false
				helpers.assert_nil(action())
				helpers.assert_eq(#state.removals, 1)
				helpers.assert_eq(state.removals[1].title, about_parent_corpus().locales.en.uninstall)
			end)
		end)
	end

	helpers.it("preserves the original late translation error identity before native delivery (uninstall-declared-caption)", function()
		local control, failure = { armed = false }, {}
		with_about_parent("en", { caption_get = function(key, get)
			if control.armed and key == "menu.global.uninstall" then error(failure, 0) end
			return get(key)
		end }, function(items, state)
			local action = assert(about_parent_at(items, about_parent_corpus().locales.en.about_parent)).menu[7].fn
			control.armed = true
			local ok, detail = pcall(action)
			control.armed = false
			helpers.assert_eq(ok, false)
			helpers.assert_true(rawequal(detail, failure), "no wrapping or success fallback replaces the original error")
			helpers.assert_eq(#state.removals, 0)
			helpers.assert_nil(action())
			helpers.assert_eq(#state.removals, 1)
		end)
	end)

	for _, mode in ipairs({ "missing", "empty", "key echo" }) do
		helpers.it("refuses a late " .. mode .. " translation then repairs (uninstall-declared-caption)", function()
			local control = { armed = false }
			with_about_parent("en", { caption_get = function(key, get)
				if control.armed and key == "menu.global.uninstall" then
					if mode == "missing" then return nil end
					if mode == "empty" then return "" end
					return key
				end
				return get(key)
			end }, function(items, state)
				local action = assert(about_parent_at(items, about_parent_corpus().locales.en.about_parent)).menu[7].fn
				control.armed = true
				local outcome = packed(pcall(function()
					helpers.assert_eq(action(), false)
					helpers.assert_eq(#state.removals, 0)
				end))
				control.armed = false
				if not outcome[1] then error(outcome[2], 0) end
				helpers.assert_nil(action())
				helpers.assert_eq(#state.removals, 1)
			end)
		end)
	end

	for _, name in ipairs({ "receiver API", "renderer facade", "translator facade" }) do
		helpers.it("refuses replacement of the actual " .. name .. " without observing it then repairs (uninstall-declared-caption)", function()
			with_about_parent("en", nil, function(items, state)
				local action = assert(about_parent_at(items, about_parent_corpus().locales.en.about_parent)).menu[7].fn
				local renderer = package.loaded["infra.manifest_menu"]
				local hits = 0
				local function foreign() hits = hits + 1; error("foreign caption owner was observed") end
				local owner, key, replacement
				if name == "receiver API" then owner, key, replacement = renderer, "command_caption_receiver", foreign
				elseif name == "renderer facade" then
					owner, key, replacement = package.loaded, "infra.manifest_menu", { command_caption_receiver = foreign }
				else owner, key, replacement = package.loaded, "infra.i18n", { get = foreign } end
				with_uninstall_caption_field(owner, key, replacement, function()
					helpers.assert_eq(action(), false)
					helpers.assert_eq(hits, 0)
					helpers.assert_eq(#state.removals, 0)
				end)
				helpers.assert_nil(action())
				helpers.assert_eq(#state.removals, 1)
			end)
		end)
	end
end)

helpers.describe("Linux uninstall does not observe a retired option translator", function()
	for _, name in ipairs({ "getter", "facade" }) do
		helpers.it("refuses " .. name .. " replacement during actual confirmation read then repairs (uninstall-declared-caption)", function()
			local control = { armed = false, reads = 0, foreign_hits = 0 }
			with_about_parent("en", { caption_get = function(key, get)
				local value = get(key)
				if control.armed and key == "dialog.uninstall.confirm" then
					control.reads = control.reads + 1
					rawset(control.owner, control.key, control.replacement)
				end
				return value
			end }, function(items, state)
				local action = assert(about_parent_at(items, about_parent_corpus().locales.en.about_parent)).menu[7].fn
				local function foreign()
					control.foreign_hits = control.foreign_hits + 1
					return "foreign option translator"
				end
				if name == "getter" then
					control.owner, control.key, control.replacement = package.loaded["infra.i18n"], "get", foreign
				else
					control.owner, control.key, control.replacement = package.loaded, "infra.i18n", { get = foreign }
				end
				control.armed = true
				with_uninstall_caption_field(control.owner, control.key, rawget(control.owner, control.key), function()
					helpers.assert_eq(action(), false)
					helpers.assert_eq(control.reads, 1, "the actual retained confirmation translator ran")
					helpers.assert_eq(control.foreign_hits, 0, "the retired failure translator is never called")
					helpers.assert_eq(#state.removals, 0)
				end)
				control.armed = false
				helpers.assert_nil(action())
				helpers.assert_eq(#state.removals, 1)
			end)
		end)
	end
end)
