--- tests/unit/ui/test_personal_info_editor_port_leak.lua

--- Regression test for ui-windows-b-5 (personal-info editor resource leak) —
--- now an architecture-level guard.
---
--- The editor originally spun up a local HTTP server (port 18743) and served a
--- form to the browser; if the tab was closed without hitting /save or /cancel
--- the port stayed bound. The first fix added a SESSION_TIMEOUT_SEC watchdog.
---
--- The editor was since rebuilt as a standalone WKWebView app: it loads the
--- shared frontend (_shared/ui/personal_info_editor) and talks over the
--- usercontent message bridge, exactly like every other editor. That removes
--- the HTTP server entirely, so the port-leak class is impossible by
--- construction. This test guards that stronger invariant: no HTTP server / no
--- bound port, plus explicit teardown (M.close) and webview cleanup on close.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "ui/personal_info_editor/init.lua"
local fh = io.open(src_path, "r")
if not fh then error("personal_info_editor/init.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: No local HTTP server — that was the source of the leak.
helpers.assert_true(
	src:find("hs.httpserver", 1, true) == nil,
	"personal_info_editor must not spin up an HTTP server (port-leak class removed) (ui-windows-b-5)"
)

-- Test 2: The old fixed port must not be bound anywhere.
helpers.assert_true(
	src:find("18743", 1, true) == nil,
	"personal_info_editor must not bind the old fixed HTTP port 18743 (ui-windows-b-5)"
)

-- Test 3: M.close() must still be exposed for explicit teardown.
helpers.assert_true(
	src:find("function M.close()", 1, true) ~= nil,
	"personal_info_editor/init.lua must expose M.close() for explicit teardown (ui-windows-b-5)"
)

-- Test 4: A close_webview() helper must exist to release the WKWebView.
helpers.assert_true(
	src:find("local function close_webview()", 1, true) ~= nil,
	"personal_info_editor/init.lua must define close_webview() to release the webview (ui-windows-b-5)"
)

-- Test 5: The window's on_close must release state so a closed window leaves
-- no dangling resource.
helpers.assert_true(
	src:find("on_close", 1, true) ~= nil,
	"personal_info_editor/init.lua must set an on_close handler that releases state (ui-windows-b-5)"
)

print("[PASS] test_personal_info_editor_port_leak")
