--- tests/unit/modules/shortcuts/test_magic_editor_policy.lua

--- ==============================================================================
--- MODULE: Shared Physical Magic Editor Policy Tests
--- DESCRIPTION:
--- Replays physical eligibility, explicit assignments and delivery fences from
--- the common corpus without creating native input or changing a user setting.
--- ==============================================================================

local helpers = require("tests.helpers")
require("test.magic_editor_contract")(helpers, require("json"), helpers.shared(""))
require("test.keyboard_assignment_contract")(helpers)
