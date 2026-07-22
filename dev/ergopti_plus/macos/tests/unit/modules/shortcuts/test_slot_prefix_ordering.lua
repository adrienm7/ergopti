--- tests/unit/modules/shortcuts/test_slot_prefix_ordering.lua

--- Regression test for shortcuts-core-1: slot_to_hotkey() and slot_label()
--- iterated SLOT_MODS with pairs() which gives non-deterministic order. When
--- "cmd_" happened to be checked before "cmd_shift_", a slot like
--- "cmd_shift_a" matched the shorter prefix and was bound as Cmd+a (wrong)
--- instead of Cmd+Shift+a — a behaviour that changed between Lua VM runs.
---
--- Fix: SLOT_MODS is now an ordered array with longest prefix first; both
--- functions use ipairs() so "cmd_shift_" is always checked before "cmd_".

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "modules/shortcuts/keyboard_shortcuts.lua"
local fh = io.open(src_path, "r")
if not fh then error("keyboard_shortcuts.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: SLOT_MODS is an array (uses { prefix, mods } pairs), not a hash.
-- Pre-fix: `["cmd_"] = {"cmd"}` syntax (hash map).
-- Post-fix: `{ "cmd_", {"cmd"} }` syntax (array entry).
local has_hash = src:find('["cmd_"]', 1, true) ~= nil or src:find('["cmd_shift_"]', 1, true) ~= nil
helpers.assert_true(
	not has_hash,
	"keyboard_shortcuts.lua SLOT_MODS must not use hash syntax [\"...\"] = ... (shortcuts-core-1)"
)

-- Test 2: cmd_shift_ entry appears BEFORE cmd_ entry in the array.
local cmd_shift_pos = src:find('"cmd_shift_"', 1, true)
local cmd_only_pos  = src:find('"cmd_"', 1, true)
helpers.assert_true(
	cmd_shift_pos ~= nil,
	"keyboard_shortcuts.lua SLOT_MODS must contain a \"cmd_shift_\" entry"
)
helpers.assert_true(
	cmd_only_pos ~= nil,
	"keyboard_shortcuts.lua SLOT_MODS must contain a \"cmd_\" entry"
)
helpers.assert_true(
	cmd_shift_pos < cmd_only_pos,
	"\"cmd_shift_\" must appear before \"cmd_\" in SLOT_MODS (longest-first ordering — shortcuts-core-1)"
)

-- Test 3: both iteration sites use ipairs(), not pairs().
-- pairs() on an array still works but loses ordering; ipairs() is the contract.
local pairs_count = 0
for _ in src:gmatch("for prefix, mods in pairs%(SLOT_MODS%)") do
	pairs_count = pairs_count + 1
end
helpers.assert_true(
	pairs_count == 0,
	"keyboard_shortcuts.lua must use ipairs(SLOT_MODS), not pairs(SLOT_MODS) (shortcuts-core-1)"
)

print("[PASS] test_slot_prefix_ordering")
