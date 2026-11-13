--- macos/tests/unit/gestures/engine/engine/test_incremental_vectors.lua

--- ==============================================================================
--- MODULE: Incremental Step Vectors (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/gestures/incremental_steps.json, which the
--- Linux and Windows suites replay too, through _shared/gestures/incremental,
--- the step rule the engine counts with (Geometry.incrementalSteps).
---
--- ROOT CAUSE ENCODED:
--- The step rule was pinned only by literals in test_geometry_math.lua, so a
--- third driver porting it had no shared vectors to prove the port against.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("core.text.engine.json")

require("tests.lua.incremental_steps_contract")(helpers, json, helpers.shared(""))
