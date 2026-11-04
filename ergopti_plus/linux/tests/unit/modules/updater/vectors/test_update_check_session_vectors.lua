--- tests/unit/modules/updater/vectors/test_update_check_session_vectors.lua

--- ==============================================================================
--- MODULE: Update Check Session Vectors (Linux)
--- DESCRIPTION:
--- Replays the session and rate-limit vectors shared with macOS and Windows.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.check_session_contract")(helpers, require("json"), helpers.driver_root() .. "/../_shared")
