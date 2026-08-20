--- tests/unit/lib/test_config_overrides_comment_strip.lua

--- ==============================================================================
--- MODULE: Config override comment boundary regression
--- DESCRIPTION:
--- Drives the real loader so a quote in a trailing comment cannot become part
--- of the setting value. The assertion is intentionally behavioral: parsing is
--- now owned by the canonical TOML codec, not a spelling-pinned line scanner.
--- ==============================================================================

local helpers = require("tests.helpers")

local stored = {}
local original_settings = _G.hs and _G.hs.settings or nil
_G.hs = _G.hs or {}
_G.hs.settings = {
	set = function(key, value) stored[key] = value end,
	get = function(key) return stored[key] end,
}

local Overrides = helpers.load_with_stubs("infra.config_overrides")
_G.hs.settings = {
	set = function(key, value) stored[key] = value end,
	get = function(key) return stored[key] end,
}

local path = os.tmpname()
local file = assert(io.open(path, "w"))
assert(file:write('[features]\nkey = "DEBUG" # note with "quotes"\n'))
assert(file:close())

helpers.assert_eq(Overrides.apply(path), 1)
helpers.assert_eq(stored.key, "DEBUG",
	"a quote in a trailing TOML comment must never extend the setting value")

os.remove(path)
if original_settings then _G.hs.settings = original_settings end
print("[PASS] test_config_overrides_comment_strip")
