--- tests/unit/modules/shortcuts/magic_editor/test_magic_editor_policy.lua

--- ==============================================================================
--- MODULE: Shared Physical Magic Editor Policy Tests
--- DESCRIPTION:
--- Replays physical eligibility, explicit assignments and delivery fences from
--- the common corpus without creating native input or changing a user setting.
--- ==============================================================================

local helpers = require("tests.helpers")
require("tests.lua.layouts.magic_editor_contract")(helpers, require("core.text.engine.json"), helpers.shared(""))
require("tests.lua.layouts.keyboard_assignment_contract")(helpers)
