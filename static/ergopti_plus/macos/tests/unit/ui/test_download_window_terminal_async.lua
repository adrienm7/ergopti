--- tests/unit/ui/test_download_window_terminal_async.lua

--- ==============================================================================
--- MODULE: Regression - asynchronous download-window Terminal action
--- DESCRIPTION:
--- The WebView bridge must hand AppleScript to ShellRunner and return without
--- waiting for osascript. Launch and terminal failures remain visible in logs.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"ui.download_window",
	"ui.ui_builder",
	"infra.logger",
	"adapters.shell_runner",
}

local function make_webview_overrides(state)
	return {
		execute = function()
			state.execute_calls = state.execute_calls + 1
			return "", true
		end,
		webview = {
			new = function()
				local webview = {}
				for _, method in ipairs({
					"windowTitle", "windowStyle", "level", "allowTextEntry",
					"allowGestures", "allowNewWindows",
					"navigationCallback", "html", "show",
				}) do webview[method] = function(self) return self end end
				webview.windowCallback = function(self, callback)
					state.window_callback = callback
					return self
				end
				webview.frame = function() return { x = 0, y = 0, w = 460, h = 380 } end
				webview.evaluateJavaScript = function() end
				webview.delete = function() end
				webview.hswindow = function() return nil end
				return webview
			end,
			usercontent = {
				new = function()
					return { setCallback = function(_self, fn) state.bridge = fn end }
				end,
			},
		},
		screen = {
			mainScreen = function()
				return { frame = function() return { x = 0, y = 0, w = 1920, h = 1080 } end }
			end,
		},
	}
end

local function append_error(state, _tag, fmt, ...)
	state.errors[#state.errors + 1] = string.format(fmt, ...)
end

local function with_terminal_bridge(callback)
	helpers.with_fresh_modules(MODULES, function()
		local state = {
			applescript_calls = 0,
			execute_calls = 0,
			errors = {},
			launch_result = true,
		}
		local logger = helpers.make_logger_stub()
		logger.UNIFIED_LOG_FILE = "/controlled/hammerspoon.log"
		logger.error = function(...) append_error(state, ...) end
		logger.callback = function(module, label, fn, ...)
			local args = table.pack(...)
			local results = table.pack(xpcall(function()
				return fn(table.unpack(args, 1, args.n))
			end, debug.traceback))
			if not results[1] then
				logger.error(module, "%s callback threw: %s", label, tostring(results[2]))
				return false, results[2]
			end
			return true, table.unpack(results, 2, results.n)
		end
		package.loaded["infra.logger"] = logger
		package.loaded["adapters.shell_runner"] = {
			applescript = function(script, on_done)
				state.applescript_calls = state.applescript_calls + 1
				state.script = script
				state.on_done = on_done
				return state.launch_result, { marker = "terminal-task" }
			end,
		}

		local DownloadWindow = helpers.load_with_stubs(
			"ui.download_window", make_webview_overrides(state))
		local callback_ok, callback_err = xpcall(function()
			callback(DownloadWindow, state)
		end, debug.traceback)
		package.loaded["adapters.shell_runner"] = nil
		package.loaded["ui.menu.menu_llm.models_manager.download_abort_hook"] = nil
		package.loaded["ui.menu.menu_llm.models_manager.download_retry_hook"] = nil
		if not callback_ok then error(callback_err, 0) end
	end)
end

local function errors_contain(errors, needle)
	for _, message in ipairs(errors) do
		if message:find(needle, 1, true) then return true end
	end
	return false
end

helpers.describe("HS-196: download-window Terminal bridge is asynchronous", function()
	helpers.it("dispatches exact AppleScript and reports launch or completion failure", function()
		with_terminal_bridge(function(DownloadWindow, state)
			helpers.assert_true(type(state.bridge) == "function",
				"download-window bridge callback must be installed")
			helpers.assert_true(DownloadWindow.show({
				kind = "mlx_model",
				model = "controlled-model",
				terminal_cmd = "echo controlled",
			}))

			state.bridge({ body = "terminal" })
			helpers.assert_eq(state.execute_calls, 0,
				"the interactive bridge must never call synchronous hs.execute")
			helpers.assert_eq(state.applescript_calls, 1)
			helpers.assert_eq(state.script,
				"tell application \"Terminal\"\n"
					.. "do script \"echo controlled\"\n"
					.. "activate\n"
					.. "end tell")
			helpers.assert_true(type(state.on_done) == "function")

			state.on_done(false)
			helpers.assert_true(errors_contain(state.errors, "Terminal AppleScript failed"),
				"an asynchronous osascript failure must be logged")

			state.launch_result = false
			state.bridge({ body = "terminal" })
			helpers.assert_true(errors_contain(state.errors, "Terminal AppleScript could not start"),
				"a refused osascript launch must be logged")
		end)
	end)
end)

helpers.describe("HS-198: download-window controllers remain visible", function()
	helpers.it("logs throwing bridge and native-close controllers exactly once", function()
		with_terminal_bridge(function(DownloadWindow, state)
			local calls = { abort = 0, cancel = 0, resolve = 0, retry_hook = 0, retry = 0 }
			package.loaded["ui.menu.menu_llm.models_manager.download_abort_hook"] = function()
				calls.abort = calls.abort + 1
				error("download abort hook exploded", 0)
			end
			package.loaded["ui.menu.menu_llm.models_manager.download_retry_hook"] = function()
				calls.retry_hook = calls.retry_hook + 1
				error("download retry hook exploded", 0)
			end
			helpers.assert_true(DownloadWindow.show({
				kind = "mlx_model",
				on_cancel = function()
					calls.cancel = calls.cancel + 1
					error("download cancel callback exploded", 0)
				end,
				on_resolve = function()
					calls.resolve = calls.resolve + 1
					error("download resolve callback exploded", 0)
				end,
				on_retry = function()
					calls.retry = calls.retry + 1
					error("download retry callback exploded", 0)
				end,
			}))

			state.bridge({ body = "cancel" })
			state.bridge({ body = "resolve" })
			state.bridge({ body = "retry" })
			helpers.assert_type(state.window_callback, "function")
			state.window_callback("closing")

			helpers.assert_eq(calls.abort, 2,
				"bridge cancel and native close must each invoke the abort hook once")
			helpers.assert_eq(calls.cancel, 2,
				"bridge cancel and native close must each invoke the cancel controller once")
			helpers.assert_eq(calls.resolve, 1)
			helpers.assert_eq(calls.retry_hook, 1)
			helpers.assert_eq(calls.retry, 1)
			helpers.assert_eq(#state.errors, 7,
				"every throwing controller invocation must cross the logger once")
			for _, expected in ipairs({
				"Download abort hook", "Download cancel callback",
				"Download resolve callback", "Download retry hook",
				"Download retry callback",
			}) do
				helpers.assert_true(errors_contain(state.errors, expected),
					"missing contextual callback log for " .. expected)
			end
		end)
	end)
end)
