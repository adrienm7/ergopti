--- tests/unit/modules/keymap/test_registry_update_trigger_char.lua

--- Regression test for keymap-core-1: update_trigger_char() recomputed
--- m.tail_char using Lua's ASCII-only :lower() instead of
--- text_utils.trig_lower(). For magic-key mappings whose star_base ends
--- with an accented capital (e.g. "Ê"), the stored tail_char remained "Ê"
--- instead of being lowercased to "ê", causing mappings_for_tail() to miss
--- the bucket and silently never fire the mapping.
---
--- The inconsistency was between:
---   add_raw() line: tail_char = text_utils.trig_lower(tail_codepoint(t))
---   update_trigger_char() line: tail_char = tail_codepoint(new_tr):lower()
---
--- Fix: changed update_trigger_char to use text_utils.trig_lower().

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "modules/keymap/registry.lua"
local fh = io.open(src_path, "r")
if not fh then error("registry.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Find the update_trigger_char function body.
local fn_start = src:find("function update_trigger_char", 1, true)
	or src:find("function M.update_trigger_char", 1, true)
helpers.assert_true(
	fn_start ~= nil,
	"registry.lua must define update_trigger_char (keymap-core-1)"
)

-- Extract up to the next top-level `end` (~200 lines is enough to cover the function).
local fn_body = src:sub(fn_start, fn_start + 3000)

-- Test 1: The ASCII-only :lower() must NOT appear on the tail_char assignment.
-- Pre-fix: `m.tail_char = tail_codepoint(new_tr):lower()`
local has_ascii_lower = fn_body:find('tail_codepoint(new_tr):lower()', 1, true) ~= nil
helpers.assert_true(
	not has_ascii_lower,
	"registry.lua update_trigger_char must not use tail_codepoint():lower() — ASCII-only, misses accented capitals (keymap-core-1)"
)

-- Test 2: The Unicode-aware trig_lower must be used for tail_char.
-- Post-fix: `m.tail_char = text_utils.trig_lower(tail_codepoint(new_tr))`
local has_trig_lower = fn_body:find('trig_lower(tail_codepoint(new_tr))', 1, true) ~= nil
helpers.assert_true(
	has_trig_lower,
	"registry.lua update_trigger_char must use text_utils.trig_lower(tail_codepoint(new_tr)) for tail_char (keymap-core-1)"
)

-- Test 3: Confirm the initial registration path also uses trig_lower (invariant check).
-- This is the reference: update_trigger_char must mirror add_raw().
local add_raw_trig_lower = src:find('tail_char    = text_utils.trig_lower(tail_codepoint(', 1, true) ~= nil
helpers.assert_true(
	add_raw_trig_lower,
	"registry.lua add_raw() must set tail_char via text_utils.trig_lower(tail_codepoint()) — both paths must be consistent (keymap-core-1)"
)

print("[PASS] test_registry_update_trigger_char")
