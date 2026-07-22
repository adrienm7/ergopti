--- tests/unit/modules/test_karabiner_reset_script_self_destruct.lua

--- Regression test for karabiner-life-3: run_total_reset_async() wrote the
--- reset script to a unique timestamped /tmp path and deleted it only on
--- launch failure. On success the file was never removed, leaking one /tmp
--- entry per async reset call.
---
--- Fix: added `/bin/rm -f "$0"` self-destruct to KARABINER_KILL_TOTAL_SCRIPT
--- so the script removes itself when it finishes, regardless of whether the
--- caller cleans up.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "modules/karabiner/ke_lifecycle.lua"
local fh = io.open(src_path, "r")
if not fh then error("ke_lifecycle.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: the script body must contain the self-destruct line.
-- `$0` is the standard shell idiom for the script's own path.
local has_self_destruct = src:find('rm -f "$0"', 1, true) ~= nil
helpers.assert_true(
	has_self_destruct,
	'ke_lifecycle.lua KARABINER_KILL_TOTAL_SCRIPT must contain /bin/rm -f "$0" self-destruct (karabiner-life-3)'
)

-- Test 2: self-destruct must appear before exit 0 inside the script body.
local script_start = src:find("KARABINER_KILL_TOTAL_SCRIPT", 1, true)
helpers.assert_true(script_start ~= nil, "KARABINER_KILL_TOTAL_SCRIPT must exist (karabiner-life-3)")

local script_region = src:sub(script_start, script_start + 2000)
local self_destruct_pos = script_region:find('rm -f "$0"', 1, true)
local exit_pos          = script_region:find("exit 0", 1, true)
helpers.assert_true(
	self_destruct_pos ~= nil and exit_pos ~= nil and self_destruct_pos < exit_pos,
	'self-destruct rm -f "$0" must appear before exit 0 in the script body (karabiner-life-3)'
)

print("[PASS] test_karabiner_reset_script_self_destruct")
