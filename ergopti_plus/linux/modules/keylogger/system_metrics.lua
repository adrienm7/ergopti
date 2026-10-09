--- modules/keylogger/system_metrics.lua

--- ==============================================================================
--- MODULE: System Metrics (Linux)
--- DESCRIPTION:
--- Samples the machine's own state — battery, network, screen lock, suspend —
--- and accumulates the per-day figures `agg_system_day` declares.
---
--- WHY THIS EXISTS SEPARATELY FROM THE KEYLOGGER:
--- Nothing here is a keystroke. The keylogger's whole surface is "what did the
--- user type"; this answers "what was the machine doing while they did", which
--- the dashboard puts beside it to explain a quiet afternoon. Keeping them apart
--- means a machine with no battery and no network manager costs the typing path
--- nothing at all.
---
--- HOW IT READS, AND WHY EACH WAY:
--- Battery through /sys/class/power_supply, which is a kernel file and needs no
--- daemon. Lock state and suspend through logind, which is the only thing on a
--- systemd desktop that knows both. Network through the first of nmcli, iwgetid
--- or /proc/net/wireless that answers — three because distributions disagree
--- about which is installed, and a metric that works on one distribution is a
--- metric nobody can compare.
---
--- WHAT IT DELIBERATELY LEAVES AT ZERO, AND WHY:
--- `space_switches` counts virtual-desktop changes, which X11 and each Wayland
--- compositor report differently and several do not report at all — there is no
--- reading that means the same thing on two machines. `passive_count` and
--- `night_wake_count` are derived on macOS from wake reasons the kernel exposes
--- there and not here. Reporting a zero is honest for those; inventing a number
--- that looks measured is not, and a column of plausible fiction is worse than a
--- column of nothing.
---
--- SAMPLING, NOT WATCHING:
--- Every reading is a poll. Watching would mean a D-Bus subscription this driver
--- has no binding for, and the quantities are minutes-scale: a battery that
--- moved 1% between two samples is the same answer either way.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Shell = require("adapters.shell_runner")

local LOG = "modules.keylogger.system_metrics"

-- How often the machine's state is read, in milliseconds. Battery and lock
-- state move on a scale of minutes; sampling faster spends subprocesses to
-- learn the same answer.
local SAMPLE_INTERVAL_MS = 30000

-- A gap between two samples longer than this means the machine was not running
-- in between — it suspended, or the daemon was stopped. Three sample intervals,
-- so a busy machine that merely ran late is never mistaken for one that slept.
local SLEEP_GAP_MS = SAMPLE_INTERVAL_MS * 3

-- Where the kernel publishes battery state. A glob rather than a fixed name:
-- BAT0 and BAT1 are both common, and a machine can have neither.
local BATTERY_GLOB = "/sys/class/power_supply/BAT*/capacity"

-- Where the kernel lists the wireless interfaces: two header lines, then one
-- line per interface.
local WIRELESS_PATH = "/proc/net/wireless"

-- The accumulated day, or nil before the first sample.
local _day = nil

-- The wireless listing read now: WIRELESS_PATH, or a test's fixture.
local _wireless_path = WIRELESS_PATH

-- Persistence is bound by the collector after its own database is opened.
local _owner_database, _owner_device, _load_day = nil, nil, nil

-- What the previous sample saw, for the transitions.
local _last = { at_ms = nil, ssid = nil, locked = nil, muted = nil }




-- =========================================
-- =========================================
-- ======= 1/ Reading the machine ==========
-- =========================================
-- =========================================

--- Battery charge as a percentage.
--- @return number|nil nil on a machine with no battery, which is not a failure.
local function read_battery()
	local out = Shell.exec_line("cat " .. BATTERY_GLOB .. " 2>/dev/null | head -1")
	local value = tonumber(out)
	if not value or value < 0 or value > 100 then return nil end
	return value
end

--- The first wireless interface the kernel lists, as "wlan0:": the first field
--- of the third line. Read here rather than with awk, which no package
--- declares: an install without it never saw a network change.
--- @return string|nil nil when nothing is listed or the file is absent (no
---   wireless driver), which is no answer rather than a failure.
local function read_wireless_interface()
	local fh = io.open(_wireless_path, "r")
	if not fh then return nil end
	local line = nil
	for _ = 1, 3 do
		line = fh:read("*l")
		if not line then break end
	end
	fh:close()
	return line and line:match("^%s*(%S+)") or nil
end

--- The network the machine is on.
---
--- Three readers because distributions disagree about which is installed. The
--- VALUE is never stored — only whether it changed — so this is a fingerprint
--- rather than a record of where the user was.
--- @return string|nil
local function read_network()
	if Shell.has_command("nmcli") then
		local out = Shell.exec_line(
			"nmcli -t -f active,ssid dev wifi 2>/dev/null | grep '^yes' | head -1")
		if out and out ~= "" then return out end
	end
	if Shell.has_command("iwgetid") then
		local out = Shell.exec_line("iwgetid -r 2>/dev/null")
		if out and out ~= "" then return out end
	end
	return read_wireless_interface()
end

--- Whether the session is locked.
--- @return boolean|nil nil when logind cannot answer, which is not "unlocked".
local function read_locked()
	if not Shell.has_command("loginctl") then return nil end
	local out = Shell.exec_line(
		"loginctl show-session $(loginctl show-user $USER -p Display --value) "
		.. "-p LockedHint --value 2>/dev/null")
	if out == "yes" then return true end
	if out == "no" then return false end
	return nil
