--- tests/unit/ui/menu/test_feature_notice.lua

--- ==============================================================================
--- MODULE: Feature And Refusal Notices (macOS)
--- DESCRIPTION:
--- Replays the shared contract for the notices the macOS menu sends.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.feature_notice_contract")(helpers, require("json"), helpers.shared(""))
