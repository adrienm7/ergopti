--- tests/unit/modules/llm/vectors/test_auth_failure_vectors.lua

--- ==============================================================================
--- MODULE: Authentication Failure Corpus (shared Lua oracle)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/auth_failure_vectors.json through the shared
--- failure classifier the prediction retry policy consults, so a refused key is
--- never retried while every other failure keeps the retry policy.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local SHARED = helpers.driver_root() .. "/../_shared/"
package.path = SHARED .. "lua/?.lua;" .. SHARED .. "lua/?/init.lua;" .. package.path

local FailureClass = require("llm.failure_class")

local function read_vectors()
	local path = SHARED .. "tests/corpus/llm/auth_failure_vectors.json"
	local fh = assert(io.open(path, "r"), "cannot open " .. path)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), path .. " is not valid JSON")
end

helpers.describe("Authentication failure corpus", function()
	for _, vec in ipairs(read_vectors().vectors) do
		helpers.it(vec.name, function()
			local failure = vec.failure
			if json.is_null and json.is_null(failure) then failure = nil end
			helpers.assert_eq(FailureClass.is_authentication_failure(failure), vec.authentication, vec.name)
		end)
	end
end)
