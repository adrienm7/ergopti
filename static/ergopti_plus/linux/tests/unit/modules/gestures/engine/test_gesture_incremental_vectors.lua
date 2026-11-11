--- tests/unit/modules/gestures/engine/test_gesture_incremental_vectors.lua

--- ==============================================================================
--- MODULE: Incremental Step Vectors (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/gestures/incremental_steps.json, which the
--- macOS and Windows suites replay too, through _shared/lua/gestures/incremental,
--- the step rule modules/gestures/incremental_tracker.lua counts with.
---
--- ROOT CAUSE ENCODED:
--- The step rule was pinned only by macOS literals, so a third driver porting
--- it had no shared vectors to prove the port against.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

require("test.incremental_steps_contract")(helpers, json, helpers.driver_root() .. "/../_shared")
