--- modules/keystats/calendar.lua
--- ==============================================================================
--- MODULE: Metrics Capture Calendar
--- DESCRIPTION:
--- Captures local calendar identity with the elapsed-time clock, and retains
--- dated application accumulators until their exact committed source retires.
--- ==============================================================================

local M = {}
local Monotonic = require("infra.monotonic")
local TableUtil = require("table_util")
local StorageOwned = require("storage_owned")
local Logger = require("logger.shim")
local MS_PER_SECOND = 1000
local US_PER_MS = MS_PER_SECOND
local LOG = "modules.keystats.calendar"
local coarse_reported = false

--- Reads epoch milliseconds from the native runtime, independently of timezone.
--- @return number wall_ms
local function wall_ms()
	local available, uv = pcall(require, "luv")
	if available and type(uv.gettimeofday) == "function" then
		local seconds, microseconds = uv.gettimeofday()
		assert(type(seconds) == "number" and type(microseconds) == "number", "Native calendar clock refused")
		return seconds * MS_PER_SECOND + microseconds / US_PER_MS
	end
	-- Match the daemon's explicit coarse-clock mode when native timing is absent.
	if not coarse_reported then
		coarse_reported = true
		Logger.warn(LOG, "Native calendar clock unavailable; metrics capture has one-second resolution.")
	end
	return os.time() * MS_PER_SECOND
end

--- Captures a single calendar observation for one producer invocation.
--- @return table { wall_ms, mono_ms, date, ts }.
function M.capture()
	local wall, mono = wall_ms(), math.floor(Monotonic.now_ms())
	return {
		wall_ms = wall, mono_ms = mono,
		date = os.date("%Y-%m-%d", math.floor(wall / MS_PER_SECOND)),
		ts = os.date("!%Y-%m-%d %H:%M:%S", math.floor(wall / MS_PER_SECOND)),
	}
end

--- Returns the next local calendar midnight, including short and long DST days.
--- @param epoch_ms number Instant within the day being closed.
--- @return number Epoch milliseconds at the following local midnight.
function M.next_midnight(epoch_ms)
	local date = os.date("*t", math.floor(epoch_ms / MS_PER_SECOND))
	return assert(os.time({ year = date.year, month = date.month, day = date.day + 1,
		hour = 0, min = 0, sec = 0 })) * MS_PER_SECOND
end

--- Visits local day cuts with elapsed-time coordinates, conserving monotonic time.
--- @param previous table Earlier capture observation.
--- @param current table Current capture observation.
--- @param visit function Receives mono_ms, previous_date, next_date, wall_ms.
function M.boundaries(previous, current, visit)
	if previous.date == current.date then return end
	if current.wall_ms < previous.wall_ms then
		visit(current.mono_ms, previous.date, current.date, current.wall_ms)
		return
	end
	local boundary = M.next_midnight(previous.wall_ms)
	local date = previous.date
	while boundary <= current.wall_ms do
		local next_date = os.date("%Y-%m-%d", math.floor(boundary / MS_PER_SECOND))
		local at = math.max(previous.mono_ms,
			math.min(current.mono_ms, math.floor(current.mono_ms - (current.wall_ms - boundary))))
		visit(at, date, next_date, boundary)
		date = next_date
		boundary = M.next_midnight(boundary)
	end
	assert(date == current.date, "Metrics calendar changed without a native midnight")
end

--- Creates dated storage using the collector's one canonical app constructor.
--- @param new_app function Creates an application accumulator.
--- @return table store
function M.new(new_app)
	assert(type(new_app) == "function", "Missing metrics app constructor")
	local days = {}
	local store = {}

	--- Returns one application's mutable capture state for its actual local day.
	function store.app(date, app, timestamp)
		days[date] = days[date] or {}
		local value = days[date][app]
		if value == nil then value = new_app(timestamp); days[date][app] = value end
		return value
	end

	--- Snapshots projected values together with their exact private source owners.
	function store.snapshot(project)
		local snapshot = { values = {}, owners = {} }
		for date, apps in pairs(days) do
			snapshot.values[date], snapshot.owners[date] = {}, {}
			for app, value in pairs(apps) do
				snapshot.values[date][app] = TableUtil.deep_copy(project(value, date, app))
				snapshot.owners[date][app] = value
			end
		end
		return snapshot
	end

	--- Retires only unchanged closed-day sources covered by the exact COMMIT.
	--- @return table Dates whose complete accumulator was retired.
	function store.prune(snapshot, project, today)
		local retired = {}
		for date, apps in pairs(snapshot.values) do
			local current_day, unchanged = days[date], true
			if date ~= today and current_day then
				for app, current in pairs(current_day) do
					if not rawequal(current, snapshot.owners[date][app])
						or not StorageOwned.equal(project(current, date, app), apps[app]) then
						unchanged = false
						break
					end
				end
				if unchanged then days[date] = nil; retired[#retired + 1] = date end
			end
		end
		return retired
	end

	return store
end

return M
