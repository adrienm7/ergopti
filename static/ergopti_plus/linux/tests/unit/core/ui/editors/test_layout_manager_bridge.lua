--- tests/unit/core/ui/editors/test_layout_manager_bridge.lua

--- ==============================================================================
--- MODULE: Layout Manager Bridge (Linux)
--- DESCRIPTION:
--- The Linux host of the layout manager page wires the shared controller
--- (_shared/layouts/engine/manager_bridge.lua) to the WebKitGTK window, the Linux
--- registry client and xdg-open (layout-manager-bridge). These tests inject
--- each authority and pin the wiring: pushes reach the layout_manager window as
--- window.<function>(<json>), the strings are the ones strings.json declares,
--- a homepage opens through a quoted xdg-open, and close hides the window.
--- ==============================================================================

local helpers = require("tests.helpers")

local INDEX = { layouts = { { id = "ergol", name = "Ergo-L", homepage = "https://ergol.org" } } }

--- The bridge with every authority injected.
--- @return table bridge, table state, table daemon_state
local function bridge()
	local Bridge = helpers.load_module("ui.layout_manager.bridge")
	Bridge._reset()
	local state = { pushes = {}, hidden = {}, commands = {}, calls = {} }
	local daemon_state = {
		webview_manager = {
			eval_js = function(app, js) state.pushes[#state.pushes + 1] = { app = app, js = js }; return true end,
			hide = function(app) state.hidden[#state.hidden + 1] = app; return true end,
		},
		shell = {
			has_command = function(name) return name == "xdg-open" end,
			quote = function(value) return "'" .. value .. "'" end,
			run = function(command) state.commands[#state.commands + 1] = command; return true end,
		},
		i18n = { get = function(key) return "translated:" .. key end },
		layout_registry = {
			snapshot = function() return { platform = "linux", index = INDEX, installed = {}, source = "cache" } end,
			refresh = function(on_done) state.calls[#state.calls + 1] = "refresh"; on_done({}) end,
			install = function(id, on_done) state.calls[#state.calls + 1] = "install " .. id; on_done(true, {}) end,
			uninstall = function() end,
			select = function() end,
		},
	}
	return Bridge, state, daemon_state
end

helpers.describe("layout manager bridge (Linux)", function()
	helpers.it("pushes the page state into the layout_manager window (layout-manager-bridge)", function()
		local Bridge, state, daemon_state = bridge()
		helpers.assert_eq(Bridge.bridge_name, "layout_manager_bridge")
		local result = Bridge.on_message({ action = "ready" }, daemon_state)
		helpers.assert_true(result.handled)
		helpers.assert_eq(state.pushes[1].app, "layout_manager")
		helpers.assert_contains(state.pushes[1].js, "window.initData(")
		helpers.assert_contains(state.pushes[1].js, '"layout_manager.window_title":"translated:layout_manager.window_title"')
		helpers.assert_contains(state.pushes[1].js, '"platform":"linux"')
		helpers.assert_contains(state.pushes[1].js, '"shortcut_menu_path":"shortcuts/menu.lua"')
		helpers.assert_contains(state.pushes[2].js, "window.updateState(")
		helpers.assert_eq(state.calls[1], "refresh")
	end)

	helpers.it("opens the catalogue homepage through xdg-open and hides on close (layout-manager-bridge)", function()
		local Bridge, state, daemon_state = bridge()
		helpers.assert_true(Bridge.on_message({ action = "open_homepage", id = "ergol" }, daemon_state).handled)
		helpers.assert_eq(state.commands[1], "xdg-open 'https://ergol.org' >/dev/null 2>&1 &")
		helpers.assert_true(Bridge.on_message({ action = "close" }, daemon_state).handled)
		helpers.assert_eq(state.hidden[1], "layout_manager")
		helpers.assert_true(Bridge.on_message({ action = "shell", id = "ergol" }, daemon_state).handled == false,
			"an action outside the allowlist is refused")
	end)

	helpers.it("applies the layout editor's navigation layer through the layer editor's save (layout-editor-nav-apply)", function()
		local Bridge, state, daemon_state = bridge()
		local applied = {}
		daemon_state.layer_editor_bridge = {
			apply_text = function(text, given_state)
				applied[#applied + 1] = { text = text, state = given_state }
				return { saved = true, applied = true, errors = {} }
			end,
		}
		Bridge.on_message({ action = "ready" }, daemon_state)
		helpers.assert_contains(state.pushes[1].js, '"nav_apply":true')
		helpers.assert_true(Bridge.on_message({ action = "nav_save", text = "[layers]\n" }, daemon_state).handled)
		helpers.assert_eq(applied[1].text, "[layers]\n")
		helpers.assert_true(applied[1].state == daemon_state, "the daemon state reaches the save")
		local last = state.pushes[#state.pushes].js
		helpers.assert_contains(last, "window.navResult(")
		helpers.assert_contains(last, '"saved":true')
		helpers.assert_contains(last, '"applied":true')
		helpers.assert_true(Bridge.on_message({ action = "nav_save" }, daemon_state).handled == false,
			"a save without its text is refused")
		helpers.assert_eq(#applied, 1)
	end)

	helpers.it("offers no navigation layer save without the layer editor (layout-editor-nav-apply)", function()
		local Bridge, state, daemon_state = bridge()
		daemon_state.layer_editor_bridge = { }
		Bridge.on_message({ action = "ready" }, daemon_state)
		helpers.assert_contains(state.pushes[1].js, '"nav_apply":false')
		helpers.assert_true(Bridge.on_message({ action = "nav_save", text = "x" }, daemon_state).handled == false)
	end)

	--- The bridge with the composer's emulation and the editor's files.
	local function emulating_bridge(choose_ok, reload_ok)
		local Bridge, state, daemon_state = bridge()
		state.emulated, state.stored = {}, {}
		daemon_state.layout_registry.composer_emulate = function(payload, on_done)
			state.stored[#state.stored + 1] = payload
			on_done(true, nil, nil, "composed")
		end
		daemon_state.layout_registry.source_open = function(on_done) on_done({ filename = "mine.toml", text = "x" }) end
		daemon_state.layout_registry.source_save = function() end
		daemon_state.layout_emulation_preferences = {
			choose = function(id) state.emulated[#state.emulated + 1] = id; return choose_ok ~= false end,
		}
		daemon_state.layout_emulation = { reload_if_started = function() return reload_ok ~= false end }
		return Bridge, state, daemon_state
	end

	helpers.it("(lmh-001-002-emulation-reload) a changed emulated layout reloads the emulation and the tray", function()
		local Bridge, state, daemon_state = emulating_bridge()
		state.reloads, state.rebuilds = 0, 0
		daemon_state.layout_emulation = {
			status = function() return { active = true, id = "ergol" } end,
			reload_if_started = function() state.reloads = state.reloads + 1; return true end,
		}
		daemon_state.on_config_changed = function() state.rebuilds = state.rebuilds + 1 end
		daemon_state.layout_registry.snapshot = function()
			return { platform = "linux", index = INDEX, installed = { ergol = { id = "ergol" }, other = { id = "other" } }, source = "cache" }
		end
		daemon_state.layout_registry.uninstall = function(_, on_done) on_done(true, {}) end
		Bridge.on_message({ action = "ready" }, daemon_state)
		helpers.assert_true(Bridge.on_message({ action = "uninstall", id = "other" }, daemon_state).handled)
		helpers.assert_eq(state.reloads, 0, "a layout that is not emulated leaves the emulation alone")
		helpers.assert_true(Bridge.on_message({ action = "uninstall", id = "ergol" }, daemon_state).handled)
		helpers.assert_eq(state.reloads, 1, "the uninstalled emulated layout stops (it stays chosen)")
		helpers.assert_eq(state.rebuilds, 1, "the tray shows the stopped emulation")
		helpers.assert_true(Bridge.on_message({ action = "install", id = "ergol" }, daemon_state).handled)
		helpers.assert_eq(state.reloads, 2, "a reinstall resumes it")
	end)

	-- EDD-1 (maintainer, 2026-11-12): a pause stops typing, not configuration.
	helpers.it("(edd1-paused-writes) runs page commands while the daemon is paused", function()
		local Bridge, state, daemon_state = bridge()
		daemon_state.is_paused = function() return true end
		Bridge.on_message({ action = "ready" }, daemon_state)
		helpers.assert_true(Bridge.on_message({ action = "install", id = "ergol" }, daemon_state).handled ~= false)
		helpers.assert_true(#state.calls > 1, "the install ran: " .. table.concat(state.calls, ","))
	end)

	helpers.it("(lmh-004-extension-reload) a layout shipping an extension reloads the daemon", function()
		local Bridge, state, daemon_state = bridge()
		state.daemon_reloads = 0
		daemon_state.on_reload = function() state.daemon_reloads = state.daemon_reloads + 1; return true end
		daemon_state.layout_registry.snapshot = function()
			return { platform = "linux", index = INDEX, installed = { ergol = { id = "ergol", extension = { root = "x" } } }, source = "cache" }
		end
		daemon_state.layout_registry.uninstall = function(_, on_done) on_done(true, {}) end
		Bridge.on_message({ action = "ready" }, daemon_state)
		helpers.assert_true(Bridge.on_message({ action = "uninstall", id = "ergol" }, daemon_state).handled)
		helpers.assert_eq(state.daemon_reloads, 1, "the uninstalled extension's hotstrings go through a reload")
	end)

	helpers.it("(lmh-005-emulate-tray) emulating without installing rebuilds the tray", function()
		local Bridge, state, daemon_state = emulating_bridge()
		state.rebuilds = 0
		daemon_state.on_config_changed = function() state.rebuilds = state.rebuilds + 1 end
		Bridge.on_message({ action = "ready" }, daemon_state)
		helpers.assert_true(Bridge.on_message({ action = "composer_emulate", source = "src", keylayout = "<k/>" }, daemon_state).handled)
		helpers.assert_eq(state.rebuilds, 1, "the tray ticks the newly emulated layout")
	end)

	helpers.it("emulates a source without installing it (layout-editor-emulate)", function()
		local Bridge, state, daemon_state = emulating_bridge()
		Bridge.on_message({ action = "ready" }, daemon_state)
		helpers.assert_contains(state.pushes[1].js, '"emulate":true')
		local message = { action = "composer_emulate", source = "src", keylayout = "<k/>", emulation = "{}" }
		helpers.assert_true(Bridge.on_message(message, daemon_state).handled)
		helpers.assert_eq(state.stored, { { source = "src", keylayout = "<k/>", emulation = "{}" } })
		helpers.assert_eq(state.emulated, { "composed" }, "the composed layout becomes the emulated one")
		local result = nil
		for _, push in ipairs(state.pushes) do
			if push.js:find("window.composerResult(", 1, true) then result = push.js end
		end
		helpers.assert_contains(result, '"action":"composer_emulate"')
		helpers.assert_contains(result, '"ok":true')
		helpers.assert_true(Bridge.on_message({ action = "composer_emulate", keylayout = "<k/>" }, daemon_state).handled
			== false, "an emulation without its source is refused")
	end)

	helpers.it("reports an emulation the settings or the engine refused (layout-editor-emulate)", function()
		for _, case in ipairs({ { false, true, "emulate_not_saved" }, { true, false, "emulate_failed" } }) do
			local Bridge, state, daemon_state = emulating_bridge(case[1], case[2])
			Bridge.on_message({ action = "ready" }, daemon_state)
			Bridge.on_message({ action = "composer_emulate", source = "src", keylayout = "<k/>" }, daemon_state)
			local last = state.pushes[#state.pushes - 1].js
			helpers.assert_contains(last, '"ok":false')
			helpers.assert_contains(last, '"code":"' .. case[3] .. '"')
		end
	end)

	helpers.it("offers no emulation without the emulation preferences (layout-editor-emulate)", function()
		local Bridge, state, daemon_state = emulating_bridge()
		daemon_state.layout_emulation_preferences = {}
		Bridge.on_message({ action = "ready" }, daemon_state)
		helpers.assert_contains(state.pushes[1].js, '"emulate":false')
		helpers.assert_true(Bridge.on_message({ action = "composer_emulate", source = "s", keylayout = "k" },
			daemon_state).handled == false)
		helpers.assert_eq(#state.stored, 0)
	end)

	helpers.it("the editor window answers its ready with the last saved source (layout-editor-own-window)", function()
		local Bridge, state, daemon_state = emulating_bridge()
		local Editor = Bridge.editor
		Editor._reset()
		helpers.assert_eq(Editor.bridge_name, "layout_editor_window_bridge")
		local calls = #state.calls
		helpers.assert_true(Editor.on_message({ action = "ready" }, daemon_state).handled)
		helpers.assert_eq(state.pushes[1].app, "layout_editor_window", "the editor window receives its own pushes")
		helpers.assert_contains(state.pushes[1].js, "window.initData(")
		helpers.assert_contains(state.pushes[1].js, '"layout_editor.title":"translated:layout_editor.title"')
		helpers.assert_contains(state.pushes[#state.pushes].js, "window.sourceData(")
		helpers.assert_contains(state.pushes[#state.pushes].js, '"filename":"mine.toml"')
		helpers.assert_eq(#state.calls, calls, "the editor window fetches no catalogue")
		Editor._reset()
	end)

	helpers.it("the manager's « Layout editor » shows the editor window (layout-editor-own-window)", function()
		local Bridge, state, daemon_state = emulating_bridge()
		local shown = {}
		daemon_state.webview_manager.show = function(app) shown[#shown + 1] = app; return true end
		Bridge.on_message({ action = "ready" }, daemon_state)
		helpers.assert_true(Bridge.on_message({ action = "open_editor" }, daemon_state).handled)
		helpers.assert_eq(shown, { "layout_editor_window" })
		for _, push in ipairs(state.pushes) do
			helpers.assert_true(not push.js:find("window.sourceData(", 1, true), "the manager page receives no source")
		end
	end)
end)

helpers.describe("Ergopti Studio links (Linux)", function()
	helpers.it("the Studio window opens an https link through xdg-open (studio-open-link)", function()
		local Bridge, state, daemon_state = bridge()
		daemon_state.layout_registry.source_open = function(on_done) on_done({ filename = "mine.toml", text = "x" }) end
		daemon_state.layout_registry.source_save = function() end
		local Editor = Bridge.editor
		Editor._reset()
		local ok, err = pcall(function()
			helpers.assert_true(Editor.on_message({ action = "ready" }, daemon_state).handled)
			helpers.assert_true(Editor.on_message({ action = "open_link", url = "https://ergopti.fr/studio" }, daemon_state).handled)
			helpers.assert_eq(state.commands[#state.commands], "xdg-open 'https://ergopti.fr/studio' >/dev/null 2>&1 &")
			helpers.assert_true(Editor.on_message({ action = "open_link", url = "file:///etc/passwd" }, daemon_state).handled == false)
			helpers.assert_eq(#state.commands, 1, "a non-https link is never opened")
		end)
		Editor._reset()
		helpers.assert_true(ok, tostring(err))
	end)
end)

helpers.describe("Ergopti Studio personal layouts (Linux bridge)", function()
	helpers.it("forwards the Studio's layout store to the registry with the page's requests with their number", function()
		local Bridge, state, daemon_state = bridge()
		daemon_state.layout_registry.source_open = function(on_done) on_done({ filename = "mine.toml", text = "x" }) end
		daemon_state.layout_registry.source_save = function() end
		local saved = {}
		daemon_state.layout_registry.studio_list = function(on_done) on_done(true, { '{"id":"user_a"}' }) end
		daemon_state.layout_registry.studio_save = function(payload, on_done) saved[#saved + 1] = payload; on_done(true, nil, payload.id) end
		daemon_state.layout_registry.studio_remove = function(payload, on_done) on_done(true, nil, payload.id) end
		daemon_state.layout_registry.studio_profile_load = function(on_done) on_done(true, nil) end
		daemon_state.layout_registry.studio_profile_save = function(payload, on_done) saved[#saved + 1] = payload; on_done(true) end
		local Editor = Bridge.editor
		Editor._reset()
		local ok, err = pcall(function()
			helpers.assert_true(Editor.on_message({ action = "ready" }, daemon_state).handled)
			helpers.assert_contains(state.pushes[1].js, '"studio_store":true')
			helpers.assert_true(Editor.on_message({ action = "studio_layouts", request = 2 }, daemon_state).handled)
			helpers.assert_contains(state.pushes[#state.pushes].js, "window.studioLayouts(")
			helpers.assert_contains(state.pushes[#state.pushes].js, '"request":2')
			helpers.assert_true(Editor.on_message({ action = "studio_layout_save", request = 3, id = "user_a",
				text = '{"id":"user_a"}' }, daemon_state).handled)
			helpers.assert_eq(saved, { { id = "user_a", text = '{"id":"user_a"}' } })
			helpers.assert_contains(state.pushes[#state.pushes].js, "window.studioLayoutResult(")
			helpers.assert_true(Editor.on_message({ action = "studio_profile_save", request = 4,
				text = '{"id":"mine"}' }, daemon_state).handled)
			helpers.assert_eq(saved[#saved], { text = '{"id":"mine"}', reset = false })
			helpers.assert_contains(state.pushes[#state.pushes].js, "window.studioProfileResult(")
			helpers.assert_true(Editor.on_message({ action = "studio_profile_load", request = 5 }, daemon_state).handled)
			helpers.assert_contains(state.pushes[#state.pushes].js, "window.studioProfile(")
		end)
		Editor._reset()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("forwards the editor's export step to the registry and answers it (lua-export-host)", function()
		local Bridge, state, daemon_state = bridge()
		daemon_state.layout_registry.source_open = function(on_done) on_done({ filename = "mine.toml", text = "x" }) end
		daemon_state.layout_registry.source_save = function() end
		local asked
		daemon_state.layout_registry.source_export_step = function(payload, on_done)
			asked = payload
			on_done(true, '{"ok":true}')
		end
		local Editor = Bridge.editor
		Editor._reset()
		local ok, err = pcall(function()
			helpers.assert_true(Editor.on_message({ action = "ready" }, daemon_state).handled)
			helpers.assert_contains(state.pushes[1].js, '"lua_export":true')
			helpers.assert_true(Editor.on_message({ action = "lua_export", request = 9, step = "xkb", input = '{"a":1}' },
				daemon_state).handled)
			helpers.assert_eq(asked, { step = "xkb", input = '{"a":1}' })
			helpers.assert_contains(state.pushes[#state.pushes].js, "window.luaExportResult(")
			helpers.assert_contains(state.pushes[#state.pushes].js, '"request":9')
		end)
		Editor._reset()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("runs the chosen corpus's generated tables in the Studio page, then answers (studio-corpus-tables)", function()
		local Bridge, state, daemon_state = bridge()
		daemon_state.layout_registry.source_open = function(on_done) on_done({ filename = "mine.toml", text = "x" }) end
		daemon_state.layout_registry.source_save = function() end
		daemon_state.layout_registry.studio_corpus = function(payload, on_done)
			on_done(true, "var LAYOUT_ANALYSIS_CORPORA = {}; // " .. payload.id, "studio_corpus_unavailable")
		end
		local Editor = Bridge.editor
		Editor._reset()
		local ok, err = pcall(function()
			helpers.assert_true(Editor.on_message({ action = "ready" }, daemon_state).handled)
			local before = #state.pushes
			helpers.assert_true(Editor.on_message({ action = "studio_corpus", request = 7, id = "fr_swann" }, daemon_state).handled)
			helpers.assert_eq(#state.pushes, before + 2)
			helpers.assert_eq(state.pushes[before + 1].js, "var LAYOUT_ANALYSIS_CORPORA = {}; // fr_swann",
				"the tables run as shipped, before the answer")
			helpers.assert_contains(state.pushes[before + 2].js, "window.studioCorpus(")
			helpers.assert_contains(state.pushes[before + 2].js, '"request":7')
		end)
		Editor._reset()
		helpers.assert_true(ok, tostring(err))
	end)
end)

helpers.describe("Ergopti Studio keystats bridge (Linux)", function()
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

	local StudioNgrams = require("metrics.engine.view.studio_ngrams")

	helpers.it("projects physical keystrokes only and refuses an absent or partial store (studio-keystats-bridge)", function()
		local payload = StudioNgrams.project({
			c = { a = { c = 10, hs = 3, llm = 1, o = 1 }, b = { c = 2, hs = 2 }, [""] = { c = 4 } },
			bg = { ab = { c = 5 } },
			tg = { abc = { c = 1, llm = 1 } },
		})
		helpers.assert_eq(payload.schema, StudioNgrams.SCHEMA)
		helpers.assert_eq(payload.source, "keystats")
		helpers.assert_eq(payload.chars, { a = 5 }, "synthetic sources are not keystrokes")
		helpers.assert_eq(payload.bigrams, { ab = 5 })
		helpers.assert_eq(payload.trigrams, {})
		helpers.assert_eq(payload.total, 5)
		local function read(exists, dict, complete)
			return StudioNgrams.read({ path = "/db.sqlite", exists = function() return exists end,
				read = function() return dict, complete end })
		end
		helpers.assert_eq(read(false, {}, true), { ok = false, code = "keystats_absent" })
		helpers.assert_eq(read(true, { c = {} }, false), { ok = false, code = "keystats_unreadable" },
			"a partial read is never offered as the user's data")
		helpers.assert_eq(StudioNgrams.read({ path = "/db.sqlite", exists = function() return true end,
			read = function() error("database is locked") end }), { ok = false, code = "keystats_unreadable" })
		helpers.assert_eq(StudioNgrams.read({ path = nil, exists = function() return true end,
			read = function() return {}, true end }), { ok = false, code = "keystats_absent" })
		helpers.assert_true(read(true, { c = {}, bg = {}, tg = {} }, true).ok)
	end)

	helpers.it("keeps the projection while the store's revision is unchanged (studio-keystats-bridge)", function()
		StudioNgrams.reset_cache()
		local reads, rev = 0, "7"
		local deps = { path = "/db.sqlite", exists = function() return true end,
			stamp = function() return rev end,
			read = function() reads = reads + 1; return { c = { e = { c = reads } } }, true end }
		local first = StudioNgrams.read(deps)
		helpers.assert_eq(first.ngrams.chars, { e = 1 })
		helpers.assert_true(first.cached == false)
		local second = StudioNgrams.read(deps)
		helpers.assert_true(second.cached == true, "an unchanged revision is not read again")
		helpers.assert_eq(reads, 1)
		rev = "8"
		helpers.assert_eq(StudioNgrams.read(deps).ngrams.chars, { e = 2 }, "a new ingest is read")
		deps.stamp = function() return nil end
		helpers.assert_eq(StudioNgrams.read(deps).ngrams.chars, { e = 3 }, "no revision, no cache")
		helpers.assert_eq(StudioNgrams.read(deps).ngrams.chars, { e = 4 })
		deps.stamp = function() return "8" end
		deps.exists = function() return false end
		helpers.assert_eq(StudioNgrams.read(deps).code, "keystats_absent", "a removed store is never answered from the cache")
		StudioNgrams.reset_cache()
	end)

	helpers.it("the Studio window answers keystats_ngrams with the store's counts, the manager refuses it (studio-keystats-bridge)", function()
		local Bridge, state, daemon_state = bridge()
		daemon_state.layout_registry.source_open = function(on_done) on_done({ filename = "mine.toml", text = "x" }) end
		daemon_state.layout_registry.source_save = function() end
		local read_paths = {}
		daemon_state.config_paths = { metrics_path = function() return "/home/u/.config/ergopti/metrics.sqlite" end }
		local revision = 7
		daemon_state.keystats_writer = { get_revision = function() return revision end }
		daemon_state.keystats_reader = {
			read_studio_ngrams = function(path)
				read_paths[#read_paths + 1] = path
				return { c = { e = { c = 7 } }, bg = {}, tg = {} }, true
			end,
		}
		local saved_fs = package.loaded["core.fs.adapters.file_system"]
		StudioNgrams.reset_cache()
		local ok, err = pcall(function()
			local FileSystem = require("core.fs.adapters.file_system")
			local native_exists = FileSystem.exists
			FileSystem.exists = function(path) return path == "/home/u/.config/ergopti/metrics.sqlite" end
			local Editor = Bridge.editor
			Editor._reset()
			local done, inner = pcall(function()
				helpers.assert_true(Editor.on_message({ action = "ready" }, daemon_state).handled)
				helpers.assert_contains(state.pushes[1].js, '"keystats":true')
				helpers.assert_true(Editor.on_message({ action = "keystats_ngrams" }, daemon_state).handled)
				local last = state.pushes[#state.pushes]
				helpers.assert_eq(last.app, "layout_editor_window", "the counts reach the Studio window alone")
				helpers.assert_contains(last.js, "window.keystatsNgrams(")
				helpers.assert_contains(last.js, '"ok":true')
				helpers.assert_contains(last.js, '"chars":{"e":7}')
				helpers.assert_eq(read_paths, { "/home/u/.config/ergopti/metrics.sqlite" })
				helpers.assert_true(Editor.on_message({ action = "keystats_ngrams" }, daemon_state).handled)
				helpers.assert_contains(state.pushes[#state.pushes].js, '"chars":{"e":7}')
				helpers.assert_eq(#read_paths, 1, "an unchanged revision answers from the cache")
				revision = 8
				helpers.assert_true(Editor.on_message({ action = "keystats_ngrams" }, daemon_state).handled)
				helpers.assert_eq(#read_paths, 2, "a new ingest is read again")
				FileSystem.exists = function() return false end
				helpers.assert_true(Editor.on_message({ action = "keystats_ngrams" }, daemon_state).handled)
				helpers.assert_contains(state.pushes[#state.pushes].js, '"code":"keystats_absent"')
				helpers.assert_eq(#read_paths, 2, "an absent store is not opened")
			end)
			FileSystem.exists = native_exists
			Editor._reset()
			if not done then error(inner, 0) end
			Bridge.on_message({ action = "ready" }, daemon_state)
			helpers.assert_true(Bridge.on_message({ action = "keystats_ngrams" }, daemon_state).handled == false,
				"the layout manager window does not read keystats")
		end)
		package.loaded["core.fs.adapters.file_system"] = saved_fs
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("reads the three Studio families read only from a real store (studio-keystats-bridge)", function()
		local shell = io.popen("command -v sqlite3 2>/dev/null")
		local found = shell and shell:read("*a") or ""
		if shell then shell:close() end
		-- CI installs sqlite3 for this suite (ci-linux.yml); a missing binary fails here.
		helpers.assert_true(found ~= "", "sqlite3 must be installed to run the Linux reader on a real store")
		local dir = os.tmpname()
		os.remove(dir)
		local path = dir .. ".sqlite"
		local schema = assert(io.open(require("core.fs.engine.paths").shared("metrics/data/db/schema.sql"), "rb")):read("*a")
		local sql = schema .. [[
INSERT INTO ngram_chars(device_id, date, app, token, c, esrc_json) VALUES ('d1', '2026-11-01', 'App', 'e', 9, '{"hotstring":2}');
INSERT INTO ngram_chars(device_id, date, app, token, c, esrc_json) VALUES ('d2', '2026-11-02', 'Other', 'e', 3, '{}');
INSERT INTO ngram_bigrams(device_id, date, app, token, c, esrc_json) VALUES ('d1', '2026-11-01', 'App', 'es', 4, '{}');
INSERT INTO ngram_trigrams(device_id, date, app, token, c, esrc_json) VALUES ('d1', '2026-11-01', 'App', 'est', 2, '{}');
INSERT INTO ngram_words(device_id, date, app, token, c, esrc_json) VALUES ('d1', '2026-11-01', 'App', 'est', 2, '{}');
INSERT OR REPLACE INTO meta(key, value) VALUES ('rev', '42');
]]
		local writer = assert(io.popen("sqlite3 '" .. path .. "' >/dev/null", "w"))
		writer:write(sql)
		writer:close()
		local saved = package.loaded["modules.keystats.sqlite_reader"]
		package.loaded["modules.keystats.sqlite_reader"] = nil
		local ok, err = pcall(function()
			local Reader = require("modules.keystats.sqlite_reader")
			local dict, complete = Reader.read_studio_ngrams(path)
			helpers.assert_true(complete, "every Studio family was read")
			helpers.assert_eq(dict.c.e.c, 12, "every device and app is summed")
			helpers.assert_eq(dict.c.e.hs, 2)
			helpers.assert_eq(dict.bg.es.c, 4)
			helpers.assert_eq(dict.tg.est.c, 2)
			helpers.assert_nil(dict.w, "the other families are not read")
			local payload = StudioNgrams.project(dict)
			helpers.assert_eq(payload.chars, { e = 10 })
			local _, missing_complete = Reader.read_studio_ngrams(dir .. "-absent.sqlite")
			helpers.assert_true(missing_complete == false, "a read-only open never creates the store")
			local probe = io.open(dir .. "-absent.sqlite", "rb")
			helpers.assert_nil(probe, "the absent store stays absent")
		end)
		package.loaded["modules.keystats.sqlite_reader"] = saved
		os.remove(path)
		helpers.assert_true(ok, tostring(err))
	end)
end)

helpers.describe("layout editor menu row (Linux)", function()
	helpers.it("« Create or edit a layout… » shows the layout editor's own window (layout-editor-own-window)", function()
		local saved = { bridge = package.loaded["ui.layout_manager.bridge"], builder = package.loaded["ui.menu.builder"] }
		local calls = {}
		package.loaded["ui.layout_manager.bridge"] = {
			open_editor_window = function(manager) return manager.show("layout_editor_window") end,
		}
		package.loaded["ui.menu.builder"] = nil
		local ok, err = pcall(function()
			local module = helpers.load_module("ui.menu.builder")
			local items = module.build({ webview = { show = function(name)
				calls[#calls + 1] = "show " .. name
				return true
			end } })
			local I18n = require("core.i18n.engine.i18n")
			local row = nil
			for _, top in ipairs(items) do
				if top.title == I18n.get("menu.layout.title") then
					for _, child in ipairs(top.menu) do
						if child.title == I18n.get("menu.layout.edit") then row = child end
					end
				end
			end
			helpers.assert_eq(type(row), "table", "the row reaches the tray")
			helpers.assert_eq(type(row.fn), "function")
			row.fn()
		end)
		package.loaded["ui.layout_manager.bridge"], package.loaded["ui.menu.builder"] = saved.bridge, saved.builder
		helpers.assert_true(ok, tostring(err))
		helpers.assert_eq(calls, { "show layout_editor_window" })
	end)

	helpers.it("the top-level « Ergopti Studio » row shows the layout editor's own window (ergopti-studio-menu-row)", function()
		local saved = { bridge = package.loaded["ui.layout_manager.bridge"], builder = package.loaded["ui.menu.builder"],
			studio = package.loaded["ui.menu.menu_ergopti_studio"] }
		local calls = {}
		package.loaded["ui.layout_manager.bridge"] = {
			open_editor_window = function(manager) return manager.show("layout_editor_window") end,
		}
		package.loaded["ui.menu.builder"], package.loaded["ui.menu.menu_ergopti_studio"] = nil, nil
		local ok, err = pcall(function()
			local module = helpers.load_module("ui.menu.builder")
			local items = module.build({ webview = { show = function(name)
				calls[#calls + 1] = "show " .. name
				return true
			end } })
			local I18n = require("core.i18n.engine.i18n")
			local studio, layout_index, studio_index = nil, nil, nil
			for index, top in ipairs(items) do
				if top.title == I18n.get("menu.layout.title") then layout_index = index end
				if top.title == I18n.get("menu.studio.title") then studio, studio_index = top, index end
			end
			helpers.assert_eq(type(studio), "table", "the Ergopti Studio row reaches the tray root")
			helpers.assert_eq(studio_index, layout_index + 1, "the row follows the keyboard layout group")
			helpers.assert_eq(studio.menu, nil, "the row is a command, not a submenu")
			helpers.assert_eq(type(studio.fn), "function")
			studio.fn()
		end)
		package.loaded["ui.layout_manager.bridge"], package.loaded["ui.menu.builder"] = saved.bridge, saved.builder
		package.loaded["ui.menu.menu_ergopti_studio"] = saved.studio
		helpers.assert_true(ok, tostring(err))
		helpers.assert_eq(calls, { "show layout_editor_window" })
	end)
end)

--- Captures actual provider data while forwarding its status and rendering to the real binding.
--- @param callback function Receives the native build, fixture state and binding.
local function with_empty_layout(callback)
	local names = { "ui.menu.builder", "infra.manifest_menu", "core.i18n.engine.i18n", "modules.keymap.layout_registry" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	local ok, err = xpcall(function()
		local state = { selections = 0, installed = false }
		package.loaded["modules.keymap.layout_registry"] = {
			snapshot = function()
				return { installed = state.installed and { { id = "native", name = "Native layout" } } or {}, active = "native" }
			end,
			select = function() state.selections = state.selections + 1; return true end,
		}
		local binding = require("infra.manifest_menu")
		local module = helpers.load_module("ui.menu.builder")
		local native_build = binding.build
		binding.build = function(key, title, dynamic, click, ctx, providers)
			if key == "layout_menu" then
				local provider = providers.custom_layouts
				providers.custom_layouts = function()
					state.data = provider()
					return state.data
				end
			end
			return native_build(key, title, dynamic, click, ctx, providers)
		end
		callback(function()
			local items = module.build({})
			for _, row in ipairs(items) do
				if row.title == require("core.i18n.engine.i18n").get("menu.layout.title") then
					helpers.assert_eq(type(row.menu), "table")
					return row.menu
				end
			end
			error("The actual layout submenu must reach the tray.")
		end, state, binding)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

-- Independent pre-migration captions; the generated status declaration is the subject.
local EmptyLayoutJson = require("core.text.engine.json")
local function read_empty_layout_json(path)
	local file = assert(io.open(path, "rb"))
	local value = assert(EmptyLayoutJson.decode(file:read("*a")))
	file:close()
	return value
end

local EmptyLayoutCorpus = read_empty_layout_json(require("core.fs.engine.paths").shared("tests/corpus/menu/layout_empty_status.json"))

local function empty_layout_owner(binding)
	for _, row in ipairs(binding.get_array(EmptyLayoutCorpus.section)) do
		if row.id == EmptyLayoutCorpus.provider then return row end
	end
	error("The actual custom-layout provider declaration must exist.")
end

local function count_empty_layout_caption(rows, title)
	local count = 0
	for _, row in ipairs(rows or {}) do
		if row.title == title then
			count = count + 1
			helpers.assert_eq(row.disabled, true)
			helpers.assert_nil(row.fn)
			helpers.assert_nil(row.menu)
		end
	end
	return count
end

helpers.describe("the shared empty native-layout status", function()
	helpers.it("(layout-empty-status) retains the independent inert declaration", function()
		with_empty_layout(function(_, state, binding)
			helpers.assert_eq(empty_layout_owner(binding).status_rows[EmptyLayoutCorpus.status], { EmptyLayoutCorpus.row })
			local count = 0
			for _ in pairs(EmptyLayoutCorpus.captions) do count = count + 1 end
			helpers.assert_eq(count, 21)
			helpers.assert_eq(state.selections, 0)
		end)
	end)

	for locale, expected in pairs(EmptyLayoutCorpus.captions) do
		helpers.it("(layout-empty-status) renders the real empty provider in " .. locale, function()
			with_empty_layout(function(build, state, binding)
				local catalogue = read_empty_layout_json(require("core.fs.engine.paths").shared("core/i18n/data/locales/" .. locale .. ".json"))
				helpers.assert_eq(catalogue[EmptyLayoutCorpus.row.i18n], expected)
				require("core.i18n.engine.i18n").get = function(key) return catalogue[key] or key end
				local rows = build()
				helpers.assert_eq(state.data, { { label = expected, disabled = true } })
				helpers.assert_eq(count_empty_layout_caption(rows, expected), 1)
				helpers.assert_eq(state.selections, 0)
				local declaration = empty_layout_owner(binding).status_rows[EmptyLayoutCorpus.status][1]
				declaration.i18n = "menu.layout.manage"
				build()
				helpers.assert_eq(state.data, { { label = catalogue["menu.layout.manage"], disabled = true } },
					"The native provider consumes the live declaration, not a repeated native caption.")
			end)
		end)
	end

	for _, invalid in ipairs({ "missing", "empty", "command", "effectful_label" }) do
		helpers.it("(layout-empty-status) refuses the empty caption after " .. invalid, function()
			with_empty_layout(function(build, state, binding)
				local statuses = empty_layout_owner(binding).status_rows
				local baseline = build()
				local caption = require("core.i18n.engine.i18n").get(EmptyLayoutCorpus.row.i18n)
				helpers.assert_eq(count_empty_layout_caption(baseline, caption), 1)
				local bad = {
					empty = {}, command = { { type = "command", id = "layout_manager", i18n = "menu.layout.manage" } },
					effectful_label = { { type = "label", i18n = EmptyLayoutCorpus.row.i18n, action = "layout_manager" } },
				}
				statuses[EmptyLayoutCorpus.status] = bad[invalid]
				local rows = build()
				helpers.assert_eq(state.data, {})
				helpers.assert_eq(count_empty_layout_caption(rows, caption), 0)
				helpers.assert_eq(state.selections, 0)
			end)
		end)
	end

	helpers.it("(layout-empty-status) refuses an unavailable status-renderer port", function()
		with_empty_layout(function(build, state, binding)
			build()
			helpers.assert_eq(#state.data, 1)
			binding.status_rows = nil
			build()
			helpers.assert_eq(state.data, {})
			helpers.assert_eq(state.selections, 0)
		end)
	end)

	helpers.it("(layout-empty-status) leaves installed native layout data actionable", function()
		with_empty_layout(function(build, state, binding)
			state.installed = true
			empty_layout_owner(binding).status_rows[EmptyLayoutCorpus.status] = nil
			build()
			helpers.assert_eq(#state.data, 1)
			helpers.assert_eq(state.data[1].label, "Native layout")
			helpers.assert_eq(state.data[1].checked, true)
			helpers.assert_eq(type(state.data[1].action), "function")
			helpers.assert_true(state.data[1].disabled ~= true)
			helpers.assert_eq(state.selections, 0)
		end)
	end)
end)


--- Keeps native page epochs and asynchronous registry receipts independent.
--- @return table bridge, table observations, table daemon, function advance
local function owned_layout_bridge()
	local Bridge, observed, daemon = bridge()
	local epoch, refreshes, installs = 1, {}, {}
	daemon.webview_manager.current_epoch = function() return epoch end
	daemon.webview_manager.page_current = function(app, expected) return app == "layout_manager" and epoch == expected end
	daemon.layout_registry.refresh = function(callback) refreshes[#refreshes + 1] = callback end
	daemon.layout_registry.install = function(_, callback) installs[#installs + 1] = callback end
	local snapshot = daemon.layout_registry.snapshot
	observed.snapshot_reads = 0
	daemon.layout_registry.snapshot = function()
		observed.snapshot_reads = observed.snapshot_reads + 1
		return snapshot()
	end
	observed.refreshes, observed.installs = refreshes, installs
	return Bridge, observed, daemon, function(next_epoch) epoch = next_epoch end
end

helpers.describe("layout manager native page ownership", function()
	for _, operation in ipairs({ "refresh", "install" }) do
		helpers.it("(layout-retired-owner) old " .. operation .. " completion cannot reach a replacement", function()
			local Bridge, observed, daemon, advance = owned_layout_bridge()
			Bridge.on_message({ action = "ready" }, daemon, { app_name = "layout_manager", epoch = 1 })
			if operation == "install" then
				Bridge.on_message({ action = "install", id = "ergol" }, daemon, { app_name = "layout_manager", epoch = 1 })
			end
			-- The real WebKit manager calls this optional lifecycle hook on close.
			if type(Bridge.on_window_closed) == "function" then Bridge.on_window_closed(1) end
			advance(2)
			Bridge.on_message({ action = "ready" }, daemon, { app_name = "layout_manager", epoch = 2 })
			local pushes, reads = #observed.pushes, observed.snapshot_reads
			if operation == "install" then observed.installs[1](true, {}) else observed.refreshes[1]({}) end
			local expected = pushes
			if operation == "install" then
				expected = pushes + 1
				helpers.assert_eq(#observed.pushes, expected, "The new ready observer receives fresh global registry state")
				local body = assert(observed.pushes[expected].js:match("window%.updateState%((.*)%)$"))
				helpers.assert_nil(assert(EmptyLayoutJson.decode(body)).result,
					"A fresh global snapshot must not forward the retired page's operation result")
			else
				helpers.assert_eq(#observed.pushes, pushes, "An old catalogue response has no publication authority")
				helpers.assert_eq(observed.snapshot_reads, reads, "Retired refresh callbacks must not read a replacement snapshot")
			end
			observed.refreshes[2]({})
			helpers.assert_eq(#observed.pushes, expected + 1, "The new page's own refresh must still complete")
		end)
	end

	helpers.it("(layout-retired-owner) an old close notification cannot revoke the live page", function()
		local Bridge, observed, daemon, advance = owned_layout_bridge()
		Bridge.on_message({ action = "ready" }, daemon, { app_name = "layout_manager", epoch = 1 })
		advance(2)
		Bridge.on_message({ action = "ready" }, daemon, { app_name = "layout_manager", epoch = 2 })
		if type(Bridge.on_window_closed) == "function" then Bridge.on_window_closed(1) end
		local pushes = #observed.pushes
		observed.refreshes[2]({})
		helpers.assert_eq(#observed.pushes, pushes + 1)
	end)

	helpers.it("(layout-retired-owner) stale native requests never dispatch registry work", function()
		local Bridge, observed, daemon, advance = owned_layout_bridge()
		Bridge.on_message({ action = "ready" }, daemon, { app_name = "layout_manager", epoch = 1 })
		advance(2)
		local pushes = #observed.pushes
		local result = Bridge.on_message({ action = "install", id = "ergol" }, daemon,
			{ app_name = "layout_manager", epoch = 1 })
		helpers.assert_eq(result.handled, false)
		helpers.assert_eq(#observed.installs, 0)
		helpers.assert_eq(#observed.pushes, pushes)
	end)
end)

helpers.describe("layout manager native admission refusals", function()
	helpers.it("(layout-retired-owner) missing, refused or throwing native ownership cannot borrow a controller", function()
		for _, kind in ipairs({ "missing", "refused", "throwing" }) do
			local Bridge, observed, daemon = owned_layout_bridge()
			if kind == "missing" then daemon.webview_manager.page_current = nil
			elseif kind == "refused" then daemon.webview_manager.page_current = function() return false end
			else daemon.webview_manager.page_current = function() error("native owner unavailable") end end
			local result = Bridge.on_message({ action = "install", id = "ergol" }, daemon,
				{ app_name = "layout_manager", epoch = 1 })
			helpers.assert_eq(result.handled, false)
			helpers.assert_eq(#observed.installs, 0)
			helpers.assert_eq(observed.snapshot_reads, 0)
			helpers.assert_eq(#observed.pushes, 0)
		end
	end)
end)


helpers.describe("layout manager observes global operation settlement", function()
	helpers.it("(layout-retired-owner) a replacement ready clears completed global busy without the old result", function()
		local Bridge, observed, daemon, advance = owned_layout_bridge()
		local busy = { id = "ergol", action = "install" }
		local snapshot = daemon.layout_registry.snapshot
		daemon.layout_registry.snapshot = function()
			local state = snapshot()
			state.busy = busy
			return state
		end
		Bridge.on_message({ action = "install", id = "ergol" }, daemon, { app_name = "layout_manager", epoch = 1 })
		if type(Bridge.on_window_closed) == "function" then Bridge.on_window_closed(1) end
		advance(2)
		Bridge.on_message({ action = "ready" }, daemon, { app_name = "layout_manager", epoch = 2 })
		local before = #observed.pushes
		busy = nil
		observed.installs[1](false, "old operation failure")
		helpers.assert_eq(#observed.pushes, before + 1)
		local body = assert(observed.pushes[#observed.pushes].js:match("window%.updateState%((.*)%)$"))
		local update = assert(EmptyLayoutJson.decode(body))
		helpers.assert_nil(update.busy, "The replacement must not remain disabled after the global operation settles")
		helpers.assert_nil(update.result, "The old page's failure is not the replacement's operation result")
		observed.installs[1](true, {})
		helpers.assert_eq(#observed.pushes, before + 1, "A duplicate native terminal cannot republish into the observer")
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
