--- tests/unit/platform/remap/test_typing_rollover_catalog.lua

--- ==============================================================================
--- MODULE: Shared Typing-Priority Key Catalogue
--- DESCRIPTION:
--- Replays all backend aliases and invalid-list refusals against shipped TOML.
--- ==============================================================================

local helpers = require("tests.helpers")
local Catalog = require("tap_hold.key_catalog")
local path = helpers.driver_root() .. "/../_shared/tap_hold/defaults.toml"
local handle = assert(io.open(path, "r"))
local defaults = require("toml_codec").decode(handle:read("*a"))
assert(handle:close())
require("test.tap_hold_rollover_contract")(helpers, Catalog, defaults)
