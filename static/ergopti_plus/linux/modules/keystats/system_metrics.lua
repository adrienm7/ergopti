--- modules/keystats/system_metrics.lua

--- ==============================================================================
--- MODULE: System Metrics (Linux)
--- DESCRIPTION:
--- Samples the machine's own state — battery, network, screen lock, suspend —
--- and accumulates the per-day figures `agg_system_day` declares.
---
--- WHY THIS EXISTS SEPARATELY FROM THE KEYSTATS:
--- Nothing here is a keystroke. The keystats's whole surface is "what did the
--- user type"; this answers "what was the machine doing while they did", which
--- the dashboard puts beside it to explain a quiet afternoon. Keeping them apart
--- means a machine with no battery and no network manager costs the typing path
--- nothing at all.
---
--- HOW IT READS, AND WHY EACH WAY:
--- Battery through /sys/class/power_supply, which is a kernel file and needs no
--- daemon. Lock state comes from logind; suspension is the difference between
--- the boot and monotonic clocks. Network uses the first of nmcli, iwgetid
--- or /proc/net/wireless that answers — three because distributions disagree
--- about which is installed, and a metric that works on one distribution is a
--- metric nobody can compare. Audio mute through the first sound stack that
--- answers: PulseAudio (or PipeWire's pulse server) through pactl, PipeWire's
--- own wpctl, then the ALSA mixer of a system with neither sound server.
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
local Calendar = require("modules.keystats.calendar")
local TableUtil = require("table_util")
local StorageOwned = require("storage_owned")

local LOG = "modules.keystats.system_metrics"

-- How often the machine's state is read, in milliseconds. Battery and lock
-- state move on a scale of minutes; sampling faster spends subprocesses to
-- learn the same answer.
local SAMPLE_INTERVAL_MS = 30000

-- Ignore short apparent suspensions within three sample intervals. When the
-- suspend-aware clock is unavailable, retain the older elapsed-gap heuristic.
local SLEEP_GAP_MS = SAMPLE_INTERVAL_MS * 3

-- A sampler must never switch time domains within one captured history.
local _sample_clock_source = nil

-- Where the kernel publishes battery state. A glob rather than a fixed name:
-- BAT0 and BAT1 are both common, and a machine can have neither.
local BATTERY_GLOB = "/sys/class/power_supply/BAT*/capacity"

-- Where the kernel lists the wireless interfaces: two header lines, then one
-- line per interface.
local WIRELESS_PATH = "/proc/net/wireless"

-- The accumulated day, or nil before the first sample.
local _day = nil
local _days = {}

-- The wireless listing read now: WIRELESS_PATH, or a test's fixture.
local _wireless_path = WIRELESS_PATH

-- Persistence is bound by the collector after its own database is opened.
local _owner_database, _owner_device, _load_day = nil, nil, nil
local _event_admit = nil

-- What the previous sample saw, for the transitions.
local function new_last() return { at_ms = nil, ssid = nil, ssid_source = nil, locked = nil, muted = nil } end
local _last = new_last()

-- The transitions seen since the collector last took them, for events_system:
-- { action, metadata? } in order.
local _events = {}




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
	local read_ok, line = pcall(function()
		local current
		for _ = 1, 3 do
			current = fh:read("*l")
			if not current then break end
		end
		return current
	end)
	local close_ok, closed = pcall(fh.close, fh)
	if not read_ok or not close_ok or closed ~= true or type(line) ~= "string" then return nil end
	return line:match("^%s*(%S+)")
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
			"LC_ALL=C nmcli --colors no -t -f active,ssid dev wifi 2>/dev/null | grep '^yes:' | head -1")
		if out and out ~= "" then return out, "nmcli" end
	end
	if Shell.has_command("iwgetid") then
		local out = Shell.exec_line("iwgetid -r 2>/dev/null")
		if out and out ~= "" then return out, "iwgetid" end
	end
	local interface = read_wireless_interface()
	return interface, interface and "interface" or nil
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

--- The ALSA simple controls whose playback switch is the output's mute, in order.
local ALSA_CONTROLS = { "Master", "PCM" }

--- Reads one ALSA control's playback switches: muted when every channel is off.
--- @param control string Simple mixer control name.
--- @return boolean|nil nil when the control has no playback switch here.
local function alsa_control_muted(control)
	local out = Shell.exec("LC_ALL=C amixer sget " .. Shell.quote(control) .. " 2>/dev/null")
	local on, off = 0, 0
	for line in (type(out) == "string" and out or ""):gmatch("[^\n]+") do
		-- A channel line ends with its switch: "Front Left: Playback 30 [47%] [-34.50dB] [on]".
		local switch = line:find("Playback", 1, true) and line:match("%[(o[nf]f?)%]%s*$")
		if switch == "on" then on = on + 1 elseif switch == "off" then off = off + 1 end
	end
	if on + off == 0 then return nil end
	return on == 0
end

