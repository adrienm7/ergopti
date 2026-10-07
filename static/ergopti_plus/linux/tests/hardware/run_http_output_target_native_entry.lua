--- tests/hardware/run_http_output_target_native_entry.lua
--- ==============================================================================
--- MODULE: Native Retained Output Fixture Bootstrap
--- DESCRIPTION:
--- Resolves only the supplied source-admitted driver and executes its native fixture.
--- ==============================================================================

local driver = assert(arg[1], "Exact native driver root is required")
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;"
    .. driver .. "/../_shared/lua/?.lua;" .. driver .. "/../_shared/lua/?/init.lua;" .. package.path
local compat = require("compat.utf8")
if compat.install then compat.install() end
dofile(driver .. "/tests/hardware/run_http_output_target_native.lua")
