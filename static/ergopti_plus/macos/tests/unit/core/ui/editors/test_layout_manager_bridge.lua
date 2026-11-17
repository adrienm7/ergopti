--- tests/unit/core/ui/editors/test_layout_manager_bridge.lua

--- ==============================================================================
--- MODULE: Layout Manager Bridge (shared, replayed on macOS)
--- DESCRIPTION:
--- The layout manager page may only ask for the allowlisted actions, each
--- checked against the catalogue or the installed layouts, and every refresh
--- or operation pushes the page the same state on every driver
--- (layout-manager-bridge). These tests drive the shared controller
--- (_shared/layouts/engine/manager_bridge.lua) with a fake registry client and
--- record what it pushes, opens and closes.
--- ==============================================================================

local helpers = require("tests.helpers")
local ManagerBridge = require("layouts.engine.manager_bridge")

local INDEX = {
	layouts = {
		{ id = "ergol", name = "Ergo-L", homepage = "https://ergol.org", sha256 = "b", version = "1.0.2" },
		{ id = "plain", name = "Plain", homepage = "http://insecure.example.org", sha256 = "c", version = "1.0.0" },
	},
}

--- A controller over a fake registry client.
--- @param installed table Installed entries by id.
--- @return table controller, table state
local function controller(installed)
	local state = { pushes = {}, calls = {}, opened = {}, closed = 0, logs = {}, pending = {} }
	local snapshot = {
		platform = "macos", index = INDEX, source = "network", installed = installed or {}, active = "",
	}
	local registry = {
		snapshot = function() return snapshot end,
		refresh = function(on_done) state.calls[#state.calls + 1] = "refresh"; on_done({}) end,
		install = function(id, on_done)
			state.calls[#state.calls + 1] = "install " .. id
			state.pending[#state.pending + 1] = on_done
		end,
		uninstall = function(id, on_done) state.calls[#state.calls + 1] = "uninstall " .. id; on_done(true, { id = id }) end,
		select = function(id, on_done) state.calls[#state.calls + 1] = "select " .. id; on_done(false, "select_failed", "no") end,
	}
	local instance = ManagerBridge.new({
		registry = registry,
		push = function(name, payload) state.pushes[#state.pushes + 1] = { name = name, payload = payload }; return true end,
		strings = function() return { ["layout_manager.window_title"] = "Keyboard layouts" } end,
		open_url = function(url) state.opened[#state.opened + 1] = url end,
		close = function() state.closed = state.closed + 1 end,
		log = function(level, message) state.logs[#state.logs + 1] = level .. ": " .. message end,
	})
	return instance, state
end

helpers.describe("layout manager bridge: what the page may ask", function()
	helpers.it("answers ready with the strings and the state, then the refreshed state (layout-manager-bridge)", function()
		local instance, state = controller()
		helpers.assert_true(instance.on_message({ action = "ready" }))
		helpers.assert_eq(state.pushes[1].name, "initData")
		helpers.assert_eq(state.pushes[1].payload.strings["layout_manager.window_title"], "Keyboard layouts")
		helpers.assert_eq(state.pushes[1].payload.state.platform, "macos")
		helpers.assert_eq(state.pushes[1].payload.state.shortcut_menu_path, "shortcuts/menu.lua",
			"the page counts the menu file this driver loads")
		helpers.assert_eq(state.pushes[1].payload.state.index, INDEX)
		helpers.assert_eq(state.calls[1], "refresh")
		helpers.assert_eq(state.pushes[2].name, "updateState")
	end)

	helpers.it("refuses anything outside the allowlist or naming an unknown layout (layout-manager-bridge)", function()
		local instance, state = controller()
		for _, payload in ipairs({
			"install", {}, { action = "rm -rf" }, { action = "install" }, { action = "install", id = "../evil" },
			{ action = "install", id = "absent" }, { action = "uninstall", id = "ergol" }, { action = "select", id = "ergol" },
			{ action = "open_homepage", id = "plain" },
		}) do
			helpers.assert_true(instance.on_message(payload) == false, "accepted: " .. tostring(payload.action))
		end
		helpers.assert_eq(#state.calls, 0, "no refused message reaches the registry")
		helpers.assert_eq(#state.opened, 0, "no refused message opens anything")
		helpers.assert_true(#state.logs >= 8, "every refusal is logged")
	end)

	-- macOS 26 lists the layout and turns it on at the next login (composer-macos26).
	helpers.it("reports a layout macOS turns on at the next login as pending, not as a missing step", function()
		local instance, state = controller()
		helpers.assert_true(instance.on_message({ action = "install", id = "ergol" }))
		state.pending[1](true, { entry = INDEX.layouts[1], enabled = false, pending_activation = true })
		helpers.assert_eq(state.pushes[#state.pushes].payload.result.warning, "pending_logout")
		helpers.assert_true(instance.on_message({ action = "update", id = "ergol" }))
		-- macOS asks to allow a keyboard it has not seen: the page says so.
		state.pending[2](true, { entry = INDEX.layouts[1], enabled = true, consent = true })
		helpers.assert_eq(state.pushes[#state.pushes].payload.result.warning, "macos_consent")
	end)

	helpers.it("installs a catalogue layout and reports the result once it settles (layout-manager-bridge)", function()
		local instance, state = controller()
		helpers.assert_true(instance.on_message({ action = "install", id = "ergol" }))
		helpers.assert_eq(state.calls[1], "install ergol")
		helpers.assert_eq(state.pushes[#state.pushes].payload.result, nil, "no result before the operation settles")
		state.pending[1](true, { entry = INDEX.layouts[1], enabled = false })
		local result = state.pushes[#state.pushes].payload.result
		helpers.assert_eq(result.id, "ergol")
		helpers.assert_eq(result.ok, true)
		helpers.assert_eq(result.warning, "not_enabled", "an installed but not enabled layout says so")
		helpers.assert_true(instance.on_message({ action = "update", id = "ergol" }))
		state.pending[2](false, "download_failed", "HTTP 404 for x")
		result = state.pushes[#state.pushes].payload.result
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(result.code, "download_failed")
		helpers.assert_eq(result.detail, "HTTP 404 for x")
	end)

	helpers.it("uninstalls and selects installed layouts only (layout-manager-bridge)", function()
		local instance, state = controller({ ergol = INDEX.layouts[1] })
		helpers.assert_true(instance.on_message({ action = "uninstall", id = "ergol" }))
		helpers.assert_true(instance.on_message({ action = "select", id = "ergol" }))
		helpers.assert_eq(state.calls[1], "uninstall ergol")
		helpers.assert_eq(state.calls[2], "select ergol")
		local result = state.pushes[#state.pushes].payload.result
		helpers.assert_eq(result.action, "select")
		helpers.assert_eq(result.code, "select_failed")
	end)

	helpers.it("opens only the https homepage the catalogue gives, and closes on request (layout-manager-bridge)", function()
		local instance, state = controller()
		helpers.assert_true(instance.on_message({ action = "open_homepage", id = "ergol", url = "https://evil.test" }))
		helpers.assert_eq(state.opened[1], "https://ergol.org", "the page never chooses the URL")
		helpers.assert_true(instance.on_message({ action = "close" }))
		helpers.assert_eq(state.closed, 1)
	end)
end)

helpers.describe("layout manager bridge: the layout editor's navigation layer", function()
	--- A controller whose host applies the navigation layer, or none.
	local function nav_controller(apply_nav)
		local pushes, logs = {}, {}
		local instance = ManagerBridge.new({
			registry = { snapshot = function() return { platform = "macos", installed = {} } end,
				refresh = function() end },
			push = function(name, payload) pushes[#pushes + 1] = { name = name, payload = payload }; return true end,
			strings = function() return {} end,
			open_url = function() end, close = function() end,
			log = function(level, message) logs[#logs + 1] = level .. ": " .. message end,
			apply_nav = apply_nav,
		})
		return instance, pushes, logs
	end

	helpers.it("routes nav_save to the host's navigation layer save and answers navResult (layout-editor-nav-apply)", function()
		local texts = {}
		local instance, pushes = nav_controller(function(text, on_done)
			texts[#texts + 1] = text
			on_done({ saved = true, applied = false, errors = {} })
		end)
		helpers.assert_true(instance.on_message({ action = "ready" }))
		helpers.assert_eq(pushes[1].payload.nav_apply, true)
		helpers.assert_true(instance.on_message({ action = "nav_save", text = "[layers]\n" }))
		helpers.assert_eq(texts[1], "[layers]\n")
		local answer = pushes[#pushes]
		helpers.assert_eq(answer.name, "navResult")
		helpers.assert_eq(answer.payload.saved, true)
		helpers.assert_eq(answer.payload.applied, false)
		helpers.assert_true(instance.on_message({ action = "nav_save", text = 3 }) == false, "a non-text save is refused")
		helpers.assert_eq(#texts, 1)
	end)

	helpers.it("refuses nav_save on a host without the navigation layer save (layout-editor-nav-apply)", function()
		local instance, pushes, logs = nav_controller(nil)
		helpers.assert_true(instance.on_message({ action = "ready" }))
		helpers.assert_eq(pushes[1].payload.nav_apply, false)
		helpers.assert_true(instance.on_message({ action = "nav_save", text = "x" }) == false)
		helpers.assert_true(#logs >= 1, "the refusal is logged")
	end)
end)

--- A bridge whose host records layout changes and answers its pause state.
--- @param paused table { value = boolean }
--- @return table instance, table changed
local function host_bridge(paused)
	local changed = {}
	local snapshot = { platform = "macos", index = INDEX, source = "network", installed = { ergol = { id = "ergol" } }, active = "" }
	local instance = ManagerBridge.new({
		registry = {
			snapshot = function() return snapshot end,
			refresh = function(on_done) on_done({}) end,
			install = function(_, on_done) on_done(true, {}) end,
			uninstall = function(_, on_done) on_done(true, {}) end,
			select = function(_, on_done) on_done(true, {}) end,
			composer_save = function(_, on_done) on_done(true) end,
		},
		push = function() return true end,
		strings = function() return {} end,
		open_url = function() end,
		close = function() end,
		log = function() end,
		layout_changed = function(id) changed[#changed + 1] = id end,
		is_paused = function() return paused.value end,
	})
	return instance, changed
end

helpers.describe("layout manager bridge: the emulation follows a changed layout", function()
	helpers.it("(lmh-001-002-emulation-reload) tells the host of every install, update, uninstall and composition", function()
		local instance, changed = host_bridge({ value = false })
		helpers.assert_true(instance.on_message({ action = "install", id = "ergol" }))
		helpers.assert_true(instance.on_message({ action = "update", id = "ergol" }))
		helpers.assert_true(instance.on_message({ action = "uninstall", id = "ergol" }))
		helpers.assert_true(instance.on_message({ action = "select", id = "ergol" }))
		helpers.assert_true(instance.on_message({ action = "composer_save", source = "src", keylayout = "kl" }))
		helpers.assert_eq(changed, { "ergol", "ergol", "ergol", "composed" },
			"a select changes no layout; every other success reaches the emulation")
	end)

	-- EDD-1 (maintainer, 2026-11-12): a pause stops typing, not configuration.
	helpers.it("(edd1-paused-writes) runs page commands while the driver is paused", function()
		local paused = { value = true }
		local instance, changed = host_bridge(paused)
		helpers.assert_true(instance.on_message({ action = "ready" }))
		helpers.assert_true(instance.on_message({ action = "install", id = "ergol" }), "an install runs while paused")
		helpers.assert_true(instance.on_message({ action = "uninstall", id = "ergol" }))
		helpers.assert_eq(changed, { "ergol", "ergol" })
		local host = assert(helpers.read_module_source("ui.layout_manager"))
		helpers.assert_nil(host:find("is_paused", 1, true), "the macOS host reads no pause")
	end)

	helpers.it("(lmh-004-extension-reload) a layout shipping an extension reloads the driver", function()
		local changed, reloads, logs = {}, {}, {}
		local snapshot = { platform = "macos", source = "network", active = "",
			index = { layouts = { { id = "ergol", name = "Ergol" }, { id = "kaladrius", name = "K", extension = { root = "x" } } } },
			installed = { ergol = { id = "ergol" }, bepo = { id = "bepo", extension = { root = "y" } } } }
		local instance = ManagerBridge.new({
			registry = {
				snapshot = function() return snapshot end,
				refresh = function(on_done) on_done({}) end,
				install = function(_, on_done) on_done(true, {}) end,
				uninstall = function(_, on_done) on_done(true, {}) end,
				select = function(_, on_done) on_done(true, {}) end,
			},
			push = function() return true end, strings = function() return {} end,
			open_url = function() end, close = function() end,
			log = function(level, message) logs[#logs + 1] = level .. ":" .. message end,
			layout_changed = function(id) changed[#changed + 1] = id end,
			reload_extensions = function(id) reloads[#reloads + 1] = id; return true end,
		})
		helpers.assert_true(instance.on_message({ action = "install", id = "kaladrius" }))
		helpers.assert_true(instance.on_message({ action = "uninstall", id = "bepo" }))
		helpers.assert_true(instance.on_message({ action = "select", id = "bepo" }))
		helpers.assert_true(instance.on_message({ action = "install", id = "ergol" }))
		helpers.assert_eq(reloads, { "kaladrius", "bepo" }, "catalogue and installed extensions both reload; a select changes no extension")
		helpers.assert_eq(changed, { "ergol" }, "a layout without an extension only reloads the emulation")
		helpers.assert_eq(#logs, 0)
	end)

	helpers.it("(lmh-001-002-emulation-reload) the macOS host reloads the emulated layout and the menu", function()
		local menu = assert(helpers.read_module_source("menu.ui"))
		helpers.assert_contains(menu, 'require("ui.layout_manager").set_layout_change_handler(function(id)')
		helpers.assert_contains(menu, "if Emulation.status().id ~= id then return end")
		local host = assert(helpers.read_module_source("ui.layout_manager"))
		helpers.assert_contains(menu, 'require("ui.layout_manager").set_extension_reloader(function()')
		helpers.assert_contains(host, "reload_extensions = function(id) return _extension_reloader ~= nil and _extension_reloader(id) == true end")
		helpers.assert_contains(host, "if _layout_change_handler then _layout_change_handler(id) end")
	end)
end)


--- A controller over a registry that stores the layout editor's sources.
--- @param extra table|nil More deps (editor_window, open_editor_window).
--- @return table controller, table state
local function editor_controller(extra)
	local state = { pushes = {}, calls = {}, logs = {}, windows = 0 }
	local deps = {
		registry = {
			snapshot = function() return { platform = "macos", installed = {} } end,
			refresh = function(on_done) state.calls[#state.calls + 1] = "refresh"; on_done({}) end,
			source_open = function(on_done) on_done({ text = "format = 1", filename = "mine.toml", folder = "x/" }) end,
			source_save = function(_, on_done) on_done(true) end,
		},
		push = function(name, payload) state.pushes[#state.pushes + 1] = { name = name, payload = payload }; return true end,
		strings = function() return { ["layout_editor.title"] = "Layout editor" } end,
		open_url = function() end,
		close = function() end,
		log = function(level, message) state.logs[#state.logs + 1] = level .. ": " .. message end,
	}
	for key, value in pairs(extra or {}) do deps[key] = value end
	return ManagerBridge.new(deps), state
end

helpers.describe("layout manager bridge: the layout editor in its own window", function()
	helpers.it("the manager's open_editor opens the editor window (layout-editor-own-window)", function()
		local state
		local instance
		instance, state = editor_controller({ open_editor_window = function() state.windows = state.windows + 1 end })
		helpers.assert_true(instance.on_message({ action = "open_editor" }) == true)
		helpers.assert_eq(state.windows, 1, "the host opens the editor window")
		helpers.assert_eq(#state.pushes, 0, "the manager page itself receives no source")
	end)

	helpers.it("refuses open_editor on a host without an editor window (layout-editor-own-window)", function()
		local instance, state = editor_controller()
		helpers.assert_true(instance.on_message({ action = "open_editor" }) == false)
		helpers.assert_true(#state.logs == 1, "the refusal is logged")
	end)

	helpers.it("the editor window answers ready with the last saved source and no catalogue (layout-editor-own-window)",
		function()
			local instance, state = editor_controller({ editor_window = true })
			helpers.assert_true(instance.on_message({ action = "ready" }) == true)
			helpers.assert_eq(state.pushes[1].name, "initData")
			helpers.assert_eq(state.pushes[1].payload.strings["layout_editor.title"], "Layout editor")
			helpers.assert_eq(state.pushes[1].payload.state.platform, "macos", "the editor compiles for this platform")
			helpers.assert_true(state.pushes[1].payload.source_editor == true)
			helpers.assert_eq(state.pushes[2].name, "sourceData")
			helpers.assert_eq(state.pushes[2].payload.filename, "mine.toml")
			helpers.assert_eq(#state.calls, 0, "the editor window fetches no catalogue")
		end)
end)

helpers.describe("Ergopti Studio keystats bridge (macOS)", function()
	helpers.it("the Studio window title is exactly « Ergopti Studio » in every locale (window-title-product-name)", function()
		package.loaded["core.ui.engine.window_titles"] = nil
		local WindowTitles = require("core.ui.engine.window_titles")
		local Json = require("core.text.engine.json")
		local Paths = require("core.fs.engine.paths")
		local key = WindowTitles.key_for_app("layout_editor_window")
		helpers.assert_eq(key, "layout_editor.title")
		local order = Json.decode(assert(io.open(Paths.shared("core/i18n/data/locale_order.json"), "rb")):read("*a")).order
		helpers.assert_eq(#order, 21)
		for _, code in ipairs(order) do
			local strings = Json.decode(assert(io.open(Paths.shared("core/i18n/data/locales/" .. code .. ".json"), "rb")):read("*a"))
			helpers.assert_eq(WindowTitles.compose(strings[key]), "Ergopti Studio", code .. ": the whole title is the product name")
		end
		helpers.assert_eq(WindowTitles.compose("Paths"), "ErgoptiPlus — Paths", "every other window keeps the brand")
		helpers.assert_eq(WindowTitles.compose("Ergopti Studio 2"), "ErgoptiPlus — Ergopti Studio 2")
	end)

	helpers.it("the Studio window pushes the store's counts, the manager refuses them (studio-keystats-bridge)", function()
		local reads = 0
		local instance, state = editor_controller({ editor_window = true, read_keystats = function(on_done)
			reads = reads + 1
			on_done(reads == 1 and { ok = true, ngrams = { schema = 1, chars = { e = 7 } } }
				or { ok = false, code = "keystats_absent" })
		end })
		helpers.assert_true(instance.on_message({ action = "ready" }) == true)
		helpers.assert_true(state.pushes[1].payload.keystats == true, "initData offers « My typing »")
		helpers.assert_true(instance.on_message({ action = "keystats_ngrams" }) == true)
		local last = state.pushes[#state.pushes]
		helpers.assert_eq(last.name, "keystatsNgrams")
		helpers.assert_eq(last.payload, { ok = true, ngrams = { schema = 1, chars = { e = 7 } } })
		helpers.assert_true(instance.on_message({ action = "keystats_ngrams" }) == true)
		helpers.assert_eq(state.pushes[#state.pushes].payload, { ok = false, code = "keystats_absent" })
		local manager, manager_state = editor_controller({ read_keystats = function() error("never read") end })
		helpers.assert_true(manager.on_message({ action = "ready" }) == true)
		helpers.assert_true(manager_state.pushes[1].payload.keystats == false)
		helpers.assert_true(manager.on_message({ action = "keystats_ngrams" }) == false,
			"the layout manager window does not read keystats")
	end)

	helpers.it("the reader opens the store read only and reads the three Studio families (studio-keystats-bridge)", function()
		local queries, flags = {}, nil
		local rows = {
			ngram_chars = { { token = "e", c = 9, td = 0, e = 0, esrc_json = '{"hotstring":2}', source_rows = 1 } },
			ngram_bigrams = { { token = "es", c = 4, td = 0, e = 0, esrc_json = "{}", source_rows = 1 } },
			ngram_trigrams = { { token = "est", c = 2, td = 0, e = 0, esrc_json = "{}", source_rows = 1 } },
			meta = { { value = "42" } },
		}
		local fake = {
			OPEN_READONLY = 1,
			open = function(_, given_flags)
				flags = given_flags
				return {
					exec = function() return 0 end,
					close = function() end,
					nrows = function(_, sql)
						queries[#queries + 1] = sql
						local table_name = sql:match("FROM (ngram_[a-z]+)") or (sql:find("FROM meta", 1, true) and "meta")
						local list, index = rows[table_name] or {}, 0
						return function() index = index + 1; return list[index] end
					end,
				}
			end,
		}
		local saved_sqlite, saved_reader = package.loaded["hs.sqlite3"], package.loaded["modules.keystats.sqlite_reader"]
		-- The reader requires hs.json too; a run of this file alone has no other module that loaded it.
		local saved_json = package.loaded["hs.json"]
		local SharedJson = require("core.text.engine.json")
		package.loaded["hs.json"] = saved_json or { encode = SharedJson.encode, decode = SharedJson.decode }
		package.loaded["hs.sqlite3"] = fake
		package.loaded["modules.keystats.sqlite_reader"] = nil
		local ok, err = pcall(function()
			local Reader = require("modules.keystats.sqlite_reader")
			local dict, complete = Reader.read_studio_ngrams("/Users/u/.ergopti/db.sqlite")
			helpers.assert_true(complete)
			helpers.assert_eq(flags, fake.OPEN_READONLY, "the store is opened read only")
			helpers.assert_eq(#queries, 3, "only the three Studio families are read")
			helpers.assert_eq(dict.c.e.c, 9)
			helpers.assert_eq(dict.c.e.hs, 2)
			local payload = require("metrics.engine.view.studio_ngrams").project(dict)
			helpers.assert_eq(payload.chars, { e = 7 }, "hotstring expansions are not keystrokes")
			helpers.assert_eq(payload.bigrams, { es = 4 })
			helpers.assert_eq(payload.trigrams, { est = 2 })
			helpers.assert_eq(payload.final.chars, { e = 9 }, "the final text keeps the hotstring expansions")
			helpers.assert_eq(payload.final.total, 9)
		end)
		package.loaded["hs.sqlite3"] = saved_sqlite
		package.loaded["modules.keystats.sqlite_reader"] = saved_reader
		package.loaded["hs.json"] = saved_json
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("the macOS host reads keystats for the Studio window alone, deferred (studio-keystats-bridge)", function()
		local host = assert(helpers.read_module_source("ui.layout_manager"))
		helpers.assert_contains(host, "read_keystats = spec.editor_window and function(on_done)")
		helpers.assert_contains(host, 'read = require("modules.keystats.sqlite_reader").read_studio_ngrams,')
		helpers.assert_contains(host, 'path = require("modules.keystats.log_manager").get_sqlite_path(),')
		helpers.assert_contains(host, 'local rev = require("modules.keystats.export").get_db_rev()')
	end)
end)

helpers.describe("Ergopti Studio links (macOS)", function()
	helpers.it("the Studio window opens only https links, the manager none (studio-open-link)", function()
		local opened = {}
		local instance = editor_controller({ editor_window = true,
			open_url = function(url) opened[#opened + 1] = url end })
		helpers.assert_true(instance.on_message({ action = "open_link", url = "https://ergopti.fr/studio" }) == true)
		helpers.assert_true(instance.on_message({ action = "open_link", url = "http://example.org" }) == false)
		helpers.assert_true(instance.on_message({ action = "open_link", url = "https://a b" }) == false)
		helpers.assert_true(instance.on_message({ action = "open_link" }) == false)
		local manager = editor_controller({ open_url = function(url) opened[#opened + 1] = url end })
		helpers.assert_true(manager.on_message({ action = "open_link", url = "https://ergopti.fr" }) == false)
		helpers.assert_eq(opened, { "https://ergopti.fr/studio" })
	end)
end)

helpers.describe("Ergopti Studio personal layouts (studio-layout-store)", function()
	local StudioStore = require("layouts.engine.composer.studio_store")
	local Json = require("core.text.engine.json")
	local Paths = require("core.fs.engine.paths")
	local defaults = Json.decode(assert(io.open(Paths.shared("layouts/data/defaults.json"), "rb")):read("*a"))
	local settings = assert(StudioStore.settings(defaults))

	--- A store over an in-memory disk.
	local function store(files)
		files = files or {}
		local logs = {}
		local operations = StudioStore.new({
			settings = settings,
			config_dir = "/cfg/", shared_dir = "/shared/",
			exists = function(path) return files[path] ~= nil end,
			read_bounded = function(path) return files[path], files[path] and "ok" or "absent" end,
			write = function(path, text) files[path] = text; return true end,
			log = function(level, message) logs[#logs + 1] = level .. ": " .. message end,
		})
		return operations, files, logs
	end
	local function call(operation, ...)
		local result
		local args = { ... }
		args[#args + 1] = function(...) result = { ... } end
		operation((table.unpack or unpack)(args))
		return result
	end

	helpers.it("stores each layout's JSON text exactly as given and lists it back by id", function()
		local operations, files = store()
		helpers.assert_eq(call(operations.list), { true, {} }, "an absent store is empty")
		local b = '{"id":"user_b","rows":{"KeyQ":["q",null,null,"Q"]},"name":"B"}'
		local a = '{"id":"user_a","name":"A","dead":{}}'
		helpers.assert_eq(call(operations.save, { id = "user_b", text = b }), { true, nil, "user_b" })
		helpers.assert_eq(call(operations.save, { id = "user_a", text = a }), { true, nil, "user_a" })
		helpers.assert_eq(call(operations.list), { true, { a, b } }, "null cells survive: the text is never re-encoded")
		local replaced = '{"id":"user_a","name":"A2"}'
		call(operations.save, { id = "user_a", text = replaced })
		helpers.assert_eq(call(operations.list), { true, { replaced, b } }, "saving an existing id replaces it")
		helpers.assert_eq(call(operations.remove, { id = "user_a" }), { true, nil, "user_a" })
		helpers.assert_eq(call(operations.remove, { id = "user_a" }), { true, nil, "user_a" }, "an absent id is already removed")
		helpers.assert_eq(call(operations.list), { true, { b } })
		helpers.assert_true(files["/cfg/" .. settings.folder .. "/" .. settings.file] ~= nil)
	end)

	helpers.it("refuses a foreign id, a layout naming another id and a non-JSON layout", function()
		local operations, files = store()
		local invalid = settings.failures.invalid
		helpers.assert_eq(call(operations.save, { id = "../x", text = '{"id":"../x"}' })[2], invalid)
		helpers.assert_eq(call(operations.save, { id = "bepo", text = '{"id":"bepo"}' })[2], invalid)
		helpers.assert_eq(call(operations.save, { id = "user_a", text = '{"id":"user_b"}' })[2], invalid)
		helpers.assert_eq(call(operations.save, { id = "user_a", text = "not json" })[2], invalid)
		helpers.assert_eq(call(operations.save, { id = "user_a", text = string.rep("x", settings.max_layout_bytes + 1) })[2], invalid)
		helpers.assert_eq(call(operations.remove, { id = "/etc" })[2], invalid)
		helpers.assert_eq(next(files), nil, "nothing reached the disk")
	end)

	helpers.it("never replaces an unreadable store and reports it on every operation", function()
		local path = "/cfg/" .. settings.folder .. "/" .. settings.file
		local operations, files = store({ [path] = "{broken" })
		local unreadable = settings.failures.unreadable
		helpers.assert_eq(call(operations.list)[2], unreadable)
		helpers.assert_eq(call(operations.save, { id = "user_a", text = '{"id":"user_a"}' })[2], unreadable)
		helpers.assert_eq(call(operations.remove, { id = "user_a" })[2], unreadable)
		helpers.assert_eq(files[path], "{broken", "the damaged file is kept for the user")
		files[path] = '{"schema":1,"layouts":{"bepo":"{}"}}'
		helpers.assert_eq(call(operations.list)[2], unreadable, "a foreign entry makes the store unreadable")
	end)

	helpers.it("bounds the number of layouts", function()
		local small = {}
		for key, value in pairs(settings) do small[key] = value end
		small.max_layouts = 2
		local files = {}
		local operations = StudioStore.new({ settings = small, config_dir = "/cfg/", shared_dir = "/shared/",
			exists = function(path) return files[path] ~= nil end,
			read_bounded = function(path) return files[path], "ok" end,
			write = function(path, text) files[path] = text; return true end,
			log = function() end })
		call(operations.save, { id = "user_a", text = '{"id":"user_a"}' })
		call(operations.save, { id = "user_b", text = '{"id":"user_b"}' })
		helpers.assert_eq(call(operations.save, { id = "user_c", text = '{"id":"user_c"}' })[2], small.failures.invalid)
		helpers.assert_eq(call(operations.save, { id = "user_a", text = '{"id":"user_a","n":2}' })[1], true,
			"replacing a stored layout is not one more")
	end)
end)

helpers.describe("Ergopti Studio personal layouts through the controller (studio-layout-store)", function()
	helpers.it("answers the page's requests with their number, from the Studio window only", function()
		local saved = {}
		local registry = {
			snapshot = function() return { platform = "macos", installed = {} } end,
			refresh = function(on_done) on_done({}) end,
			source_open = function(on_done) on_done({}) end,
			source_save = function(_, on_done) on_done(true) end,
			studio_list = function(on_done) on_done(true, { '{"id":"user_a"}' }) end,
			studio_save = function(payload, on_done)
				saved[#saved + 1] = payload
				on_done(false, "studio_write_failed", "disk full")
			end,
			studio_remove = function(payload, on_done) on_done(true, nil, payload.id) end,
			studio_profile_load = function(on_done) on_done(true, '{"id":"mine"}') end,
			studio_profile_save = function(payload, on_done)
				saved[#saved + 1] = payload
				on_done(true)
			end,
		}
		local function controller(editor_window)
			local pushes = {}
			local instance = ManagerBridge.new({ registry = registry, editor_window = editor_window,
				push = function(name, payload) pushes[#pushes + 1] = { name = name, payload = payload }; return true end,
				strings = function() return {} end, open_url = function() end, close = function() end,
				log = function() end })
			return instance, pushes
		end
		local instance, pushes = controller(true)
		helpers.assert_true(instance.on_message({ action = "ready" }) == true)
		helpers.assert_true(pushes[1].payload.studio_store == true)
		helpers.assert_true(instance.on_message({ action = "studio_layouts", request = 4 }) == true)
		helpers.assert_eq(pushes[#pushes], { name = "studioLayouts",
			payload = { request = 4, ok = true, layouts = { '{"id":"user_a"}' } } })
		helpers.assert_true(instance.on_message({ action = "studio_layout_save", request = 5, id = "user_a",
			text = '{"id":"user_a"}' }) == true)
		helpers.assert_eq(saved, { { id = "user_a", text = '{"id":"user_a"}' } })
		helpers.assert_eq(pushes[#pushes], { name = "studioLayoutResult",
			payload = { request = 5, ok = false, code = "studio_write_failed", detail = "disk full" } })
		helpers.assert_true(instance.on_message({ action = "studio_layout_remove", request = 6, id = "user_a" }) == true)
		helpers.assert_eq(pushes[#pushes].payload, { request = 6, ok = true, detail = "user_a" })
		helpers.assert_true(instance.on_message({ action = "studio_layouts" }) == false, "a request number is required")
		helpers.assert_true(instance.on_message({ action = "studio_profile_load", request = 7 }) == true)
		helpers.assert_eq(pushes[#pushes], { name = "studioProfile",
			payload = { request = 7, ok = true, profile = '{"id":"mine"}' } })
		helpers.assert_true(instance.on_message({ action = "studio_profile_save", request = 8, reset = true }) == true)
		helpers.assert_eq(saved[#saved], { reset = true })
		helpers.assert_eq(pushes[#pushes], { name = "studioProfileResult", payload = { request = 8, ok = true } })
		local manager, manager_pushes = controller(false)
		helpers.assert_true(manager.on_message({ action = "ready" }) == true)
		helpers.assert_true(manager_pushes[1].payload.studio_store == false)
		helpers.assert_true(manager.on_message({ action = "studio_layouts", request = 1 }) == false)
	end)

	helpers.it("keeps the editor's workspace through the Studio window only (studio-editor-workspace)", function()
		local saved = {}
		local registry = {
			snapshot = function() return { platform = "macos", installed = {} } end,
			refresh = function(on_done) on_done({}) end,
			source_open = function(on_done) on_done({}) end,
			source_save = function(_, on_done) on_done(true) end,
			studio_workspace_load = function(on_done) on_done(true, '{"schema":1,"tabs":[]}') end,
			studio_workspace_save = function(payload, on_done)
				saved[#saved + 1] = payload
				on_done(false, "studio_write_failed", "disk full")
			end,
		}
		local function controller(editor_window)
			local pushes = {}
			local instance = ManagerBridge.new({ registry = registry, editor_window = editor_window,
				push = function(name, payload) pushes[#pushes + 1] = { name = name, payload = payload }; return true end,
				strings = function() return {} end, open_url = function() end, close = function() end,
				log = function() end })
			return instance, pushes
		end
		local instance, pushes = controller(true)
		helpers.assert_true(instance.on_message({ action = "ready" }) == true)
		helpers.assert_true(pushes[1].payload.studio_workspace == true)
		helpers.assert_true(instance.on_message({ action = "studio_workspace_load", request = 3 }) == true)
		helpers.assert_eq(pushes[#pushes], { name = "studioWorkspace",
			payload = { request = 3, ok = true, workspace = '{"schema":1,"tabs":[]}' } })
		helpers.assert_true(instance.on_message({ action = "studio_workspace_save", request = 4, text = '{"tabs":[]}' }) == true)
		helpers.assert_eq(saved, { { text = '{"tabs":[]}', reset = false } })
		helpers.assert_eq(pushes[#pushes], { name = "studioWorkspaceResult",
			payload = { request = 4, ok = false, code = "studio_write_failed", detail = "disk full" } })
		helpers.assert_true(instance.on_message({ action = "studio_workspace_load" }) == false, "a request number is required")
		local manager, manager_pushes = controller(false)
		helpers.assert_true(manager.on_message({ action = "ready" }) == true)
		helpers.assert_true(manager_pushes[1].payload.studio_workspace == false)
		helpers.assert_true(manager.on_message({ action = "studio_workspace_load", request = 1 }) == false)
	end)

	helpers.it("runs a built-in corpus's tables in the Studio page before answering (studio-corpus-tables)", function()
		local events, run_result = {}, true
		local registry = {
			snapshot = function() return { platform = "test", installed = {} } end,
			refresh = function(on_done) on_done({}) end,
			studio_corpus = function(payload, on_done)
				if payload.id == "fr_swann" then on_done(true, "var T = 1;", "studio_corpus_unavailable")
				else on_done(false, "studio_corpus_unavailable", "no such corpus") end
			end,
		}
		local function controller(editor_window, run_script)
			return ManagerBridge.new({ registry = registry, editor_window = editor_window,
				push = function(name, payload) events[#events + 1] = { push = name, payload = payload }; return true end,
				run_script = run_script, strings = function() return {} end, open_url = function() end,
				close = function() end, log = function() end })
		end
		local instance = controller(true, function(text)
			events[#events + 1] = { run = text }
			return run_result
		end)
		helpers.assert_true(instance.on_message({ action = "studio_corpus", request = 2, id = "fr_swann" }) == true)
		helpers.assert_eq(events, { { run = "var T = 1;" },
			{ push = "studioCorpus", payload = { request = 2, ok = true } } })
		events = {}
		helpers.assert_true(instance.on_message({ action = "studio_corpus", request = 3, id = "absent" }) == true)
		helpers.assert_eq(events, { { push = "studioCorpus",
			payload = { request = 3, ok = false, code = "studio_corpus_unavailable", detail = "no such corpus" } } })
		events, run_result = {}, false
		helpers.assert_true(instance.on_message({ action = "studio_corpus", request = 4, id = "fr_swann" }) == true)
		helpers.assert_eq(events[2], { push = "studioCorpus", payload = { request = 4, ok = false,
			code = "studio_corpus_unavailable", detail = "the page refused the corpus script" } })
		helpers.assert_true(instance.on_message({ action = "studio_corpus", id = "fr_swann" }) == false,
			"a request number is required")
		helpers.assert_true(controller(false, function() return true end).on_message({ action = "studio_corpus",
			request = 1, id = "fr_swann" }) == false, "only the Studio window runs corpus tables")
		helpers.assert_true(controller(true, nil).on_message({ action = "studio_corpus",
			request = 1, id = "fr_swann" }) == false, "a host that cannot run a script refuses it")
	end)
end)

helpers.describe("Layout editor export step (lua-export-host)", function()
	local ExportStep = require("layouts.engine.composer.export_step")
	local Json = require("core.text.engine.json")
	local Paths = require("core.fs.engine.paths")
	local defaults = Json.decode(assert(io.open(Paths.shared("layouts/data/defaults.json"), "rb")):read("*a"))

	helpers.it("runs the shared adapter's steps on JSON text, bounded, and refuses anything else", function()
		local settings = assert(ExportStep.settings(defaults))
		local ok, output = ExportStep.run(settings, "read", '{"xml":"<keyboard/>"}')
		helpers.assert_true(ok, tostring(output))
		local result = Json.decode(output)
		helpers.assert_eq(result.ok, false, "the adapter's own refusal is passed on as it is")
		helpers.assert_eq(type(result.reason), "string")
		for _, case in ipairs({ { "write", '{"xml":""}' }, { "read", "" }, { "read", "[1]" }, { "read", "{broken" },
			{ nil, '{"xml":""}' } }) do
			local refused, code = ExportStep.run(settings, case[1], case[2])
			helpers.assert_eq(refused, false, tostring(case[1]) .. " " .. tostring(case[2]))
			helpers.assert_eq(code, "target_export_refused")
		end
		local small = { max_bytes = 8, failure = settings.failure }
		local over, code, detail = ExportStep.run(small, "read", '{"xml":"<keyboard/>"}')
		helpers.assert_eq(over, false)
		helpers.assert_eq(code, "target_export_refused")
		helpers.assert_true(detail:find("bound", 1, true) ~= nil, detail)
		helpers.assert_eq(ExportStep.settings({ source = { failures = {} } }), nil, "settings without a bound")
	end)

	helpers.it("the editor window answers lua_export with its request number, the manager refuses it", function()
		local ManagerBridge = require("layouts.engine.manager_bridge")
		local settings = assert(ExportStep.settings(defaults))
		local registry = {
			snapshot = function() return { platform = "test", installed = {} } end,
			refresh = function(on_done) on_done({}) end,
			source_export_step = function(payload, on_done) on_done(ExportStep.run(settings, payload.step, payload.input)) end,
		}
		local function controller(editor_window)
			local pushes = {}
			local instance = ManagerBridge.new({ registry = registry, editor_window = editor_window,
				push = function(name, payload) pushes[#pushes + 1] = { name = name, payload = payload }; return true end,
				strings = function() return {} end, open_url = function() end, close = function() end,
				log = function() end })
			return instance, pushes
		end
		local instance, pushes = controller(true)
		helpers.assert_true(instance.on_message({ action = "ready" }) == true)
		helpers.assert_true(pushes[1].payload.lua_export == true, "the editor window offers lua_export")
		helpers.assert_true(instance.on_message({ action = "lua_export", request = 3, step = "read",
			input = '{"xml":"<keyboard/>"}' }) == true)
		local answer = pushes[#pushes]
		helpers.assert_eq(answer.name, "luaExportResult")
		helpers.assert_eq(answer.payload.request, 3)
		helpers.assert_eq(answer.payload.ok, true)
		helpers.assert_eq(Json.decode(answer.payload.output).ok, false)
		helpers.assert_true(instance.on_message({ action = "lua_export", request = 4, step = "write", input = "{}" }) == true)
		helpers.assert_eq(pushes[#pushes].payload, { request = 4, ok = false, code = "target_export_refused",
			detail = "the export step is not read or xkb" })
		helpers.assert_true(instance.on_message({ action = "lua_export", step = "read", input = "{}" }) == false,
			"a request number is required")
		local manager, manager_pushes = controller(false)
		helpers.assert_true(manager.on_message({ action = "ready" }) == true)
		helpers.assert_true(manager_pushes[1].payload.lua_export == false)
		helpers.assert_true(manager.on_message({ action = "lua_export", request = 1, step = "read", input = "{}" }) == false)
	end)
end)
