--- tests/unit/test_init_boot_logger_format.lua

--- Regression test for init-boot-logger: init.lua had a Logger.warn call
--- that used "{1}" and "{2}" as format placeholders. The Logger uses Lua's
--- string.format under the hood, which does not recognise {N} syntax — only
--- %s, %d, %q, etc. The warning was emitted as a literal string with "{1}"
--- and "{2}" still in it, hiding the actual directory paths from the log.
---
--- Fix: replaced "{1}" and "{2}" with "%s" in the format string.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "../../init.lua"
-- Fallback: look from the test root
local fh = io.open(src_path, "r")
if not fh then
	src_path = helpers.driver_root() .. "init.lua"
	fh = io.open(src_path, "r")
end
if not fh then error("init.lua not readable (tried driver_root/../../init.lua and driver_root/init.lua)") end
local src = fh:read("*a") ; fh:close()

-- Test 1: The old {1}/{2} placeholders must not appear in a Logger call.
local has_old_placeholder = src:find("'{1}'", 1, true) ~= nil or src:find('"{1}"', 1, true) ~= nil
helpers.assert_true(
	not has_old_placeholder,
	"init.lua must not use '{1}' as a Logger format placeholder — use '%s' (init-boot-logger)"
)

-- Test 2: The corrected %s format must appear in the hotstring fallback warning.
-- Use plain search — the literal chars "%s" (percent + s) must appear in the format string.
local has_correct_format = src:find("Logger.info(LOG, \"No shared hotstring groups in '%s'", 1, true) ~= nil
helpers.assert_true(
	has_correct_format,
	"init.lua must use '%%s' in the informational hotstring fallback log (init-boot-logger)"
)

print("[PASS] test_init_boot_logger_format")
