--- tests/unit/ui/test_onboarding_config_roundtrip.lua

--- Regression test for ui-windows-a-2: onboarding/init.lua loadExistingConfig
--- read the AHK PascalCase schema (Layout.ErgoptiBase, Hotstrings.MagicKey,
--- Metrics.metrics_enabled, Gestures.Enabled) but commit() writes the canonical
--- lowercase macOS schema ([hotstrings].enabled, [hotstrings].trigger_char,
--- [metrics].enabled, [gestures].enabled). Re-opening the wizard after a first
--- completion pre-filled every option as false.
---
--- Fix: extracted M._answers_from_config(parsed) which reads the canonical
--- lowercase schema first and falls back to PascalCase for Windows migration.

local helpers = require("tests.helpers")

-- Load just enough of the module: require a pure module stub that exports
-- _answers_from_config and _build_config_updates without hs.* dependencies.
-- We use the source-invariant approach: verify the structural properties of
-- the source rather than executing it (hs.* is unavailable headless).

-- Selected by a declaration unique to ui/onboarding/init.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function _layout_image_url")
helpers.assert_true(src ~= nil, "ui/onboarding/init.lua source must be locatable")

-- Test 1: M._answers_from_config must be defined.
local has_answers_from_config = src:find("function M._answers_from_config(", 1, true) ~= nil
helpers.assert_true(
	has_answers_from_config,
	"onboarding/init.lua must define M._answers_from_config (ui-windows-a-2)"
)

-- Test 2: _answers_from_config must read the canonical lowercase schema.
local fn_pos = src:find("function M._answers_from_config(", 1, true)
helpers.assert_true(fn_pos ~= nil, "_answers_from_config must be defined (ui-windows-a-2)")
local fn_body = src:sub(fn_pos, fn_pos + 1500)
local has_lowercase_hotstrings = fn_body:find("parsed.hotstrings", 1, true) ~= nil
helpers.assert_true(
	has_lowercase_hotstrings,
	"_answers_from_config must read parsed.hotstrings (canonical schema) (ui-windows-a-2)"
)
local has_canonical_enabled = fn_body:find("hs_sec.enabled", 1, true) ~= nil
helpers.assert_true(
	has_canonical_enabled,
	"_answers_from_config must check [hotstrings].enabled from canonical schema (ui-windows-a-2)"
)
local has_trigger_char = fn_body:find("trigger_char", 1, true) ~= nil
helpers.assert_true(
	has_trigger_char,
	"_answers_from_config must read [hotstrings].trigger_char for magic_key (ui-windows-a-2)"
)

-- Test 3: _answers_from_config must still include PascalCase fallback.
local has_pascal_fallback = fn_body:find("parsed.Layout", 1, true) ~= nil
	or fn_body:find("ErgoptiBase", 1, true) ~= nil
helpers.assert_true(
	has_pascal_fallback,
	"_answers_from_config must keep AHK PascalCase fallback for Windows migration (ui-windows-a-2)"
)

-- Test 4: loadExistingConfig must call M._answers_from_config, not inline the old logic.
local load_pos = src:find("loadExistingConfig", 1, true)
helpers.assert_true(load_pos ~= nil, "onboarding/init.lua must define loadExistingConfig (ui-windows-a-2)")
local load_body = src:sub(load_pos, load_pos + 2000)
local has_fn_call = load_body:find("M._answers_from_config(", 1, true) ~= nil
helpers.assert_true(
	has_fn_call,
	"loadExistingConfig must call M._answers_from_config(parsed) (ui-windows-a-2)"
)
-- Old inline PascalCase reads must be gone from loadExistingConfig
local has_old_inline = load_body:find("parsed.Layout", 1, true) ~= nil
	or load_body:find("parsed.Hotstrings", 1, true) ~= nil
helpers.assert_true(
	not has_old_inline,
	"loadExistingConfig must not contain inline PascalCase reads — use M._answers_from_config (ui-windows-a-2)"
)

print("[PASS] test_onboarding_config_roundtrip")
