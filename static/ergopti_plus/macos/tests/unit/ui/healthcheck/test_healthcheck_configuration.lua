--- tests/unit/ui/healthcheck/test_healthcheck_configuration.lua

--- ==============================================================================
--- MODULE: Diagnostics Configuration Reducer (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/healthcheck/configuration_vectors.json through
--- healthcheck.configuration: booleans, numbers and manifest enum values are
--- exact, every other string keeps only its length, every list only its item
--- count, and a key the manifest does not declare never becomes a row. The
--- Windows suite replays the same vectors through its AHK port.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Configuration = require("healthcheck.configuration")
local Toml = require("toml_codec")

--- The shared corpus.
--- @return table
local function corpus()
	local fh = assert(io.open(helpers.shared("tests/corpus/healthcheck/configuration_vectors.json"), "rb"))
	local data = Json.decode(fh:read("*a"))
	fh:close()
	return data
end

local CORPUS = corpus()

helpers.describe("diagnostics configuration reducer", function()
	for _, vector in ipairs(CORPUS.vectors) do
		helpers.it("reduces " .. vector.id, function()
			local rows = Configuration.rows(CORPUS.features, Toml.decode(vector.toml), vector.driver, 800)
			helpers.assert_eq(rows, vector.expected, vector.id)
			local encoded = Json.encode(rows)
			for _, canary in ipairs(CORPUS.canaries) do
				helpers.assert_true(not encoded:find(Json.encode(canary):sub(2, -2), 1, true),
					vector.id .. " leaked " .. canary)
			end
		end)
	end

	helpers.it("bounds the number of rows", function()
		local rows = Configuration.rows(CORPUS.features,
			Toml.decode("[script]\nlog_level = \"INFO\"\nshow_error_dialog = true\n\n[metrics]\nkeep_days = 3\n"),
			"windows", 2)
		helpers.assert_eq(#rows, 2)
	end)

	helpers.it("refuses an unknown driver", function()
		helpers.assert_true(not pcall(Configuration.rows, CORPUS.features, {}, "beos", 10))
	end)
end)
