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

--- Runs an isolated controller with observable native owners.
--- @param test function Behavioral assertions.
local function with_window(test)
	local loaded, original_hs = {}, _G.hs
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local state = { callbacks = {}, views = {}, options = {}, writes = 0 }
	local ok, err = xpcall(function()
		package.loaded["infra.logger"] = {
			debug = function() end, info = function() end, error = function() end,
			callback = function(_, _, callback, ...) return pcall(callback, ...) end,
		}
		package.loaded["infra.paths"] = { shared = function(path) return "/virtual/" .. path end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.fs_dir"] = { entries = function() return {} end }
		package.loaded["modules.keymap"] = {}
		package.loaded["modules.hotstrings.hotstrings_config"] = {
			set_override = function() state.writes = state.writes + 1 return true end,
			resolve = function() return {} end, get_toml_defaults = function() return {} end,
			get_user_override = function() return {} end, get_sections = function() return {} end,
		}
		_G.hs = { json = { encode = function() return "{}" end }, webview = {
			usercontent = { new = function()
				return { setCallback = function(self, callback)
					if callback then state.callbacks[#state.callbacks + 1] = callback end
					return self
				end }
			end },
		} }
		package.loaded["ui.ui_builder"] = {
			get_app_geometry = function() return { width = 10, height = 10 } end,
			get_centered_frame = function() return {} end, force_focus = function() end,
			show_webview = function(options)
				if state.throw_before_create then error("injected factory entry failure") end
				local view = { deletes = 0, javascript = 0 }
				function view:delete()
					self.deletes = self.deletes + 1
					if state.refuse_delete then error("injected delete failure") end
				end
				function view:evaluateJavaScript()
					self.javascript = self.javascript + 1
					if state.on_javascript then state.on_javascript() end
					return self
				end
				state.views[#state.views + 1] = view
				state.options[#state.options + 1] = options
				if options.on_webview_created then options.on_webview_created(view) end
				if state.throw_after_create then error("injected factory post-allocation failure") end
				if state.close_during_show then options.on_close() end
				return view
			end,
		}
		package.loaded["ui.hotstrings_config_window"] = nil
		test(require("ui.hotstrings_config_window"), state)
	end, debug.traceback)
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	_G.hs = original_hs
	if not ok then error(err, 0) end
end

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
