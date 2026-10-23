--- tests/support/modules/keystats/today_completion_fixture.lua

--- ==============================================================================
--- MODULE: Today Read Completion Fixture
--- DESCRIPTION:
--- Compose actual today reads and public deliveries around native SQL refusals.
--- ==============================================================================

local helpers = require("tests.helpers")
local Completion = require("tests.support.modules.keystats.ngram_completion_fixture")
local with_delivery = require("tests.support.typing_delivery_fixture")
local M = {}

M.PAST, M.NEXT, M.TODAY, M.FAMILIES = Completion.PAST, Completion.NEXT, Completion.TODAY, Completion.FAMILIES

--- Fixes only the captured current calendar day and restores the exact native function.
--- @param callback function Complete calendar-scoped operation.
--- @return ... Callback results.
function M.with_calendar(callback)
	local previous = os.date
	os.date = function(format, timestamp)
		if format == "%Y-%m-%d" and timestamp == nil then return M.TODAY end
		return previous(format, timestamp)
	end
	local result = table.pack(xpcall(callback, debug.traceback))
	os.date = previous
	if not result[1] then error(result[2], 0) end
	return table.unpack(result, 2, result.n)
end

--- Runs the real reader and projection with today populated separately from history.
--- @param options table|nil Native query controls.
--- @param callback function Receives state, actual reader and actual projection.
--- @return ... Callback results.
function M.run(options, callback)
	local controls = { today = true, today_only = true }
	for key, value in pairs(options or {}) do controls[key] = value end
	return M.with_calendar(function() return Completion.run(controls, callback) end)
end

--- Returns today's independently seeded first token for one family.
--- @param family table Family descriptor from the shared n-gram fixture.
--- @return string key
function M.key(family)
	return family.code == "kc" and "16" or "b"
end

--- Runs actual dashboard jobs, snapshot saves and correlated range publications.
--- @param options table Native query controls, including empty-source admission.
--- @param callback function Receives public controls and query observations.
--- @return ... Callback results.
function M.with_publication(options, callback)
	return M.with_calendar(function()
		return helpers.with_fresh_modules({ "hs.sqlite3" }, function()
			return with_delivery(function(dashboard, context, timers, errors, _, evaluations)
				local controls = { today = true, today_only = true }
				for key, value in pairs(options) do controls[key] = value end
				local state = Completion.new(controls)
				local Json = require("json")
				package.loaded["hs.json"].encode, package.loaded["hs.json"].decode = Json.encode, Json.decode
				package.loaded["hs.fs"].attributes = function(path)
					if path == "/fixture/db.sqlite" then return { mode = "file" } end
				end
				package.loaded["hs.sqlite3"] = state.sqlite
				package.loaded["modules.keystats.sqlite_reader"] = nil
				local reader = require("modules.keystats.sqlite_reader")
				package.loaded["modules.keystats.log_manager"].get_sqlite_path = function() return "/fixture/db.sqlite" end
				dashboard._app_icon_cache.Editor = false
				local Snapshot = package.loaded["ui.metrics_typing.snapshot"]
				local actual_save = Snapshot.save
				state.saves = {}
				Snapshot.save = function(payload, generated_at)
					local accepted = actual_save(payload, generated_at)
					state.saves[#state.saves + 1] = { payload = payload, accepted = accepted }
					return accepted
				end
				local control = { state = state, reader = reader, dashboard = dashboard,
					errors = errors, evaluations = evaluations }
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
				function control.bootstrap()
					timers[1](); context.settle_jobs(); apply_pending()
				end
				function control.request(id, first, last)
					local previous = #evaluations
					context.poll()
					helpers.assert_eq(#evaluations, previous + 1)
					evaluations[#evaluations].received = true
					evaluations[#evaluations].done(Json.encode({ start_date = first or M.TODAY,
						end_date = last or M.TODAY, apps = { "Editor" }, request_id = id }), nil)
					evaluations[#evaluations].received = true
					evaluations[#evaluations].done(true, nil)
					context.settle_jobs()
					local delivered = evaluations[#evaluations]
					delivered.received = true; delivered.done(true, nil)
					return delivered.code
				end
				return callback(control)
			end)
		end)
	end)
end

return M
