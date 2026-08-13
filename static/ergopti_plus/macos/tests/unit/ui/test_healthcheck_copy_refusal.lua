--- tests/unit/ui/test_healthcheck_copy_refusal.lua

--- ==============================================================================
--- MODULE: Healthcheck copy-button clipboard refusal
--- DESCRIPTION:
--- Drives the real navigation and polling callbacks. setContents(false) keeps
--- the report open, resets the JS request flag, and logs the missing output.
--- ==============================================================================

local helpers = require("tests.helpers")


helpers.describe("healthcheck copy button: native refusal is not success", function()
	helpers.it("keeps the report open when setContents returns false", function()
		for _, name in ipairs({
			"ui.healthcheck.core", "ui.healthcheck.helpers", "healthcheck.snapshot",
			"infra.logger", "infra.paths", "infra.i18n", "ui.ui_builder",
		}) do package.loaded[name] = nil end
		package.loaded["tests.stubs.hs"] = nil
		local hs_stub = require("tests.stubs.hs")
		hs_stub.__reset()
		_G.hs = hs_stub
		package.loaded["hs"] = hs_stub

		local errors = {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_log, message, ...)
			errors[#errors + 1] = string.format(message, ...)
		end
		package.loaded["infra.logger"] = logger
		package.loaded["ui.healthcheck.helpers"] = {}
		package.loaded["healthcheck.snapshot"] = {}
		package.loaded["infra.paths"] = { shared = function() return "/shared" end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		local navigation_callback = nil
		local poll_callback = nil
		local deleted = 0
		local reset_requests = 0
		local poll_stops = 0
		package.loaded["ui.ui_builder"] = {
			build_injected_html = function() return "<html></html>" end,
			get_app_geometry = function() return { width = 740, height = 560 } end,
			force_focus = function() end,
		}
		package.loaded["adapters.timer_scheduler"] = {
			every = function(_delay, callback)
				poll_callback = callback
				return { timer = {} }, true
			end,
			cancel = function(handle) handle.timer = nil; return true end,
			after = function() error("the configured focus helper must avoid fallback scheduling") end,
		}

		local wv = {}
		for _, method in ipairs({
			"windowStyle", "windowTitle", "allowTextEntry", "allowNewWindows",
			"allowGestures", "level", "html", "show",
		}) do wv[method] = function(self) return self end end
		wv.windowCallback = function(self, callback) self.window_callback = callback; return self end
		wv.navigationCallback = function(self, callback)
			navigation_callback = callback
			return self
		end
		wv.evaluateJavaScript = function(self, script, callback)
			if script == "window.__hs_copy_requested=false" then reset_requests = reset_requests + 1 end
			if type(callback) == "function" then callback(true) end
			return self
		end
		wv.delete = function() deleted = deleted + 1 end
		hs_stub.webview.new = function() return wv end
		hs_stub.webview.windowMasks = { titled = 1, closable = 2, miniaturizable = 4 }
		hs_stub.screen.mainScreen = function()
			return { frame = function() return { x = 0, y = 0, w = 1440, h = 900 } end }
		end
		hs_stub.json.encode = function() return "{}" end
		hs_stub.pasteboard.setContents = function() return false end
		package.loaded["adapters.timer_scheduler"].cancel = function(handle)
			poll_stops = poll_stops + 1
			handle.timer = nil
			return true
		end

		local healthcheck = require("ui.healthcheck.core")
		healthcheck.run = function() return {} end
		healthcheck.format_plain = function() return "diagnostic text" end
		healthcheck.show_window()
		helpers.assert_type(navigation_callback, "function")
		navigation_callback("didFinishNavigation")
		helpers.assert_type(poll_callback, "function")
		poll_callback()

		helpers.assert_eq(deleted, 0,
			"a refused copy must not close the only remaining copy source")
		helpers.assert_eq(poll_stops, 0,
			"the user must be able to click Copy again after a transient refusal")
		helpers.assert_eq(reset_requests, 1)
		helpers.assert_true(#errors > 0,
			"the asynchronous refusal must reach the file logger")
	end)
end)
