--- tests/unit/modules/llm/remote/test_auth_failure_vectors.lua

--- ==============================================================================
--- MODULE: Authentication Failure Corpus (shared Lua oracle)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/auth_failure_vectors.json through the shared
--- failure classifier the prediction retry policy consults, so a refused key is
--- never retried while every other failure keeps the retry policy.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("core.text.engine.json")

local SHARED = helpers.driver_root() .. "/../_shared/"
package.path = SHARED .. "?.lua;" .. SHARED .. "?/init.lua;" .. package.path

local FailureClass = require("ai.engine.policy.failure_class")

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

-- Windows hands the creation's own failure to on_fail
-- (_LLMRemote_OnBackboardAssistantFail), so a refused key stops at once. Linux
-- wrapped it as "the Backboard assistant could not be created: HTTP 401", which
-- the classifier's leading status no longer reads: every retry posted the
-- refused key again, six creations for one prediction (AIL-001,
-- backboard-creation-refusal).
helpers.describe("Backboard creation refusal stays a refused credential (backboard-creation-refusal)", function()
	helpers.it("a 401 or 403 creation fails as a refused credential, a 500 does not (backboard-creation-refusal)", function()
		local names = { "modules.llm.api_remote", "adapters.http_client", "core.logger.engine.shim" }
		local saved, calls = {}, {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		package.loaded["adapters.http_client"] = {
			post = function(url, _, _, callback) calls[#calls + 1] = { url = url, callback = callback }; return true end,
			cancel = function() return true end,
		}
		package.loaded["core.logger.engine.shim"] = helpers.make_logger_stub()
		local ok, detail = xpcall(function()
			local remote = helpers.load_module("modules.llm.api_remote")
			remote._reset_for_test()
			local FailureClass = require("ai.engine.policy.failure_class")
			local entry = { provider = "backboard", token = "owned-fixture-token", model = "openai/fixture",
				base_url = "http://127.0.0.1:1234" }
			for status, refused in pairs({ [401] = true, [403] = true, [500] = false }) do
				local failure
				remote.chat(entry, nil, { { role = "user", content = "fixture" } }, {}, nil, function(_, f) failure = f end)
				calls[#calls].callback({ ok = false, status = status, error_body = '{"detail":"fixture"}' })
				helpers.assert_true(calls[#calls].url:find("/assistants", 1, true) ~= nil, "the creation request")
				helpers.assert_eq(FailureClass.is_authentication_failure(failure), refused,
					"HTTP " .. status .. ": " .. tostring(failure))
				helpers.assert_true(tostring(failure):find("Backboard assistant", 1, true) ~= nil, "names the creation")
			end
		end, debug.traceback)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(detail, 0) end
	end)
end)
