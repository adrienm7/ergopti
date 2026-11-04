--- tests/support/adapters/file_system/cooperative_writer_lock_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_cooperative_writer_lock
--- DESCRIPTION:
--- Prelude shared by the test_cooperative_writer_lock_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.file_system_transaction_fixture").with_fixture

return {
	with_fixture = with_fixture,
}
