--- tests/unit/llm/test_api_entry_names_vectors.lua

--- ==============================================================================
--- MODULE: API Entry Names Corpus (shared Lua oracle)
--- DESCRIPTION:
--- Regression api-entry-auto-name. Replays
--- _shared/tests/corpus/llm/api_entry_names_vectors.json through
--- _shared/lua/llm/api_entry_names.lua, the rule every tray names a remote API
--- entry by: <provider>/<model>, told apart by host, then by order, when two
--- entries share it. The AutoHotkey port replays the same corpus.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local SHARED = helpers.driver_root() .. "/../_shared/"
package.path = SHARED .. "lua/?.lua;" .. SHARED .. "lua/?/init.lua;" .. package.path

local EntryNames = require("llm.api_entry_names")

--- @return table decoded The corpus.
local function corpus()
	local path = "tests/corpus/llm/api_entry_names_vectors.json"
	local fh = assert(io.open(SHARED .. path, "r"), "cannot open " .. path)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), path .. " is not valid JSON")
end

helpers.describe("API entry names replay the shared corpus (api-entry-auto-name)", function()
	local vectors = corpus()

	helpers.it("reads the host of a base URL", function()
		helpers.assert_true(#vectors.host >= 5, "the host vectors must not be empty")
		for _, vector in ipairs(vectors.host) do
			helpers.assert_eq(EntryNames.host(vector.url), vector.host, "host of '" .. vector.url .. "'")
		end
	end)

	helpers.it("names each entry, and entries of one provider and model apart", function()
		helpers.assert_true(#vectors.names >= 5, "the name vectors must not be empty")
		for _, vector in ipairs(vectors.names) do
			helpers.assert_eq(EntryNames.names(vector.entries), vector.names, vector.id)
		end
	end)
end)
