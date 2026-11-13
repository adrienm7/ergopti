--- tests/unit/ui/menu/test_feature_notice.lua

--- ==============================================================================
--- MODULE: Feature And Refusal Notices (macOS)
--- DESCRIPTION:
--- Replays the shared contract for the notices the macOS menu sends.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.menu.feature_notice_contract")(helpers, require("core.text.engine.json"), helpers.shared(""))
