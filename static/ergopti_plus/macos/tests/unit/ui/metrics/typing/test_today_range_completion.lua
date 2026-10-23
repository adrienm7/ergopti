--- tests/unit/ui/metrics/typing/test_today_range_completion.lua

--- ==============================================================================
--- MODULE: Today Range Completion Regression
--- DESCRIPTION:
--- Compose both slice receipts without discarding accepted historical cache entries.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.keystats.today_completion_fixture")

local function range(state, reader, projection, first, last)
	local raw, complete = projection.session(reader, "/fixture/db.sqlite", Fixture.TODAY, state.pacer)
		.range(first, last, { "Editor" })
	return require("json").decode(raw), complete
end

helpers.describe("today-range-completion", function()
	for _, failure in ipairs({ "rows", "after-row", "open" }) do
		helpers.it("(today-range-completion) today-only refuses " .. failure .. " without reading history", function()
			Fixture.run({}, function(state, reader, projection)
				if failure == "open" then state.refuse_open_at = 1 else state.failure = failure end
				local _, complete = range(state, reader, projection, Fixture.TODAY, Fixture.TODAY)
				helpers.assert_eq(complete, false)
				helpers.assert_eq(#state.histories, 0)
				helpers.assert_true(#state.errors > 0)
				state.failure, state.refuse_open_at = nil, nil
				local recovered, accepted = range(state, reader, projection, Fixture.TODAY, Fixture.TODAY)
				helpers.assert_eq(accepted, true)
				helpers.assert_eq(recovered.today.Editor.c.b.c, 11)
				helpers.assert_eq(#state.histories, 0)
			end)
		end)
	end
	helpers.it("(today-range-completion) historical-only excludes a failing today source", function()
		Fixture.run({ failure = "rows" }, function(state, reader, projection)
			local payload, complete = range(state, reader, projection, Fixture.PAST, Fixture.NEXT)
			helpers.assert_eq(complete, true)
			helpers.assert_eq(payload.historical.c.a.c, 7)
			helpers.assert_eq(payload.historical.c.b.c, 11)
			helpers.assert_eq(next(payload.today), nil)
			helpers.assert_eq(#state.errors, 0)
			for _, query in ipairs(state.reads) do helpers.assert_true(query.day ~= Fixture.TODAY) end
		end)
	end)
	helpers.it("(today-range-completion) a healthy today cannot certify failed history", function()
		Fixture.run({ failure = "rows", today_only = false, history_only = true }, function(state, reader, projection)
			local payload, complete = range(state, reader, projection, Fixture.PAST, Fixture.TODAY)
			helpers.assert_eq(complete, false)
			helpers.assert_eq(payload.today.Editor.c.b.c, 11)
			helpers.assert_true(#state.errors > 0)
		end)
	end)
	for _, failure in ipairs({ "rows", "after-row" }) do
		helpers.it("(today-range-completion) preserves accepted history across today " .. failure, function()
			Fixture.run({}, function(state, reader, projection)
				local healthy, complete = range(state, reader, projection, Fixture.PAST, Fixture.TODAY)
				helpers.assert_eq(complete, true)
				helpers.assert_eq(healthy.historical.c.a.c, 7)
				local previous = #state.histories
				state.failure = failure
				local partial, refused = range(state, reader, projection, Fixture.PAST, Fixture.TODAY)
				helpers.assert_eq(refused, false)
				helpers.assert_eq(partial.historical.c.a.c, 7)
				helpers.assert_eq(partial.historical.c.b.c, 11)
				helpers.assert_eq(#state.histories, previous)
				state.failure = nil
				local recovered, accepted = range(state, reader, projection, Fixture.PAST, Fixture.TODAY)
				helpers.assert_eq(accepted, true)
				helpers.assert_eq(recovered.today.Editor.c.b.c, 11)
				helpers.assert_eq(recovered.historical.c.a.c, 7)
				helpers.assert_eq(#state.histories, previous, "today retry does not reproject or double accepted history")
			end)
		end)
	end
	helpers.it("(today-range-completion) an empty range has two successful slice receipts", function()
		Fixture.run({ empty = true }, function(state, reader, projection)
			local payload, complete = range(state, reader, projection, Fixture.PAST, Fixture.TODAY)
			helpers.assert_eq(complete, true)
			helpers.assert_eq(next(payload.today), nil)
			helpers.assert_eq(next(payload.historical.c), nil)
			helpers.assert_eq(#state.errors, 0)
		end)
	end)
	for _, failure in ipairs({ "healthy", "history", "today", "today-open" }) do
		helpers.it("(today-range-completion) legacy split wrapper combines " .. failure .. " receipts", function()
			local options = failure == "history" and { today_only = false, history_only = true } or {}
			Fixture.run(options, function(state, reader)
				if failure == "today-open" then state.refuse_open_at = 2
				elseif failure ~= "healthy" then state.failure = "rows" end
				local payload, complete = reader.read_range_split_today("/fixture/db.sqlite", Fixture.PAST, Fixture.TODAY,
					{ "Editor" }, state.pacer)
				helpers.assert_eq(complete, failure == "healthy")
				if failure ~= "history" then helpers.assert_eq(payload.historical.c.a.c, 7) end
				if failure == "healthy" or failure == "history" then helpers.assert_eq(payload.today.Editor.c.b.c, 11) end
				helpers.assert_eq(#state.errors == 0, failure == "healthy")
			end)
		end)
	end
	helpers.it("(today-range-completion) a forced assertion restores the exact calendar function", function()
		local previous = os.date
		local ok, detail = pcall(function()
			Fixture.run({}, function() error("controlled today fixture assertion") end)
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(detail):find("controlled today fixture assertion", 1, true) ~= nil)
		helpers.assert_true(rawequal(os.date, previous))
	end)
end)
