--- tests/unit/modules/llm/test_enable_admission_policy.lua

--- ==============================================================================
--- MODULE: Shared Local AI Enable Admission Contract
--- DESCRIPTION:
--- Replays independently written version receipts and lifecycle transitions.
--- ==============================================================================

local helpers = require("tests.helpers")
local function test(name, body) helpers.it(name .. " (ai-enable-admission)", body) end
local Policy = require("llm.enable_admission")
local Json = require("json")
local Paths = require("infra.paths")
local file = assert(io.open(Paths.shared("tests/corpus/llm/enable_admission.json"), "rb"))
local corpus = assert(Json.decode_lossless(file:read("*a")))
file:close()

helpers.describe("shared local AI enable admission", function()
	for _, row in ipairs(corpus.receipts) do
		test(row.name, function()
			local admitted = Policy.receipt(row.result)
			helpers.assert_eq(admitted, row.expected)
		end)
	end
	for _, row in ipairs(corpus.current) do
		test(row.name, function()
			helpers.assert_eq(Policy.current(row.captured, row.live), row.expected)
		end)
	end
	test("API activation is independent of Ollama", function()
		helpers.assert_eq(Policy.requires_probe("api"), false)
		helpers.assert_eq(Policy.requires_probe("ollama"), true)
		helpers.assert_eq(Policy.VERSION_PATH, "/api/version")
	end)
end)
