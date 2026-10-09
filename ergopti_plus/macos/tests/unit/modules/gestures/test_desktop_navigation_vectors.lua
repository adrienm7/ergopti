--- tests/unit/modules/gestures/test_desktop_navigation_vectors.lua

--- ==============================================================================
--- MODULE: Space navigation replays the shared desktop vectors (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/desktop_navigation/vectors.json, which the Linux
--- and Windows suites replay too, through _shared/lua/desktop_navigation, the
--- index maths the space_prev_wrap / space_next_wrap actions use.
---
--- ROOT CAUSE ENCODED:
--- A global "circular Spaces" checkbox decided whether the two Space actions
--- stopped at the edge, and nothing ever wrapped: macOS stops at the last Space
--- and the toggle only chose between a bounce and no bounce. The wrap is now a
--- separate action whose target comes from this one rule.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

require("test.desktop_navigation_contract")(helpers, json, helpers.shared(""))
