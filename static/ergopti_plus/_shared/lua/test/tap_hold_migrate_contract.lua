--- _shared/lua/test/tap_hold_migrate_contract.lua

--- ==============================================================================
--- MODULE: Tap-Hold Migration Contract
--- DESCRIPTION:
--- The behaviour every driver's tap_hold.toml migration must keep, registered
--- once per driver suite: the shipped registry (_shared/tap_hold/migrations.toml)
--- is well formed, every case of _shared/tests/corpus/tap_hold_migrations is
--- replayed through the shared migrator with the driver's retired delays, a
--- migrated document equals the case's expected one, replaying the migration
--- on its own output changes nothing, and a registry defect is refused.
---
--- USAGE (one call per driver suite):
---   require("test.tap_hold_migrate_contract").register(helpers,
---     { driver = "linux", platform = "linux", shared_root = "<_shared>" })
--- ==============================================================================

local M = {}

local Migrate = require("tap_hold.migrate")
local TomlCodec = require("toml_codec")
local KeyCatalog = require("tap_hold.key_catalog")

--- The number of cases the corpus index must list, pinned so a truncated index
--- fails instead of shrinking the contract.
M.CASE_COUNT = 9

--- Reads a file whole, failing loudly when it is missing.
--- @param path string
--- @return string
local function read(path)
	local fh = io.open(path, "rb")
	if not fh then error("tap-hold migration corpus file is missing: " .. path) end
	local content = fh:read("*a")
	fh:close()
	return content
end

--- Decodes a corpus document with the canonical shape receipt.
--- @param text string
--- @return table document, table shapes
local function decode(text)
	local document, shapes = TomlCodec.decode_with_shapes(text)
	assert(type(document) == "table", "tap-hold migration corpus file does not parse")
	return document, shapes
end

--- Registers the contract in a driver suite.
--- @param helpers table The driver's test helpers.
--- @param opts table `{ driver = string, platform = string, shared_root = string }`;
---   platform is the key catalogue column of the driver.
function M.register(helpers, opts)
	local root = opts.shared_root
	local corpus = root .. "/tests/corpus/tap_hold_migrations"
	local registry = Migrate.load_registry(root .. "/tap_hold/migrations.toml")
	local retired = KeyCatalog.load_retired_delays(root .. "/tap_hold/defaults.toml", opts.platform)

	--- Runs one document through the migration.
	local function run(document, shapes)
		local function is_table(value) return type(value) == "table" and not shapes.arrays[value] end
		return Migrate.apply(document, registry, retired, is_table)
	end

	helpers.describe("tap-hold migration contract: " .. opts.driver .. " (tap-hold-migration-contract)", function()
		helpers.it("the shipped registry is one gap-free chain to the current version", function()
			helpers.assert_eq(registry.unstamped, 0)
			helpers.assert_eq(registry.current, 1)
			helpers.assert_eq(#registry.steps, 1)
			helpers.assert_eq(registry.steps[1].from, 0)
		end)

		local index = decode(read(corpus .. "/cases.toml")).corpus.cases
		helpers.it("the corpus index lists every pinned case", function()
			helpers.assert_eq(#index, M.CASE_COUNT)
		end)

		for _, name in ipairs(index) do
			local case = decode(read(corpus .. "/" .. name .. "/case.toml")).case
			local listed = false
			for _, driver in ipairs(case.drivers) do if driver == opts.driver then listed = true end end
			if listed then
				helpers.it("corpus case " .. name .. ": " .. case.description, function()
					local input = read(corpus .. "/" .. name .. "/input.toml")
					local document, shapes = decode(input)
					local outcome, from = run(document, shapes)
					helpers.assert_eq(outcome, case.outcome)
					if case.outcome == "migrated" then
						-- The in-place editor reaches the same document as the decoded migration.
						local source_document, source_shapes = decode(input)
						local edit_outcome, _, operations = Migrate.file_operations(source_document, registry, retired,
							function(value) return type(value) == "table" and not source_shapes.arrays[value] end)
						helpers.assert_eq(edit_outcome, "migrated")
						local plan = require("config_migrate").plan_operations(input, operations)
						helpers.assert_eq(plan.outcome, "migrated", tostring(plan.detail))
						helpers.assert_eq((decode(plan.candidate)), (decode(read(corpus .. "/" .. name .. "/expected.toml"))),
							"the line-preserving edit")
						helpers.assert_eq(from, case.from_version)
						local expected = decode(read(corpus .. "/" .. name .. "/expected.toml"))
						helpers.assert_eq(document, expected, "the migrated document")
						helpers.assert_eq((run(document, shapes)), "current", "replay on the migrated output")
						helpers.assert_eq(document, expected, "a replay changes nothing")
					else
						helpers.assert_eq(document, (decode(input)), "an unmigrated file is not edited")
					end
				end)
			end
		end
	end)
end

return M
