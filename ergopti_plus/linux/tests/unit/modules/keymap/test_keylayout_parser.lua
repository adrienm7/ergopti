--- tests/unit/modules/keymap/test_keylayout_parser.lua

--- ==============================================================================
--- MODULE: Shared Keylayout Parser
--- DESCRIPTION:
--- Replays the shared .keylayout corpus against the one parser this driver and
--- macOS share. The Linux converter reads the same canonical form.
--- ==============================================================================

local helpers = require("tests.helpers")
local shared = require("infra.paths").shared

require("test.keylayout_parser_contract").register(helpers, {
	edge_cases = shared("tests/corpus/keylayout/edge_cases.json"),
	composed_keylayout = shared("tests/corpus/layouts/composer/composed.keylayout"),
	composed_canonical = shared("tests/corpus/keylayout/composed.canonical.json"),
})
