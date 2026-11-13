--- _shared/tests/lua/settings/save_failure_contract.lua

--- ==============================================================================
--- MODULE: Configuration Save Failure Notice Replay
--- DESCRIPTION:
--- Both Lua drivers replay one refused change end to end: the writer names a
--- case twin once, and the menu's generic « could not be saved » notice stays
--- silent for that refusal but still reaches every other one.
--- ==============================================================================

local GENERIC_KEY = "dialog.bulk_toggle.save_failed"

--- Lists the driver's production Lua sources, failing when none is found.
--- @param driver_root string Absolute driver directory.
--- @return table paths
local function production_sources(driver_root)
	local listing = assert(io.popen("find '" .. driver_root .. "' -path '*/tests' -prune -o -name '*.lua' -print"))
	local paths = {}
	for path in listing:lines() do paths[#paths + 1] = path end
	listing:close()
	assert(#paths > 0, "the driver tree holds Lua sources")
	return paths
end

--- Registers the shared save failure notice regressions.
--- @param helpers table Native driver test helpers.
--- @param driver_root string Absolute driver directory.
return function(helpers, driver_root)
	local Writer = require("core.text.engine.toml_codec.writer")
	local SaveFailure = require("settings.engine.publication.save_failure")
	local function translate(key) return "<" .. key .. ">" end

	--- Refuses one save of the given TOML source and returns the menu's notices.
	local function refuse(source, row, reporter)
		local path = os.tmpname()
		local handle = assert(io.open(path, "wb"))
		handle:write(source); handle:close()
		Writer.set_case_twin_reporter(reporter)
		local prepared = Writer.prepare_batch(path, { row })
		local generic = {}
		SaveFailure.present(translate, function(message) generic[#generic + 1] = message end)
		Writer.set_case_twin_reporter(function() end)
		os.remove(path)
		return prepared, generic
	end

	helpers.describe("Configuration save failure notice (config-save-failure-case-twin)", function()
		helpers.it("config-save-failure-case-twin a named twin silences the generic notice", function()
			local notices = {}
			local prepared, generic = refuse("[menu]\nkey = 1\nKEY = 2\n", { section = "menu", key = "key", value = 3 },
				function(message) notices[#notices + 1] = message end)
			helpers.assert_eq(prepared, false)
			helpers.assert_eq(#notices, 1, "the writer names the twin")
			helpers.assert_eq(#generic, 0, "the menu does not blame a held file as well")
		end)
		helpers.it("config-save-failure-case-twin a later refusal still shows the generic notice", function()
			local _, twin_generic = refuse("[later]\nkey = 1\nKey = 2\n", { section = "later", key = "key", value = 3 },
				function() end)
			helpers.assert_eq(#twin_generic, 0)
			local generic = {}
			helpers.assert_eq(SaveFailure.present(translate, function(message) generic[#generic + 1] = message end), true,
				"the case-twin notice covers one refusal only")
			helpers.assert_eq(generic[1], "<" .. GENERIC_KEY .. ">")
			local prepared, other = refuse("[other]\nkey = 1\n", { section = "other", key = "", value = 3 },
				function() end)
			helpers.assert_eq(prepared, false)
			helpers.assert_eq(#other, 1, "a refusal without a twin keeps the generic notice")
		end)
		helpers.it("config-save-failure-case-twin an unshown twin notice keeps the generic notice", function()
			local prepared, generic = refuse("[shown]\nkey = 1\nKEY = 2\n", { section = "shown", key = "key", value = 3 },
				function() error("notification centre unavailable") end)
			helpers.assert_eq(prepared, false)
			helpers.assert_eq(#generic, 1, "the user still learns the change was not saved")
		end)
		helpers.it("config-save-failure-case-twin no driver source reads the generic key itself", function()
			for _, path in ipairs(production_sources(driver_root)) do
				local handle = assert(io.open(path, "rb"))
				local source = handle:read("*a")
				handle:close()
				helpers.assert_true(not source:find(GENERIC_KEY, 1, true),
					path .. " shows the generic save failure without config_save_failure")
			end
		end)
	end)
end
