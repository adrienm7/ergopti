--- _shared/tests/lua/workflows/workflow_model_contract.lua

--- ==============================================================================
--- MODULE: User Workflow Model Contract
--- DESCRIPTION:
--- Replays _shared/tests/corpus/workflows/validation_vectors.json against the
--- shared Lua model, so the macOS and Linux suites accept and refuse the same
--- workflow files as the canonical JS check of the editor, with the same
--- reason at the same JSON Pointer. Also pins the placeholder expansion and
--- the shell approval digest.
---
--- ROOT CAUSE ENCODED:
--- No driver could read a user workflow: an imported file had no rule to be
--- refused by, and three hand-written checks would refuse different files.
--- ==============================================================================

local Json = require("core.text.engine.json")
local Model = require("shortcuts.engine.workflows.model")

local M = {}

--- Decodes one JSON file through the driver's shared-root resolver.
--- @param shared_path function
--- @param relative string
--- @param lossless boolean
--- @return table
local function load_json(shared_path, relative, lossless)
	local file = assert(io.open(shared_path(relative), "rb"))
	local text = assert(file:read("*a")); assert(file:close())
	return assert(lossless and Json.decode_lossless(text) or Json.decode(text), relative)
end

--- A copy of the catalogue with the vector's limits merged over its own.
--- @param catalogue table
--- @param limits table|nil
--- @return table
local function with_limits(catalogue, limits)
	if not limits then return catalogue end
	local copy = {}
	for key, value in pairs(catalogue) do copy[key] = value end
	copy.limits = {}
	for key, value in pairs(catalogue.limits) do copy.limits[key] = value end
	for key, value in pairs(limits) do copy.limits[key] = value end
	return copy
end

--- Registers the vector replay and the helper checks.
--- @param helpers table Driver test API.
--- @param shared_path function Driver resolver for a path under _shared/.
function M.register(helpers, shared_path)
	local catalogue = load_json(shared_path, Model.CATALOGUE_PATH, false)
	local vocabulary = load_json(shared_path, "shortcuts/data/actions/send_keys.json", false)
	local corpus = load_json(shared_path, "tests/corpus/workflows/validation_vectors.json", true)
	assert(#corpus.vectors >= 90, "the workflow validation corpus lost its vectors")
	local context = { vocabulary = vocabulary, timings = corpus.timings }

	helpers.describe("workflows: validation vectors", function()
		for _, vector in ipairs(corpus.vectors) do
			local row = vector
			helpers.it("workflows: validation " .. row.id, function()
				local result = Model.validate_file(row.doc, with_limits(catalogue, row.limits), context)
				helpers.assert_eq(result.ok, row.expected.ok, row.id)
				if not row.expected.ok then
					helpers.assert_eq(result.reason, row.expected.reason, row.id)
					helpers.assert_eq(result.path, row.expected.path, row.id)
				end
			end)
		end
	end)

	helpers.describe("workflows: placeholders and shell digest", function()
		helpers.it("workflows: a known variable expands, an unknown one is named", function()
			helpers.assert_eq(Model.expand("Hi {{who}}!", { who = "Ada" }), "Hi Ada!")
			local value, missing = Model.expand("{{who}} {{what}}", { who = "Ada" })
			helpers.assert_eq(value, nil)
			helpers.assert_eq(missing, "what")
		end)
		helpers.it("workflows: braces that name no identifier stay text", function()
			helpers.assert_eq(Model.expand("{{ x }} {{}} {{1a}} {{a", {}), "{{ x }} {{}} {{1a}} {{a")
		end)
		helpers.it("workflows: a placeholder value is not expanded again", function()
			helpers.assert_eq(Model.expand("{{a}}", { a = "{{b}}" }), "{{b}}")
		end)
		helpers.it("workflows: the shell digest covers the id and every command in order", function()
			local workflow = { id = "wf_1", steps = {
				{ kind = "shell", command = "echo a" },
				{ kind = "if", condition = {}, ["then"] = { { kind = "shell", command = "echo b" } },
					["else"] = { { kind = "repeat", count = 1, steps = { { kind = "shell", command = "echo c" } } } } },
			} }
			local digest = Model.shell_digest(workflow)
			helpers.assert_eq(digest, require("core.crypto.engine.sha256").hex("wf_1\0echo a\0echo b\0echo c"))
			workflow.steps[1].command = "echo A"
			helpers.assert_true(Model.shell_digest(workflow) ~= digest, "an edited command needs a new approval")
			helpers.assert_eq(Model.shell_digest({ id = "wf_1", steps = { { kind = "wait", duration_ms = 1 } } }), nil)
		end)
	end)
end

return M
