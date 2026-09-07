--- tests/support/metrics_typing_fixture.lua

--- ==============================================================================
--- MODULE: Typing Metrics Controller Fixture
--- DESCRIPTION:
--- Exposes real dashboard entry points behind controlled timer and native boundaries.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a fresh dashboard around controlled timer and webview boundaries.
--- @param scheduler table TimerScheduler test double.
--- @param subscribe function|nil Ingest-listener acquisition double.
--- @return table module Fresh dashboard module.
--- @return table context Captured UI side effects.
local function load_dashboard(scheduler, subscribe, controls)
	controls = controls or {}
	local context = { deleted = 0, evaluated = 0, webviews_created = 0, on_close = nil }
	local webview = {}
	context.webview = webview
	local native_window = {id = function() return 42 end, focus = function() return true end}
	webview.delete = function()
		context.deleted = context.deleted + 1
		if controls.delete_throws then error("synthetic metrics dashboard delete refusal") end
	end
	webview.evaluateJavaScript = function(self)
		context.evaluated = context.evaluated + 1
		return self
	end
	webview.hswindow = function() return controls.focused and native_window or nil end
	webview.bringToFront = function() end

	package.loaded["adapters.timer_scheduler"] = scheduler
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["hs.fs"] = { dir = function() return function() end, {} end }
	package.loaded["hs.json"] = {
		encode = function() return "{}" end,
		decode = function() return {} end,
	}
	package.loaded["ui.ui_builder"] = {
		show_webview = function(options)
			context.webviews_created = context.webviews_created + 1
			context.on_close = options.on_close
			return webview
		end,
	}
	package.loaded["modules.keylogger.log_manager"] = {
		on_ingest_done = subscribe or function(callback)
			context.on_ingest = callback
			return true
		end,
	}

	local dashboard = helpers.load_with_stubs("ui.metrics_typing.init", {
		screen = {
			mainScreen = function()
				return { frame = function() return { x = 0, y = 0, w = 1400, h = 900 } end }
			end,
		},
		window = { focusedWindow = function() return controls.focused and native_window or nil end },
	})
	return dashboard, context
end

return load_dashboard
