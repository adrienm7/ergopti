--- tests/unit/lib/test_vscode_bridge_estimate_nil_guard.lua

--- Regression test for lib-update-04: vscode_bridge.lua estimate_position()
--- computed caret.line - caret.visibleStartLine without nil-checking either
--- field. A POST body like {"active":true} stored verbatim via /caret caused
--- the arithmetic to throw (number expected, got nil), violating the
--- @return table|nil contract.
---
--- Fix: added an explicit nil/type check for caret.line, caret.visibleStartLine,
--- and caret.character before the arithmetic — returns nil on incomplete data.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "lib/vscode_bridge.lua"
local fh = io.open(src_path, "r")
if not fh then error("vscode_bridge.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Locate estimate_position body.
local fn_pos = src:find("function M.estimate_position()", 1, true)
helpers.assert_true(fn_pos ~= nil, "vscode_bridge.lua must define M.estimate_position (lib-update-04)")
local fn_body = src:sub(fn_pos, fn_pos + 700)

-- Test 1: type-check for caret.line must exist before the arithmetic.
local has_line_check = fn_body:find('type(caret.line) ~= "number"', 1, true) ~= nil
helpers.assert_true(
	has_line_check,
	'estimate_position must type-check caret.line before arithmetic (lib-update-04)'
)

-- Test 2: type-check for caret.visibleStartLine must exist.
local has_vsl_check = fn_body:find('type(caret.visibleStartLine) ~= "number"', 1, true) ~= nil
helpers.assert_true(
	has_vsl_check,
	'estimate_position must type-check caret.visibleStartLine (lib-update-04)'
)

-- Test 3: type-check for caret.character must exist.
local has_char_check = fn_body:find('type(caret.character) ~= "number"', 1, true) ~= nil
helpers.assert_true(
	has_char_check,
	'estimate_position must type-check caret.character (lib-update-04)'
)

-- Test 4: the guard must return nil on failure (before the subtraction).
local guard_end = fn_body:find("return nil", 1, true)
local arith_pos = fn_body:find("caret.line - caret.visibleStartLine", 1, true)
helpers.assert_true(
	guard_end ~= nil and arith_pos ~= nil and guard_end < arith_pos,
	"estimate_position guard must return nil before the line subtraction (lib-update-04)"
)

print("[PASS] test_vscode_bridge_estimate_nil_guard")
