--- tests/unit/ui/dialogs/lifecycle/test_permission_native_window_release.lua

--- ==============================================================================
--- MODULE: Permission Dialog Native Window Release
--- DESCRIPTION:
--- Runs the real dialog and WebView factory over the packaged binding's window
--- reference contract: user close retains udRef by default; deleteOnClose or
--- explicit deletion releases it. Visible explicit delete completes later,
--- and its second GC attempt tolerates a userdata already retired by close.
--- ==============================================================================

local helpers = require("tests.helpers")
require("logger")

--- Models libwebview.m at packaged pin 1469832361b4c3687ec7d589c1b4efe4d3b742ee.
--- @param scenario function Complete dialog and deferred native cleanup scenario.
local function with_windows(scenario)
	helpers.with_stub_scope({
		"ui.permission_dialog", "ui.ui_builder", "ui.webview_close_owner", "adapters.timer_scheduler", "infra.deferred_work",
		"infra.log_folders", "locale.core", "json", "adapters.json_codec", "diagnostics.redact",
		"window_titles", "webview.presentation", "infra.launcher_environment", "adapters.log_transport",
		"app_dirs", "infra.logger", "infra.locale", "_generated.logger_sub_files", "webview.i18n_seed",
		"tests.support.native_webview_close_fixture",
	}, function()
		local h = { windows = {}, retained = {}, script_refs = {}, deferred = {}, closed = 0 }
		local new_window = require("tests.support.native_webview_close_fixture")(h)
		h.dialog = helpers.load_with_stubs("ui.permission_dialog", {
			webview = { new = new_window, windowMasks = { titled = 1, closable = 2, utility = 16 },
				usercontent = { new = function()
					local controller = {}
					function controller:setCallback(callback)
						if callback == nil and h.release_refuses then error("native script unref refusal") end
						h.script_refs[self] = callback
						return self
					end
					return controller
				end } },
			drawing = { windowLevels = { normal = 0, floating = 3 } },
			focus = function() end,
			screen = { mainScreen = function()
				return { frame = function() return { x = 0, y = 0, w = 1400, h = 900 } end }
			end },
		})
		function h.show(kind, on_closed)
			return h.dialog.show({ kind = kind or "accessibility", bundle_path = "/Applications/Hammerspoon.app",
				open_settings = function() return true end, on_closed = on_closed or function() h.closed = h.closed + 1 end })
		end
		function h.drain()
			h.drain_native_close()
		end
		scenario(h)
	end)
end

helpers.describe("permission native window reference lifetime", function()
	for _, kind in ipairs({ "accessibility", "login_items" }) do
		helpers.it("releases the native window after the user closes " .. kind, function()
			with_windows(function(h)
				helpers.assert_true(h.show(kind))
				local first = h.windows[1]
				helpers.assert_true(h.show(kind))
				helpers.assert_eq(#h.windows, 1, "raising a still-open dialog must reuse its native owner")
				helpers.assert_true(h.retained[first])
				helpers.assert_eq(h.closed, 0)
				first:user_close()
				h.drain()
				helpers.assert_eq(h.dialog.is_open(), false)
				helpers.assert_nil(next(h.script_refs), "native script callback must be unreferenced")
				helpers.assert_nil(h.retained[first], "closed native window must release its own Lua reference")
				helpers.assert_eq(h.closed, 1)
			end)
		end)
	end

	helpers.it("preserves deferred explicit deletion with an idempotent second native GC", function()
		with_windows(function(h)
			helpers.assert_true(h.show())
			local first = h.windows[1]
			helpers.assert_true(h.dialog.close())
			helpers.assert_eq(#h.deferred, 1, "explicit deletion must keep the binding's deferred completion")
			helpers.assert_true(h.retained[first])
			helpers.assert_true(h.show())
			local successor = h.windows[2]
			h.drain()
			helpers.assert_nil(h.retained[first])
			helpers.assert_true(h.retained[successor])
			helpers.assert_true(h.dialog.is_open())
			helpers.assert_eq(first.deletes, 1)
			helpers.assert_eq(h.closed, 1)
		end)
	end)

	helpers.it("keeps the window opened by a native close owner", function()
		with_windows(function(h)
			helpers.assert_true(h.show(nil, function()
				h.closed = h.closed + 1
				helpers.assert_true(h.show("login_items"))
			end))
			h.windows[1]:user_close()
			h.drain()
			helpers.assert_nil(h.retained[h.windows[1]])
			helpers.assert_true(h.retained[h.windows[2]])
			helpers.assert_true(h.dialog.is_open("login_items"))
			helpers.assert_eq(h.closed, 1)
		end)
	end)

	helpers.it("retains script cleanup debt after native window retirement", function()
		with_windows(function(h)
			helpers.assert_true(h.show())
			h.release_refuses = true
			h.windows[1]:user_close()
			h.drain()
			helpers.assert_nil(h.retained[h.windows[1]])
			helpers.assert_not_nil(next(h.script_refs))
			helpers.assert_eq(h.show(), false)
			h.release_refuses = false
			helpers.assert_true(h.dialog.close())
			helpers.assert_nil(next(h.script_refs))
			helpers.assert_eq(h.windows[1].deletes, 1, "controller cleanup cannot repeat the deferred window deletion")
			helpers.assert_eq(h.closed, 1)
		end)
	end)

	for _, refusal in ipairs({ "throw", "false", "nil" }) do
		helpers.it("rolls back the exact native window when automatic retirement returns " .. refusal, function()
			with_windows(function(h)
				h.policy_refuses = refusal
				helpers.assert_eq(h.show(), false)
				h.drain()
				helpers.assert_nil(next(h.retained))
				helpers.assert_nil(next(h.script_refs))
				helpers.assert_eq(h.closed, 0, "a window never opened must not notify a close")
			end)
		end)
	end

	helpers.it("leaves ordinary factory windows under their existing explicit deletion owner", function()
		with_windows(function(h)
			local window = require("ui.ui_builder").show_webview({ title = "Ordinary", focus = false,
				html_string = "<html></html>" })
			helpers.assert_not_nil(window)
			window:user_close()
			h.drain()
			helpers.assert_true(h.retained[window], "automatic retirement is an explicit opt-in only")
			window:delete()
			helpers.assert_nil(h.retained[window])
		end)
	end)
end)
