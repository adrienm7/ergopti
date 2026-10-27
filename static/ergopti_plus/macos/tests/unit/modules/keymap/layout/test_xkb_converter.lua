--- tests/unit/modules/keymap/layout/test_xkb_converter.lua

--- ==============================================================================
--- MODULE: Shared Keylayout to XKB Converter
--- DESCRIPTION:
--- Replays the shared conversion vector against the converter the Linux driver uses
--- to install a registry layout.
--- ==============================================================================

local helpers = require("tests.helpers")
local shared = helpers.shared

require("test.xkb_converter_contract").register(helpers, {
	vectors = shared("tests/corpus/keylayout/xkb_conversion_vectors.json"),
	keycodes = shared("modules/layouts/mac_keycodes.json"),
	data_dir = helpers.driver_root() .. "/../../ergopti/linux/xkb_generation/data",
})