end

--- Whether audio output is muted.
--- @return boolean|nil
local function read_muted()
	if Shell.has_command("pactl") then
		-- pactl translates yes/no through gettext; machine parsing needs C locale.
		local out = Shell.exec_line("LC_ALL=C pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null")
		if out and out:find("yes", 1, true) then return true end
		if out and out:find("no", 1, true) then return false end
	end
	if Shell.has_command("amixer") then
		local out = Shell.exec_line("amixer get Master 2>/dev/null | tail -1")
		if out and out:find("%[off%]") then return true end
		if out and out:find("%[on%]") then return false end
	end
	return nil
end




-- =========================================
-- =========================================
-- ======= 2/ Accumulating =================
-- =========================================
-- =========================================

--- A fresh day.
--- @param date string "YYYY-MM-DD".
--- @return table
local function new_day(date)
	return {
		date = date,
		wifi_changes = 0,
		-- Left at zero deliberately: X11 and each Wayland compositor report
		-- virtual-desktop changes differently and several not at all, so there is
		-- no reading that means the same thing on two machines.
		space_switches = 0,
		battery_sum = 0, battery_count = 0, battery_min = nil, battery_max = nil,
		audio_muted_ms = 0,
		locked_ms = 0,
		sleep_ms = 0,
		awake_ms = 0,
		-- Derived on macOS from wake reasons the kernel exposes there and not
		-- here. A zero is honest; a plausible number would not be.
		passive_count = 0,
		night_wake_count = 0,
	}
end

--- Binds the collector's exact persistence identity and checked day loader.
--- Reopening the same database preserves the live cumulative day.
--- @param database string Database identity.
--- @param device_id string Collector identity.
--- @param loader function Returns row, accepted for one calendar day.
function M.bind(database, device_id, loader)
	assert(type(database) == "string" and database ~= "", "system metrics need a database identity")
	assert(type(device_id) == "string" and device_id ~= "", "system metrics need a device identity")
	assert(type(loader) == "function", "system metrics need a checked day loader")
	if database ~= _owner_database or device_id ~= _owner_device then
		_day = nil
		_last = { at_ms = nil, ssid = nil, locked = nil, muted = nil }
	end
	_owner_database, _owner_device, _load_day = database, device_id, loader
end

--- Reads the machine once and folds the result into the day.
---
--- @param now_ms number Monotonic milliseconds.
--- @param date string "YYYY-MM-DD".
--- @return table|nil The accumulated day, or nil when it is not yet due.
function M.sample(now_ms, date)
	if type(now_ms) ~= "number" or type(date) ~= "string" then return nil end
	if _day and _day.date ~= date then
		-- A new day starts a new row. The old one has already been flushed —
		-- persistence runs far more often than midnight.
		_day = nil
		_last = { at_ms = nil, ssid = nil, locked = nil, muted = nil }
	end
	if _last.at_ms and (now_ms - _last.at_ms) < SAMPLE_INTERVAL_MS then return _day end

	if not _day then
		if _load_day then
			local ok, persisted, accepted = pcall(_load_day, date)
			if not ok or accepted ~= true then return nil end
			_day = persisted
		end
		_day = _day or new_day(date)
	end
	local elapsed = _last.at_ms and (now_ms - _last.at_ms) or 0

	if elapsed > SLEEP_GAP_MS then
		-- The machine was not running in between. Counted as sleep rather than as
		-- awake time, which is the one reading that would otherwise be badly
		-- wrong: a laptop shut overnight would report eight hours of use.
		_day.sleep_ms = _day.sleep_ms + elapsed
	elseif elapsed > 0 then
		if _last.locked == true then
			_day.locked_ms = _day.locked_ms + elapsed
		else
			_day.awake_ms = _day.awake_ms + elapsed
		end
		if _last.muted == true then
			_day.audio_muted_ms = _day.audio_muted_ms + elapsed
		end
	end

	local battery = read_battery()
	if battery then
		_day.battery_sum = _day.battery_sum + battery
		_day.battery_count = _day.battery_count + 1
		_day.battery_min = _day.battery_min and math.min(_day.battery_min, battery) or battery
		_day.battery_max = _day.battery_max and math.max(_day.battery_max, battery) or battery
	end

	local ssid = read_network()
	-- Counted only once both samples have an answer. A transition to or from
	-- "cannot tell" is a reading about this module, not about the network.
	if _last.ssid ~= nil and ssid ~= nil and ssid ~= _last.ssid then
		_day.wifi_changes = _day.wifi_changes + 1
	end

	_last.at_ms = now_ms
	_last.ssid = ssid
	_last.locked = read_locked()
	_last.muted = read_muted()
	return _day
end

--- The accumulated day, or nil before the first sample.
--- @return table|nil
function M.current()
	return _day
end

--- Test seam: forgets everything, the wireless listing's path included.
function M._reset()
	_owner_database, _owner_device, _load_day = nil, nil, nil
	_day = nil
	_last = { at_ms = nil, ssid = nil, locked = nil, muted = nil }
	_wireless_path = WIRELESS_PATH
end

--- Test seam: reads the wireless listing from `path` instead of the kernel's.
--- @param path string
function M._set_wireless_path(path)
	if type(path) ~= "string" or path == "" then error("the wireless listing needs a path", 2) end
	_wireless_path = path
end

--- Test seam: how often a sample is taken.
--- @return number
function M._sample_interval_ms()
	return SAMPLE_INTERVAL_MS
end

return M
