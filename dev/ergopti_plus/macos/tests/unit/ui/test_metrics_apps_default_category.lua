--- tests/unit/ui/test_metrics_apps_default_category.lua

--- Regression test for ui-windows-b-1: metrics_apps/init.lua had the string
--- "Général" hardcoded in two places (chooser callback and bridge message
--- handler), violating the single-source-of-truth rule and making it easy
--- to change one occurrence while missing the other.
---
--- Fix: introduced the named constant DEFAULT_APP_CATEGORY = "Général" and
--- replaced both literal usages with it.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "ui/metrics_apps/init.lua"
local fh = io.open(src_path, "r")
if not fh then error("metrics_apps/init.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: A named constant for the default category must be defined.
local has_constant = src:find('DEFAULT_APP_CATEGORY', 1, true) ~= nil
helpers.assert_true(
	has_constant,
	"metrics_apps/init.lua must define DEFAULT_APP_CATEGORY constant (ui-windows-b-1)"
)

-- Test 2: The two old call sites must NOT contain bare "Général" literals.
-- We check the specific assignment and fallback patterns that had hardcoded strings.
local has_old_chooser_literal = src:find('{ type = "G', 1, true) ~= nil
local has_old_bridge_literal  = src:find('body.cat or "G', 1, true) ~= nil
helpers.assert_true(
	not has_old_chooser_literal,
	"metrics_apps/init.lua chooser callback must not use a bare \"Général\" literal for type (ui-windows-b-1)"
)
helpers.assert_true(
	not has_old_bridge_literal,
	"metrics_apps/init.lua bridge handler must not use a bare \"Général\" literal as fallback (ui-windows-b-1)"
)

-- Test 3: The two call sites must reference DEFAULT_APP_CATEGORY, not a bare literal.
local has_chooser_ref  = src:find("cats[choice.text] or { type = DEFAULT_APP_CATEGORY", 1, true) ~= nil
local has_bridge_ref   = src:find("body.cat or DEFAULT_APP_CATEGORY", 1, true) ~= nil
helpers.assert_true(
	has_chooser_ref,
	"metrics_apps/init.lua chooser callback must use DEFAULT_APP_CATEGORY as fallback type (ui-windows-b-1)"
)
helpers.assert_true(
	has_bridge_ref,
	"metrics_apps/init.lua bridge handler must use DEFAULT_APP_CATEGORY as fallback cat (ui-windows-b-1)"
)

print("[PASS] test_metrics_apps_default_category")
