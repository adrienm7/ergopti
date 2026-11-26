--- _shared/tests/lua/ai/ollama_uninstall_contract.lua

--- ==============================================================================
--- MODULE: Managed Ollama Uninstall Contract
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/ollama_uninstall_vectors.json through the
--- shared uninstall sequence over scripted ports: the steps run in order, the
--- first refusal ends them, and the message each outcome shows. The Windows
--- port replays the same vectors. Both Lua drivers register it with their own
--- paths.
--- ==============================================================================

local M = {}

--- Registers the vector cases.
--- @param helpers table The driver's test helpers.
--- @param shared function Resolves a path under _shared/.
function M.register(helpers, shared)
	local Json = require("core.text.engine.json")
	local Uninstall = require("ai.engine.ollama.runtime_uninstall")
	local handle = assert(io.open(shared("tests/corpus/llm/ollama_uninstall_vectors.json"), "rb"))
	local corpus = assert(Json.decode_lossless(handle:read("*a")))
	handle:close()

	helpers.describe("managed Ollama uninstall vectors (oll-11)", function()
		helpers.it("(oll-11) reads the uninstall vectors", function()
			helpers.assert_true(#corpus.cases >= 8)
		end)
		for _, case in ipairs(corpus.cases) do
			helpers.it("(oll-11) uninstall " .. case.id, function()
				local refused = not Json.is_null(case.refuse) and case.refuse or nil
				local calls, files_flag, results = {}, nil, {}
				local function answer(step, done)
					calls[#calls + 1] = step
					done(step ~= refused)
				end
				Uninstall.run(case.remove_models, {
					busy = function() return case.busy end,
					delete_models = function(done) answer("models", done) end,
					stop = function(done) answer("stop", done) end,
					remove_files = function(remove_models, done)
						files_flag = remove_models
						answer("files", done)
					end,
				}, function(result) results[#results + 1] = result end)
				helpers.assert_eq(#results, 1, "one terminal result")
				helpers.assert_eq(calls, case.steps)
				helpers.assert_eq(results[1].steps, case.steps)
				helpers.assert_eq(results[1].ok, case.ok)
				helpers.assert_eq(results[1].message, case.message)
				if files_flag ~= nil then helpers.assert_eq(files_flag, case.remove_models) end
			end)
		end
		helpers.it("(oll-11) refuses an incomplete port set before running anything", function()
			local ok = pcall(Uninstall.run, false, { busy = function() return false end }, function() end)
			helpers.assert_eq(ok, false)
		end)
	end)
end

return M