-- The mute readers, in the order a session answers them. Each command is a
-- machine query run under the C locale: pactl translates yes/no through gettext.
local AUDIO_READERS = {
	{ source = "pulseaudio", command = "pactl", read = function()
		if not Shell.has_command("pactl") then return nil end
		local state = (Shell.exec_line("LC_ALL=C pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null") or "")
			:match("^Mute:%s*(%a+)%s*$")
		if state == "yes" then return true end
		if state == "no" then return false end
		return nil
	end },
	{ source = "pipewire", command = "wpctl", read = function()
		if not Shell.has_command("wpctl") then return nil end
		local out = Shell.exec_line("LC_ALL=C wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null") or ""
		if not out:match("^Volume:%s*%d") then return nil end
		return out:find("[MUTED]", 1, true) ~= nil
	end },
	{ source = "alsa", command = "amixer", read = function()
		if not Shell.has_command("amixer") then return nil end
		for _, control in ipairs(ALSA_CONTROLS) do
			local muted = alsa_control_muted(control)
			if muted ~= nil then return muted end
		end
		return nil
	end },
}

-- The sound stack that answered last, so a change of answering source is said once.
local _audio_source = nil

--- Whether audio output is muted, from the first sound stack that answers.
--- @return boolean|nil nil when no sound stack answers, which is not "unmuted".
local function read_muted()
	for _, reader in ipairs(AUDIO_READERS) do
		-- Each reader probes its own program, so the probe sits beside the call.
		local muted = reader.read()
		if muted ~= nil then
			if _audio_source ~= reader.source then
				_audio_source = reader.source
				Logger.info(LOG, "Audio mute is read from %s (%s).", reader.source, reader.command)
			end
			return muted
		end
	end
	if _audio_source ~= false then
		_audio_source = false
		Logger.warn(LOG, "No sound stack answers (pactl, wpctl, amixer); muted time is not measured.")
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

--- Binds the collector's one live recording-policy authority for raw transitions.
--- Machine aggregates remain independent of the boolean capture decision.
--- @param admit function Returns an exact boolean for the current producer span.
function M.bind_event_capture(admit)
	assert(type(admit) == "function", "System transitions require a recording-policy authority")
	_event_admit = admit
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
		if _owner_database == nil and next(_days) ~= nil then
			-- Samples accepted while SQLite was unavailable are deltas, not a
			-- replacement baseline. Admit every date before publishing any merge.
			local merged = {}
			for date, captured in pairs(_days) do
				local ok, persisted, accepted = pcall(loader, date)
				if not ok or accepted ~= true then
					Logger.error(LOG, "Cannot bind sampled system history: baseline read refused for %s.", date)
					error("System baseline refused before initial binding", 2)
				end
				local value = TableUtil.deep_copy(persisted or new_day(date))
				for field, count in pairs(captured) do
					if type(count) == "number" then
						if field == "battery_min" then
							value[field] = value[field] and math.min(value[field], count) or count
						elseif field == "battery_max" then
							value[field] = value[field] and math.max(value[field], count) or count
						else value[field] = (value[field] or 0) + count end
					end
				end
				merged[date] = value
			end
			local current_date = _day and _day.date
			_days, _day = merged, current_date and merged[current_date] or nil
		else
			_day, _days = nil, {}
			_last = new_last()
		end
	end
	_owner_database, _owner_device, _load_day = database, device_id, loader
end

--- Loads one exact device/day before its cumulative replacement can advance.
local function retained_day(date)
	if _days[date] then return _days[date] end
	local day
	if _load_day then
		local ok, persisted, accepted = pcall(_load_day, date)
		if not ok or accepted ~= true then return nil end
		day = persisted
	end
	day = day or new_day(date)
	_days[date] = day
	return day
end

