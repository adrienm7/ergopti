--- tests/unit/adapters/test_wpm_surface_lifecycle.lua

--- ==============================================================================
--- MODULE: WPM Surface Terminal Hide Contract
--- DESCRIPTION:
--- Exercises the real surface owner against GTK-shaped window methods. A hide
--- request must not acknowledge success while the native window remains visible.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_surface(body)
	local previous = package.loaded["adapters.wpm_surface"]
	package.loaded["adapters.wpm_surface"] = nil
	local surface = require("adapters.wpm_surface")
	local state = { visible = false }
	local window = setmetatable({
		get_screen = function() return { get_rgba_visual = function() return nil end } end,
		get_visible = function() return state.visible end,
		show_all = function() if state.show then return state.show() end; state.visible = true end,
		hide = function()
			if state.hide then return state.hide() end
			state.visible = false
		end,
	}, { __index = function() return function() end end })
	surface._set_binding_for_test({
		Gtk = { Window = function() return window end },
		Gdk = { EventMask = { BUTTON_PRESS_MASK = 1, BUTTON_RELEASE_MASK = 2, POINTER_MOTION_MASK = 4 } },
	})
	local ok, err = pcall(body, surface, state)
	package.loaded["adapters.wpm_surface"] = previous
	if not ok then error(err, 0) end
end

helpers.describe("WPM surface terminal hide", function()
	helpers.it("rejects refused or unobserved native show before releasing restoration", function()
		for _, refusal in ipairs({ function() return false end, function() end, function() error("GTK show failed") end }) do
			with_surface(function(surface, state)
				state.show = refusal
				helpers.assert_eq(surface.draw({ width = 30, height = 20 }, 0, 0), false)
				helpers.assert_eq(state.visible, false)
				state.show = nil
				helpers.assert_true(surface.draw({ width = 30, height = 20 }, 0, 0))
				helpers.assert_eq(state.visible, true)
			end)
		end
	end)
	helpers.it("acknowledges an absent window and a verified native hide", function()
		with_surface(function(surface, state)
			helpers.assert_eq(surface.hide(), true)
			helpers.assert_eq(surface.draw({ width = 30, height = 20 }, 0, 0), true)
			helpers.assert_eq(state.visible, true)
			helpers.assert_eq(surface.hide(), true)
			helpers.assert_eq(state.visible, false)
		end)
	end)

	helpers.it("rejects thrown and unobserved hides while retaining the window for retry", function()
		for _, refusal in ipairs({ function() error("GTK hide failed") end, function() end }) do
			with_surface(function(surface, state)
				helpers.assert_true(surface.draw({ width = 30, height = 20 }, 0, 0))
				state.hide = refusal
				helpers.assert_eq(surface.hide(), false)
				helpers.assert_eq(state.visible, true)
				state.hide = nil
				helpers.assert_eq(surface.hide(), true)
				helpers.assert_eq(state.visible, false)
			end)
		end
	end)
end)
