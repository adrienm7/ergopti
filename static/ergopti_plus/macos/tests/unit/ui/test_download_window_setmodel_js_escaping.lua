--- tests/unit/ui/test_download_window_setmodel_js_escaping.lua

--- ==============================================================================
--- MODULE: Regression — setModel() call sites bypass js_str() escaping (F-LOW-16)
--- DESCRIPTION:
--- ui/download_window/init.lua already has a correct js_str() helper (used
--- everywhere else in the file for JS string injection: setKind, injectError,
--- addLog, …) that escapes backslashes BEFORE quotes. But the two setModel()
--- call sites in M.show() hand-rolled their own escaping instead:
---   local safe = M._current_model:gsub("'", "\\'"):gsub("\"", "\\\"")
---   eval("setModel(\"" .. safe .. "\")")
--- This omits backslash-escaping entirely, so a model name containing a
--- backslash would break out of the generated JS string literal. Not reachable
--- today given the constrained model-name input pattern (HuggingFace repo ids),
--- but worth hardening — and it duplicates escaping logic js_str() already
--- centralises.
---
--- Fix: route both call sites through js_str(), like every other injection
--- site in the file.
---
--- This test drives M.show() with a model name containing a double quote and
--- a backslash and asserts the queued JS payload safely escapes both — it
--- fails before the fix (backslash left unescaped, breaking the JS string) and
--- passes after.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Installs the minimal hs.webview stub download_window/init.lua needs at
--- module load time (its usercontent bridge is created outside any function),
--- captures the navigationCallback handler so the test can simulate
--- "didFinishNavigation" (flushing ui_builder's queued eval() calls into
--- evaluateJavaScript), and records every JS snippet actually executed.
--- @return table overrides hs_overrides for helpers.load_with_stubs.
--- @return function get_evaluated Returns the array of JS code strings executed so far.
--- @return function fire_navigation Simulates "didFinishNavigation" on the last-created webview.
local function make_webview_overrides()
	local evaluated = {}
	local nav_callback = nil
	local overrides = {
		webview = {
			new = function()
				local wv
				wv = {
					frame              = function(_self) return { x = 0, y = 0, w = 460, h = 380 } end,
					evaluateJavaScript = function(_self, code) evaluated[#evaluated + 1] = code end,
					delete             = function(_self) end,
					navigationCallback = function(_self, fn) nav_callback = fn end,
					windowCallback     = function(_self, _fn) end,
					windowTitle        = function(self) return self end,
					windowStyle        = function(self) return self end,
					level              = function(self) return self end,
					allowTextEntry     = function(self) return self end,
					allowGestures      = function(self) return self end,
					allowNewWindows    = function(self) return self end,
					html               = function(self) return self end,
					show               = function(self) return self end,
				}
				return wv
			end,
			usercontent = {
				new = function(_name)
					return { setCallback = function(_self, _fn) end }
				end,
			},
			windowMasks = {},
		},
		screen = {
			mainScreen = function()
				return { frame = function() return { x = 0, y = 0, w = 1920, h = 1080 } end }
			end,
		},
	}
	return overrides,
		function() return evaluated end,
		function() if nav_callback then nav_callback("didFinishNavigation") end end
end

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
