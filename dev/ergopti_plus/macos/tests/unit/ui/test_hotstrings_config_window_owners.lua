--- tests/unit/ui/test_hotstrings_config_window_owners.lua

--- ==============================================================================
--- MODULE: Hotstrings Configuration Window Ownership Tests
--- DESCRIPTION:
--- Replays captured native callbacks against the real window controller.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===================================
-- ===================================
-- ======= 1/ Native Ownership =======
-- ===================================
-- ===================================

local with_window = require("tests.support.hotstrings_config_window_fixture").with_window

helpers.describe("hotstrings configuration native owners", function()
	for _, phase in ipairs({ "before", "after" }) do
		helpers.it("construction exception " .. phase .. " allocation remains retryable (config-window-owner)", function()
			with_window(function(window, state)
				state["throw_" .. phase .. "_create"] = true
				helpers.assert_eq(window.open(), false)
				if phase == "after" then helpers.assert_eq(state.views[1].deletes, 1) end
				state["throw_" .. phase .. "_create"] = false
				helpers.assert_eq(window.close(), true)
				helpers.assert_eq(window.open(), true)
			end)
		end)
	end
	helpers.it("rejects retired bridge mutation, navigation and close (config-window-owner)", function()
		with_window(function(window, state)
			helpers.assert_eq(window.open(), true)
			local old = state.callbacks[1]
			helpers.assert_eq(window.close(), true)
			helpers.assert_eq(window.open(), true)
			old({ body = { action = "set_color", group = "common", category = "rolls", hex = "#abc" } })
			state.options[1].on_navigation("didFinishNavigation")
			old({ body = { action = "close" } })
			helpers.assert_eq(state.writes, 0)
			helpers.assert_eq(state.views[2].javascript, 0)
			helpers.assert_eq(state.views[2].deletes, 0)
			state.callbacks[2]({ body = { action = "set_color", group = "common", category = "rolls", hex = "#abc" } })
			helpers.assert_eq(state.writes, 1)
			helpers.assert_eq(state.views[2].javascript, 1)
		end)
	end)

	helpers.it("a refused close leaves cleanup authority but no mutation authority (config-window-owner)", function()
		with_window(function(window, state)
			helpers.assert_eq(window.open(), true)
			state.refuse_delete = true
			helpers.assert_eq(window.close(), false)
			state.callbacks[1]({ body = { action = "set_color", group = "common", category = "rolls", hex = "#abc" } })
			helpers.assert_eq(state.writes, 0)
			state.refuse_delete = false
			helpers.assert_eq(window.close(), true)
			helpers.assert_eq(state.views[1].deletes, 2)
			helpers.assert_eq(window.open(), true)
			helpers.assert_eq(#state.views, 2)
		end)
	end)

	helpers.it("construction-time close cannot publish an owner (config-window-owner)", function()
		with_window(function(window, state)
			state.close_during_show = true
			helpers.assert_eq(window.open(), false)
			state.callbacks[1]({ body = { action = "set_color", group = "common", category = "rolls", hex = "#abc" } })
			helpers.assert_eq(state.writes, 0)
			helpers.assert_eq(state.views[1].deletes, 1)
			state.close_during_show = false
			helpers.assert_eq(window.open(), true)
			helpers.assert_eq(#state.views, 2)
		end)
	end)

	helpers.it("native close and navigation from A cannot retire B (config-window-owner)", function()
		with_window(function(window, state)
			helpers.assert_eq(window.open(), true)
			state.options[1].on_close()
			helpers.assert_eq(window.open(), true)
			state.options[1].on_close()
			state.options[1].on_navigation("didFinishNavigation")
			state.options[2].on_navigation("didFinishNavigation")
			helpers.assert_eq(state.views[2].javascript, 1)
			helpers.assert_eq(state.views[2].deletes, 0)
		end)
	end)

	helpers.it("JavaScript reentry cannot invoke a successor refresh callback (config-window-owner)", function()
		with_window(function(window, state)
			local refreshed = 0
			helpers.assert_eq(window.open(), true)
			state.on_javascript = function()
				window.close()
				window.open()
				window._on_config_changed = function() refreshed = refreshed + 1 end
			end
			state.callbacks[1]({ body = { action = "set_color", group = "common", category = "rolls", hex = "#abc" } })
			helpers.assert_eq(state.writes, 1)
			helpers.assert_eq(refreshed, 0)
			helpers.assert_eq(#state.views, 2)
		end)
	end)
end)
