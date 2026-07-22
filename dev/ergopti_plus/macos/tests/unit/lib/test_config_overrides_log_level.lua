--- tests/unit/lib/test_config_overrides_log_level.lua

--- ==============================================================================
--- MODULE: Regression — config.toml [script] log_level override is honored
--- DESCRIPTION:
--- Audit finding F-M4. The documented expert override `[script] log_level = "..."`
--- (and the AHK-parity LogLevel) silently no-opped: config_overrides wrote it to a
--- BARE settings key ("log_level"), but the logger restore reads only the canonical
--- "ergopti.log_level" — and even if the key matched, Logger.set_level ran at boot
--- BEFORE config_overrides, so nothing re-applied it.
---
--- Fix: config_overrides maps log_level/LogLevel onto "ergopti.log_level", and
--- init.lua re-applies the level AFTER overrides. This test pins the key mapping
--- behaviorally and the re-apply step at source.
--- ==============================================================================

local helpers = require("tests.helpers")

local stored = {}
_G.hs = _G.hs or {}
_G.hs.settings = {
	set = function(key, value) stored[key] = value end,
	get = function(key) return stored[key] end,
}

local Overrides = helpers.load_with_stubs("lib.config_overrides")
_G.hs.settings = {
	set = function(key, value) stored[key] = value end,
	get = function(key) return stored[key] end,
}

local function write_tmp(contents)
	local path = (os.getenv("TEMP") or os.getenv("TMP") or "."):gsub("\\", "/")
		.. "/ergopti_config_overrides_loglevel.toml"
	local fh = assert(io.open(path, "w"))
	fh:write(contents); fh:close()
	return path
end

helpers.describe("config_overrides maps [script] log_level onto the canonical logger key", function()
	helpers.it("a [script] log_level override lands under ergopti.log_level", function()
		for k in pairs(stored) do stored[k] = nil end
		local path = write_tmp('[script]\nlog_level = "ERROR"\nsome_other = 7\n')
		Overrides.apply(path)
		-- The canonical key the logger restore actually reads.
		helpers.assert_eq(stored["ergopti.log_level"], "ERROR")
		-- A non-log [script] key still routes to its bare name (unchanged behavior).
		helpers.assert_eq(stored["some_other"], 7)
		-- And it must NOT also leak under the bare "log_level" key (no dead writer).
		helpers.assert_nil(stored["log_level"])
		os.remove(path)
	end)

	helpers.it("the AHK-parity LogLevel spelling is also mapped", function()
		for k in pairs(stored) do stored[k] = nil end
		local path = write_tmp('[script]\nLogLevel = "DEBUG"\n')
		Overrides.apply(path)
		helpers.assert_eq(stored["ergopti.log_level"], "DEBUG")
		os.remove(path)
	end)
end)

helpers.describe("init re-applies the log level after config overrides", function()
	helpers.it("source: Logger.set_level is re-derived from ergopti.log_level after apply", function()
		local fh = assert(io.open(helpers.driver_root() .. "init.lua", "r"))
		local src = fh:read("*a"); fh:close()
		local apply_idx = src:find("config_overrides.apply", 1, true)
		helpers.assert_true(apply_idx ~= nil, "config_overrides.apply must be called at boot")
		-- A set_level reading ergopti.log_level must appear AFTER the overrides apply.
		local reapply = src:find('Logger.set_level', apply_idx, true)
		helpers.assert_true(reapply ~= nil and reapply > apply_idx,
			"the log level must be re-applied AFTER config_overrides.apply")
		helpers.assert_true(src:find('hs.settings.get("ergopti.log_level")', apply_idx, true) ~= nil,
			"the re-apply must read the canonical ergopti.log_level key")
	end)
end)
