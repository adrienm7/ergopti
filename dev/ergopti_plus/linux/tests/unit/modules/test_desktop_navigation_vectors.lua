--- tests/unit/modules/test_desktop_navigation_vectors.lua

--- ==============================================================================
--- MODULE: Workspace switching replays the shared desktop vectors (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/desktop_navigation/vectors.json, which the macOS
--- and Windows suites replay too, through _shared/lua/desktop_navigation, the
--- index maths the desktop_prev / desktop_next actions and their wrapping
--- variants use.
---
--- ROOT CAUSE ENCODED:
--- desktop_prev and desktop_next always wrapped around on this driver, while
--- Windows and macOS stopped at the edge: one action id, two behaviours. The
--- plain actions now stop and the wrapping ones wrap, by one shared rule.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

require("test.desktop_navigation_contract")(helpers, json, helpers.driver_root() .. "/../_shared")
