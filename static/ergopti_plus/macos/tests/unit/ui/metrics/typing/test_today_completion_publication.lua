--- tests/unit/ui/metrics/typing/test_today_completion_publication.lua

--- ==============================================================================
--- MODULE: Today Completion Publication Regression
--- DESCRIPTION:
--- Incomplete live slices refuse fresh snapshots and preserve correlated retry delivery.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.keylogger.today_completion_fixture")
local Json = require("json")

local function contains(evaluations, fragment)
	for _, call in ipairs(evaluations) do
		if call.code:find(fragment, 1, true) then return true end
	end
	return false
end

helpers.describe("today-completion-publication", function()
	helpers.it("(today-completion-publication) healthy full data is actually saved and published fresh", function()
		Fixture.with_publication({}, function(control)
			control.bootstrap()
			helpers.assert_eq(#control.state.saves, 1)
			helpers.assert_eq(control.state.saves[1].accepted, true)
			local payload = Json.decode(control.state.saves[1].payload)
			helpers.assert_eq(payload.initial_data.today.Editor.c.b.c, 11)
			helpers.assert_true(contains(control.evaluations, "window.publishTypingMetricsData("))
			helpers.assert_true(contains(control.evaluations, '"state":"fresh"'))
			helpers.assert_eq(#control.errors, 0)
		end)
	end)
	for _, failure in ipairs({ "rows", "after-row" }) do
		helpers.it("(today-completion-publication) full prefetch refuses today " .. failure, function()
			Fixture.with_publication({}, function(control)
				local healthy = control.reader.read_today_split("/fixture/db.sqlite", Fixture.TODAY, Fixture.TODAY,
					{ "Editor" }, nil, Fixture.TODAY)
				helpers.assert_eq(healthy.Editor.c.b.c, 11, "the same native query port succeeds before refusal")
				helpers.assert_eq(#control.errors, 0)
				control.state.failure = failure
				control.bootstrap()
				helpers.assert_eq(#control.state.saves, 0, "an incomplete today slice cannot replace the accepted snapshot")
				helpers.assert_true(#control.errors > 0)
				helpers.assert_true(contains(control.evaluations, '"state":"failed"'))
				helpers.assert_true(not contains(control.evaluations, "window.publishTypingMetricsData("))
				helpers.assert_true(not contains(control.evaluations, '"state":"fresh"'))
			end)
		end)
		helpers.it("(today-completion-publication) range refuses today " .. failure .. " then correlates recovery", function()
			Fixture.with_publication({}, function(control)
				control.bootstrap()
				helpers.assert_eq(#control.state.saves, 1)
				helpers.assert_eq(control.state.saves[1].accepted, true)
				control.state.failure = failure
				local rejected = control.request(102)
				helpers.assert_eq(rejected, "window.receive_range_data(null,102)")
				helpers.assert_true(#control.errors > 0)
				control.state.failure = nil
				local recovered = control.request(103)
				local raw = recovered:match("^window%.receive_range_data%((.*),103%)$")
				helpers.assert_true(raw ~= nil and raw ~= "null")
				helpers.assert_eq(Json.decode(raw).today.Editor.c.b.c, 11)
				helpers.assert_eq(#control.state.saves, 1, "a range reply does not publish a new full snapshot")
			end)
		end)
	end
	helpers.it("(today-completion-publication) legitimate empty data remains fresh and non-null", function()
		Fixture.with_publication({ empty = true }, function(control)
			control.bootstrap()
			helpers.assert_eq(#control.state.saves, 1)
			helpers.assert_eq(control.state.saves[1].accepted, true)
			helpers.assert_eq(#control.errors, 0)
			local reply = control.request(104)
			local raw = reply:match("^window%.receive_range_data%((.*),104%)$")
			helpers.assert_true(raw ~= nil and raw ~= "null")
			helpers.assert_eq(next(Json.decode(raw).today), nil)
			helpers.assert_true(contains(control.evaluations, '"state":"fresh"'))
		end)
	end)
end)
