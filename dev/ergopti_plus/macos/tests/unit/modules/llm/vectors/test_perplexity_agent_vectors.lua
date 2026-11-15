--- tests/unit/modules/llm/vectors/test_perplexity_agent_vectors.lua

--- ==============================================================================
--- MODULE: Perplexity Agent API Corpus (macOS)
--- DESCRIPTION:
--- Replays the agent_body and agent_answer sections of
--- _shared/tests/corpus/llm/remote_formats_vectors.json through the shared
--- request writer and classifier, the sections Linux and Windows replay too.
---
--- ROOT CAUSE ENCODED:
--- Perplexity's Agent API answers a typed output array, may hold a null error
--- beside a good answer, and refuses a chat-completions body.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("core.text.engine.json")

local Formats = require("ai.engine.api.remote_formats")
local Classifier = require("ai.engine.policy.remote_response_classifier")

--- @return table corpus The decoded corpus.
local function corpus()
	local fh = assert(io.open(helpers.driver_root() .. "/../_shared/tests/corpus/llm/remote_formats_vectors.json", "r"))
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw))
end

helpers.describe("Perplexity Agent API corpus", function()
	local vectors = corpus()

	for _, v in ipairs(vectors.agent_body) do
		helpers.it("agent body '" .. v.id .. "'", function()
			local body = Formats.agent_body(v.spec)
			for key, value in pairs(v.expected) do helpers.assert_eq(body[key], value, key) end
			for key in pairs(body) do helpers.assert_true(v.expected[key] ~= nil, key .. " is unexpected") end
		end)
	end

	for _, v in ipairs(vectors.agent_answer) do
		helpers.it("agent answer '" .. v.id .. "'", function()
			helpers.assert_eq(Classifier.classify(Formats.AGENT_FORMAT, v.body).text, v.text)
		end)
	end
end)
