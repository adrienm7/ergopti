--- tests/support/platform/remap/enable_transaction/bulk_owner_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_bulk_owner
--- DESCRIPTION:
--- Prelude shared by the test_bulk_owner_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

return {
	with_fixture = with_fixture,
}
