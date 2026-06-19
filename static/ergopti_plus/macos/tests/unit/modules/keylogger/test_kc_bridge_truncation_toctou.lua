--- tests/unit/modules/keylogger/test_kc_bridge_truncation_toctou.lua

--- Regression test for keylogger-support-2: drain_log() opened a second
--- file handle to re-query the live file size just before truncation.
--- Between fh:close() and the new io.open("r"), KE could append fresh
--- lines. The re-query would see the old size (equal to _file_offset),
--- pass the truncation guard, and wipe the newly written lines.
---
--- Fix: removed the second io.open() and instead compared _file_offset
--- against file_size — the size captured when the file was first opened,
--- before the read loop ran.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "modules/keylogger/kc_bridge.lua"
local fh = io.open(src_path, "r")
if not fh then error("kc_bridge.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: The intermediate fh_size re-open for a size check must not exist.
-- Pre-fix code used `local fh_size = io.open(KC_LOG_PATH, "r")` followed by
-- `fh_size:seek("end")` to re-query live file size — that is the TOCTOU source.
local has_fh_size = src:find("fh_size", 1, true) ~= nil
helpers.assert_true(
	not has_fh_size,
	"kc_bridge.lua must not use an fh_size re-open for size check after reading (TOCTOU race) (keylogger-support-2)"
)

-- Test 2: The truncation guard must compare against file_size (captured at open time).
local has_file_size_guard = src:find("_file_offset >= file_size", 1, true) ~= nil
helpers.assert_true(
	has_file_size_guard,
	"kc_bridge.lua drain_log must guard truncation with `_file_offset >= file_size` (keylogger-support-2)"
)

-- Test 3: The truncation write path must still open in "w" mode (not removed entirely).
local has_trunc_write = src:find('io.open(KC_LOG_PATH, "w")', 1, true) ~= nil
helpers.assert_true(
	has_trunc_write,
	"kc_bridge.lua must still truncate via io.open(KC_LOG_PATH, \"w\") when at EOF (keylogger-support-2)"
)

-- F-MED-2: the SPECIFIC re-query TOCTOU above was closed, but the reclaim still
-- fired on EVERY drain-to-EOF and blind-wiped the whole file, losing any line KE
-- appended in the close→reopen window. The fix (a) gates the reclaim on a size
-- cap so it is rare, and (b) PRESERVES the unread tail instead of wiping it.

-- Test 4: the reclaim must be cap-gated, not unconditional on `file_size > 0`.
helpers.assert_true(
	src:find("file_size > KC_LOG_MAX_BYTES", 1, true) ~= nil,
	"kc_bridge.lua reclaim must be gated on `file_size > KC_LOG_MAX_BYTES` (F-MED-2)"
)
helpers.assert_true(
	src:find("file_size > 0 then", 1, true) == nil,
	"the old unconditional `file_size > 0` truncate-on-every-EOF must be gone (F-MED-2)"
)

-- Test 5: the reclaim must rewrite the preserved tail, not blind-wipe the file.
helpers.assert_true(
	src:find("fh_trunc:write(tail)", 1, true) ~= nil,
	"kc_bridge.lua reclaim must rewrite the preserved tail so a concurrent KE append survives (F-MED-2)"
)

print("[PASS] test_kc_bridge_truncation_toctou")
