--- tests/unit/ui/model_browser/test_model_browser_bridge.lua

--- ==============================================================================
--- MODULE: Regression — Model Browser bridge silently no-ops on real WKWebView tables (F-HIGH-29)
--- DESCRIPTION:
--- host_bridge.js's makeHostBridge() posts non-string payloads RAW on WKWebView
--- (no JSON.stringify — WebKit itself converts the JS object into a native Lua
--- table), but ensure_ucc()'s callback ran pcall(hs.json.decode, body) on that
--- already-a-table `body`. hs.json.decode expects a JSON *string*, so the decode
--- always threw, the pcall swallowed the error, and BOTH row-click actions —
--- "open_url" (the source-page link) and "select_model" ("Use this model") —
--- silently no-oped with zero logging.
---
--- Fix: read msg.body directly as a table (no hs.json.decode), matching the
--- convention already used by action_picker / hotstring_editor /
--- hotstrings_config_window / metrics_apps (and the sibling changelog window,
--- F-MED-14).
---
--- This test drives the REAL contract: the captured bridge callback is invoked
--- with `{ body = { action = ..., ... } }` — a native Lua table, exactly what
--- WKWebView delivers for a raw-object postMessage — NOT a JSON string. It
--- fails before the fix (hs.json.decode(table) throws, swallowed silently,
--- neither select_model nor open_url fires) and passes after.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds the hs stub surface the model browser window needs to open without
--- a real WKWebView (screen geometry, webview/usercontent constructors, urlevent).
--- @return function get_bridge_callback Returns the captured setCallback fn once M.open() has run.
local function install_hs_stubs()
	_G.hs = _G.hs or {}
	local state = { creates = 0, delete_throws = false, deletes = 0, errors = {} }

	_G.hs.screen = {
		mainScreen = function()
			return {
				frame     = function() return { x = 0, y = 0, w = 1920, h = 1080 } end,
				fullFrame = function() return { x = 0, y = 0, w = 1920, h = 1080 } end,
			}
		end,
		primaryScreen = function() return hs.screen.mainScreen() end,
	}

	local bridge_callback = nil
	_G.hs.webview = _G.hs.webview or {}
	_G.hs.webview.usercontent = {
		new = function(_name)
			return { setCallback = function(_self, fn) bridge_callback = fn end }
		end,
	}
	_G.hs.webview.new = function()
		state.creates = state.creates + 1
		return {
			windowStyle     = function(self) return self end,
			closeOnEscape   = function(self) return self end,
			level           = function(self) return self end,
			shadow          = function(self) return self end,
			html            = function(self) return self end,
			show            = function(self) return self end,
			delete          = function(self)
				state.deletes = state.deletes + 1
				if state.delete_throws then error("synthetic webview delete refusal") end
				return self
			end,
			hswWindow       = function(self) return self end,
			frame           = function(self) return { x = 0, y = 0, w = 880, h = 560 } end,
		}
	end

	_G.hs.urlevent = _G.hs.urlevent or {}
	_G.hs.json = _G.hs.json or {}
	_G.hs.json.encode = function(_t) return "mock_json" end

	-- ui_builder's post-open focus retry (try_focus, added 2026-06-09) always
	-- runs on M.open() and falls into its "handle not ready" branch here since
	-- this stub's webview mock has no working hswindow()/focus(); without a
	-- doAfter stub the very first retry crashes with "attempt to call a nil
	-- value (field 'doAfter')" before the test ever reaches the bridge
	-- assertions. Invoking synchronously just drains the bounded retry loop
	-- (max_attempts = 20) down to the pcall-guarded bringToFront fallback.
	_G.hs.timer = _G.hs.timer or {}
	_G.hs.timer.doAfter = _G.hs.timer.doAfter or function(_delay, fn) fn() end

	local logger = helpers.make_logger_stub()
	logger.callback = function(_, label, fn, ...)
		local args = table.pack(...)
		local results = table.pack(xpcall(function()
			return fn(table.unpack(args, 1, args.n))
		end, debug.traceback))
		if not results[1] then
			state.errors[#state.errors + 1] = tostring(label) .. ": " .. tostring(results[2])
			return false, results[2]
		end
		return true, table.unpack(results, 2, results.n)
	end
	package.loaded["infra.logger"] = logger

	return function() return bridge_callback end, state
end

helpers.describe("model_browser bridge: reads WKWebView tables directly (F-HIGH-29)", function()
	helpers.it("select_model posted as a native table fires on_select and closes the window", function()
		local get_bridge_callback = install_hs_stubs()

		local opened_url = nil
		_G.hs.urlevent.openURL = function(url) opened_url = url; return true end

		package.loaded["ui.model_browser"] = nil
		package.loaded["ui.ui_builder"]    = nil
		local ModelBrowser = require("ui.model_browser")

		local selected_name = nil
		ModelBrowser.open({
			presets       = {},
			active_backend = "mlx",
			active_model  = "",
			models_mgr    = nil,
			on_select     = function(name) selected_name = name end,
		})

		local bridge_callback = get_bridge_callback()
		helpers.assert_true(type(bridge_callback) == "function", "bridge callback must be registered by M.open()")

		-- Real WKWebView contract: msg.body is a native Lua table, not a JSON string.
		bridge_callback({ body = { action = "select_model", name = "gemma-4-E4B-it" } })

		helpers.assert_eq(selected_name, "gemma-4-E4B-it",
			"a native-table select_model message must invoke on_select with the model name (F-HIGH-29)")
		helpers.assert_nil(opened_url, "select_model must not also open a URL")
	end)

	helpers.it("open_url posted as a native table opens the model's source page", function()
		local get_bridge_callback = install_hs_stubs()

		local opened_url = nil
		_G.hs.urlevent.openURL = function(url) opened_url = url; return true end

		package.loaded["ui.model_browser"] = nil
		package.loaded["ui.ui_builder"]    = nil
		local ModelBrowser = require("ui.model_browser")

		local selected_name = nil
		ModelBrowser.open({
			presets        = {},
			active_backend = "mlx",
			active_model   = "",
			models_mgr     = nil,
			on_select      = function(name) selected_name = name end,
		})

		local bridge_callback = get_bridge_callback()
		helpers.assert_true(type(bridge_callback) == "function", "bridge callback must be registered by M.open()")

		local mock_url = "https://huggingface.co/mlx-community/gemma-4-E4B-it"
		bridge_callback({ body = { action = "open_url", url = mock_url } })

		helpers.assert_eq(opened_url, mock_url,
			"a native-table open_url message must open the model's source page (F-HIGH-29)")
		helpers.assert_nil(selected_name, "open_url must not also select a model")

		for _, blocked_url in ipairs({
			"shortcuts://run-shortcut?name=fixture",
			"file:///tmp/fixture",
			"javascript:alert(1)",
			"https:///missing-host",
			"https://safe.example/path\nshortcuts://run-shortcut",
		}) do
			opened_url = nil
			bridge_callback({ body = { action = "open_url", url = blocked_url } })
			helpers.assert_nil(opened_url,
				"the model browser bridge must reject non-HTTP or malformed URLs: " .. blocked_url)
		end

		local mixed_case_url = "HtTp://example.test/model"
		bridge_callback({ body = { action = "open_url", url = mixed_case_url } })
		helpers.assert_eq(opened_url, mixed_case_url,
			"the HTTP scheme allowlist must be case-insensitive")
	end)

	helpers.it("keeps a refused or throwing model selection open for retry", function()
		local get_bridge_callback, state = install_hs_stubs()

		package.loaded["ui.model_browser"] = nil
		package.loaded["ui.ui_builder"]    = nil
		local ModelBrowser = require("ui.model_browser")

		local attempts = 0
		ModelBrowser.open({
			presets        = {},
			active_backend = "mlx",
			active_model   = "",
			models_mgr     = nil,
			on_select      = function()
				attempts = attempts + 1
				if attempts == 1 then return false end
				error("model activation exploded")
			end,
		})

		local bridge_callback = get_bridge_callback()
		bridge_callback({ body = { action = "select_model", name = "retry-model" } })
		helpers.assert_eq(attempts, 1)
		helpers.assert_eq(state.deletes, 0,
			"an explicit activation refusal must keep the browser open")

		bridge_callback({ body = { action = "select_model", name = "retry-model" } })
		helpers.assert_eq(attempts, 2)
		helpers.assert_eq(state.deletes, 0,
			"a throwing activation callback must keep the browser open")
		helpers.assert_eq(#state.errors, 1,
			"the activation exception must reach the central logger once")
		helpers.assert_contains(state.errors[1], "model activation exploded")
	end)

	helpers.it("retains a model browser whose native delete raises", function()
		local _, state = install_hs_stubs()
		package.loaded["ui.model_browser"] = nil
		package.loaded["ui.ui_builder"] = nil
		local ModelBrowser = require("ui.model_browser")
		local context = {
			presets = {},
			active_backend = "mlx",
			active_model = "",
		}

		ModelBrowser.open(context)
		helpers.assert_eq(state.creates, 1)
		state.delete_throws = true
		helpers.assert_eq(ModelBrowser.close(), false,
			"a throwing native delete must remain an explicit close refusal")
		ModelBrowser.open(context)
		helpers.assert_eq(state.creates, 1,
			"a refused close must retain and focus the exact existing window")

		state.delete_throws = false
		helpers.assert_eq(ModelBrowser.close(), true,
			"retry must settle the retained native owner")
		ModelBrowser.open(context)
		helpers.assert_eq(state.creates, 2,
			"only a committed delete may permit a replacement window")
	end)
end)
