--- _shared/lua/keystats/local_time.lua

--- ==============================================================================
--- MODULE: Metrics Row Time — UTC Instant and Recorded Offset
--- DESCRIPTION:
--- A raw metrics row stores its instant in UTC (`ts`) and the local UTC offset
--- in force when it was recorded (`utc_offset_min`), on every OS (maintainer
--- decision KMD-1 of 11 November 2026). Hour-of-day slots, night wakes and the
--- day of a row are read in the local time the user lived: `ts` plus that
--- offset. A row recorded before the column existed has none: a Linux row then
--- held UTC and is read with the reading device's current offset (noted by the
--- caller), a macOS or Windows row held local time already.
---
--- FEATURES & RATIONALE:
--- 1. Calendar arithmetic only: the offset of an instant is the distance
---    between its local and its UTC calendar fields, so no os.time() reading of
---    a broken-down time can apply the wrong daylight-saving flag.
--- 2. A timestamp keeps its fractional seconds as written (macOS and Windows
---    write milliseconds, Linux whole seconds), so a converted value sorts and
---    compares like the original.
--- 3. Replayed by _shared/tests/corpus/keystats/local_time_vectors.json.
--- ==============================================================================

local M = {}

-- The widest offset a row may carry, in minutes (ISO 8601 allows +-18:00)
M.MAX_OFFSET_MIN = 1080

local TIMESTAMP = "^(%d%d%d%d)%-(%d%d)%-(%d%d)[ T](%d%d):(%d%d):(%d%d)(.*)$"
local SECONDS_PER_DAY = 86400




-- ===============================
-- ===============================
-- ======= 1/ Calendar ===========
-- ===============================
-- ===============================

--- Days from 1970-01-01 to a civil date (proleptic Gregorian).
--- @param year integer
--- @param month integer 1 to 12.
--- @param day integer 1 to 31.
--- @return integer days
local function days_from_civil(year, month, day)
	local floor = math.floor
	year = month <= 2 and year - 1 or year
	local era = floor((year >= 0 and year or year - 399) / 400)
	local yoe = year - era * 400
	local doy = floor((153 * (month + (month > 2 and -3 or 9)) + 2) / 5) + day - 1
	local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

--- Splits a "YYYY-MM-DD HH:MM:SS[.fff]" timestamp.
--- @param ts string
--- @return table|nil fields { year, month, day, hour, min, sec, fraction }
local function split(ts)
	if type(ts) ~= "string" then return nil end
	local year, month, day, hour, min, sec, fraction = ts:match(TIMESTAMP)
	if not year then return nil end
	return { year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = tonumber(hour),
		min = tonumber(min), sec = tonumber(sec), fraction = fraction }
end

--- The UTC epoch of a timestamp read as UTC, whole seconds.
--- @param fields table split() output.
--- @return integer epoch
local function utc_epoch(fields)
	return days_from_civil(fields.year, fields.month, fields.day) * SECONDS_PER_DAY
		+ fields.hour * 3600 + fields.min * 60 + fields.sec
end

--- Formats a UTC epoch as "YYYY-MM-DD HH:MM:SS" followed by a fraction.
--- @param epoch integer
--- @param fraction string The original fractional part (".mmm" or "").
--- @return string
local function format(epoch, fraction)
	return os.date("!%Y-%m-%d %H:%M:%S", epoch) .. fraction
end




-- ===============================
-- ===============================
-- ======= 2/ Public API =========
-- ===============================
-- ===============================

--- The local UTC offset, in minutes, in force at an instant on this device.
--- @param epoch number Seconds since 1970 (UTC).
--- @return integer offset East of UTC is positive.
function M.offset_at(epoch)
	assert(type(epoch) == "number", "an instant needs its epoch")
	local seconds = math.floor(epoch)
	local here, utc = os.date("*t", seconds), os.date("!*t", seconds)
	local days = days_from_civil(here.year, here.month, here.day) - days_from_civil(utc.year, utc.month, utc.day)
	return days * 1440 + (here.hour - utc.hour) * 60 + (here.min - utc.min)
end

--- Whether a value is a recordable offset.
--- @param offset any
--- @return boolean
function M.valid_offset(offset)
	return type(offset) == "number" and offset % 1 == 0 and math.abs(offset) <= M.MAX_OFFSET_MIN
end

--- The offset of a UTC timestamp's instant on this device: what a writer
--- stores beside a row whose `ts` is already UTC (Linux).
--- @param ts string UTC "YYYY-MM-DD HH:MM:SS[.fff]".
--- @return integer offset
function M.offset_of_utc(ts)
	local fields = split(ts)
	assert(fields, "not a metrics timestamp: " .. tostring(ts))
	return M.offset_at(utc_epoch(fields))
end

--- A local timestamp as its UTC instant and the offset in force then: what a
--- writer stores for a row stamped in local time (macOS). In the repeated hour
--- of a daylight-saving fall-back the local reading is ambiguous and the
--- system's choice is kept.
--- @param ts string Local "YYYY-MM-DD HH:MM:SS[.fff]".
--- @return string utc_ts, integer offset
function M.from_local(ts)
	local fields = split(ts)
	assert(fields, "not a metrics timestamp: " .. tostring(ts))
	local epoch = os.time({ year = fields.year, month = fields.month, day = fields.day,
		hour = fields.hour, min = fields.min, sec = fields.sec })
	assert(type(epoch) == "number", "the local timestamp has no instant: " .. ts)
	return format(epoch, fields.fraction), M.offset_at(epoch)
end

--- The local time a row's user lived, as "YYYY-MM-DD HH:MM:SS[.fff]": its UTC
--- `ts` plus its recorded offset. A row without one keeps its legacy reading:
--- a Linux row held UTC and takes `legacy_offset` (the reading device's
--- current offset), any other held local time already.
--- @param ts string The row's ts.
--- @param offset integer|nil The row's utc_offset_min.
--- @param legacy_utc boolean Whether an offset-less row of its device held UTC (Linux).
--- @param legacy_offset integer|nil The offset an offset-less UTC row is read with.
--- @return string|nil local_ts nil when ts is no timestamp.
function M.local_ts(ts, offset, legacy_utc, legacy_offset)
	local fields = split(ts)
	if not fields then return nil end
	if offset == nil then
		if not legacy_utc then return ts end
		offset = legacy_offset
	end
	assert(M.valid_offset(offset), "a row's offset must be whole minutes within +-18 h, got " .. tostring(offset))
	return format(utc_epoch(fields) + offset * 60, fields.fraction)
end

return M
