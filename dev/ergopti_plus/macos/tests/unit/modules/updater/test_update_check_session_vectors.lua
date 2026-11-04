--- tests/unit/modules/updater/test_update_check_session_vectors.lua

--- ==============================================================================
--- MODULE: Update Check Session Vectors (macOS)
--- DESCRIPTION:
--- Replays the session and rate-limit vectors shared with Linux and Windows.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.check_session_contract")(helpers, require("json"), helpers.shared(""))
