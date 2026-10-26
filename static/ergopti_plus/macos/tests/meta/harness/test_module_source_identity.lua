--- tests/meta/harness/test_module_source_identity.lua

--- ==============================================================================
--- MODULE: Canonical Loader Source Coordinates
--- DESCRIPTION:
--- Requires exact constructors on both POSIX and Windows-hosted Lua fixtures.
--- Source coordinates never grant filesystem or configuration authority.
--- ==============================================================================

require("test.module_source_identity_contract").register(require("tests.helpers"))
