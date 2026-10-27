--- tests/unit/infra/config/test_byte_limits.lua

--- ==============================================================================
--- MODULE: Byte Limits Tests (macOS)
--- DESCRIPTION:
--- Registers the shared [limits] contract: the byte caps shared Lua modules
--- publish are the registry values, as on Linux.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.byte_limits_contract").register(helpers, { driver = "macos", timings = require("infra.timings") })
