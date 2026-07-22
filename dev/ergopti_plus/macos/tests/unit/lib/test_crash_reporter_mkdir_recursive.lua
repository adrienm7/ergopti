--- tests/unit/lib/test_crash_reporter_mkdir_recursive.lua

--- Regression test for lib-update-05: crash_reporter.lua M.save() used a
--- two-level mkdir (parent + dir). If two or more ancestor directories were
--- absent simultaneously the mkdir of the parent would fail, and the dir
--- mkdir would also fail, leaving the crash reports directory uncreateable.
---
--- Fix: replaced with a loop that splits the target path into segments and
--- creates each missing ancestor before the leaf directory.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "lib/crash_reporter.lua"
local fh = io.open(src_path, "r")
if not fh then error("crash_reporter.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: The old 2-level approach must not appear.
local has_old_approach = src:find('dir:match("^(.*[/\\\\])[^/\\\\]+[/\\\\]?%$")', 1, true) ~= nil
	or src:find("local parent = dir:match", 1, true) ~= nil
helpers.assert_true(
	not has_old_approach,
	"crash_reporter.lua must not use the old 2-level (parent + dir) mkdir approach (lib-update-05)"
)

-- Test 2: The recursive mkdir loop must iterate over path segments.
local has_segments = src:find("segments", 1, true) ~= nil
helpers.assert_true(
	has_segments,
	"crash_reporter.lua must use a segments-based recursive mkdir loop (lib-update-05)"
)

-- Test 3: hs.fs.mkdir must still be called (not replaced with os.execute).
local has_mkdir_call = src:find("hs.fs.mkdir(built)", 1, true) ~= nil
helpers.assert_true(
	has_mkdir_call,
	"crash_reporter.lua must call hs.fs.mkdir(built) inside the recursive loop (lib-update-05)"
)

print("[PASS] test_crash_reporter_mkdir_recursive")
