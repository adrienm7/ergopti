--- tests/unit/platform/system/test_tray_menu_adapter.lua

--- ==============================================================================
--- MODULE: TrayMenu Adapter — behaviour with and without a backend
--- DESCRIPTION:
--- What the port-facing adapter does on a machine that can host a tray, and on
--- one that cannot.
---
--- WHY BOTH HALVES MATTER:
--- The daemon calls setIcon, setMenu and pump unconditionally, from the event
--- loop, on every machine. A headless server, a TTY session and a desktop
--- missing libayatana all reach this code — and hotstring expansion has nothing
--- to do with having a tray, so none of them may be turned into a crash or a
--- stall. Equally, a machine that CAN host one must actually get the menu: the
--- previous adapter degraded so gracefully that it degraded on every machine and
--- nobody noticed for the life of the driver.
--- ==============================================================================

local helpers = require("tests.helpers")
-- Every case installs its own indicator double; the module end puts the real
-- entries back so no later module meets the double.
local restore_loaded = helpers.keep_loaded({ "tray.adapters.appindicator", "tray.adapters.menu",
	"core.i18n.engine.i18n", "tray.protocol", "core.logger.engine.shim" })

--- Installs a stand-in indicator and loads the adapter over it.
--- @param available boolean Whether the machine can host a tray.
--- @return table adapter, table log
local function with_indicator(available)
	local log = { menus = {}, icons = {}, pumps = 0, created = nil, destroyed = 0 }
	package.loaded["tray.adapters.appindicator"] = {
		is_available = function() return available end,
		create = function(id, icon, title, description)
			if not available then return false end
			log.created = { id = id, icon = icon, title = title, description = description }
			return true
		end,
		set_menu = function(items) log.menus[#log.menus + 1] = items ; return true end,
		set_icon = function(icon, description)
			log.icons[#log.icons + 1] = icon
			log.descriptions = log.descriptions or {}
			log.descriptions[#log.icons] = description
			return true
		end,
		pump = function() log.pumps = log.pumps + 1 ; return 0 end,
		destroy = function() log.destroyed = log.destroyed + 1 end,
		is_live = function() return log.created ~= nil end,
	}
	return helpers.load_module("tray.adapters.menu"), log
end





-- =================================================================
-- =================================================================
-- ======= 1/ On a machine that can host a tray ====================
-- =================================================================
-- =================================================================

helpers.describe("tray_menu: with a backend", function()

	helpers.it("creates the icon on first use and reports the backend", function()
		local tray, log = with_indicator(true)
		tray.setMenu({ { title = "Quitter", fn = function() end } })
		helpers.assert_true(log.created ~= nil, "the first setMenu brings the icon up")
		helpers.assert_eq(tray.getBackend(), "appindicator",
			"the daemon logs which backend it got; nil there used to be the answer "
				.. "on every machine")
	end)

	helpers.it("never resolves the icon to an empty name", function()
		local tray, log = with_indicator(true)
		tray.setMenu({})
		helpers.assert_true(log.created.icon ~= "",
			"an empty icon name draws a blank, unclickable space in the panel — "
				.. "which is what shipped, because the assets directory does not exist "
				.. "and the resolved value went into a local nothing read")
	end)

	helpers.it("passes the menu tree through unchanged", function()
		local tray, log = with_indicator(true)
		local tree = {
			{ title = "Hotstrings", menu = { { title = "Rolls", checked = true } } },
			{ separator = true },
			{ title = "Quitter", fn = function() end },
		}
		tray.setMenu(tree)
		helpers.assert_eq(log.menus[#log.menus], tree,
			"the adapter is a binding, not a transformer; anything it rewrote here "
				.. "would be a second menu vocabulary to keep in sync")
	end)

	helpers.it("(greyed-reason-rows) draws a greyed row's reason below it, at every depth", function()
		local tray, log = with_indicator(true)
		local reason = "Unavailable: Only an X11 session, or GNOME, KDE or Hyprland on Wayland, applies this live."
		local tree = {
			{ title = "Layout", menu = {
				{ title = "Also reorder the three edge keys — Unavailable", disabled = true, tooltip = reason },
				{ title = "Next", fn = function() end },
			} },
		}
		tray.setMenu(tree)
		local drawn = log.menus[#log.menus][1].menu
		local said = {}
		for index = 2, #drawn - 1 do
			helpers.assert_eq(drawn[index].disabled, true, "a reason row runs nothing")
			helpers.assert_eq(drawn[index].fn, nil)
			helpers.assert_true(#drawn[index].title <= 4 + 60 + 8, "a reason line stays narrow: " .. drawn[index].title)
			said[#said + 1] = drawn[index].title:gsub("^%s+", "")
		end
		helpers.assert_true(#said >= 2, "a long reason wraps over several rows")
		helpers.assert_eq(table.concat(said, " "),
			"Only an X11 session, or GNOME, KDE or Hyprland on Wayland, applies this live.")
		helpers.assert_eq(drawn[#drawn].title, "Next")
		helpers.assert_eq(tray.getMenu(), tree, "the menu model itself is kept as the builder made it")
		helpers.assert_eq(#tree[1].menu, 2)
	end)

	-- Arch field report of 2026-11-25 (KDE Plasma, Wayland): a feature switched
	-- off greyed every row of its submenu with one reason, said under each, and
	-- Plasma could not scroll back up to the switch.
	helpers.it("(tray-submenu-height) says a shared reason once and folds an overlong submenu", function()
		local tray, log = with_indicator(true)
		local reason = "Category off: tick the first row of this menu to use it"
		local rows = { { title = "Enable", checked = false, fn = function() end }, { title = "-" } }
		for group = 1, 3 do
			rows[#rows + 1] = { title = "— Group " .. group .. " —", disabled = true }
			for slot = 1, 9 do
				rows[#rows + 1] = { title = "Slot " .. group .. "." .. slot .. " — Category off", disabled = true, tooltip = reason }
			end
			rows[#rows + 1] = { title = "-" }
		end
		tray.setMenu({ { title = "Gestures", checked = false, menu = rows } })
		local drawn = log.menus[#log.menus][1].menu
		helpers.assert_eq(drawn[1].title, "Enable", "the switch stays the first row")
		helpers.assert_true(#drawn <= require("tray.adapters.menu").MAX_SUBMENU_ENTRIES, "drawn: " .. #drawn)
		local told = 0
		local function count(items)
			for _, row in ipairs(items) do
				if row.title == "    tick the first row of this menu to use it" then told = told + 1 end
				if row.menu then count(row.menu) end
			end
		end
		count(drawn)
		helpers.assert_eq(told, 1, "the reason is said below its first greyed row only")
		helpers.assert_eq(drawn[3].title, "Group 1", "each section opens as a submenu named by its header")
		helpers.assert_eq(#tray.getMenu()[1].menu, #rows, "the menu model itself is kept as the builder made it")
	end)

	helpers.it("(greyed-reason-rows) says a reason whole when the label lacks its head, and wraps CJK text", function()
		local tray = require("menu.engine.renderer")
		local drawn = tray.with_reason_rows({ { title = "Row", disabled = true, tooltip = "Not here: never" } })
		helpers.assert_eq(drawn[2].title, "    Not here: never")
		local cjk = string.rep("\228\184\173", 50)
		drawn = tray.with_reason_rows({ { title = "Row — X", disabled = true, tooltip = "X\239\188\154" .. cjk } })
		helpers.assert_eq(#drawn, 3, "fifty wide characters take two lines of sixty columns")
		helpers.assert_eq(drawn[2].title, "    " .. string.rep("\228\184\173", 30))
		local plain = { { title = "Row — Off", disabled = true, tooltip = "Off" }, { title = "Live", disabled = true } }
		helpers.assert_true(tray.with_reason_rows(plain) == plain, "nothing to add keeps the same table")
	end)

	helpers.it("builds both fallback menus with one builder (appimage-catalogue-tray-screenshot)", function()
		local tray, log = with_indicator(true)
		local quit, details, logs = function() end, function() end, function() end
		tray.setFallbackMenu("Ergopti qwerty", "Quit", quit)
		local plain = log.menus[#log.menus]
		helpers.assert_eq(#plain, 2, "a name and a way out, no separator")
		helpers.assert_eq(plain[1].disabled, true)
		helpers.assert_eq(plain[2].fn, quit)
		tray.setFallbackMenu("No keyboard", "Quit", quit,
			{ { { label = "Details", fn = details } }, { { label = "Logs", fn = logs } } })
		local grouped = log.menus[#log.menus]
		local shape = {}
		for _, row in ipairs(grouped) do shape[#shape + 1] = row.separator and "-" or row.title end
		helpers.assert_eq(table.concat(shape, "|"), "No keyboard|Details|-|Logs|-|Quit")
		helpers.assert_eq(grouped[2].fn, details)
		helpers.assert_eq(grouped[4].fn, logs)
		helpers.assert_eq(grouped[6].fn, quit)
	end)

	helpers.it("rebuilds on every setMenu, because a toggle changes the tree", function()
		local tray, log = with_indicator(true)
		tray.setMenu({ { title = "A" } })
		tray.setMenu({ { title = "B" } })
		helpers.assert_eq(#log.menus, 2,
			"a menu built once at startup shows stale checkmarks for the rest of the "
				.. "session, which is what the driver did")
	end)

	helpers.it("tears down and comes back", function()
		local tray, log = with_indicator(true)
		tray.setMenu({ { title = "A" } })
		tray.destroy()
		helpers.assert_eq(log.destroyed, 1, "destroy reaches the backend")
		tray.setMenu({ { title = "B" } })
		helpers.assert_true(log.created ~= nil, "and the reload path can bring it back")
	end)

	-- The setIcon vectors of TrayMenu.spec.js 2.0.0 read what the indicator
	-- received. The earlier spec's setIcon('active') could not fail: this
	-- adapter ignored the string, as it ignored { title } (TRAY-04).
	local function with_errors()
		local errors = {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_, message, ...) errors[#errors + 1] = string.format(message, ...) end
		package.loaded["core.logger.engine.shim"] = logger
		local tray, log = with_indicator(true)
		return tray, log, errors
	end

	helpers.it("set_icon_draws_the_image", function()
		local tray, log = with_errors()
		local logo = helpers.load_module("core.fs.engine.paths").shared("tray/data/ergopti_tray.png")
		helpers.assert_eq(tray.setIcon({ image = logo }), true, "set_icon_draws_the_image: an existing file is drawn")
		helpers.assert_eq(log.icons[#log.icons], logo, "set_icon_draws_the_image: the indicator draws that file")
	end)

	helpers.it("set_icon_refuses_a_missing_file", function()
		local tray, log, errors = with_errors()
		tray.start()
		local base = os.tmpname()
		os.remove(base)
		local missing = base .. "-tray-04-missing.png"
		helpers.assert_eq(tray.setIcon({ image = missing }), false,
			"set_icon_refuses_a_missing_file: a missing file is refused")
		helpers.assert_eq(#log.icons, 0, "set_icon_refuses_a_missing_file: nothing else is drawn in its place")
		helpers.assert_eq(#errors, 1, "set_icon_refuses_a_missing_file: the refusal is logged")
		helpers.assert_contains(errors[1], missing)
	end)

	helpers.it("set_icon_refuses_a_state_name", function()
		local tray, log, errors = with_errors()
		tray.start()
		helpers.assert_eq(tray.setIcon("active"), false, "set_icon_refuses_a_state_name: the old state string")
		helpers.assert_eq(tray.setIcon({ title = "Ergopti" }), false, "a map without an image is refused too")
		helpers.assert_eq(#log.icons, 0)
		helpers.assert_eq(#errors, 2)
	end)

	helpers.it("destroy_then_set_icon_is_safe", function()
		local tray, log = with_errors()
		tray.start()
		tray.destroy()
		local logo = helpers.load_module("core.fs.engine.paths").shared("tray/data/ergopti_tray.png")
		helpers.assert_eq(tray.setIcon({ image = logo }), true, "destroy_then_set_icon_is_safe: the icon comes back")
		helpers.assert_eq(log.icons[#log.icons], logo)
	end)

	helpers.it("start brings the icon up with the state's logo", function()
		local tray, log = with_indicator(true)
		helpers.assert_eq(tray.start(), true)
		helpers.assert_contains(log.created.icon, "ergopti_tray.png")
		helpers.assert_eq(with_indicator(false).start(), false, "no backend, no icon, and the daemon is told")
	end)

	helpers.it("pumps without blocking", function()
		local tray, log = with_indicator(true)
		tray.setMenu({})
		tray.pump()
		helpers.assert_eq(log.pumps, 1, "the event loop drains the tray on every tick")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 2/ On a machine that cannot ============================
-- =================================================================
-- =================================================================

helpers.describe("tray_menu: with no backend", function()

	helpers.it("keeps the menu for later instead of discarding it", function()
		local tray = with_indicator(false)
		tray.setMenu({ { title = "Quitter" } })
		helpers.assert_eq(#tray.getMenu(), 1,
			"a headless boot that later gains a display should not have lost the menu")
		helpers.assert_eq(tray.getBackend(), nil,
			"and the absence must be reported honestly rather than as a working tray")
	end)

	helpers.it("accepts every call the daemon makes, without raising", function()
		local tray = with_indicator(false)
		-- The daemon calls all of these unconditionally from its event loop.
		-- Hotstring expansion has nothing to do with having a tray, so none of
		-- them may become a crash on a TTY or a headless server.
		local ok, err = pcall(function()
			tray.setIcon({ title = "Ergopti" })
			tray.setIcon(nil)
			tray.setMenu(nil)
			tray.setMenu({})
			tray.setTooltip("hello")
			tray.setTooltip(nil)
			tray.pump()
			tray.destroy()
			tray.destroy()
			tray.pump()
		end)
		helpers.assert_eq(ok, true, "no call may raise without a backend: " .. tostring(err))
	end)

	helpers.it("treats a non-table menu as empty rather than propagating it", function()
		local tray = with_indicator(false)
		tray.setMenu("not a menu")
		helpers.assert_eq(#tray.getMenu(), 0,
			"a malformed menu must not reach the widget builder, where it would "
				.. "raise inside GTK with no Lua traceback")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= The Ergopti logo, not a generic glyph ===================
-- =================================================================
-- =================================================================

helpers.describe("tray_menu: the icon is named for screen readers (a11y-tray-description)", function()

	--- Installs a locale catalogue double and loads the adapter over it.
	--- @param strings table|nil Translations by key; nil while none is loaded.
	--- @return table adapter, table log, table strings
	local function with_catalogue(strings)
		package.loaded["core.i18n.engine.i18n"] = {
			has = function(key) return strings ~= nil and strings[key] ~= nil end,
			get = function(key)
				if strings == nil or strings[key] == nil then error("get() of a missing key answers the key itself") end
				return strings[key]
			end,
		}
		local tray, log = with_indicator(true)
		return tray, log, strings
	end

	helpers.it("names the icon at creation and says the paused state in words", function()
		local tray, log = with_catalogue({
			["accessibility.tray_tip"] = "Ergopti+",
			["accessibility.tray_tip_paused"] = "Ergopti+ (en pause)",
		})
		tray.setMenu({})
		helpers.assert_eq(log.created.description, "Ergopti+",
			"an empty description leaves Orca with a file name or nothing")
		tray.setPaused(true)
		helpers.assert_eq(log.descriptions[#log.icons], "Ergopti+ (en pause)",
			"the greyed logo is the only other sign of a pause, and a screen reader cannot see it")
		tray.setPaused(false)
		helpers.assert_eq(log.descriptions[#log.icons], "Ergopti+")
	end)

	helpers.it("relabels after the catalogue loads or changes, once", function()
		local strings = {}
		local tray, log = with_catalogue(strings)
		tray.setMenu({})
		helpers.assert_eq(log.created.description, "", "never the key itself before the catalogue loads")
		strings["accessibility.tray_tip"] = "Ergopti+"
		strings["accessibility.tray_tip_paused"] = "Ergopti+ (paused)"
		tray.setMenu({})
		helpers.assert_eq(#log.icons, 1, "the menu build after the catalogue loads names the icon")
		helpers.assert_eq(log.descriptions[1], "Ergopti+")
		tray.setMenu({})
		helpers.assert_eq(#log.icons, 1, "an unchanged description is not re-sent over D-Bus")
	end)

end)


helpers.describe("tray_menu: the icon is the Ergopti logo", function()

	helpers.it("shows the bundled logo from the shared tree", function()
		-- The candidates used to hang off "<driver root>/../_shared/tray/data", a
		-- directory that did not exist: every Linux user got the themed
		-- "input-keyboard" glyph instead of the logo macOS and Windows show.
		local Paths = helpers.load_module("core.fs.engine.paths")
		local expected = Paths.shared("tray/data/ergopti_tray.png")
		local tray, log = with_indicator(true)
		tray.setMenu({})
		helpers.assert_eq(log.created.icon, expected,
			"the tray must be created with the bundled Ergopti logo")
		local fh = io.open(log.created.icon, "rb")
		helpers.assert_true(fh ~= nil, "the logo must exist on disk: " .. tostring(log.created.icon))
		local magic = fh:read(8)
		fh:close()
		helpers.assert_eq(magic, "\137PNG\r\n\26\n", "the logo must be a PNG a panel can load")
	end)

	helpers.it("greys the logo while paused and restores it on resume", function()
		local tray, log = with_indicator(true)
		tray.setMenu({})
		tray.setPaused(true)
		helpers.assert_contains(log.icons[#log.icons], "ergopti_tray_paused.png",
			"a paused daemon shows the disabled logo, as on macOS and Windows")
		tray.setPaused(true)
		helpers.assert_eq(#log.icons, 1, "an unchanged state must not re-send the icon")
		tray.setPaused(false)
		helpers.assert_contains(log.icons[#log.icons], "ergopti_tray.png")
		helpers.assert_true(not log.icons[#log.icons]:find("paused", 1, true),
			"resuming must bring the normal logo back")
	end)

	helpers.it("resolves from the shared root, whichever layout found it", function()
		-- /usr/lib/ergopti nests _shared INSIDE the driver root; the old
		-- "<driver>/../_shared" candidate addressed /usr/lib/_shared there.
		local Protocol = helpers.load_module("tray.protocol")
		local Paths = helpers.load_module("core.fs.engine.paths")
		local root = Paths.shared_root()
		helpers.assert_contains(Protocol.resolve_tray_icon(root, false), "/tray/data/ergopti_tray.png")
		helpers.assert_eq(Protocol.resolve_tray_icon(nil, false), "",
			"no shared tree means no file, and the caller falls back to a themed name")
	end)

	helpers.it("keeps the shared root's spelling whatever separator the host declares", function()
		-- The icon path was rewritten to backslashes wherever package.config
		-- declared "\": the tray then announced a path infra.paths never spells,
		-- and on Linux the rewritten path names no file. Declaring that separator
		-- here reproduces it on every host.
		local Protocol = helpers.load_module("tray.protocol")
		local Paths = helpers.load_module("core.fs.engine.paths")
		local real_config = package.config
		package.config = "\\" .. real_config:sub(2)
		local ok, icon = pcall(Protocol.resolve_tray_icon, Paths.shared_root(), false)
		package.config = real_config
		helpers.assert_true(ok, tostring(icon))
		helpers.assert_eq(icon, Paths.shared("tray/data/ergopti_tray.png"),
			"the icon is the shared root's own path to the logo")
	end)

end)


helpers.describe("tray_menu: a missing logo file is said, not swapped (tray-05)", function()

	helpers.it("a missing paused logo never resolves to the running one", function()
		local luv = require("luv")
		local root = os.tmpname()
		os.remove(root)
		assert(luv.fs_mkdir(root, 448))
		assert(luv.fs_mkdir(root .. "/tray", 448))
		assert(luv.fs_mkdir(root .. "/tray/data", 448))
		local running = root .. "/tray/data/ergopti_tray.png"
		local handle = assert(io.open(running, "wb"))
		handle:write("\137PNG\r\n\26\n")
		handle:close()
		local Protocol = helpers.load_module("tray.protocol")
		local paused_icon, paused_missing = Protocol.resolve_tray_icon(root, true)
		local running_icon, running_missing = Protocol.resolve_tray_icon(root, false)
		os.remove(running)
		luv.fs_rmdir(root .. "/tray/data")
		luv.fs_rmdir(root .. "/tray")
		luv.fs_rmdir(root)
		helpers.assert_eq(paused_icon, "", "a paused daemon drawn with the running logo looks running")
		helpers.assert_eq(paused_missing, root .. "/tray/data/ergopti_tray_paused.png",
			"the missing file is named for the log")
		helpers.assert_eq(running_icon, running)
		helpers.assert_eq(running_missing, nil)
	end)

	helpers.it("draws the warning sign, logs the file once and says so", function()
		local errors = {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_, message, ...) errors[#errors + 1] = string.format(message, ...) end
		package.loaded["core.logger.engine.shim"] = logger
		local missing = "/usr/lib/ergopti/_shared/tray/data/ergopti_tray_paused.png"
		package.loaded["tray.protocol"] = {
			resolve_tray_icon = function(_, paused)
				if paused then return "", missing end
				return "/usr/lib/ergopti/_shared/tray/data/ergopti_tray.png", nil
			end,
		}
		package.loaded["core.i18n.engine.i18n"] = {
			has = function() return true end,
			get = function(key) return "<" .. key .. ">" end,
		}
		local tray, log = with_indicator(true)
		tray.setMenu({})
		tray.setPaused(true)
		helpers.assert_eq(log.icons[#log.icons], "dialog-warning",
			"the warning sign, not the running logo and not a keyboard glyph")
		helpers.assert_eq(log.descriptions[#log.icons], "<accessibility.tray_tip_paused_icon_missing>",
			"a screen reader hears that the paused logo is missing")
		helpers.assert_eq(#errors, 1, "the missing file is logged")
		helpers.assert_contains(errors[1], missing)
		tray.setPaused(false)
		tray.setPaused(true)
		helpers.assert_eq(#errors, 1, "once, not at every pause")
		tray.setPaused(false)
		helpers.assert_eq(log.descriptions[#log.icons], "<accessibility.tray_tip>",
			"the running state, whose logo exists, is named as usual")
	end)

end)

restore_loaded()
