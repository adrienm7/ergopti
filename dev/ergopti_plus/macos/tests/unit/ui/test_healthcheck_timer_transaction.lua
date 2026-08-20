--- tests/unit/ui/test_healthcheck_timer_transaction.lua

--- ==============================================================================
--- MODULE: Healthcheck Timer Transaction Tests
--- DESCRIPTION:
--- Drives the copy-poller lifecycle through activation refusal, retained cleanup
--- debt, and a queued callback after native window close. This protects the exact
--- timer capability instead of asserting one source spelling.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the real healthcheck window with controlled webview and timer owners.
--- @param scheduler table TimerScheduler test double.
--- @return table module Fresh healthcheck module.
--- @return table context Captured native callbacks and side effects.
local function load_healthcheck(scheduler)
	for _, name in ipairs({
		"ui.healthcheck.core", "ui.healthcheck.helpers", "healthcheck.snapshot",
		"infra.logger", "infra.paths", "infra.i18n", "ui.ui_builder",
	}) do package.loaded[name] = nil end

	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub

	local context = { evaluated = 0, deleted = 0, clipboard_writes = 0 }
	local webview = {}
	for _, method in ipairs({
		"windowStyle", "windowTitle", "allowTextEntry", "allowNewWindows",
		"allowGestures", "level", "html", "show",
	}) do webview[method] = function(self) return self end end
	webview.windowCallback = function(self, callback)
		context.window_callback = callback
		return self
	end
	webview.navigationCallback = function(self, callback)
		context.navigation_callback = callback
		return self
	end
	webview.evaluateJavaScript = function(self, _script, callback)
		context.evaluated = context.evaluated + 1
		if callback then
			context.js_callback = callback
			if not context.defer_js_callbacks then callback(false) end
		end
		return self
	end
	webview.delete = function() context.deleted = context.deleted + 1 end

	package.loaded["adapters.timer_scheduler"] = scheduler
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["ui.healthcheck.helpers"] = {}
	package.loaded["healthcheck.snapshot"] = {}
	package.loaded["infra.paths"] = { shared = function() return "/shared" end }
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["ui.ui_builder"] = {
		build_injected_html = function() return "<html></html>" end,
		get_app_geometry = function() return { width = 740, height = 560 } end,
		force_focus = function() end,
	}

	hs_stub.webview.new = function() return webview end
	hs_stub.webview.windowMasks = { titled = 1, closable = 2, miniaturizable = 4 }
	hs_stub.screen.mainScreen = function()
		return { frame = function() return { x = 0, y = 0, w = 1440, h = 900 } end }
	end
	hs_stub.json.encode = function() return "{}" end
	hs_stub.pasteboard.setContents = function()
		context.clipboard_writes = context.clipboard_writes + 1
		return true
	end

	local healthcheck = require("ui.healthcheck.core")
	healthcheck.run = function() return {} end
	healthcheck.format_plain = function() return "diagnostic" end
	return healthcheck, context
end

helpers.describe("healthcheck copy poller transaction", function()
	helpers.it("contains poller acquisition throws and nil returns", function()
		for _, case in ipairs({
			{ label = "throw", every = function() error("poll constructor exploded") end },
			{ label = "nil", every = function() return nil, nil end },
		}) do
			local every_calls = 0
			local healthcheck, context = load_healthcheck({
				every = function(...)
					every_calls = every_calls + 1
					return case.every(...)
				end,
				cancel = function() error("no poll handle exists") end,
				after = function() error("the normal focus helper must avoid fallback scheduling") end,
			})
			healthcheck.show_window()
			local ok, err = pcall(context.navigation_callback, "didFinishNavigation")
			helpers.assert_true(ok, case.label .. " poll acquisition failure must remain logged: " .. tostring(err))
			helpers.assert_eq(every_calls, 1,
				case.label .. " must reach and reject the real poller acquisition boundary")
			local retry_ok, retry_count_or_err = pcall(function()
				context.navigation_callback("didFinishNavigation")
				return every_calls
			end)
			helpers.assert_true(retry_ok,
				case.label .. " refusal must leave navigation retryable: "
					.. tostring(retry_count_or_err))
			helpers.assert_eq(retry_count_or_err, 2,
				case.label .. " refusal must not be published as a live poller")
		end
	end)

	helpers.it("blocks a replacement while uncommitted poller cleanup is refused", function()
		local every_calls = 0
		local cancel_calls = 0
		local scheduler = {
			every = function()
				every_calls = every_calls + 1
				return { timer = {} }, false
			end,
			cancel = function()
				cancel_calls = cancel_calls + 1
				return false
			end,
			after = function() error("the normal focus helper must avoid fallback scheduling") end,
		}
		local healthcheck, context = load_healthcheck(scheduler)
		healthcheck.show_window()
		context.navigation_callback("didFinishNavigation")
		context.navigation_callback("didFinishNavigation")

		helpers.assert_eq(every_calls, 1,
			"a retained exact poller must block a conflicting navigation poller")
		helpers.assert_true(cancel_calls >= 2,
			"each navigation retry must target the retained exact handle")
	end)

	helpers.it("generation-fences a queued poll callback after native close", function()
		local poll_callback = nil
		local scheduler = {
			every = function(_delay, callback)
				poll_callback = callback
				return { timer = {} }, true
			end,
			cancel = function(handle) handle.timer = nil; return true end,
			after = function() error("the normal focus helper must avoid fallback scheduling") end,
		}
		local healthcheck, context = load_healthcheck(scheduler)
		healthcheck.show_window()
		context.navigation_callback("didFinishNavigation")
		helpers.assert_type(poll_callback, "function")
		context.window_callback("closing")
		local evaluated_before_stale = context.evaluated
		poll_callback()

			helpers.assert_eq(context.evaluated, evaluated_before_stale,
			"a queued callback from the closed window must be inert")
	end)

	helpers.it("rechecks ownership after the asynchronous WebKit completion", function()
		local poll_callback = nil
		local scheduler = {
			every = function(_delay, callback)
				poll_callback = callback
				return { timer = {} }, true
			end,
			cancel = function(handle) handle.timer = nil; return true end,
			after = function() error("the normal focus helper must avoid fallback scheduling") end,
		}
		local healthcheck, context = load_healthcheck(scheduler)
		healthcheck.show_window()
		context.navigation_callback("didFinishNavigation")
		local old_close = context.window_callback
		context.defer_js_callbacks = true
		poll_callback()
		local stale_completion = context.js_callback
		helpers.assert_type(stale_completion, "function")

		old_close("closing")
		healthcheck.show_window()
		local deleted_before_stale = context.deleted
		stale_completion(true)

		helpers.assert_eq(context.clipboard_writes, 0,
			"an old WebKit completion must not copy after its window generation closed")
		helpers.assert_eq(context.deleted, deleted_before_stale,
			"an old completion must not delete the replacement diagnostic window")
	end)
end)
