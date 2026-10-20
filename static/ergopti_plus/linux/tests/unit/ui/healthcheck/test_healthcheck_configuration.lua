--- tests/unit/ui/healthcheck/test_healthcheck_configuration.lua

--- ==============================================================================
--- MODULE: Diagnostics Configuration Reducer (Linux)
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
	local fh = assert(io.open(helpers.driver_root() .. "/../_shared/tests/corpus/healthcheck/configuration_vectors.json", "rb"))
	local data = Json.decode(fh:read("*a"))
	fh:close()
	return data
end

local CORPUS = corpus()
local SHARED_ROOT = helpers.driver_root() .. "/../_shared/"

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

helpers.describe("diagnostics configuration sharing", function()
	local Share = require("healthcheck.share")

	--- Reads a shared JSON document.
	--- @param rel string Path under _shared/.
	--- @return table
	local function shared_json(rel)
		local fh = assert(io.open(SHARED_ROOT .. rel, "rb"))
		local data = Json.decode(fh:read("*a"))
		fh:close()
		return data
	end

	local schema = shared_json("modules/diagnostics/schema.json")
	schema.export_strings = shared_json("data/locales/en.json")
	local controls = shared_json("tests/corpus/healthcheck/configuration_share_vectors.json")

	--- A minimal host snapshot carrying only the configuration sections.
	--- @param driver string
	--- @param rows table
	--- @param files table
	--- @return table
	local function snapshot_of(driver, rows, files)
		return {
			schema_version = 2, driver = driver, generated_at = "2026-10-20T10:00:00Z",
			detailed = false, extensive = false,
			sections = { configuration = { items = rows }, configuration_files = { items = files } },
		}
	end

	for _, driver in ipairs({ "windows", "macos", "linux" }) do
		for _, vector in ipairs(controls.vectors) do
			helpers.it(driver .. ": " .. vector.id, function()
				local snapshot = snapshot_of(driver, vector.items, controls.files)
				local safe = Share.snapshot(snapshot, schema)
				helpers.assert_eq(safe.sections.configuration.items, vector.expected, vector.id)
				helpers.assert_eq(safe.sections.configuration_files.items, controls.expected_files, vector.id .. " files")
				local document = Share.document(snapshot, schema, "notice")
				for _, canary in ipairs(controls.canaries) do
					helpers.assert_true(not document.text:find(canary, 1, true), vector.id .. " leaked " .. canary)
				end
				for _, row in ipairs(vector.expected) do
					helpers.assert_contains(document.text, "| " .. row.setting .. " | " .. row.type .. ": " .. row.value .. " |")
				end
			end)
		end
	end

	helpers.it("bounds the shared configuration rows", function()
		local rows = {}
		for index = 1, 801 do rows[index] = { setting = "script.k" .. index, type = "boolean", value = "true" } end
		local safe = Share.snapshot(snapshot_of("linux", rows, {}), schema)
		helpers.assert_eq(#safe.sections.configuration.items, 800)
	end)

	helpers.it("shares nothing a collector's own canaries could carry, end to end", function()
		for _, vector in ipairs(CORPUS.vectors) do
			local rows = Configuration.rows(CORPUS.features, Toml.decode(vector.toml), vector.driver, 800)
			local document = Share.document(snapshot_of(vector.driver, rows, {}), schema, "notice")
			for _, canary in ipairs(CORPUS.canaries) do
				helpers.assert_true(not document.text:find(canary, 1, true), vector.id .. " leaked " .. canary)
			end
		end
	end)
end)

helpers.describe("diagnostics configuration files", function()
	--- An io.open replacement serving fixed outcomes by path.
	--- @param table_of table path -> { text = string } | { errno = number } | { read_fails = true }
	--- @return function
	local function fake_open(table_of)
		return function(path)
			local entry = table_of[path]
			if entry.errno then return nil, "refused", entry.errno end
			return {
				read = function() if entry.read_fails then return nil, "Is a directory" end return entry.text end,
				close = function() return true end,
			}
		end
	end

	local function path_of(id) return "/cfg/" .. id .. ".toml" end
	local IDS = { "defaults", "config", "layers", "tap_hold" }

	helpers.it("reports ok, missing and unreadable in resolution order", function()
		local items, document = Configuration.read_files(IDS, path_of, Toml.decode, fake_open({
			["/cfg/config.toml"] = { text = '[script]\nlog_level = "INFO"\n' },
			["/cfg/layers.toml"] = { errno = 2 },
			["/cfg/tap_hold.toml"] = { read_fails = true },
		}))
		helpers.assert_eq(items, {
			{ id = "defaults", state = "ok" }, { id = "config", state = "ok" },
			{ id = "layers", state = "missing" }, { id = "tap_hold", state = "unreadable" },
		})
		helpers.assert_eq(document.script.log_level, "INFO")
	end)

	helpers.it("reports a permission failure as unreadable, never as missing", function()
		local items = Configuration.read_files({ "config" }, path_of, Toml.decode,
			fake_open({ ["/cfg/config.toml"] = { errno = 13 } }))
		helpers.assert_eq(items[1].state, "unreadable")
	end)

	helpers.it("reports a config.toml that does not decode as invalid and yields no setting", function()
		local result = Configuration.collect({ configuration = { files = { linux = { "defaults", "config" } }, max_rows = 800 } },
			"linux", CORPUS.features, path_of,
			function() error("malformed TOML") end,
			fake_open({ ["/cfg/config.toml"] = { text = "[script\n" } }))
		helpers.assert_eq(result.files.items[2].state, "invalid")
		helpers.assert_eq(#result.settings.items, 0)
	end)

	helpers.it("collects the shareable rows of a readable config.toml", function()
		local result = Configuration.collect({ configuration = { files = { linux = { "defaults", "config" } }, max_rows = 800 } },
			"linux", CORPUS.features, path_of, Toml.decode,
			fake_open({ ["/cfg/config.toml"] = { text = '[script]\nlocale = "/home/PRIVATE_USER_ZEBRA/notes"\n' } }))
		helpers.assert_eq(result.settings.items, { { setting = "script.locale", type = "text", value = "30" } })
	end)
end)
