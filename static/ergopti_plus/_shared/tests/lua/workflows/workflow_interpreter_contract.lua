--- _shared/tests/lua/workflows/workflow_interpreter_contract.lua

--- ==============================================================================
--- MODULE: User Workflow Interpreter Contract
--- DESCRIPTION:
--- Replays _shared/tests/corpus/workflows/interpreter_vectors.json against the
--- shared interpreter: the effects a run asks for, in order, with their paths
--- and deadlines, the branches an « if » takes, the repeat count, the
--- variables, the shell approval rules and the outcome of a failure or an
--- abort. Each corpus workflow is first held valid by the shared model, so a
--- vector cannot pin the behaviour of a file the editor would refuse.
---
--- ROOT CAUSE ENCODED:
--- A workflow could not run anywhere; without one contract, three drivers
--- would take different branches, keep different variables or run a shell
--- step an import was never approved for.
--- ==============================================================================

local Json = require("core.text.engine.json")
local Model = require("shortcuts.engine.workflows.model")
local Interpreter = require("shortcuts.engine.workflows.interpreter")

local M = {}

local FINAL = { done = true, failed = true, aborted = true }
local DIGEST_TOKEN = "@digest"

--- @param shared_path function
--- @param relative string
--- @param lossless boolean
--- @return table
local function load_json(shared_path, relative, lossless)
	local file = assert(io.open(shared_path(relative), "rb"))
	local text = assert(file:read("*a")); assert(file:close())
	return assert(lossless and Json.decode_lossless(text) or Json.decode(text), relative)
end

--- Replaces the digest token by the workflow's own digest, deeply.
--- @param value any
--- @param digest string|nil
--- @return any
local function resolve(value, digest)
	if value == DIGEST_TOKEN then return digest end
	if type(value) ~= "table" or Json.is_null(value) then return value end
	local out = {}
	for key, item in pairs(value) do out[key] = resolve(item, digest) end
	return out
end

--- Registers the run replay.
--- @param helpers table Driver test API.
--- @param shared_path function Driver resolver for a path under _shared/.
function M.register(helpers, shared_path)
	local catalogue = load_json(shared_path, Model.CATALOGUE_PATH, false)
	local vocabulary = load_json(shared_path, "shortcuts/data/actions/send_keys.json", false)
	local corpus = load_json(shared_path, "tests/corpus/workflows/interpreter_vectors.json", true)
	assert(#corpus.vectors >= 30, "the workflow interpreter corpus lost its vectors")
	local context = { vocabulary = vocabulary, timings = { wait_max_ms = 600000 } }

	helpers.describe("workflows: interpreter vectors", function()
		for _, vector in ipairs(corpus.vectors) do
			local row = vector
			helpers.it("workflows: run " .. row.id, function()
				local valid = Model.validate_workflow(row.workflow, catalogue, context)
				helpers.assert_true(valid.ok, row.id .. " is not a valid workflow: " .. tostring(valid.reason)
					.. " at " .. tostring(valid.path))
				local run_catalogue = catalogue
				if row.limits then
					run_catalogue = {}
					for key, value in pairs(catalogue) do run_catalogue[key] = value end
					run_catalogue.limits = {}
					for key, value in pairs(catalogue.limits) do run_catalogue.limits[key] = value end
					for key, value in pairs(row.limits) do run_catalogue.limits[key] = value end
				end
				local digest = Model.shell_digest(row.workflow)
				local run = Interpreter.new({
					workflow = row.workflow, catalogue = run_catalogue, timeouts = corpus.timeouts,
					approved_digest = resolve(row.approved_digest, digest), variables = row.variables,
				})
				local results, expected_effects = row.results or {}, row.effects
				local seen, final = 0, nil
				for _ = 1, #expected_effects + 2 do
					local effect = run.next()
					if FINAL[effect.op] then final = effect; break end
					seen = seen + 1
					local wanted = expected_effects[seen]
					helpers.assert_true(wanted ~= nil, row.id .. ": unexpected effect " .. tostring(effect.op)
						.. " at " .. tostring(effect.path))
					for key, value in pairs(resolve(wanted, digest)) do
						if Json.is_null(value) then
							helpers.assert_eq(effect[key], nil, row.id .. " effect " .. seen .. " " .. key)
						else
							helpers.assert_eq(effect[key], value, row.id .. " effect " .. seen .. " " .. key)
						end
					end
					if row.abort_at == seen then
						run.abort()
					else
						local answer = results[seen] or { ok = true }
						run.complete({ ok = answer.ok, value = answer.value, reason = answer.reason })
					end
				end
				helpers.assert_eq(seen, #expected_effects, row.id .. ": effect count")
				helpers.assert_true(final ~= nil, row.id .. ": the run did not end")
				for _, key in ipairs({ "op", "reason", "path", "kind" }) do
					helpers.assert_eq(final[key], row.expected[key], row.id .. " outcome " .. key)
				end
				if row.approved_now ~= nil then helpers.assert_eq(run.approved_now(), row.approved_now, row.id) end
			end)
		end
	end)

	helpers.describe("workflows: interpreter guards", function()
		helpers.it("workflows: a run without a registry timeout refuses to start", function()
			local ok = pcall(Interpreter.new, { workflow = { id = "a", steps = {} }, catalogue = catalogue, timeouts = {} })
			helpers.assert_eq(ok, false)
		end)
		helpers.it("workflows: completing a finished run changes nothing", function()
			local run = Interpreter.new({ workflow = { id = "a", origin = "local", steps = {} },
				catalogue = catalogue, timeouts = corpus.timeouts })
			helpers.assert_eq(run.next().op, "done")
			run.complete({ ok = false })
			run.abort()
			helpers.assert_eq(run.status, "done")
		end)
	end)
end

return M
