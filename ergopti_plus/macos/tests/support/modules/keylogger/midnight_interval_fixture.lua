--- tests/support/modules/keylogger/midnight_interval_fixture.lua

--- ==============================================================================
--- MODULE: Midnight Foreground Interval Fixture
--- DESCRIPTION:
--- Compose the actual tracker and maintenance writer around retryable rollover.
--- Calendar ports distinguish wall labels from elapsed time across DST changes.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}
local BASE_NS = 100000000000000
local MIDNIGHT_EPOCH = 2000000000

--- Copies one exact calendar observation before a native calendar conversion.
--- @param value table Local calendar fields.
--- @return table fields Independent field values.
local function copy(value)
	local out = {}
	for key, item in pairs(value) do out[key] = item end
	return out
end

--- Runs public capture and maintenance with no native sensor activation.
--- @param options table|nil Calendar day controls.
--- @param callback function Receives actual tracker and maintenance controls.
--- @return ... Callback results.
function M.run(options, callback)
	options = options or {}
	return helpers.with_stub_scope({
		"modules.keylogger.context_tracker", "modules.keylogger.watchers", "modules.keylogger.log_manager",
		"adapters.secure_field_detector", "adapters.task_lifecycle", "adapters.timer_scheduler",
		"infra.logger", "infra.timings", "keylogger.private_window", "keylogger.physical_lifecycle_observation",
	}, function()
		local original_date, original_time = os.date, os.time
		local state = { rows = {}, errors = {}, flushes = 0, rollover_calls = 0, rollover_accepted = false,
			name = "Editor", elapsed = -3600 }
		local today = { year = options.year or 2026, month = options.month or 10, day = options.day or 21 }
		local previous = options.previous or { year = 2026, month = 10, day = 20 }
		function state.advance(seconds, wall)
			state.elapsed = seconds
			state.wall = copy(seconds < 0 and previous or today)
			local labels = wall or { hour = math.floor((seconds % 86400) / 3600),
				min = math.floor((seconds % 3600) / 60), sec = seconds % 60, isdst = false }
			for key, value in pairs(labels) do state.wall[key] = value end
		end
		state.advance(-3600)
		os.date = function(format, timestamp)
			if timestamp == nil and format == "*t" then return copy(state.wall) end
			if timestamp == nil and format == "%Y-%m-%d" then
				return string.format("%04d-%02d-%02d", state.wall.year, state.wall.month, state.wall.day)
			end
			return original_date(format, timestamp)
		end
		os.time = function(fields)
			if fields == nil then return MIDNIGHT_EPOCH + state.elapsed end
			assert(fields.year == state.wall.year and fields.month == state.wall.month and fields.day == state.wall.day,
				"Calendar conversion must use the observed local date")
			if fields.hour == 0 and fields.min == 0 and fields.sec == 0 and fields.isdst == nil then
				return MIDNIGHT_EPOCH + (state.elapsed < 0 and -86400 or 0)
			end
			assert(fields.hour == state.wall.hour and fields.min == state.wall.min and fields.sec == state.wall.sec
				and fields.isdst == state.wall.isdst, "Midnight must resolve its own native DST offset")
			return MIDNIGHT_EPOCH + state.elapsed
		end
		local result = table.pack(xpcall(function()
			local logger = helpers.make_logger_stub()
			logger.error = function(_, format, ...) state.errors[#state.errors + 1] = string.format(format, ...) end
			package.loaded["infra.logger"] = logger
			package.loaded["adapters.secure_field_detector"] = {
				refresh = function() end, isSecureField = function() return false end,
				isSecureApp = function() return false end,
			}
			local app = { name = function() return state.name end,
				bundleID = function() return "test." .. state.name end,
				path = function() return "/" .. state.name .. ".app" end,
				pid = function() return state.name == "Editor" and 42 or 43 end }
			local tracker = helpers.load_with_stubs("modules.keylogger.context_tracker", {
				timer = { absoluteTime = function() return BASE_NS + (state.elapsed + 3600) * 1000000000 end },
				application = { watcher = { activated = 1 }, frontmostApplication = function() return app end },
				window = { focusedWindow = function() return nil end },
				axuielement = { observer = { new = function() return nil end } },
				mouse = { absolutePosition = function() return { x = 0, y = 0 } end },
			})
			local function dormant() error("Maintenance must not activate a native timer or task") end
			package.loaded["adapters.task_lifecycle"] = { native = dormant, start = dormant }
			package.loaded["adapters.timer_scheduler"] = { after = dormant, cancel = dormant }
			package.loaded["infra.timings"] = { ms = function() return 1000 end }
			local manager = {
				append_log = function() end,
				flush_buffer = function() state.flushes = state.flushes + 1 end,
				day_rollover = function()
					state.rollover_calls = state.rollover_calls + 1
					return state.rollover_accepted
				end,
				log_app_switch = function(from, to, duration, timestamp)
					state.rows[#state.rows + 1] = { from = from, to = to, duration = duration, timestamp = timestamp }
				end,
			}
			package.loaded["modules.keylogger.log_manager"] = manager
			local watchers = require("modules.keylogger.watchers")
			local core = { is_enabled = true, today_idx = { sentinel = true }, ngram_context = {},
				buffer_events = {}, mouse_distance_px = 0 }
			local function not_paused() return false end
			helpers.assert_eq(tracker.init(core, manager, not_paused), true)
			helpers.assert_eq(watchers.init(core, not_paused), true)
			helpers.assert_eq(tracker.capture_frontmost_app(), true)
			helpers.assert_eq(tracker.get_active_app_snapshot().duration_ms, 0)
			helpers.assert_eq(#state.rows, 0)
			state.tracker, state.core = tracker, core
			function state.maintain(accepted)
				state.rollover_accepted = accepted == true
				watchers.perform_maintenance()
			end
			function state.activate(name)
				state.name = name
				helpers.assert_eq(tracker.capture_frontmost_app(), true)
			end
			function state.duration() return tracker.get_active_app_snapshot().duration_ms end
			return callback(state)
		end, debug.traceback))
		os.date, os.time = original_date, original_time
		if not result[1] then error(result[2], 0) end
		return table.unpack(result, 2, result.n)
	end)
end

return M
