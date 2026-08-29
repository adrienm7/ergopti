--- tests/unit/platform/remap/test_generator_shell_quoting.lua

--- Regression test for karabiner-gen-3: the shell_command strings for
--- KE_PHYSICAL_KC_LOG used Lua string.format("%s", ...) with unquoted
--- values, making them vulnerable to shell injection if the config
--- directory path contains an apostrophe (e.g. "/Users/O'Brien/config/").
---
--- Fix: the canonical physical-key ledger factory uses a local sq() helper
--- that wraps values in POSIX single quotes with embedded-apostrophe escaping
--- ("'" -> "'\\''") for both its payload and KE_PHYSICAL_KC_LOG path.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to platform/remap/generator.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function build_sticky_companion_manipulators")
helpers.assert_true(src ~= nil, "platform/remap/generator.lua source must be locatable")

-- Test 1: The old unquoted format string must not appear.
-- Pre-fix: string.format("echo '%s' >> '%s'", key_code, KE_PHYSICAL_KC_LOG)
local has_old_format = src:find('"echo \'%s\' >> \'%s\'"', 1, true) ~= nil
helpers.assert_true(
	not has_old_format,
	"generator.lua must not use unquoted echo format (injection risk if path has apostrophe) (karabiner-gen-3)"
)

-- Test 2: A sq() quoting helper must be present.
local has_sq = src:find("local function sq(value)", 1, true) ~= nil
helpers.assert_true(
	has_sq,
	"generator.lua must define a local sq() POSIX-quoting helper (karabiner-gen-3)"
)

-- Test 3: The sq() helper must escape embedded single quotes.
local has_escape = src:find("gsub(\"'\", \"'\\\\''\")", 1, true) ~= nil
helpers.assert_true(
	has_escape,
	"generator.lua sq() must escape embedded single quotes via gsub (karabiner-gen-3)"
)

-- Test 4: The canonical ledger factory must quote both payload and path.
local sq_count = 0
local pos = 1
while true do
	local found = src:find("sq(", pos, true)
	if not found then break end
	sq_count = sq_count + 1
	pos = found + 1
end
helpers.assert_true(
	sq_count >= 3,
	"generator.lua must quote both the ledger payload and destination path (karabiner-gen-3)"
)

print("[PASS] test_generator_shell_quoting")
