--- tests/unit/ui/test_healthcheck_timer_transaction.lua

--- ==============================================================================
--- MODULE: Healthcheck Timer Transaction Tests
--- DESCRIPTION:
--- Drives the window's deferred focus through a refused deletion and a native
--- close: a focus continuation of a window that is gone must never bring
--- Hammerspoon forward. The window is presented only through the shared focus
--- helper, never by a level (ui-focus-not-topmost). The copy poller these tests also covered is gone: the
--- page now posts its actions to a message handler
--- (tests/unit/ui/test_healthcheck_bridge_actions.lua).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the real healthcheck window with controlled webview and timer owners.
--- @param scheduler table TimerScheduler test double.
--- @return table module Fresh healthcheck module.
--- @return table context Captured native callbacks and side effects.
local function load_healthcheck(scheduler, title_label)
	for _, name in ipairs({
		"ui.healthcheck.core", "ui.healthcheck.helpers", "healthcheck.snapshot",
		"infra.logger", "infra.paths", "infra.i18n", "ui.ui_builder",
	}) do package.loaded[name] = nil end

	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub

	local context = { evaluated = 0, deleted = 0 }
	local webview = {}
	for _, method in ipairs({
		"windowStyle", "windowTitle", "allowTextEntry", "allowNewWindows",
		"allowGestures", "level", "html", "show", "shadow",
	}) do webview[method] = function(self) return self end end
	webview.windowTitle = function(self, title) context.title = title return self end
	webview.windowCallback = function(self, callback)
		context.window_callback = callback
		return self
	end
	webview.navigationCallback = function(self, callback)
		context.navigation_callback = callback
		return self
	end
	webview.evaluateJavaScript = function(self)
		context.evaluated = context.evaluated + 1
		return self
	end
	webview.delete = function() context.deleted = context.deleted + 1 end

	package.loaded["adapters.timer_scheduler"] = scheduler
	local logger = helpers.make_logger_stub()
	context.warnings = {}
	logger.warn = function(_, message, ...)
		context.warnings[#context.warnings + 1] = string.format(message, ...)
	end
	package.loaded["infra.logger"] = logger
	package.loaded["ui.healthcheck.helpers"] = {}
	package.loaded["healthcheck.snapshot"] = {}
	local compose_title = require("ui.ui_builder").window_title
	package.loaded["infra.paths"] = { shared = function() return "/shared" end }
	package.loaded["infra.i18n"] = { get = function(key)
		return key == "menu.debug.healthcheck" and title_label or key
	end }
	package.loaded["ui.ui_builder"] = {
		build_injected_html = function() return "<html></html>" end,
		window_chrome_steps = function() return {} end,
		get_app_geometry = function() return { width = 860, height = 720 } end,
		window_title = compose_title,
		force_focus = function() return true end,
	}

	hs_stub.webview.new = function() return webview end
	hs_stub.webview.windowMasks = { titled = 1, closable = 2, miniaturizable = 4 }
	hs_stub.screen.mainScreen = function()
		return { frame = function() return { x = 0, y = 0, w = 1440, h = 900 } end }
	end
	hs_stub.json.encode = function() return "{}" end

	local healthcheck = require("ui.healthcheck.core")
	healthcheck.run = function() return {} end
	return healthcheck, context
end

helpers.describe("healthcheck window focus ownership", function()
	helpers.it("sends one localized product prefix to the native title owner in every locale", function()
		local Json = require("json")
		local function read_json(relative)
			local file = assert(io.open(helpers.shared(relative), "rb"))
			local text = file:read("*a")
			file:close()
			return Json.decode(text)
		end
		local locales = read_json("data/locale_order.json").order
		helpers.assert_eq(#locales, 21)
		for _, locale in ipairs(locales) do
			local label = read_json("data/locales/" .. locale .. ".json")["menu.debug.healthcheck"]
			local healthcheck, context = load_healthcheck({ cancel = function() return true end }, label)
			helpers.assert_true(healthcheck.show_window())
			helpers.assert_eq(context.title, "ErgoptiPlus — " .. label, locale .. " native title")
			context.window_callback("closing")
		end
	end)

	helpers.it("(ui-focus-not-topmost) healthcheck presents only through the shared focus helper", function()
		local healthcheck, context = load_healthcheck({ cancel = function() return true end })
		local view = hs.webview.new()
		local presented = {}
		package.loaded["ui.ui_builder"].force_focus = function(target, is_new, lifecycle)
			presented[#presented + 1] = { target = target, is_new = is_new, lifecycle = lifecycle }
			return true
		end
		view.bringToFront = function() error("bringToFront pins the diagnostics window above other apps") end
		helpers.assert_true(healthcheck.show_window())
		helpers.assert_eq(#presented, 1)
		helpers.assert_true(presented[1].target == view, "the exact diagnostics window is presented")
		helpers.assert_eq(presented[1].is_new, true)
		helpers.assert_eq(presented[1].lifecycle.is_current(), true)
		context.window_callback("closing")
	end)

	helpers.it("(webview-focus-owner) healthcheck refused deletion permanently revokes deferred focus", function()
		local healthcheck = load_healthcheck({ cancel = function() return true end })
		local view = hs.webview.new()
		require("tests.support.webview_focus_fixture").check(view,
			function() return healthcheck.show_window() end,
			function()
				view.delete = function() error("native deletion refused") end
				helpers.assert_eq(healthcheck.show_window(), false)
			end)
	end)

	helpers.it("(webview-focus-owner) healthcheck native close revokes initial deferred focus", function()
		local healthcheck, context = load_healthcheck({ cancel = function() return true end })
		require("tests.support.webview_focus_fixture").check(hs.webview.new(),
			function() return healthcheck.show_window() end,
			function() context.window_callback("closing") end)
	end)
end)
