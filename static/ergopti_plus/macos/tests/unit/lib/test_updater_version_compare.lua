--- tests/unit/lib/test_updater_version_compare.lua

--- Regression test for lib-update-03: updater.lua compare_versions() used
--- lexicographic string comparison (na > nb) as a fallback for non-semver tags.
--- This returned the wrong result for tags like "10" vs "9" ("10" < "9"
--- lexicographically), which could cause the updater to miss an available update.
---
--- Fix: the non-semver fallback is now fail-closed — it returns 0 (equal) and
--- logs a WARNING, ensuring ambiguous comparisons never incorrectly trigger an
--- update or block one.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "lib/updater.lua"
local fh = io.open(src_path, "r")
if not fh then error("updater.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: the old lexicographic fallback must not be present.
local cmp_pos = src:find("function M.compare_versions(", 1, true)
helpers.assert_true(cmp_pos ~= nil, "updater.lua must define M.compare_versions (lib-update-03)")
local cmp_body = src:sub(cmp_pos, cmp_pos + 600)

-- Old pattern: "return na > nb and 1 or -1"
local has_old_lex = cmp_body:find("na > nb and 1 or %-1", 1, false) ~= nil
helpers.assert_true(
	not has_old_lex,
	"compare_versions must not use lexicographic fallback (na > nb and 1 or -1) for non-semver (lib-update-03)"
)

-- Test 2: the fallback must return 0 (fail-closed).
local has_fail_closed = cmp_body:find("return 0", 1, true) ~= nil
helpers.assert_true(
	has_fail_closed,
	"compare_versions non-semver fallback must return 0 (fail-closed) (lib-update-03)"
)

-- Test 3: the fallback must log a warning.
local has_warn = cmp_body:find("Logger.warn", 1, true) ~= nil
helpers.assert_true(
	has_warn,
	"compare_versions non-semver fallback must call Logger.warn (lib-update-03)"
)

print("[PASS] test_updater_version_compare")
