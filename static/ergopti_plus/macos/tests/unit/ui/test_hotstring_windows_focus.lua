--- tests/unit/ui/test_hotstring_windows_focus.lua

--- ==============================================================================
--- MODULE: Hotstring Window Deferred Focus Ownership
--- DESCRIPTION:
--- Exercises both real controllers and the real focus retry implementation.
--- Native views become unusable after deletion, as on the actual host.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ==================================
-- ==================================
-- ======= 1/ Focus Ownership =======
-- ==================================
-- ==================================

--- Runs one window with observable native views and deferred focus callbacks.
--- @param module_name string Real controller module.
--- @param scenario function Behavioral assertions.
local function with_window(module_name, scenario)
	local saved, prior_hs = {}, _G.hs
	for key, value in pairs(package.loaded) do saved[key] = value end
	local state = { views = {}, deferred = {}, focuses = 0 }
	local ok, err = xpcall(function()
		package.loaded["infra.logger"] = {
			debug = function() end, info = function() end, warn = function() end, error = function() end,
		}
		package.loaded["infra.paths"] = { shared = function() return "/virtual" end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.fs_dir"] = { entries = function() return {} end }
		package.loaded["infra.deferred_work"] = { after = function(_, callback)
			state.deferred[#state.deferred + 1] = callback
			return true
		end }
		package.loaded["adapters.file_system"] = { read_with_status = function() return "source", "ok" end }
		package.loaded["infra.toml.reader"] = { parse = function() return {}, true end }
		package.loaded["infra.toml.writer"] = {}
		package.loaded["modules.hotstrings.hotstrings_config"] = {}
		package.loaded["hs.spaces"] = {}
		_G.hs = {
			focus = function() state.focuses = state.focuses + 1 end,
			screen = { mainScreen = function() return {} end },
			json = { encode = function() return "{}" end },
			webview = { windowMasks = {}, usercontent = { new = function()
				return { setCallback = function(self) return self end }
			end } },
		}
		package.loaded["ui.ui_builder"] = nil
		local real_builder = require("ui.ui_builder")
		package.loaded["ui.ui_builder"] = {
			force_focus = real_builder.force_focus,
			get_app_geometry = function() return { width = 10, height = 10 } end,
			get_centered_frame = function() return {} end,
			show_webview = function(options)
				local view = { deletes = 0 }
				function view:delete()
					self.deletes = self.deletes + 1
					options.on_close()
					return self
				end
				function view:hswindow()
					if self.deletes > 0 then error("deleted native view") end
					return nil
				end
				function view:bringToFront()
					if self.deletes > 0 then error("deleted native view") end
					return self
				end
				state.views[#state.views + 1] = view
				if options.on_webview_created then options.on_webview_created(view) end
				if state.focus_during_show then
					real_builder.force_focus(view, true, { is_current = options.is_current })
				end
				return view
			end,
		}
		package.loaded[module_name] = nil
		local window = require(module_name)
		if module_name == "ui.hotstring_editor" then window.init("/virtual/source.toml", {}) end
		scenario(window, state)
	end, debug.traceback)
	for key in pairs(package.loaded) do if saved[key] == nil then package.loaded[key] = nil end end
	for key, value in pairs(saved) do package.loaded[key] = value end
	_G.hs = prior_hs
	if not ok then error(err, 0) end
end

helpers.describe("hotstring windows deferred focus", function()
	for _, module_name in ipairs({ "ui.hotstring_editor", "ui.hotstrings_config_window" }) do
		for _, route in ipairs({ "factory", "reuse" }) do
			helpers.it(module_name .. " retires " .. route .. " focus retries (hotstring-focus-owner)", function()
				with_window(module_name, function(window, state)
					state.focus_during_show = route == "factory"
					helpers.assert_eq(window.open(), true)
					if route == "reuse" then helpers.assert_eq(window.open(), true) end
					helpers.assert_eq(#state.deferred, 1)
					helpers.assert_eq(window.close(), true)
					state.focus_during_show = false
					helpers.assert_eq(window.open(), true)
					for _, callback in ipairs(state.deferred) do callback() end
					helpers.assert_eq(state.focuses, 0, "retired work must not activate Hammerspoon")
					helpers.assert_eq(#state.deferred, 1, "retired work must not schedule another retry")
					helpers.assert_eq(state.views[2].deletes, 0)
				end)
			end)
		end
		helpers.it(module_name .. " preserves current focus retries (hotstring-focus-owner)", function()
			with_window(module_name, function(window, state)
				helpers.assert_eq(window.open(), true)
				helpers.assert_eq(window.open(), true)
				helpers.assert_eq(#state.deferred, 1)
				for _, callback in ipairs(state.deferred) do callback() end
				helpers.assert_eq(state.focuses, 1)
				helpers.assert_eq(state.views[1].deletes, 0)
			end)
		end)
	end
end)
