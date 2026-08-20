--- tests/unit/ui/menu/test_menu_karabiner_left_hand_load.lua

--- ==============================================================================
--- MODULE: Karabiner Menu Left-Hand Catalog Load-Order Regression Guard
--- DESCRIPTION:
--- Regression test for a load-time crash introduced with MENU-4 (deriving the
--- left/right-hand split from the shared tap_hold_keys_catalog).
---
--- ROOT CAUSE ENCODED:
--- menu_karabiner.lua's module body did
---     local LEFT_HAND_IDS = _load_left_hand_from_catalog()   -- call
---     ...
---     local function _load_left_hand_from_catalog() ... end   -- definition
--- with the CALL textually ABOVE the DEFINITION. In Lua a `local function` is
--- NOT hoisted, so at the call site the name resolves to the (nil) global
--- `_load_left_hand_from_catalog`, and the module crashes at load with
--- "attempt to call a nil value" — every macOS boot / menu build
--- (project-lua-closure-before-local-nil-global). Because the crash only fires
--- when the module is actually required, it slipped past codegen/JS gates and
--- surfaced only as collateral pollution of an unrelated test's global state.
---
--- The fix moves the `local function` definition ABOVE its call site.
---
--- The guard is BEHAVIOURAL (require the module, assert it loads) rather than a
--- source-text scan for the definition ordering: loading the module IS the exact
--- operation that crashed, so a behavioural check both encodes the real failure
--- and stays robust to refactors (project convention prefers outcome checks over
--- source spellings, and the macOS suite ratchets against new path-pinned reads).
--- ==============================================================================

local helpers = require("tests.helpers")





-- ==================================================
-- ==================================================
-- ======= 1/ Behavioural: module loads clean =======
-- ==================================================
-- ==================================================

helpers.describe("menu_karabiner: left-hand catalog loads without a nil-global crash", function()
	helpers.it("require of ui.menu.menu_remap does not throw at module load", function()
		-- Pre-fix this throws "attempt to call a nil value (global
		-- '_load_left_hand_from_catalog')" while executing the module body, because
		-- LEFT_HAND_IDS was seeded by a call placed ABOVE the local function's
		-- definition (a `local function` is not hoisted).
		local ok, mod = pcall(helpers.load_with_stubs, "ui.menu.menu_remap")
		helpers.assert_true(ok, "menu_karabiner must load without error; got: " .. tostring(mod))
		helpers.assert_true(type(mod) == "table", "menu_karabiner must return its module table")
	end)
end)