--- Captures one producer clock and partitions elapsed time at local day cuts.
--- @return table|nil Current cumulative day, or nil on source refusal.
function M.sample()
	local clock = Calendar.capture(true)
	local boot_ms = clock.boot_ms
	clock.active_mono_ms = clock.mono_ms
	if not _sample_clock_source then
		_sample_clock_source = type(boot_ms) == "number" and "boot" or "monotonic"
		if _sample_clock_source == "monotonic" then
			Logger.warn(LOG, "Suspend-aware clock unavailable; sleep intervals may be missed.")
		end
	end
	if _sample_clock_source == "boot" then
		if type(boot_ms) ~= "number" then
			Logger.error(LOG, "Suspend-aware clock refused; system sample deferred.")
			return nil
		end
		clock.mono_ms = boot_ms
	end
	local now_ms, date = clock.mono_ms, clock.date
	if _last.at_ms and (now_ms < _last.at_ms
		or (_sample_clock_source == "boot" and _last.clock
			and clock.active_mono_ms < _last.clock.active_mono_ms)) then
		Logger.error(LOG, "System sampling clock moved backwards; sample deferred.")
		return nil
	end
	if _day and _day.date == date and _last.at_ms and (now_ms - _last.at_ms) < SAMPLE_INTERVAL_MS then return _day end
	assert(type(_event_admit) == "function", "System transition capture has no recording-policy authority")
	local capture_events = _event_admit()
	assert(type(capture_events) == "boolean", "System transition recording policy must return a boolean")
	local current = retained_day(date)
	if not current then return nil end
	local elapsed = _last.at_ms and math.max(0, now_ms - _last.at_ms) or 0
	local suspended = elapsed
	if _sample_clock_source == "boot" and _last.clock then
		local active = math.max(0, clock.active_mono_ms - _last.clock.active_mono_ms)
		suspended = math.max(0, elapsed - math.min(elapsed, active))
	end
	local asleep = suspended > SLEEP_GAP_MS
	local sleep_total = asleep and suspended or 0
	local segments = {}
	local at, span_date = _last.at_ms, _last.clock and _last.clock.date
	if at and _last.clock then
		Calendar.boundaries(_last.clock, clock, function(boundary, previous_date, next_date)
			if boundary > at then segments[#segments + 1] = { date = previous_date, elapsed = boundary - at } end
			at, span_date = boundary, next_date
		end)
		if now_ms > at then segments[#segments + 1] = { date = span_date, elapsed = now_ms - at } end
	end
	-- Admit every source first: a refused historical load cannot leave half an
	-- interval credited and then counted again on the next periodic retry.
	for _, segment in ipairs(segments) do if not retained_day(segment.date) then return nil end end
	-- Two clock deltas prove the interval totals but not when suspension began.
	-- Across local day cuts, apportion those totals by segment duration; the
	-- cumulative rounding conserves every measured millisecond.
	local credited, sleep_credited = 0, 0
	for _, segment in ipairs(segments) do
		local day = _days[segment.date]
		credited = credited + segment.elapsed
		local cumulative_sleep = elapsed > 0 and math.floor(sleep_total * credited / elapsed + 0.5) or 0
		local segment_sleep = cumulative_sleep - sleep_credited
		sleep_credited = cumulative_sleep
		local active = segment.elapsed - segment_sleep
		day.sleep_ms = day.sleep_ms + segment_sleep
		local field = _last.locked == true and "locked_ms" or "awake_ms"
		day[field] = day[field] + active
		if _last.muted == true then day.audio_muted_ms = day.audio_muted_ms + active end
	end
	_day = current
	local function transition(action, metadata)
		if not capture_events then return end
		_events[#_events + 1] = { action = action, metadata = metadata, date = clock.date, ts = clock.ts }
	end
	if asleep then transition("wake", { asleep_ms = sleep_total }) end

	local battery = read_battery()
	if battery then
		_day.battery_sum = _day.battery_sum + battery
		_day.battery_count = _day.battery_count + 1
		_day.battery_min = _day.battery_min and math.min(_day.battery_min, battery) or battery
		_day.battery_max = _day.battery_max and math.max(_day.battery_max, battery) or battery
	end

	local ssid, ssid_source = read_network()
	-- Compare only readings from the same source: nmcli, iwgetid and the
	-- interface fallback use different identities for the same connection.
	-- An unreadable sample or a changed reader is not a network transition.
	if _last.ssid ~= nil and ssid ~= nil and ssid_source == _last.ssid_source and ssid ~= _last.ssid then
		_day.wifi_changes = _day.wifi_changes + 1
		-- Without the network's name: it is a fingerprint, never stored.
		transition("wifi_change")
	end

	local locked = read_locked()
	-- Counted only between two answers, like the network.
	if _last.locked ~= nil and locked ~= nil and locked ~= _last.locked then
		transition(locked and "lock" or "unlock")
	end

	_last.at_ms, _last.clock = now_ms, clock
	_last.ssid, _last.ssid_source = ssid, ssid_source
	_last.locked = locked
	_last.muted = read_muted()
	return _day
end

--- The accumulated day, or nil before the first sample.
--- @return table|nil
function M.current()
	return _day
end

--- Captures all retained days with their exact private source identities.
--- @return table snapshot
function M.snapshot()
	return { values = TableUtil.deep_copy(_days), owners = TableUtil.shallow_copy(_days) }
end

--- Retires only unchanged closed days covered by an acknowledged native prefix.
--- @param snapshot table From snapshot().
function M.acknowledge(snapshot)
	for date, value in pairs(snapshot.values) do
		if (not _day or date ~= _day.date) and rawequal(_days[date], snapshot.owners[date])
			and StorageOwned.equal(_days[date], value) then _days[date] = nil end
	end
end

--- Hands over the transitions seen since the last call and forgets them.
--- @return table events { action, metadata? } in order.
function M.take_events()
	local events = _events
	_events = {}
	return events
end

--- Test seam: forgets everything, the wireless listing's path included.
function M._reset()
	_event_admit = nil
	_sample_clock_source = nil
	_owner_database, _owner_device, _load_day = nil, nil, nil
	_day, _days = nil, {}
	_events = {}
	_last = new_last()
	_wireless_path = WIRELESS_PATH
	_audio_source = nil
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
