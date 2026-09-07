--- tests/unit/modules/llm/test_prediction_request_cancellation_logs.lua

--- ==============================================================================
--- MODULE: Prediction Request Cancellation Diagnostics
--- DESCRIPTION:
--- Exercises actual request revocation and backend callbacks. Cancellation logs
--- must identify an outstanding dispatch exactly once, without claiming success
--- or logging idle resets and already-completed requests as cancellations.
--- ==============================================================================

local helpers = require("tests.helpers")
local Pipeline = require("tests.support.prediction_pipeline")


local function load_fixture(options)
	options = options or {}
	options.render_success = true
	options.capture_info = true
	return Pipeline.load(options)
end


local function deliver(fixture, final)
	fixture.on_success({ {
		to_type = " completion", deletes = 0,
		chunks = { { type = "insert", text = " completion" } }, nw = "",
	} }, 25, final ~= false, final == false)
end


local function cancellations(fixture)
	local records = {}
	for _, record in ipairs(fixture.logs) do
		if record.message:find("LLM request cancelled", 1, true) then
			records[#records + 1] = record
		end
	end
	return records
end


helpers.describe("prediction request cancellation lifecycle", function()
	for _, boundary in ipairs({ "on_render", "on_suggested" }) do
		helpers.it("still cancels before the final outcome at " .. boundary, function()
			local reentered = false
			local fixture = load_fixture({ [boundary] = function(active)
				if not reentered then
					reentered = true
					active.engine.reset()
				end
			end })
			fixture.engine.perform_check(true)
			deliver(fixture)
			helpers.assert_true(reentered)
			helpers.assert_eq(#cancellations(fixture), 1)
			helpers.assert_true(not fixture.engine.is_visible())
			for _, record in ipairs(fixture.logs) do helpers.assert_true(record.level ~= "success") end
		end)
	end

	for _, outcome in ipairs({ "success", "failure", "empty" }) do
		helpers.it("does not cancel a terminal " .. outcome .. " from its diagnostic sink", function()
			local reentered = false
			local fixture = load_fixture({ on_log = function(active, record)
				local terminal = record.message:find("prediction(s) received", 1, true)
					or record.message:find("LLM request failed", 1, true)
					or record.message:find("No valid predictions", 1, true)
				if not reentered and terminal then
					reentered = true
					active.engine.reset()
				end
			end })
			fixture.engine.perform_check(true)
			if outcome == "success" then deliver(fixture)
			elseif outcome == "failure" then fixture.on_fail()
			else fixture.on_success({}, 25, true, false) end
			helpers.assert_true(reentered)
			helpers.assert_eq(#cancellations(fixture), 0)
			helpers.assert_true(not fixture.engine.is_visible())
		end)
	end

	helpers.it("does not clean up a successor dispatched by an abandonment diagnostic", function()
		local reentered = false
		local fixture = Pipeline.load({ capture_info = true, on_log = function(active, record)
			if not reentered and record.message:find("request abandoned", 1, true) then
				reentered = true
				active.engine.perform_check(true)
			end
		end })
		fixture.engine.perform_check(true)
		deliver(fixture)
		helpers.assert_true(reentered)
		helpers.assert_eq(fixture.fetches, 2)
		helpers.assert_eq(fixture.cancels, 0, "old cleanup must not cancel the diagnostic-created successor")
		helpers.assert_eq(#cancellations(fixture), 0)
	end)

	for _, reason in ipairs({ "reset", "supersede" }) do
		helpers.it("preserves the successor created by a reentrant " .. reason .. " diagnostic", function()
			local reentered = false
			local cancelled_after_fetches = nil
			local fixture = load_fixture({
				on_cancel = function(active) cancelled_after_fetches = active.fetches end,
				on_log = function(active, record)
				if not reentered and record.message:find("reason=" .. reason, 1, true) then
					reentered = true
					active.engine.perform_check(true)
				end
			end })
			fixture.engine.perform_check(true)
			if reason == "reset" then helpers.assert_true(fixture.engine.reset())
			else fixture.engine.perform_check(true) end
			helpers.assert_true(reentered, "the real diagnostic must cross the reentrant sink")
			helpers.assert_eq(fixture.fetches, 2,
				"only the initial request and the sink-created successor may dispatch")
			if reason == "reset" then
				helpers.assert_eq(cancelled_after_fetches, 1,
					"the backend cancel must complete before a diagnostic admits a successor")
			end
			deliver(fixture)
			helpers.assert_true(fixture.engine.is_visible(), "predecessor cleanup must not revoke its successor")
			helpers.assert_eq(#cancellations(fixture), 1)
		end)
	end

	helpers.it("logs one active reset and rejects a final callback reentered by cancellation", function()
		local fixture = load_fixture({ on_cancel = function(active)
			if active.cancels == 1 then
				deliver(active)
				helpers.assert_true(active.engine.reset())
			end
		end })
		fixture.engine.perform_check(true)
		helpers.assert_eq(fixture.fetches, 1)
		helpers.assert_true(fixture.engine.reset())
		local records = cancellations(fixture)
		helpers.assert_eq(#records, 1, "reentrant cleanup must retire the request diagnostic exactly once")
		helpers.assert_eq(records[1].level, "info", "normal cancellation must remain visible without DEBUG logging")
		helpers.assert_true(records[1].message:find("reason=reset", 1, true) ~= nil)
		helpers.assert_true(records[1].message:match("request=%d+") ~= nil)
		local request_id = records[1].message:match("request=(%d+)")
		local start_id
		for _, record in ipairs(fixture.logs) do
			if record.level == "start" then start_id = record.message:match("request=(%d+)") end
		end
		helpers.assert_eq(start_id, request_id, "start and cancellation must identify the same dispatch")
		helpers.assert_true(records[1].message:find("hello", 1, true) == nil)
		helpers.assert_eq(fixture.prediction_renders, 0)
		helpers.assert_true(not fixture.engine.is_visible())
		for _, record in ipairs(fixture.logs) do helpers.assert_true(record.level ~= "success") end
	end)

	for _, terminal in ipairs({ "idle", "success", "failure", "empty" }) do
		helpers.it("does not invent cancellation after " .. terminal, function()
			local fixture = load_fixture()
			if terminal ~= "idle" then
				fixture.engine.perform_check(true)
				helpers.assert_eq(fixture.fetches, 1)
				if terminal == "success" then deliver(fixture)
				elseif terminal == "failure" then fixture.on_fail()
				else fixture.on_success({}, 25, true, false) end
			end
			helpers.assert_true(fixture.engine.reset())
			helpers.assert_true(fixture.engine.reset())
			helpers.assert_eq(#cancellations(fixture), 0)
			helpers.assert_true(not fixture.engine.is_visible())
		end)
	end

	for _, revoke in ipairs({ "reset", "consume", "supersede" }) do
		helpers.it("logs revocation of a visible stream by " .. revoke, function()
			local fixture = load_fixture()
			fixture.engine.perform_check(true)
			deliver(fixture, false)
			helpers.assert_true(fixture.engine.is_visible(), "partial output must actually commit")
			if revoke == "reset" then helpers.assert_true(fixture.engine.reset())
			elseif revoke == "consume" then helpers.assert_not_nil(fixture.engine.consume(1))
			else fixture.engine.perform_check(true) end
			local records = cancellations(fixture)
			helpers.assert_eq(#records, 1, "visible partial output is still an outstanding request")
			helpers.assert_true(records[1].message:find("reason=" .. revoke, 1, true) ~= nil)
			if revoke == "supersede" then helpers.assert_eq(fixture.fetches, 2)
			else helpers.assert_true(not fixture.engine.is_visible()) end
		end)
	end
end)
