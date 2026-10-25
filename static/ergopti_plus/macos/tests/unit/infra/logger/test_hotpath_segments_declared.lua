--- tests/unit/infra/logger/test_hotpath_segments_declared.lua

--- ==============================================================================
--- MODULE: Hot-path Segment Inventory Test (macOS driver)
--- DESCRIPTION:
--- Holds the macOS driver to the shared segment inventory: the keydown tripwire
--- and its sub-segments (trigger match, preview rebuild, expansion output,
--- prediction tooltip) are declared with their reason, and a new
--- HotPath.log_if_slow site must be declared before it can pass.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.hotpath_segments_contract").register(helpers, {
	driver = "macos",
	root = helpers.driver_root(),
	call_pattern = 'HotPath%.log_if_slow%(%s*"([^"]+)"',
})
