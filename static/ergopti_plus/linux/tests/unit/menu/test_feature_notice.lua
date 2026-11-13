--- tests/unit/menu/test_feature_notice.lua

--- ==============================================================================
--- MODULE: Feature And Refusal Notices (Linux)
--- DESCRIPTION:
--- Replays the shared contract for the notices the Linux menu sends.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.menu.feature_notice_contract")(helpers, require("core.text.engine.json"), helpers.driver_root() .. "/../_shared")
