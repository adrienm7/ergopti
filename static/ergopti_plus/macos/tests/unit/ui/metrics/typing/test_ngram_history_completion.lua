--- tests/unit/ui/metrics/typing/test_ngram_history_completion.lua

--- ==============================================================================
--- MODULE: Typing N-gram History Completion Regression
--- DESCRIPTION:
--- Successful fingerprints never certify incomplete cold reads or extensions;
--- an incomplete extension is shown flagged but leaves the accepted history.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.keylogger.ngram_completion_fixture")

local function project(state, reader, projection, today)
	local payload, complete = projection.session(reader, "/fixture/db.sqlite", today, state.pacer)
		.range(Fixture.PAST, today, { "Editor" })
	return require("json").decode(payload), complete
end

local function count(payload, token)
	local item = payload.historical.c[token]
	return item and item.c or 0
end

helpers.describe("ngram-history-completion", function()
	for _, failure in ipairs({ "rows", "after-row", "bounds", "open" }) do
		helpers.it("(ngram-history-completion) retries cold " .. failure .. " without a source mutation", function()
			Fixture.run({}, function(state, reader, projection)
				local before = reader.fingerprint("/fixture/db.sqlite", Fixture.NEXT, state.pacer)
				if failure == "open" then state.refuse_open_at = state.opens + 2 else state.failure = failure end
				local _, complete = project(state, reader, projection, Fixture.TODAY)
				helpers.assert_eq(complete, false)
				helpers.assert_true(#state.errors > 0)
				helpers.assert_true(#state.warnings > 0, "the incomplete history is not a silent fallback")
				state.failure, state.refuse_open_at = nil, nil
				helpers.assert_eq(reader.fingerprint("/fixture/db.sqlite", Fixture.NEXT, state.pacer), before)
				local previous = #state.histories
				local recovered, accepted = project(state, reader, projection, Fixture.TODAY)
				helpers.assert_eq(accepted, true)
				helpers.assert_eq(#state.histories, previous + 1, "a failed read is retried despite the unchanged fingerprint")
				helpers.assert_eq(state.histories[#state.histories].first, Fixture.PAST)
				helpers.assert_eq(count(recovered, "a"), 7)
				helpers.assert_eq(count(recovered, "b"), 11)
			end)
		end)
		helpers.it("(ngram-history-completion) retains the accepted watermark after " .. failure .. " extension", function()
			Fixture.run({}, function(state, reader, projection)
				local prior, accepted = project(state, reader, projection, Fixture.NEXT)
				helpers.assert_eq(accepted, true)
				helpers.assert_eq(count(prior, "a"), 7)
				helpers.assert_eq(count(prior, "b"), 0)
				if failure == "open" then state.refuse_open_at = state.opens + 3 else state.failure = failure end
				local failed, complete = project(state, reader, projection, Fixture.TODAY)
				helpers.assert_eq(complete, false)
				helpers.assert_eq(failed.incomplete, true, "a partial extension is flagged for the page")
				helpers.assert_eq(count(failed, "a"), 7, "accepted history is shown with the partial days")
				helpers.assert_true(count(failed, "b") <= 11, "a partial extension never invents counts")
				state.failure, state.refuse_open_at = nil, nil
				local previous = #state.histories
				local recovered, final_complete = project(state, reader, projection, Fixture.TODAY)
				helpers.assert_eq(final_complete, true)
				helpers.assert_eq(#state.histories, previous + 1)
				helpers.assert_eq(state.histories[#state.histories].first, Fixture.NEXT,
					"the accepted old watermark survives so only its unacknowledged extension is retried")
				helpers.assert_eq(count(recovered, "a"), 7, "retry cannot double an already accepted day")
				helpers.assert_eq(count(recovered, "b"), 11)
			end)
		end)
	end
	helpers.it("(ngram-history-completion) reuses a successful empty history", function()
		Fixture.run({ empty = true }, function(state, reader, projection)
			local _, complete = project(state, reader, projection, Fixture.TODAY)
			helpers.assert_eq(complete, true)
			local previous = #state.histories
			local _, reused = project(state, reader, projection, Fixture.TODAY)
			helpers.assert_eq(reused, true)
			helpers.assert_eq(#state.histories, previous)
			helpers.assert_eq(#state.errors, 0)
		end)
	end)
	helpers.it("(ngram-history-completion) today's-only request needs no historical read", function()
		Fixture.run({}, function(state, reader, projection)
			local payload, complete = projection.session(reader, "/fixture/db.sqlite", Fixture.TODAY, state.pacer)
				.range(Fixture.TODAY, Fixture.TODAY, { "Editor" })
			helpers.assert_eq(complete, true, "a complete today-only request requires no historical read")
			helpers.assert_eq(#state.histories, 0)
			helpers.assert_true(type(payload) == "string")
		end)
	end)
end)
