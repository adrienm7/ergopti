--- tests/unit/lib/test_perf_now_nil_guard.lua

--- Regression test for lib-logger-perf-001: perf.lua M.now() contained a
--- fallback branch `return (hs.timer.secondsSinceEpoch() or 0) * 1e9` that
--- dereferenced hs.timer without a nil-guard. If hs.timer itself is nil (e.g.
--- in a headless or stripped runtime), the expression throws instead of
--- falling through to the os.time() last resort.
---
--- Fix: the fallback now checks `hs and hs.timer and hs.timer.secondsSinceEpoch`
--- with a pcall and falls back to os.time() when the table is absent.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to lib/perf.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("function M.report_all")
helpers.assert_true(src ~= nil, "lib/perf.lua source must be locatable")

-- Test 1: the raw dereference `hs.timer.secondsSinceEpoch()` without guard
-- must no longer appear as a bare fallback (unguarded form).
-- We look for the specific pattern that was the bug: the fallback line that
-- accesses hs.timer unconditionally. The fixed code uses a guarded if-block.
local bare_deref = src:match("return%s*%(hs%.timer%.secondsSinceEpoch%(%)%s*or%s*0%)")
helpers.assert_true(
	bare_deref == nil,
	"perf.lua must not dereference hs.timer.secondsSinceEpoch() without a nil-guard (lib-logger-perf-001)"
)

-- Test 2: the os.time() last-resort fallback must be present.
local has_ostime_fallback = src:find("os.time()", 1, true) ~= nil
helpers.assert_true(
	has_ostime_fallback,
	"perf.lua must include an os.time() last-resort fallback in M.now() (lib-logger-perf-001)"
)

-- Test 3: the guard around the secondary fallback must check hs.timer again.
-- Verify that the `if hs and hs.timer and` pattern exists (not just hs.timer.absoluteTime branch).
local guard_count = 0
for _ in src:gmatch("if hs and hs%.timer and") do
	guard_count = guard_count + 1
end
helpers.assert_true(
	guard_count >= 2,
	"perf.lua M.now() must have at least two hs.timer nil-guards (absoluteTime + secondsSinceEpoch) (lib-logger-perf-001)"
)

-- Test 4: pcall must wrap the secondsSinceEpoch call to avoid throws.
local has_pcall = src:find("pcall(hs.timer.secondsSinceEpoch)", 1, true) ~= nil
helpers.assert_true(
	has_pcall,
	"perf.lua must use pcall around hs.timer.secondsSinceEpoch() call (lib-logger-perf-001)"
)

print("[PASS] test_perf_now_nil_guard")
