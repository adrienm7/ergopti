--- tools/test/fixtures/perplexity-agent-client.lua

--- ==============================================================================
--- MODULE: Perplexity Agent API Lua Client
--- DESCRIPTION:
--- The shared Lua request and answer code macOS and Linux both run, for
--- test-perplexity-agent-e2e.cjs: "body <text>" prints the request a prediction
--- sends, "answer <file>" prints what the classifier reads from a response body.
--- The test owns the HTTP exchange with the fake network.
--- ==============================================================================

local root, mode, value = arg[1], arg[2], arg[3]
package.path = root .. "/_shared/?.lua;" .. root .. "/linux/?.lua;" .. root .. "/linux/vendor/?.lua;" .. package.path

local Json = require("core.text.engine.json")
local Formats = require("ai.engine.api.remote_formats")
local Classifier = require("ai.engine.policy.remote_response_classifier")

if mode == "body" then
	io.write(Json.encode(Formats.agent_body({ model = "perplexity/sonar", system = "Reply with OK.", text = value,
		max_tokens = 16, temperature = 0 })))
elseif mode == "answer" then
	local file = assert(io.open(value, "rb"))
	local classified = Classifier.classify(Formats.AGENT_FORMAT, file:read("a"))
	file:close()
	io.write(Json.encode({ text = classified.text, total_tokens = classified.usage.total_tokens }))
else
	error("unknown mode")
end
