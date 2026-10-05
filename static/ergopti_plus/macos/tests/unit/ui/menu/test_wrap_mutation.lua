--- tests/unit/ui/menu/test_wrap_mutation.lua

--- ==============================================================================
--- MODULE: Wrap Preference Mutation Conformance
--- DESCRIPTION:
--- Registers the shared mutation ownership contract in the native Mac suite.
--- ==============================================================================

local helpers = require("tests.helpers")
local suite = assert(loadfile(helpers.shared("tests/conformance/wrap_mutation.lua")))()
suite(helpers)
