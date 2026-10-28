--- _shared/lua/test/adapter_errors_contract.lua

--- ==============================================================================
--- MODULE: Adapter Error Taxonomy Contract
--- DESCRIPTION:
--- Replays the generated adapter_errors module on both Lua drivers: every
--- constant is a code-shaped id of the closed vocabulary, and the table refuses
--- an unknown name or a write, so a misspelt matcher fails where it is written.
--- ==============================================================================

local M = {}

--- Registers the taxonomy checks in a driver's existing owner.
--- @param helpers table The driver's describe/it/assertion functions.
function M.register(helpers)
	local Json = require("json")
	local Errors = require("adapter_errors")
	local file = assert(io.open(require("infra.paths").shared("modules/logger/vocabulary.json"), "rb"))
	local vocabulary = assert(Json.decode(file:read("*a")))
	file:close()
	helpers.describe("adapter error taxonomy (adapter-errors)", function()
		helpers.it("every id of the vocabulary section is a constant and a member of its closed enum (adapter-errors)", function()
			local count = 0
			for id, entry in pairs(vocabulary.adapter_errors) do
				count = count + 1
				local name = id:upper():gsub("[^A-Z0-9]+", "_")
				helpers.assert_eq(Errors[name], id)
				local member = false
				for _, listed in ipairs(vocabulary[entry.kind]) do member = member or listed == id end
				helpers.assert_true(member, id .. " must be a member of the closed " .. entry.kind .. " enum")
			end
			helpers.assert_true(count > 0, "the taxonomy must not be empty")
		end)

		helpers.it("an unknown constant raises instead of reading as nil (adapter-errors)", function()
			local ok, err = pcall(function() return Errors.PROCESS_DEADLINE_EXCEEDD end)
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(err):find("adapter_errors has no constant", 1, true) ~= nil, tostring(err))
		end)

		helpers.it("the table refuses a write (adapter-errors)", function()
			local ok, err = pcall(function() Errors.PROCESS_DEADLINE_EXCEEDED = "other" end)
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(err):find("read-only", 1, true) ~= nil, tostring(err))
			helpers.assert_eq(Errors.PROCESS_DEADLINE_EXCEEDED, "process_deadline_exceeded")
		end)
	end)
end

return M
