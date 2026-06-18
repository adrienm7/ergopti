--- tests/unit/ui/test_tooltip_llm_info_sizing.lua

--- Regression test for ui-tooltip-4: tooltip_llm.lua format_info_line() used
--- 9999 ms as the sizing placeholder for TTFT and TTLT. A model with TTLT > 10s
--- (e.g. 12400 ms → "12.40 s") produces a wider string than "9.99 s", so the
--- canvas frame reserved during the sizing pass was too narrow and the final
--- text was clipped.
---
--- Fix: raised the placeholder to 999000 ms ("999.00 s"), which is always
--- wider than any realistic timing value.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "ui/tooltip/tooltip_llm.lua"
local fh = io.open(src_path, "r")
if not fh then error("tooltip_llm.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: old 9999 ms placeholder must not appear in a sizing context.
-- The pattern "ttft_ms = 9999" or "ttlt_ms = 9999" inside the for_sizing block
-- is the regression indicator.
local has_old_placeholder = src:find("ttft_ms = 9999", 1, true) ~= nil
	or src:find("ttlt_ms = 9999", 1, true) ~= nil
helpers.assert_true(
	not has_old_placeholder,
	"tooltip_llm.lua must not use 9999 ms as the sizing placeholder (ui-tooltip-4)"
)

-- Test 2: a large placeholder constant (>= 99999 ms) must be used.
local placeholder_val = src:match("SIZING_PLACEHOLDER_MS%s*=%s*(%d+)")
helpers.assert_true(
	placeholder_val ~= nil,
	"tooltip_llm.lua must define SIZING_PLACEHOLDER_MS for the sizing pass (ui-tooltip-4)"
)
local ph_num = tonumber(placeholder_val)
helpers.assert_true(
	ph_num ~= nil and ph_num >= 99999,
	string.format(
		"SIZING_PLACEHOLDER_MS (%s) must be >= 99999 ms to accommodate TTLT > 10s (ui-tooltip-4)",
		tostring(placeholder_val)
	)
)

print("[PASS] test_tooltip_llm_info_sizing")
