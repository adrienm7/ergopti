--- tests/unit/modules/dynamic_hotstrings/test_rules_engine_stop_clears_rules.lua

--- Regression test for dynhotstrings-5: rules_engine.stop() only cleared
--- _km but did not call SharedEngine.reset_rules(). On the next start(),
--- register_date_rules() was called again, appending three duplicate rules
--- to the shared engine and causing double-expansion of "td", "dt", "date".
---
--- Fix: added SharedEngine.reset_rules() at the top of M.stop() so the
--- date rules are cleared before the engine is re-initialized.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "modules/dynamic_hotstrings/rules_engine.lua"
local fh = io.open(src_path, "r")
if not fh then error("rules_engine.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Locate the stop() function body.
local stop_start = src:find("function M.stop()", 1, true)
helpers.assert_true(
	stop_start ~= nil,
	"rules_engine.lua must define M.stop() (dynhotstrings-5)"
)

local stop_body = src:sub(stop_start, stop_start + 300)

-- Test 1: reset_rules() must be called inside stop().
local has_reset = stop_body:find("reset_rules()", 1, true) ~= nil
helpers.assert_true(
	has_reset,
	"rules_engine.lua M.stop() must call SharedEngine.reset_rules() to prevent rule duplication on reload (dynhotstrings-5)"
)

-- Test 2: _km = nil must still be present (the original cleanup must not have been removed).
local has_km_nil = stop_body:find("_km = nil", 1, true) ~= nil
helpers.assert_true(
	has_km_nil,
	"rules_engine.lua M.stop() must still clear _km = nil (dynhotstrings-5)"
)

-- Test 3: SharedEngine is required at the top of the file.
local has_shared_engine = src:find("SharedEngine", 1, true) ~= nil
helpers.assert_true(
	has_shared_engine,
	"rules_engine.lua must reference SharedEngine (dynhotstrings-5)"
)

print("[PASS] test_rules_engine_stop_clears_rules")
