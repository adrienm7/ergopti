--- _shared/lua/test/llm_request_plan_contract.lua

--- ==============================================================================
--- MODULE: LLM Request Plan Contract
--- DESCRIPTION:
--- Replays the request transcripts of the shared plan (debounce, rate floor and
--- batching) through the actual driver assertion owner. The plan has one
--- behaviour for every driver, so the corpus declares no per-driver option set.
--- Native timers, HTTP and tooltips stay driver-owned; only the decisions are
--- pinned here.
--- ==============================================================================

local M = {}
local Json = require("json")
local Debounce = require("llm.request_plan.debounce")
local Batching = require("llm.request_plan.batching")

--- Reads and decodes one corpus file.
--- @param path string Absolute path.
--- @return table decoded
local function read_json(path)
	local file = assert(io.open(path, "rb"), "cannot open " .. path)
	local content = file:read("*a")
	assert(file:close())
	return assert(Json.decode(content), path .. " is not valid JSON")
end

--- Builds the floor port a vector declares.
--- @param floor_ms number|nil The interval in milliseconds; nil makes the port raise.
--- @return function floor_ms
local function floor_port(floor_ms)
	return function()
		if floor_ms == nil then error("no floor was declared", 0) end
		return floor_ms
	end
end

--- Runs one step on a plan.
--- @param plan table The plan.
--- @param step table One step.
--- @return boolean ok
--- @return any result Decisions, or the error message.
local function run_step(plan, step)
	return pcall(function()
		if step.call == "on_dispatch" then return plan:on_dispatch(step.args, step.now_ms) end
		if step.call == "on_explicit" then return plan:on_explicit(step.args) end
		if step.call == "on_sent" then return plan:on_sent(step.now_ms) or {} end
		if step.call == "configure" then return plan:configure(step.args) or {} end
		if step.call == "reset" then return plan:reset() or {} end
		if step.call == "on_input" then return plan:on_input(step.args) end
		if step.call == "on_timer" then return plan:on_timer(step.args.token) end
		if step.call == "on_cancel" then return plan:on_cancel() end
		error("unknown step call '" .. tostring(step.call) .. "'", 0)
	end)
end

--- Registers the debounce transcripts and the driver's place in the corpus.
--- @param helpers table Driver assertions and case registration.
--- @param corpus_path string Canonical shared debounce corpus path.
--- @param driver string "macos" or "linux", the key of the corpus `drivers` record.
function M.run_debounce(helpers, corpus_path, driver)
	local corpus = read_json(corpus_path)
	helpers.describe("Shared request plan debounce transcripts (" .. driver .. ")", function()
		helpers.it("the corpus declares the one shared behaviour and this driver replays it", function()
			for _, key in ipairs({ "never", "explicit_requests", "floor", "live_word_end" }) do
				helpers.assert_eq(type(corpus.shared_behaviour[key]), "string", "shared_behaviour." .. key)
			end
			helpers.assert_contains(corpus.drivers[driver], "Replays every vector")
			helpers.assert_eq(type(corpus.drivers.windows), "string", "the Windows port is recorded")
			helpers.assert_eq(corpus.driver_options, nil, "no per-driver option set remains")
		end)

		for _, vector in ipairs(corpus.vectors) do
			helpers.it("transcript '" .. vector.id .. "'", function()
				local plan = Debounce.new(floor_port(vector.floor_ms))
				for index, step in ipairs(vector.steps) do
					local label = vector.id .. " step " .. index .. " (" .. step.call .. ")"
					local ok, result = run_step(plan, step)
					if step.expect_error then
						helpers.assert_eq(ok, false, label .. " must raise")
						helpers.assert_contains(tostring(result), step.expect_error)
					else
						helpers.assert_eq(ok, true, label .. " raised: " .. tostring(result))
						helpers.assert_eq(result, step.expect, label)
					end
				end
			end)
		end

		helpers.it("a plan refuses a missing floor port", function()
			local ok, err = pcall(Debounce.new, nil)
			helpers.assert_eq(ok, false)
			helpers.assert_contains(tostring(err), "floor_ms")
			helpers.assert_eq(pcall(Debounce.new, 500), false, "a number is not a port")
		end)
	end)
end

--- Registers the batching transcripts.
--- @param helpers table Driver assertions and case registration.
--- @param corpus_path string Canonical shared batching corpus path.
function M.run_batching(helpers, corpus_path)
	local corpus = read_json(corpus_path)
	helpers.describe("Shared request plan batching transcripts", function()
		for _, vector in ipairs(corpus.vectors) do
			helpers.it("transcript '" .. vector.id .. "'", function()
				local ok, result = pcall(Batching.plan, vector.batch_profile, vector.requested)
				if vector.expect_error then
					helpers.assert_eq(ok, false, "must raise")
					helpers.assert_contains(tostring(result), vector.expect_error)
				else
					helpers.assert_eq(ok, true, tostring(result))
					helpers.assert_eq(result, vector.expect)
				end
			end)
		end
	end)
end

return M
