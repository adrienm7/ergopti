--- tests/unit/ui/test_download_window_setmodel_js_escaping.lua

--- ==============================================================================
--- MODULE: Download Window JavaScript String Escaping Regressions
--- DESCRIPTION:
--- Exercises the real window's model, error, step, detail and log payloads.
--- Backslashes must be escaped before quotes, and subprocess control bytes
--- must remain escaped inside the JavaScript string literal. In particular,
--- PTY error tails can retain CR even when normal streaming lines are split.
--- ==============================================================================

local helpers = require("tests.helpers")

local make_webview_overrides = require("tests.support.download_window_fixture").make_webview_overrides

helpers.describe("download_window: setModel() routes through js_str() (F-LOW-16)", function()
	helpers.it("a model name containing a backslash and a quote is safely escaped", function()
		-- Two test-isolation footguns pre-existing elsewhere in this suite, both
		-- fixed the same way — force a fresh real module before load_with_stubs
		-- re-requires ui.download_window below:
		--  1. Many other test files install a partial lib.logger stub via
		--     package.loaded and never restore it; download_window/init.lua
		--     captures `local Logger = require("infra.logger")` at require-time.
		--  2. ui_builder.lua captures `local hs = hs` at require-time. Since
		--     load_with_stubs only clears the module under test (not its
		--     dependencies), a cached ui.ui_builder from an earlier test keeps
		--     calling hs.webview.new() against THAT test's stale hs stub instead
		--     of the fresh one this test installs below — so the returned
		--     webview object silently lacks evaluateJavaScript entirely.
		package.loaded["infra.logger"]  = nil
		package.loaded["ui.ui_builder"] = nil

		local overrides, get_evaluated, fire_navigation = make_webview_overrides()
		local DownloadWindow = helpers.load_with_stubs("ui.download_window", overrides)

		-- Not a realistic HuggingFace repo id, but exercises the escaping path
		-- directly regardless of what upstream input validation currently allows.
		local malicious_name = [[evil\model"name]]

		DownloadWindow.show({ kind = "mlx_model", model = malicious_name })
		-- The first show() queues its JS (page not "ready" until navigation
		-- fires); simulate the page finishing load so ui_builder flushes the
		-- queue into evaluateJavaScript, where this test can inspect it.
		fire_navigation()

		local evaluated = get_evaluated()
		local set_model_call = nil
		for _, code in ipairs(evaluated) do
			if code:find("setModel(", 1, true) then set_model_call = code end
		end

		helpers.assert_true(set_model_call ~= nil,
			"a setModel(...) JS call must have been evaluated after didFinishNavigation, found " ..
			tostring(#evaluated) .. " evaluated call(s)")

		-- js_str()'s contract: backslashes escaped BEFORE quotes, so the literal
		-- backslash must appear doubled and the embedded quote must be escaped —
		-- never a bare, unescaped backslash immediately before the closing quote
		-- context (which would break out of the JS string literal).
		helpers.assert_true(set_model_call:find([[evil\\model\"name]], 1, true) ~= nil,
			"setModel() must escape the backslash AND the quote via js_str(), got: " .. tostring(set_model_call))
		helpers.assert_true(set_model_call:find([[evil\model"name]], 1, true) == nil,
			"setModel() must not embed the raw, unescaped model name — got: " .. tostring(set_model_call))
	end)
end)

helpers.describe("download-window-control-character-escaping", function()
	helpers.it("escapes CRLF errors and control bytes in every text presentation path", function()
		package.loaded["infra.logger"] = nil
		package.loaded["ui.ui_builder"] = nil
		local overrides, get_evaluated, fire_navigation = make_webview_overrides()
		local window = helpers.load_with_stubs("ui.download_window", overrides)
		helpers.assert_true(window.show({ kind = "mlx_install" }))
		fire_navigation()
		local input = "error\r\ndetails\t\0\27\"\\"
		for method, js_function in pairs({
			set_error = "setError", set_detail = "setDetail",
			set_step = "setStep", append_log = "addLog",
		}) do
			window[method](input)
			local codes = get_evaluated()
			local code = codes[#codes]
			helpers.assert_eq(code,
				js_function .. '("error\\u000d\\u000adetails\\u0009\\u0000\\u001b\\\"\\\\")',
				"generated JavaScript must preserve text without raw control bytes")
		end
	end)
end)
