--- tests/unit/platform/remap/watchers/test_caps_word_auto_off_policy.lua

--- ==============================================================================
--- MODULE: CapsWord Auto-Off Policy Tests
--- DESCRIPTION:
--- Replays the shared CapsWord auto-off contract through the macOS test owner.
--- ==============================================================================

local helpers = require("tests.helpers")
require("test.caps_word_auto_off_contract").run(helpers,
	helpers.shared("tests/corpus/caps_word/auto_off_vectors.json"))

return true
