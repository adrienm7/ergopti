--- tests/unit/infra/test_paced_job_and_json.lua

--- ==============================================================================
--- MODULE: Paced Job And Paced JSON
--- DESCRIPTION:
--- The metrics dashboard's projection runs through `infra.paced_job` so no
--- slice blocks the run loop for long, and its multi-megabyte payload is
--- encoded by `infra.paced_json` between pauses. The runner must never start
--- inline, must yield once its budget is spent, must settle exactly once, and
--- a cancelled job must stay silent. The encoder must keep LuaSkin's shapes.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a fresh runner over a manual clock and a manual timer queue.
local function load_runner()
	local clock = { now_ns = 0 }
	local queue = {}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.timer_scheduler"] = {
		after = function(_, fn)
			local handle = { timer = {} }
			queue[#queue + 1] = { handle = handle, fn = fn }
			return handle, true
		end,
		cancel = function(handle) handle.timer = nil; handle.cancelled = true; return true end,
	}
	package.loaded["infra.paced_job"] = nil
	local runner = helpers.load_with_stubs("infra.paced_job", {
		timer = { absoluteTime = function() return clock.now_ns end },
	})
	local function run_next()
		local entry = table.remove(queue, 1)
		if entry and not entry.handle.cancelled then entry.fn() end
		return entry ~= nil
	end
	return runner, clock, queue, run_next
end

helpers.describe("infra.paced_job", function()
	local owners = { "infra.paced_job", "infra.logger", "adapters.timer_scheduler" }

	helpers.it("never runs inline and yields once the slice budget is spent", function()
		helpers.with_fresh_modules(owners, function()
			local runner, clock, queue, run_next = load_runner()
			local steps, outcome = 0, nil
			runner.start({
				label = "test job", slice_ms = 10,
				body = function(pacer)
					for _ = 1, 6 do
						steps = steps + 1
						clock.now_ns = clock.now_ns + 4 * 1000000
						pacer.pause()
					end
					return "done"
				end,
				on_done = function(ok, result) outcome = { ok, result } end,
			})
			helpers.assert_eq(steps, 0, "start() returns before any work runs")
			helpers.assert_eq(#queue, 1)
			run_next()
			helpers.assert_eq(steps, 3, "a 10 ms budget yields after the third 4 ms step")
			helpers.assert_nil(outcome)
			run_next()
			helpers.assert_eq(steps, 6)
			run_next()
			helpers.assert_eq(outcome[1], true)
			helpers.assert_eq(outcome[2], "done")
			helpers.assert_eq(#queue, 0, "a settled job owns no timer")
		end)
	end)

	helpers.it("reports a failing body once and a cancelled job never", function()
		helpers.with_fresh_modules(owners, function()
			local runner, clock, _, run_next = load_runner()
			local failures = {}
			runner.start({
				label = "failing job",
				body = function() error("boom") end,
				on_done = function(ok, result) failures[#failures + 1] = { ok, result } end,
			})
			run_next()
			helpers.assert_eq(#failures, 1)
			helpers.assert_eq(failures[1][1], false)
			helpers.assert_true(tostring(failures[1][2]):find("boom", 1, true) ~= nil)

			local called = false
			local job = runner.start({
				label = "cancelled job", slice_ms = 1,
				body = function(pacer)
					clock.now_ns = clock.now_ns + 5 * 1000000
					pacer.pause()
					return true
				end,
				on_done = function() called = true end,
			})
			run_next()
			helpers.assert_true(job.cancel())
			while run_next() do end
			helpers.assert_eq(called, false, "a cancelled job never calls back")
			helpers.assert_eq(job.state, "cancelled")
		end)
	end)
end)

helpers.describe("infra.paced_json", function()
	helpers.it("encodes LuaSkin shapes and round-trips through a JSON decoder", function()
		helpers.with_fresh_modules({ "infra.paced_json", "json" }, function()
			local PacedJson = require("infra.paced_json")
			local json = require("json")
			local value = {
				historical = { c = { a = { c = 1, t = 2.5, e = 0 }, ["\"q\\\n"] = { c = 3 } }, bg = {} },
				list = { 1, 2, 3 }, flag = true, name = "données é",
			}
			local encoded = PacedJson.encode(value)
			local decoded = json.decode(encoded)
			helpers.assert_eq(decoded.historical.c.a.t, 2.5)
			helpers.assert_eq(decoded.historical.c["\"q\\\n"].c, 3)
			helpers.assert_eq(decoded.list[3], 3)
			helpers.assert_eq(decoded.name, "données é")
			helpers.assert_true(encoded:find('"bg":[]', 1, true) ~= nil, "an empty table encodes as [] like hs.json")
			helpers.assert_eq(PacedJson.encode(12.0), "12", "integral floats keep NSJSONSerialization's form")
		end)
	end)

	helpers.it("refuses values the page could not parse", function()
		helpers.with_fresh_modules({ "infra.paced_json" }, function()
			local PacedJson = require("infra.paced_json")
			helpers.assert_eq((pcall(PacedJson.encode, { x = 0 / 0 })), false)
			helpers.assert_eq((pcall(PacedJson.encode, { x = math.huge })), false)
			helpers.assert_eq((pcall(PacedJson.encode, { x = "\255\254" })), false)
			helpers.assert_eq((pcall(PacedJson.encode, { x = function() end })), false)
		end)
	end)

	helpers.it("pauses while encoding a large value", function()
		helpers.with_fresh_modules({ "infra.paced_json" }, function()
			local PacedJson = require("infra.paced_json")
			local big = {}
			for index = 1, 3000 do big["token" .. index] = { c = index, t = 0, e = 0 } end
			local pauses = 0
			PacedJson.encode(big, { pause = function() pauses = pauses + 1 end })
			helpers.assert_true(pauses >= 10, "a large payload offers pause points")
		end)
	end)
end)
