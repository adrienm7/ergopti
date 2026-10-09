--- tests/unit/ui/test_hotstrings_config_window_javascript.lua

--- ==============================================================================
--- MODULE: Hotstrings Configuration JavaScript Boundaries
--- DESCRIPTION:
--- Replays real navigation and mutation routes against fallible native delivery.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_window = require("tests.support.hotstrings_config_window_fixture").with_window

helpers.describe("hotstrings configuration JavaScript delivery", function()
	for _, route in ipairs({ "navigation", "mutation" }) do
		for _, mode in ipairs({ "encode_throw", "encode_nil", "throw", "nil", "false", "async", "sync_error", "success" }) do
			helpers.it("observes " .. route .. " " .. mode .. " (config-window-javascript)", function()
				with_window(function(window, state)
					helpers.assert_true(window.open())
					state.eval_mode = mode
					state.encode_mode = mode:match("^encode_(.*)$")
					local function dispatch()
						if route == "navigation" then state.options[1].on_navigation("didFinishNavigation")
						else state.callbacks[1]({ body = { action = "set_color", group = "common", category = "rolls", hex = "#abc" } }) end
					end
					dispatch()
					if mode == "async" or mode == "success" then
						helpers.assert_type(state.completion, "function")
						if mode == "async" then
							state.completion(nil, { message = "private payload" })
							state.completion(nil, { message = "private payload" })
						else state.completion(nil, nil) end
					else dispatch() end
					helpers.assert_eq(#state.errors, mode == "success" and 0 or 1)
					helpers.assert_eq(state.views[1].javascript, state.encode_mode and 0 or ((mode == "async" or mode == "success") and 1 or 2))
					helpers.assert_eq(state.writes, route == "navigation" and 0 or ((mode == "async" or mode == "success") and 1 or 2))
					helpers.assert_eq(table.concat(state.errors):find("private payload", 1, true), nil)
				end)
			end)
		end
	end

	helpers.it("encoding reentry cannot send stale data to either owner (config-window-javascript)", function()
		with_window(function(window, state)
			helpers.assert_true(window.open())
			state.on_encode = function() window.close() window.open() end
			state.options[1].on_navigation("didFinishNavigation")
			helpers.assert_eq(#state.views, 2)
			helpers.assert_eq(state.views[1].javascript, 0)
			helpers.assert_eq(state.views[2].javascript, 0)
		end)
	end)

	helpers.it("late errors retain bounded diagnostics without mutating a successor (config-window-javascript)", function()
		with_window(function(window, state)
			helpers.assert_true(window.open())
			state.options[1].on_navigation("didFinishNavigation")
			local old_completion = state.completion
			helpers.assert_type(old_completion, "function")
			window.close()
			helpers.assert_true(window.open())
			old_completion(nil, { message = "private payload" })
			old_completion(nil, { message = "private payload" })
			helpers.assert_eq(#state.errors, 1)
			helpers.assert_eq(state.views[2].javascript, 0)
			helpers.assert_eq(state.views[2].deletes, 0)
			state.options[2].on_navigation("didFinishNavigation")
			state.completion(nil, { message = "private payload" })
			helpers.assert_eq(#state.errors, 2, "each exact owner reports its first failure")
		end)
	end)

	helpers.it("a failure diagnostic cannot refresh a reentrant successor (config-window-javascript)", function()
		with_window(function(window, state)
			helpers.assert_true(window.open())
			local refreshes = 0
			window._on_config_changed = function() refreshes = refreshes + 1 end
			state.eval_mode = "throw"
			state.on_error = function() window.close() window.open() end
			state.callbacks[1]({ body = { action = "set_color", group = "common", category = "rolls", hex = "#abc" } })
			helpers.assert_eq(#state.views, 2)
			helpers.assert_eq(state.writes, 1)
			helpers.assert_eq(refreshes, 0)
			helpers.assert_eq(state.views[2].javascript, 0)
		end)
	end)
end)
