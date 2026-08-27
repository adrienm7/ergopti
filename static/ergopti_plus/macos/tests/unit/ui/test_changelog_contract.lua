--- tests/unit/ui/test_changelog_contract.lua

--- ==============================================================================
--- MODULE: Regression — changelog bridge reads WKWebView tables directly (F-MED-14)
--- DESCRIPTION:
--- host_bridge.js's makeHostBridge() posts non-string payloads RAW on WKWebView
--- (no JSON.stringify — WebKit itself converts the JS object into a native Lua
--- table), but ensure_ucc()'s callback used to run pcall(hs.json.decode, body)
--- on that already-a-table `body` — hs.json.decode expects a JSON *string*, so
--- the decode always threw, the pcall swallowed the error, and "open_url" (the
--- "View on GitHub" button) as well as "fetch" (channel switching) both
--- silently no-oped.
---
--- Fix: read msg.body directly as a table (no hs.json.decode), matching the
--- convention already used by action_picker / hotstring_editor /
--- hotstrings_config_window / metrics_apps.
---
--- This test drives the REAL contract: bridge_callback is invoked with
--- `{ body = { action = "open_url", url = ... } }` — a native Lua table, exactly
--- what WKWebView delivers for a raw-object postMessage — NOT a JSON string. It
--- fails before the fix (hs.json.decode(table) throws, swallowed silently, URL
--- never opened) and passes after.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("Changelog Bridge Contract", function()
	helpers.it("correctly handles open_url messages posted as a native table (F-MED-14)", function()
		-- base_dir is used to find index.html
		_G.base_dir = helpers.driver_root()

		-- Setup global hs mock BEFORE loading anything
		_G.hs = _G.hs or {}

		-- Mock screen and its methods used by ui_builder.lua
		_G.hs.screen = {
			mainScreen = function()
				return {
					frame = function() return {x=0, y=0, w=1920, h=1080} end,
					fullFrame = function() return {x=0, y=0, w=1920, h=1080} end
				}
			end,
			primaryScreen = function()
				return hs.screen.mainScreen()
			end
		}

		-- Mock webview and usercontent
		_G.hs.webview = _G.hs.webview or {}
		local bridge_callback = nil
		_G.hs.webview.usercontent = {
			new = function(name)
				return {
					setCallback = function(self, fn) bridge_callback = fn end
				}
			end
		}

		_G.hs.webview.new = function()
			return {
				windowStyle = function(self) return self end,
				closeOnEscape = function(self) return self end,
				level = function(self) return self end,
				shadow = function(self) return self end,
				html = function(self) return self end,
				show = function(self) return self end,
				delete = function(self) return self end,
				hswWindow = function(self) return self end,
				frame = function(self) return {x=0, y=0, w=800, h=600} end,
			}
		end

		-- Mock urlevent
		local opened_url = nil
		_G.hs.urlevent = _G.hs.urlevent or {}
		_G.hs.urlevent.openURL = function(url)
			opened_url = url
			return true
		end

		-- No hs.json.decode mock: the fixed bridge must not call it at all. If a
		-- regression reintroduces hs.json.decode(body), calling it on a native
		-- table with no decode function defined here raises immediately, which
		-- the assertions below would catch via the swallowed silent no-op.
		_G.hs.json = _G.hs.json or {}
		_G.hs.json.encode = function(t) return "mock_json" end

		-- Manually clear the module and its dependencies to force a fresh load with our global hs
		package.loaded["ui.changelog"] = nil
		package.loaded["ui.ui_builder"] = nil

		-- Load the module
		local changelog = require("ui.changelog")
		local mock_url = "https://github.com/adrienm7/ergopti/releases/tag/v1.0.0"

		-- Call a dummy open to trigger ensure_ucc (which calls usercontent.new)
		changelog.open()

		helpers.assert_true(type(bridge_callback) == "function", "Bridge callback should be registered")

		-- Simulate the message exactly as WKWebView delivers it for a raw-object
		-- postMessage({ action: 'open_url', url: ... }) — msg.body is a native
		-- Lua table, NOT a JSON string.
		local mock_msg = {
			body = { action = "open_url", url = mock_url }
		}

		bridge_callback(mock_msg)

		-- Verify the URL was dispatched to the OS
		helpers.assert_eq(opened_url, mock_url, "The bridge should have opened the correct URL")

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
				"the changelog bridge must reject non-HTTP or malformed URLs: " .. blocked_url)
		end

		local mixed_case_url = "HtTpS://example.test/releases"
		bridge_callback({ body = { action = "open_url", url = mixed_case_url } })
		helpers.assert_eq(opened_url, mixed_case_url,
			"the HTTP scheme allowlist must be case-insensitive")
	end)

	helpers.it("correctly handles fetch messages posted as a native table (F-MED-14)", function()
		_G.base_dir = helpers.driver_root()
		_G.hs = _G.hs or {}
		_G.hs.screen = {
			mainScreen = function()
				return {
					frame = function() return {x=0, y=0, w=1920, h=1080} end,
					fullFrame = function() return {x=0, y=0, w=1920, h=1080} end
				}
			end,
			primaryScreen = function() return hs.screen.mainScreen() end
		}
		_G.hs.webview = _G.hs.webview or {}
		local bridge_callback = nil
		_G.hs.webview.usercontent = {
			new = function(name)
				return { setCallback = function(self, fn) bridge_callback = fn end }
			end
		}
		_G.hs.webview.new = function()
			return {
				windowStyle = function(self) return self end,
				closeOnEscape = function(self) return self end,
				level = function(self) return self end,
				shadow = function(self) return self end,
				html = function(self) return self end,
				show = function(self) return self end,
				delete = function(self) return self end,
				hswWindow = function(self) return self end,
				frame = function(self) return {x=0, y=0, w=800, h=600} end,
			}
		end
		_G.hs.urlevent = _G.hs.urlevent or {}
		_G.hs.urlevent.openURL = function() return true end
		_G.hs.json = _G.hs.json or {}
		_G.hs.json.encode = function(t) return "mock_json" end

		local fetched_channel = nil
		_G.hs.http = _G.hs.http or {}
		_G.hs.http.asyncGet = function(_url, _headers, callback)
			fetched_channel = "called"
		end

		package.loaded["ui.changelog"] = nil
		package.loaded["ui.ui_builder"] = nil
		local changelog = require("ui.changelog")
		changelog.open()

		local mock_msg = { body = { action = "fetch", channel = "dev" } }
		bridge_callback(mock_msg)

		helpers.assert_true(fetched_channel ~= nil,
			"a native-table fetch message must trigger fetch_and_inject (hs.http.asyncGet called)")
	end)
end)
