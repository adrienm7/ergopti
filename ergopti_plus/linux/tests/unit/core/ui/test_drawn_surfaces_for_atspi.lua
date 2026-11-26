--- tests/unit/core/ui/test_drawn_surfaces_for_atspi.lua

--- ==============================================================================
--- MODULE: The WPM widget and the spotlight overlay for AT-SPI (Linux)
--- DESCRIPTION:
--- Both are cairo-drawn GTK windows Orca read as nothing. These cases pin what
--- AT-SPI gets while the desktop's screen reader is on, as on Windows: the WPM
--- window is named by the speed it draws, set only when it changes; the
--- spotlight ring is a notification named « Mouse pointer highlighted », which
--- Orca speaks when it is mapped. Off, neither is touched (a11y-linux-drawn).
--- ==============================================================================

local h = require("tests.helpers")

local MODULES = { "core.ui.adapters.system_accessibility", "adapters.wpm_surface",
	"core.ui.adapters.spotlight_overlay", "core.i18n.engine.i18n" }
local restore_loaded = h.keep_loaded(MODULES)

local Atk = { Role = { NOTIFICATION = "notification" } }

--- Replaces the settings adapter with a controlled screen reader, keeping its
--- real naming.
--- @param reader table { on = boolean }
local function stub_settings(reader)
	package.loaded["core.ui.adapters.system_accessibility"] = nil
	local real = require("core.ui.adapters.system_accessibility")
	package.loaded["core.ui.adapters.system_accessibility"] = {
		ensure_started = function() return false end,
		settings = function() return { screen_reader = reader.on } end,
		name_window = real.name_window,
	}
end

--- A GTK window double recording its accessible's role and names.
--- @return table window, table accessible
local function window_double()
	local accessible = { names = {} }
	function accessible:set_role(role) self.role = role end
	function accessible:set_name(name) self.names[#self.names + 1] = name end
	local state = { visible = false }
	local window = setmetatable({
		get_accessible = function() return accessible end,
		get_screen = function()
			return { get_rgba_visual = function() return nil end, is_composited = function() return true end }
		end,
		get_window = function() return { input_shape_combine_region = function() end } end,
		get_visible = function() return state.visible end,
		show_all = function()
			accessible.shown_with = accessible.names[#accessible.names]
			state.visible = true
		end,
		hide = function() state.visible = false end,
	}, { __index = function() return function() end end })
	return window, accessible
end

h.describe("the WPM widget for AT-SPI (a11y-linux-drawn)", function()
	--- Loads the surface over one window double.
	--- @param reader table
	--- @return table surface, table accessible
	local function load_surface(reader)
		stub_settings(reader)
		package.loaded["adapters.wpm_surface"] = nil
		local surface = require("adapters.wpm_surface")
		local window, accessible = window_double()
		surface._set_binding_for_test({
			Gtk = { Window = function() return window end },
			Gdk = { EventMask = { BUTTON_PRESS_MASK = 1, BUTTON_RELEASE_MASK = 2, POINTER_MOTION_MASK = 4 } },
			Atk = Atk,
		})
		return surface, accessible
	end

	h.it("(a11y-linux-drawn) names the window by the speed it draws, only when it changes", function()
		local reader = { on = true }
		local surface, accessible = load_surface(reader)
		local frame = { width = 30, height = 20, number = "72", unit = "WPM" }
		h.assert_true(surface.draw(frame, 0, 0))
		h.assert_eq(accessible.names, { "72 WPM" })
		h.assert_eq(accessible.shown_with, "72 WPM", "named before it is mapped")
		h.assert_true(surface.draw(frame, 0, 0))
		h.assert_eq(#accessible.names, 1, "a tick that draws the same speed sets nothing")
		h.assert_true(surface.draw({ width = 30, height = 20, mode = "graph", label = "80 WPM" }, 0, 0))
		h.assert_eq(accessible.names, { "72 WPM", "80 WPM" })
		h.assert_nil(accessible.role, "the window keeps its own role: nothing is spoken per tick")
		surface.destroy()
	end)

	h.it("(a11y-linux-drawn) leaves the window unnamed while the screen reader is off", function()
		local surface, accessible = load_surface({ on = false })
		h.assert_true(surface.draw({ width = 30, height = 20, number = "72", unit = "WPM" }, 0, 0))
		h.assert_eq(#accessible.names, 0)
		surface.destroy()
	end)
end)

h.describe("the spotlight overlay for AT-SPI (a11y-linux-drawn)", function()
	--- Loads the overlay over window doubles.
	--- @param reader table
	--- @return table overlay, table accessibles
	local function load_overlay(reader)
		stub_settings(reader)
		package.loaded["core.i18n.engine.i18n"] = { get = function(key) return key end }
		package.loaded["core.ui.adapters.spotlight_overlay"] = nil
		local overlay = require("core.ui.adapters.spotlight_overlay")
		local accessibles = {}
		overlay._set_binding_for_test({
			Gtk = { Window = function()
				local window, accessible = window_double()
				accessibles[#accessibles + 1] = accessible
				return window
			end },
			Gdk = {},
			cairo = { Region = { create = function() return {} end } },
			Atk = Atk,
		})
		return overlay, accessibles
	end

	local shapes = {
		{ kind = "ring", x = 100, y = 100, size = 80, style = {} },
		{ kind = "cross", x = 900, y = 100, size = 60, style = {} },
	}

	h.it("(a11y-linux-drawn) the ring is a notification Orca speaks when it appears", function()
		local overlay, accessibles = load_overlay({ on = true })
		h.assert_true(overlay.show(shapes))
		h.assert_eq(accessibles[1].role, "notification")
		h.assert_eq(accessibles[1].shown_with, "accessibility.spotlight_shown", "named before it is mapped")
		h.assert_eq(#accessibles[2].names, 0, "the crosses on the other monitors say nothing")
		h.assert_true(overlay.show(shapes))
		h.assert_eq(accessibles[3].role, "notification", "each spotlight is a new notification")
		overlay.hide()
	end)

	h.it("(a11y-linux-drawn) says nothing while the screen reader is off", function()
		local overlay, accessibles = load_overlay({ on = false })
		h.assert_true(overlay.show(shapes))
		h.assert_nil(accessibles[1].role)
		h.assert_eq(#accessibles[1].names, 0)
		overlay.hide()
	end)
end)

restore_loaded()
