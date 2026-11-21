--- tests/unit/modules/shortcuts/star_slot/test_star_slot_policy.lua

--- ==============================================================================
--- MODULE: Shared ★ Key Slot Policy Tests
--- DESCRIPTION:
--- Replays the ★ key slot's physical eligibility, explicit assignments and
--- delivery fences from the common corpus as macOS (secondary_star) without
--- creating native input or changing a user setting.
--- ==============================================================================

local helpers = require("tests.helpers")
require("tests.lua.layouts.star_slot_contract")(helpers, require("core.text.engine.json"), helpers.shared(""), "macos")
require("tests.lua.layouts.keyboard_assignment_contract")(helpers)
