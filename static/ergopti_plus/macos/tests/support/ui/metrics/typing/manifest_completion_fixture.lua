--- tests/support/ui/metrics/typing/manifest_completion_fixture.lua

--- ==============================================================================
--- MODULE: Typing Manifest Completion Fixture
--- DESCRIPTION:
--- Compose actual manifest reads and dashboard jobs around independent title SQL refusals.
--- ==============================================================================

local helpers = require("tests.helpers")
local Completion = require("tests.support.modules.keystats.ngram_completion_fixture")
local Today = require("tests.support.modules.keystats.today_completion_fixture")
local with_delivery = require("tests.support.typing_delivery_fixture")
local Json = require("json")
local M = {}

M.PAST, M.NEXT, M.TODAY = Completion.PAST, Completion.NEXT, Completion.TODAY
local DATES = { M.PAST, M.NEXT, M.TODAY }

--- Reads one independently populated title counter.
--- @param manifest table Date/app manifest.
--- @param day string Requested date.
--- @return number count
function M.title(manifest, day)
	local cell = manifest[day] and manifest[day].Editor
	return cell and cell.win_titles.Document and cell.win_titles.Document.c or 0
end

--- Decorates native SQL statements without replacing reader or projection results.
--- @param state table Existing n-gram fixture state.
--- @param options table Empty-source controls.
local function install_titles(state, options)
	state.manifest_receipts = {}
	local original_open = state.sqlite.open
	state.sqlite.open = function(...)
		local db, err = original_open(...)
		if not db then return db, err end
		local original_rows = db.nrows
		function db:nrows(sql)
			if sql:match("FROM ([%w_]+)") ~= "agg_app_day_titles" then return original_rows(self, sql) end
			local fingerprint = sql:find("COUNT(*) AS n", 1, true) ~= nil
			local bounds = sql:find("SELECT (SELECT MIN(date)", 1, true) ~= nil
			local first, last = sql:match("date >= '([%d%-]+)'"), sql:match("date <= '([%d%-]+)'")
			local rows = {}
			if fingerprint then
				local total = { n = 0, s2 = 0, s3 = 0 }
				if not options.empty then
					for _, day in ipairs(DATES) do
						if not last or day <= last then total.n, total.s2, total.s3 = total.n + 1, total.s2 + 3, total.s3 + 300 end
					end
				end
				rows = { total }
			elseif bounds then
				if state.manifest_failure == "bounds" then error("controlled SQLITE_BUSY title bounds refusal") end
				if not options.empty then rows = { { lo = M.PAST, hi = M.TODAY } } end
			else
				if state.manifest_failure == "rows" then error("controlled SQLITE_BUSY title row refusal") end
				if not options.empty then
					for _, day in ipairs(DATES) do
						if (not first or day >= first) and (not last or day <= last) then
							rows[#rows + 1] = { date = day, app = "Editor", title = "Document", c = 3, ms = 300 }
						end
					end
				end
			end
			local index = 0
			return function()
				if not fingerprint and not bounds and state.manifest_failure == "after-row" and index == 1 then
					error("controlled SQLITE_BUSY title refusal after row")
				end
				index = index + 1
				return rows[index]
			end
		end
		return db
	end
end

--- Records the actual reader receipt while preserving its complete return tuple.
--- @param state table Query controls.
--- @param reader table Actual SQLite reader.
local function observe_manifest(state, reader)
	local original = reader.read_manifest
	reader.read_manifest = function(...)
		local result = table.pack(original(...))
		state.manifest_receipts[#state.manifest_receipts + 1] = { complete = result[2], data = result[1] }
		return table.unpack(result, 1, result.n)
	end
end

--- Arms a real manifest connection or title-statement refusal for the next session.
--- @param state table Query controls.
--- @param failure string|nil Failure mode, or nil for recovery.
function M.arm(state, failure)
	state.manifest_failure, state.refuse_open_at = nil, nil
	if failure == "open" then state.refuse_open_at = state.opens + 2
	else state.manifest_failure = failure end
end

--- Runs actual reader/projection sessions within an exact calendar/module scope.
--- @param options table Empty-source controls.
--- @param callback function Receives native state, actual Reader and actual Projection.
--- @return ... Callback results.
function M.run(options, callback)
	return Today.with_calendar(function()
		local controls = { today = true }
		for key, value in pairs(options) do controls[key] = value end
		return Completion.run(controls, function(state, reader, projection)
			install_titles(state, controls)
			observe_manifest(state, reader)
			return callback(state, reader, projection)
		end)
	end)
end

--- Runs public full/live publication and reopen around actual paced jobs.
--- @param options table Empty-source controls.
--- @param callback function Receives publication controls.
--- @return ... Callback results.
function M.with_publication(options, callback)
	return Today.with_calendar(function()
		return helpers.with_fresh_modules({ "hs.sqlite3" }, function()
			return with_delivery(function(dashboard, context, timers, errors, _, evaluations)
				local controls = { today = true }
				for key, value in pairs(options) do controls[key] = value end
				local state = Completion.new(controls)
				install_titles(state, controls)
				package.loaded["hs.json"].encode, package.loaded["hs.json"].decode = Json.encode, Json.decode
				package.loaded["hs.fs"].attributes = function(path)
					if path == "/fixture/db.sqlite" then return { mode = "file" } end
				end
				package.loaded["hs.sqlite3"] = state.sqlite
				package.loaded["modules.keystats.sqlite_reader"] = nil
				local reader = require("modules.keystats.sqlite_reader")
				observe_manifest(state, reader)
				package.loaded["modules.keystats.log_manager"].get_sqlite_path = function() return "/fixture/db.sqlite" end
				dashboard._app_icon_cache.Editor = false
				state.saves, state.disk_files = {}, {}
				local Snapshot = package.loaded["ui.metrics_typing.snapshot"]
				local original_save = Snapshot.save
				local filesystem = package.loaded["adapters.file_system"]
				filesystem.read_with_status = function(path)
					local content = state.disk_files[path]
					return content, content and "ok" or "absent"
				end
				io.open = function(path, mode)
					assert(path == Snapshot.PATH .. ".partial" and mode == "w")
					local pending = ""
					local file = {}
					function file:write(...)
						pending = pending .. table.concat({ ... })
						return self
					end
					function file:close() state.disk_files[path] = pending; return true end
					return file
				end
				os.rename = function(from, to)
					assert(from == Snapshot.PATH .. ".partial" and to == Snapshot.PATH)
					state.disk_files[to], state.disk_files[from] = assert(state.disk_files[from]), nil
					return true
				end
				Snapshot.save = function(payload, generated_at)
					local accepted = original_save(payload, generated_at)
					state.saves[#state.saves + 1] = { payload = payload, accepted = accepted }
					return accepted
				end
				local builder = package.loaded["ui.ui_builder"]
				local original_show = builder.show_webview
				builder.show_webview = function(...)
					local fresh = setmetatable({}, { __index = original_show(...) })
					context.webview = fresh
					return fresh
				end
				local control = { state = state, reader = reader, dashboard = dashboard, errors = errors,
					evaluations = evaluations, publications = {}, snapshot_path = Snapshot.PATH }
				local function flush()
					local index = 1
					while index <= #evaluations do
						local call = evaluations[index]
						if not call.received then
							call.received = true
							local arguments = call.code:match("^window%.publishTypingMetricsData%((.*)%)%;$")
							if arguments then
								local values = Json.decode("[" .. arguments .. "]")
								control.publications[#control.publications + 1] = { payload = values[1], metadata = values[2] }
							end
							call.done(call.code:sub(1, 7) == "typeof " and "function" or true, nil)
						end
						index = index + 1
					end
				end
				local next_timer = 1
				local function drain()
					flush()
					local turns = 0
					while next_timer <= #timers do
						local run = timers[next_timer]
						next_timer = next_timer + 1
						local handle
						for index = 1, 64 do
							local name, value = debug.getupvalue(run, index)
							if name == "handle" then handle = value; break end
							if not name then break end
						end
						assert(handle, "A real fixture timer owner is required")
						if handle.timer ~= nil then run(); flush() end
						turns = turns + 1
						assert(turns < 10000, "Bounded timer census exceeded")
					end
					assert(dashboard._job == nil, "Projection job must retire before inspection")
				end
				control.bootstrap = drain
				function control.reopen()
					helpers.assert_eq(dashboard.close(), true)
					helpers.assert_eq(dashboard.show(), true)
					drain()
				end
				function control.live()
					helpers.assert_eq(dashboard.push_live_update(), true)
					drain()
				end
				local result = table.pack(xpcall(function() return callback(control) end, debug.traceback))
				local closed, close_error = pcall(dashboard.close)
				if not result[1] then error(result[2], 0) end
				if not closed then error(close_error, 0) end
				return table.unpack(result, 2, result.n)
			end)
		end)
	end)
end

return M
