--- tests/unit/modules/keylogger/test_kc_bridge_truncation_toctou.lua

--- Regression guard for the Karabiner physical-key ledger. Karabiner writes
--- this file independently, so a reader-side truncate or rewrite can lose a
--- line appended between the read and the rewrite. The bridge must retain an
--- append-only file and advance only its durable byte cursor.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to modules/keylogger/kc_bridge.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function build_managed_output_set")
helpers.assert_true(src ~= nil, "modules/keylogger/kc_bridge.lua source must be locatable")

-- Test 1: The intermediate fh_size re-open for a size check must not exist.
-- Pre-fix code used `local fh_size = io.open(KC_LOG_PATH, "r")` followed by
-- `fh_size:seek("end")` to re-query a live file before an unsafe rewrite.
local has_fh_size = src:find("fh_size", 1, true) ~= nil
helpers.assert_true(
	not has_fh_size,
	"kc_bridge.lua must not use an fh_size re-open for size check after reading (TOCTOU race) (keylogger-support-2)"
)

-- Test 2: A consumer-side rewrite can race with the independent Karabiner
-- writer after its final read. The physical hand-off must remain append-only.
local has_trunc_write = src:find('io.open(KC_LOG_PATH, "w")', 1, true) ~= nil
helpers.assert_true(
	not has_trunc_write,
	"kc_bridge.lua must never rewrite the independent physical-key ledger"
)

-- Test 3: The former size-cap compaction must be absent too; making the race
-- rarer is not sufficient when an event loss corrupts the heatmap.
local has_size_cap = src:find("KC_LOG_MAX_BYTES", 1, true) ~= nil
helpers.assert_true(
	not has_size_cap,
	"kc_bridge.lua must not retain unsafe reader-side compaction"
)

-- Test 4: Offset-based consumption remains the sole durable cursor invariant.
helpers.assert_true(
	src:find("_file_offset = fh:seek(\"cur\")", 1, true) ~= nil,
	"kc_bridge.lua must advance only the append-only reader cursor after a drain"
)

print("[PASS] test_kc_bridge_truncation_toctou")
