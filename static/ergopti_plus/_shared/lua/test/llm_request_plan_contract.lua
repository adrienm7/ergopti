--- _shared/lua/test/llm_request_plan_contract.lua

--- ==============================================================================
--- MODULE: LLM Request Plan Contract
--- DESCRIPTION:
--- Replays the request transcripts of the shared plan (debounce, rate floor and
--- batching) through the actual driver assertion owner, and proves each driver's
--- own option set is the one the corpus declares for it. Native timers, HTTP and
--- tooltips stay driver-owned; only the decisions are pinned here.
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
--- @param floors table Backend to milliseconds.
--- @return function floor_ms
local function floor_port(floors)
	return function(backend)
		local value = floors[backend]
		if value == nil then error("no floor for backend '" .. tostring(backend) .. "'", 0) end
		return value
	end
end

--- Resolves a vector's option set: a driver_options name or an inline table.
--- @param corpus table The decoded corpus.
--- @param vector table One vector.
--- @return table options
local function options_of(corpus, vector)
	local chosen = vector.options
	if type(chosen) == "string" then chosen = assert(corpus.driver_options[chosen], "unknown option set " .. chosen) end
	local options = {}
	for key, value in pairs(chosen) do options[key] = value end
	options.floor_ms = floor_port(vector.floors or {})
	return options
end

--- Runs one step on a plan.
--- @param plan table The plan.
--- @param step table One step.
--- @return boolean ok
--- @return any result Decisions, or the error message.
local function run_step(plan, step)
	return pcall(function()
		if step.call == "on_dispatch" then return plan:on_dispatch(step.args, step.now_ms) end
		if step.call == "on_sent" then return plan:on_sent(step.args.backend, step.now_ms) or {} end
		if step.call == "configure" then return plan:configure(step.args) or {} end
		if step.call == "reset" then return plan:reset() or {} end
		if step.call == "on_input" then return plan:on_input(step.args) end
		if step.call == "on_timer" then return plan:on_timer(step.args.token) end
		if step.call == "on_cancel" then return plan:on_cancel() end
		error("unknown step call '" .. tostring(step.call) .. "'", 0)
	end)
end

--- Registers the debounce transcripts and the driver's option pin.
--- @param helpers table Driver assertions and case registration.
--- @param corpus_path string Canonical shared debounce corpus path.
--- @param driver string "macos" or "linux", the key of driver_options.
--- @param driver_options table The option set the driver's engine really runs, without the floor port.
function M.run_debounce(helpers, corpus_path, driver, driver_options)
	local corpus = read_json(corpus_path)
	helpers.describe("Shared request plan debounce transcripts (" .. driver .. ")", function()
		helpers.it("the driver runs the option set the corpus declares for it", function()
			local declared = assert(corpus.driver_options[driver], "no driver_options for " .. driver)
			helpers.assert_eq(driver_options, declared)
			for _, key in ipairs(Debounce.OPTION_KEYS) do
				helpers.assert_not_nil(declared[key], "declared option " .. key)
			end
		end)

		for _, vector in ipairs(corpus.vectors) do
			helpers.it("transcript '" .. vector.id .. "'", function()
				local plan = Debounce.new(options_of(corpus, vector))
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

		helpers.it("a plan refuses a missing or mistyped option", function()
			for _, key in ipairs(Debounce.OPTION_KEYS) do
				local options = options_of(corpus, { options = "macos", floors = {} })
				options[key] = nil
				local ok, err = pcall(Debounce.new, options)
				helpers.assert_eq(ok, false, key .. " omitted must raise")
				helpers.assert_contains(tostring(err), key)
			end
			local bad = options_of(corpus, { options = "linux", floors = {} })
			bad.floor_scope = "everywhere"
			helpers.assert_eq(pcall(Debounce.new, bad), false)
			bad = options_of(corpus, { options = "linux", floors = {} })
			bad.floor_ms = nil
			helpers.assert_eq(pcall(Debounce.new, bad), false)
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
