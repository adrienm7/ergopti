--- tests/support/platform/remap/lease/lease_controller_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_lease_controller
--- DESCRIPTION:
--- Prelude shared by the test_lease_controller_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")
local support = require("tests.support.lease_controller_fixture")
local with_fixture = support.with_fixture
local find_native_revoke = support.find_native_revoke
local UUIDS = support.UUIDS

return {
	UUIDS = UUIDS,
	find_native_revoke = find_native_revoke,
	support = support,
	with_fixture = with_fixture,
}
