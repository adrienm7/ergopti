--- tests/unit/lib/test_vscode_bridge_install_extension.lua

--- Regression test for lib-update-06: vscode_bridge.lua install_extension()
--- called write_file() twice without checking the return values. If either
--- write failed (e.g. permission denied or directory absent), the function
--- logged "Extension installed" and returned true, misleading the caller.
---
--- Fix: captured both write_file return values and return false with an
--- ERROR log if either write fails.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to infra/vscode_bridge.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function get_editor_ax_frame")
helpers.assert_true(src ~= nil, "infra/vscode_bridge.lua source must be locatable")

-- Locate install_extension body.
local fn_start = src:find("function M.install_extension()", 1, true)
helpers.assert_true(fn_start ~= nil, "vscode_bridge.lua must define M.install_extension() (lib-update-06)")
local fn_body = src:sub(fn_start, fn_start + 1200)

-- Test 1: write_file return values must be captured.
local has_ok_pkg = fn_body:find("ok_pkg", 1, true) ~= nil
local has_ok_ext = fn_body:find("ok_ext", 1, true) ~= nil
helpers.assert_true(
	has_ok_pkg and has_ok_ext,
	"vscode_bridge.lua install_extension must capture write_file return values (ok_pkg, ok_ext) (lib-update-06)"
)

-- Test 2: An early-return on write failure must exist.
local has_fail_return = fn_body:find("not ok_pkg or not ok_ext", 1, true) ~= nil
helpers.assert_true(
	has_fail_return,
	"vscode_bridge.lua install_extension must return false on write failure (lib-update-06)"
)

-- Test 3: The success log must come AFTER the failure check.
local fail_pos    = fn_body:find("not ok_pkg or not ok_ext", 1, true)
local success_pos = fn_body:find("Extension installed in", 1, true)
helpers.assert_true(
	fail_pos ~= nil and success_pos ~= nil and fail_pos < success_pos,
	"vscode_bridge.lua install_extension failure check must precede the success log (lib-update-06)"
)

print("[PASS] test_vscode_bridge_install_extension")
