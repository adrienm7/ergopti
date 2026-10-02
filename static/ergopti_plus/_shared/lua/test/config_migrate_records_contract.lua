--- _shared/lua/test/config_migrate_records_contract.lua

--- ==============================================================================
--- MODULE: Config Migration Record Bytes Contract
--- DESCRIPTION:
--- Replays hand-authored physical output through the actual migration engine.
--- Registered by both native Lua suites, this contract pins untouched rows,
--- comments, empty and quoted foreign headers, typed occupied choices, nested
--- arrays, and record edits independently from any canonical TOML writer.
--- ==============================================================================

local M = {}
local Engine = require("config_migrate")

local function read_bytes(path)
	local file = assert(io.open(path, "rb"), "missing record fixture: " .. path)
	local content = assert(file:read("*a"))
	assert(file:close())
	return content
end

local function corpus_root()
	local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
	local root = assert(source:match("^(.*)/lua/test/config_migrate_records_contract%.lua$"),
		"cannot locate the migration record corpus")
	return root .. "/tests/corpus/config_migration_record_bytes"
end

--- Register physical output cases in the actual driver suite.
--- @param helpers table Driver assertions and test registration owner.
--- @param options table The actual driver id in options.driver.
function M.register(helpers, options)
	local root = corpus_root()
	local variants = {
		{ id = "lf", transform = function(bytes) return bytes end },
		{ id = "bom-crlf", transform = function(bytes) return "\239\187\191" .. bytes:gsub("\n", "\r\n") end },
		{ id = "no-final-lf", transform = function(bytes) return (bytes:gsub("\n$", "")) end },
	}
	helpers.describe("config migration: independent physical records (config-migrate-records)", function()
		for _, name in ipairs({ "occupied", "changed", "moves" }) do
			for _, variant in ipairs(variants) do
				-- Appended sections have their own final terminator; no-final-LF cases
				-- instead prove exact preservation of an existing final foreign row.
				if name ~= "moves" or variant.id ~= "no-final-lf" then
					helpers.it(name .. ": " .. variant.id, function()
						local directory = root .. "/" .. name
						local input = variant.transform(read_bytes(directory .. "/input.toml"))
						local expected = variant.transform(read_bytes(directory .. "/expected.toml"))
						local registry, detail = Engine.load_registry(directory .. "/migrations.toml")
						helpers.assert_true(registry ~= nil, tostring(detail))
						local plan = Engine.plan(input, registry, options.driver)
						helpers.assert_eq(plan.outcome, "migrated", tostring(plan.detail))
						helpers.assert_eq(plan.candidate, expected, "every handwritten candidate byte")
						local expected_model, error_detail = Engine.model_from_source(expected)
						helpers.assert_true(expected_model ~= nil, tostring(error_detail))
						helpers.assert_eq(Engine.plain(plan.model), Engine.plain(expected_model),
							"the whole independently expected model, including scalar types")
						helpers.assert_eq(Engine.plan(plan.candidate, registry, options.driver).outcome,
							"current", "a candidate is never rewritten on replay")
					end)
				end
			end
		end
	end)
end

return M
