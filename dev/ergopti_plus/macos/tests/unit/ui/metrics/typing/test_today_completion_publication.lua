--- tests/unit/ui/metrics/typing/test_today_completion_publication.lua

--- ==============================================================================
--- MODULE: Today Completion Publication Regression
--- DESCRIPTION:
--- Incomplete live slices are shown flagged, never saved, and recover on retry.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.keystats.today_completion_fixture")
local Json = require("json")
local ReadLogs = require("tests.support.ui.metrics.typing.read_completion_logs")

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
		helpers.it("(incomplete-history-partial) full prefetch shows a partial today " .. failure .. " unsaved", function()
			Fixture.with_publication({}, function(control)
				local healthy = control.reader.read_today_split("/fixture/db.sqlite", Fixture.TODAY, Fixture.TODAY,
					{ "Editor" }, nil, Fixture.TODAY)
				helpers.assert_eq(healthy.Editor.c.b.c, 11, "the same native query port succeeds before refusal")
				helpers.assert_eq(#control.errors, 0)
				local logs = ReadLogs.capture()
				control.state.failure = failure
				control.bootstrap()
				helpers.assert_eq(#control.state.saves, 0, "an incomplete today slice is never saved as the snapshot")
				helpers.assert_true(not contains(control.evaluations, '"state":"failed"'))
				local payload = ReadLogs.publication(control.evaluations)
				helpers.assert_true(payload ~= nil, "the partial counts are published")
				helpers.assert_eq(payload.initial_data.incomplete, true)
				helpers.assert_eq(#logs.warnings, 1)
			end)
		end)
		helpers.it("(incomplete-history-partial) range shows a partial today " .. failure .. " then recovers", function()
			Fixture.with_publication({}, function(control)
				control.bootstrap()
				helpers.assert_eq(#control.state.saves, 1)
				helpers.assert_eq(control.state.saves[1].accepted, true)
				control.state.failure = failure
				local partial = control.request(102)
				local partial_raw = partial:match("^window%.receive_range_data%((.*),102%)$")
				helpers.assert_true(partial_raw ~= nil and partial_raw ~= "null", "a partial range is not refused")
				helpers.assert_eq(Json.decode(partial_raw).incomplete, true)
				control.state.failure = nil
				local recovered = control.request(103)
				local raw = recovered:match("^window%.receive_range_data%((.*),103%)$")
				helpers.assert_true(raw ~= nil and raw ~= "null")
				helpers.assert_eq(Json.decode(raw).today.Editor.c.b.c, 11)
				helpers.assert_eq(Json.decode(raw).incomplete, nil)
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
