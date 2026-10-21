--- tests/unit/ui/metrics/typing/test_ngram_completion_publication.lua

--- ==============================================================================
--- MODULE: Typing N-gram Completion Publication Regression
--- DESCRIPTION:
--- Failed historical reads use existing job-failure delivery without fresh saves.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.keylogger.ngram_completion_fixture")
local with_delivery = require("tests.support.typing_delivery_fixture")

--- Installs only native SQL and JSON ports after the real UI is constructed.
--- @param callback function Receives the real dashboard and public request controls.
local function with_sql_delivery(callback)
	return helpers.with_fresh_modules({ "hs.sqlite3" }, function()
		return with_delivery(function(dashboard, context, timers, errors, successes, evaluations)
			local state = Fixture.new({})
			local Json = require("json")
			package.loaded["hs.json"].encode = Json.encode
			package.loaded["hs.json"].decode = Json.decode
			package.loaded["hs.fs"].attributes = function(path)
				if path == "/fixture/db.sqlite" then return { mode = "file" } end
			end
			package.loaded["hs.sqlite3"] = state.sqlite
			package.loaded["modules.keylogger.sqlite_reader"] = nil
			local reader = require("modules.keylogger.sqlite_reader")
			package.loaded["modules.keylogger.log_manager"].get_sqlite_path = function() return "/fixture/db.sqlite" end
			dashboard._app_icon_cache.Editor = false
			local Snapshot = package.loaded["ui.metrics_typing.snapshot"]
			local original_save = Snapshot.save
			state.saves = 0
			Snapshot.save = function(...)
				state.saves = state.saves + 1
				return original_save(...)
			end
			local function apply_pending()
				local index = 1
				while index <= #evaluations do
					local call = evaluations[index]
					if not call.received then
						call.received = true
						call.done(call.code:sub(1, 7) == "typeof " and "function" or true, nil)
					end
					index = index + 1
				end
			end
			local function request(id)
				local index = #evaluations
				context.poll()
				helpers.assert_eq(#evaluations, index + 1)
				evaluations[#evaluations].received = true
				evaluations[#evaluations].done(Json.encode({ start_date = Fixture.PAST, end_date = Fixture.TODAY,
					apps = { "Editor" }, request_id = id }), nil)
				evaluations[#evaluations].received = true
				evaluations[#evaluations].done(true, nil)
				context.settle_jobs()
				local delivered = evaluations[#evaluations]
				delivered.received = true
				delivered.done(true, nil)
				return delivered.code
			end
			callback(dashboard, context, timers, errors, successes, evaluations, state, reader, apply_pending, request)
		end)
	end)
end

helpers.describe("ngram-completion-publication", function()
	helpers.it("(ngram-completion-publication) a healthy history can save and publish a fresh snapshot", function()
		with_sql_delivery(function(_, context, timers, _, _, evaluations, state, _, apply_pending)
			timers[1]()
			context.settle_jobs()
			apply_pending()
			helpers.assert_eq(state.saves, 1)
			local published = false
			for _, call in ipairs(evaluations) do
				if call.code:find("window.publishTypingMetricsData(", 1, true) == 1 then published = true end
			end
			helpers.assert_true(published, "the control reaches the actual public publication path")
		end)
	end)
	helpers.it("(ngram-completion-publication) refuses a fresh snapshot after a failed historical prefetch", function()
		with_sql_delivery(function(_, context, timers, errors, _, evaluations, state, _, apply_pending)
			state.failure = "rows"
			timers[1]()
			context.settle_jobs()
			apply_pending()
			helpers.assert_eq(state.saves, 0, "an incomplete history cannot replace the persisted accepted snapshot")
			helpers.assert_true(#errors > 0)
			local failed = false
			for _, call in ipairs(evaluations) do
				helpers.assert_true(call.code:find("window.publishTypingMetricsData(", 1, true) ~= 1)
				if call.code:find('"state":"failed"', 1, true) then failed = true end
			end
			helpers.assert_true(failed, "the existing failed freshness state is actually delivered")
		end)
	end)
	helpers.it("(ngram-completion-publication) correlates a failed range then recovers without a source mutation", function()
		with_sql_delivery(function(_, _, _, errors, _, _, state, _, _, request)
			state.failure = "rows"
			local failed = request(12)
			helpers.assert_eq(failed, "window.receive_range_data(null,12)")
			helpers.assert_true(#errors > 0)
			state.failure = nil
			local recovered = request(13)
			local raw = recovered:match("^window%.receive_range_data%((.*),13%)$")
			helpers.assert_true(raw ~= nil and raw ~= "null")
			local payload = require("json").decode(raw)
			helpers.assert_eq(payload.historical.c.a.c, 7)
			helpers.assert_eq(payload.historical.c.b.c, 11)
		end)
	end)
end)
