--- tests/unit/ui/test_download_window_resolve_gated.lua

--- ==============================================================================
--- MODULE: Regression — download window "resolve" bridge message reachability (F-MED-15)
--- DESCRIPTION:
--- ui/download_window/init.lua's bridge callback fully implements the "log in
--- and retry" flow for a gated/private HuggingFace repo: when msg.body ==
--- "resolve" it invokes opts.on_resolve (wired by
--- models_manager_mlx_download.lua to do_resolve_gated, which prompts an HF
--- login then retries). But the JS frontend
--- (_shared/ui/download_window/script.js) never had a trigger that posted
--- "resolve" — doRetry() always posted "retry", so the entire login flow was
--- permanently unreachable dead code.
---
--- Fix: script.js's done() now records the error_kind Lua passes it (already
--- threaded through models_manager_mlx_download.lua as "gated" on a
--- gated/private-repo failure); doRetry() posts "resolve" instead of "retry"
--- when the last failure was gated, reusing the existing retry button and the
--- existing message-posting convention (a single string argument, matching
--- doCancel/doTerm) rather than inventing a new bridge message shape.
---
--- This test drives the REAL bridge callback registered by
--- ui/download_window/init.lua with the message shape the fixed JS button
--- sends (`{ body = "resolve" }`), and asserts the on_resolve callback wired
--- via M.show() fires — it already passed before this fix (the Lua side was
--- never broken), but is the missing coverage proving the message shape the
--- new JS button sends is exactly what M.show()'s on_resolve contract expects.
--- The JS-side wiring itself is verified by source inspection below, since
--- it has no live WebView to execute against in this suite.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Installs the minimal hs.webview stub download_window/init.lua needs at
--- module load time (its usercontent bridge is created outside any function).
--- @return function get_bridge_callback Returns the captured setCallback fn.
local function make_webview_overrides()
	local captured_cb = nil
	local overrides = {
		webview = {
			new = function() return {
				frame              = function(self) return { x = 0, y = 0, w = 460, h = 380 } end,
				evaluateJavaScript = function(self, _code) end,
				delete             = function(self) end,
			} end,
			usercontent = {
				new = function(_name)
					return { setCallback = function(_self, fn) captured_cb = fn end }
				end,
			},
		},
		screen = {
			mainScreen = function()
				return { frame = function() return { x = 0, y = 0, w = 1920, h = 1080 } end }
			end,
		},
	}
	return overrides, function() return captured_cb end
end

helpers.describe("download_window: 'resolve' bridge message triggers on_resolve (F-MED-15)", function()
	helpers.it("msg.body == 'resolve' invokes the on_resolve callback wired via M.show()", function()
		local overrides, get_bridge_callback = make_webview_overrides()
		local DownloadWindow = helpers.load_with_stubs("ui.download_window", overrides)

		local bridge_callback = get_bridge_callback()
		helpers.assert_true(type(bridge_callback) == "function",
			"the dl_bridge usercontent callback must be registered at module load time")

		local resolve_calls = 0
		DownloadWindow.show({
			kind       = "mlx_model",
			model      = "gemma-4-E4B-it",
			on_resolve = function() resolve_calls = resolve_calls + 1 end,
		})

		bridge_callback({ body = "resolve" })

		helpers.assert_eq(resolve_calls, 1,
			"msg.body == 'resolve' must invoke on_resolve exactly once — the message shape " ..
			"the fixed JS doRetry() now sends for a gated error (F-MED-15)")
	end)

	helpers.it("msg.body == 'retry' still invokes on_retry (no regression to the plain retry path)", function()
		local overrides, get_bridge_callback = make_webview_overrides()
		local DownloadWindow = helpers.load_with_stubs("ui.download_window", overrides)

		local bridge_callback = get_bridge_callback()
		local retry_calls = 0
		local resolve_calls = 0
		DownloadWindow.show({
			kind      = "mlx_model",
			model     = "gemma-4-E4B-it",
			on_retry  = function() retry_calls = retry_calls + 1 end,
			on_resolve = function() resolve_calls = resolve_calls + 1 end,
		})

		bridge_callback({ body = "retry" })

		helpers.assert_eq(retry_calls, 1, "msg.body == 'retry' must still invoke on_retry")
		helpers.assert_eq(resolve_calls, 0, "msg.body == 'retry' must NOT invoke on_resolve")
	end)
end)




--- =================================
--- ===== JS-side source wiring =====
--- =================================

helpers.describe("download_window script.js: doRetry() posts 'resolve' for a gated error (F-MED-15)", function()
	local function read_js_source()
		local path = helpers.driver_root() .. "../_shared/ui/download_window/script.js"
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "_shared/ui/download_window/script.js must be readable")
		local src = fh:read("*a"); fh:close()
		return src
	end

	helpers.it("doRetry() branches on globalErrorKind and posts 'resolve' for a gated error", function()
		local src = read_js_source()
		local retry_pos = src:find("function doRetry%(%)")
		helpers.assert_true(retry_pos ~= nil, "script.js must define doRetry()")
		local retry_body = src:sub(retry_pos, retry_pos + 300)
		helpers.assert_true(retry_body:find("'resolve'", 1, true) ~= nil,
			"doRetry() must be able to post 'resolve' — the Lua-side log-in-and-retry flow " ..
			"was previously unreachable dead code (F-MED-15)")
		helpers.assert_true(retry_body:find("globalErrorKind", 1, true) ~= nil,
			"doRetry() must branch on the last error_kind to decide 'resolve' vs 'retry'")
	end)

	helpers.it("done() records errorKind into globalErrorKind", function()
		local src = read_js_source()
		local done_pos = src:find("function done%(isSuccess, message, errorKind%)")
		helpers.assert_true(done_pos ~= nil, "script.js must define done(isSuccess, message, errorKind)")
		local done_body = src:sub(done_pos, done_pos + 200)
		helpers.assert_true(done_body:find("globalErrorKind%s*=%s*errorKind"),
			"done() must record errorKind into globalErrorKind so doRetry() can read it later")
	end)
end)
