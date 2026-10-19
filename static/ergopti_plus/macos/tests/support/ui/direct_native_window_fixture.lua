--- tests/support/ui/direct_native_window_fixture.lua

--- ==============================================================================
--- MODULE: Direct Diagnostics Native Window Fixture
--- DESCRIPTION:
--- Runs real direct controllers over the pinned native reference model. Report
--- content and presentation are ports; the real scheduler independently owns
--- native timers. Window visibility never substitutes for userdata retirement.
--- ==============================================================================

local helpers = require("tests.helpers")
require("logger")

--- Composes one direct controller with observable native ownership roots.
--- @param domain string healthcheck or error.
--- @param scenario function Receives native observations and public actions.
local function with_window(domain, scenario)
	return helpers.with_stub_scope({
		"ui.healthcheck.core", "ui.healthcheck.helpers", "healthcheck.snapshot", "healthcheck.cleanup", "healthcheck.actions",
		"ui.error_dialog", "diagnostics.error_policy", "diagnostics.error_report", "diagnostics.issue_report", "diagnostics.redact",
		"infra.logger", "infra.paths", "infra.i18n", "ui.ui_builder", "ui.webview_close_owner", "infra.deferred_work",
		"adapters.timer_scheduler", "adapters.storage", "ui.healthcheck.report", "hs", "tests.stubs.hs",
		"tests.support.webview_recursive_close_fixture", "json", "adapters.json_codec",
	}, function()
		local h = { windows = {}, retained = {}, deferred = {}, errors = {}, notification_depth = 0,
			timers = {}, script_refs = {}, controllers = {}, serial = 0 }
		local logger = helpers.make_logger_stub()
		logger.error = function(_, format, ...)
			h.errors[#h.errors + 1] = string.format(format, ...)
			if h.on_error then h.on_error() end
		end
		logger.debug = function(_, format)
			if h.on_debug then h.on_debug(format) end
		end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.paths"] = { shared = helpers.shared }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["adapters.storage"] = { get = function() return true end, set = function() return true end }
		package.loaded["ui.ui_builder"] = {
			window_title = function(value) return "ErgoptiPlus — " .. tostring(value) end,
			get_app_geometry = function() return { width = 700, height = 600 } end,
			build_injected_html = function() return "<html></html>" end,
			window_chrome_steps = function() return {} end, force_focus = function() return true end,
		}
		package.loaded["tests.stubs.hs"] = nil
		local native = require("tests.stubs.hs")
		_G.hs, package.loaded["hs"] = native, native
		local make = require("tests.support.webview_recursive_close_fixture")(h)
		native.webview.new = function()
			local view = make()
			local policy = view.allowNewWindows
			function view:allowNewWindows(value)
				if value ~= nil and h.child_refusal then
					if h.child_refusal == "throw" then error("native child policy refused") end
					if h.child_refusal == "unapplied" then return self end
					if h.child_refusal == "false" then return false end
					return nil
				end
				return policy(self, value)
			end
			local bind = view.windowCallback
			function view:windowCallback(callback)
				if h.bind_refusal == "throw" then error("native close callback binding refused") end
				if h.bind_refusal == "false" then return false end
				return bind(self, callback)
			end
			function view:html()
				h.html_calls = (h.html_calls or 0) + 1
				h.html_auto_gc, h.html_children = self.native.delete_on_close, self.native.allow_new_windows
				return self
			end
			function view:evaluateJavaScript() return self end
			return view
		end
		native.webview.usercontent.new = function()
			local controller = {}
			function controller:setCallback(callback) h.script_refs[self] = callback; return self end
			h.controllers[#h.controllers + 1] = controller
			return controller
		end
		native.webview.windowMasks = { titled = 1, closable = 2, resizable = 8 }
		native.screen.mainScreen = function()
			return { frame = function() return { x = 0, y = 0, w = 1400, h = 900 } end }
		end
		native.timer.absoluteTime = function() return 1000000000 end
		native.timer.new = function(delay, receive)
			if h.timer_new_refusal then return nil end
			local timer = { active = false, delay = delay }
			function timer:start() self.active = true; return self end
			function timer:stop()
				if h.timer_stop_refusal then return false end
				self.active = false
				return self
			end
			function timer:running() return self.active end
			function timer:deliver() if self.active then receive() end end
			h.timers[#h.timers + 1] = timer
			return timer
		end
		local product
		if domain == "healthcheck" then
			package.loaded["ui.healthcheck.helpers"], package.loaded["healthcheck.snapshot"] = {}, {}
			product = require("ui.healthcheck.core")
			product.run = function() return {} end
			product.config = function() return { schema = {}, templates = {} } end
		else
			package.loaded["ui.healthcheck.core"] = {
				DRIVER = "macos", config = function() return { redaction = {} } end,
				run = function() return { generated_at = "2026-10-18", sections = {
					paths = { errors_today = "/virtual/errors.log" } } } end,
			}
			package.loaded["ui.healthcheck.report"] = { redaction_context = function() return {} end }
			product = require("ui.error_dialog")
			assert(product.init(), "real error policy must initialise")
		end
		function h.drain()
			for _ = 1, 64 do
				local progressed = false
				local count = #h.deferred
				for _ = 1, count do progressed = true; table.remove(h.deferred, 1)() end
				local snapshot = {}; for _, timer in ipairs(h.timers) do snapshot[#snapshot + 1] = timer end
				for _, timer in ipairs(snapshot) do if timer.active then progressed = true; timer:deliver() end end
				if not progressed then return end
			end
			error("direct window fixture did not settle")
		end
		function h.open()
			h.serial = h.serial + 1
			if domain == "healthcheck" then
				local opened = product.show_window()
				h.close_callback = h.script_refs[h.controllers[#h.controllers]] or h.close_callback
				return opened
			end
			product.on_error("unit.native-close", "signature-" .. h.serial, "signature-" .. h.serial)
			local timer = h.timers[#h.timers]
			if timer then timer:deliver() end
			h.close_callback = h.script_refs[h.controllers[#h.controllers]] or h.close_callback
			local view = h.windows[#h.windows]
			return view ~= nil and getmetatable(view) ~= nil and view.native.visible == true
		end
		function h.close()
			local callback = assert(h.close_callback, "an actual page close callback must have been published")
			callback({ body = { action = "close" } })
		end
		scenario(h, product)
	end)
end

return with_window
