--- tests/unit/modules/keystats/aggregation/test_system_metrics.lua

--- ==============================================================================
--- MODULE: What The Machine Was Doing
--- DESCRIPTION:
--- The per-day machine state — battery, network changes, lock, suspend — that
--- the dashboard puts beside the typing to explain a quiet afternoon.
---
--- WHAT WAS MISSING:
--- agg_system_day was the last table nothing wrote. It is not derivable from
--- keystrokes at all: it needs the machine polled.
---
--- THE READING THAT WOULD OTHERWISE BE BADLY WRONG:
--- A gap between two samples longer than three intervals means the machine was
--- not running in between — it suspended, or the daemon was stopped. Counting
--- that as awake time would report a laptop shut overnight as eight hours of
--- use, which is the single most misleading number this table could produce.
---
--- PASSIVE PERIODS, LOAD AND DESKTOPS:
--- A completed suspension or screen lock is one passive period, as on macOS;
--- CPU and memory are sampled from /proc as the Windows system_load event; the
--- X server's current desktop feeds space_switches, and without that source the
--- KPI is unavailable with its reason. A resume before [keystats]
--- night_wake_end_ms after local midnight is a night wake, as on macOS and Windows.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Couples the sampler's virtual elapsed clock to an explicit local calendar.
local function sample_clock(now, date)
	local year, month, day = date:match("^(%d+)%-(%d+)%-(%d+)$")
	local wall = os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = 12 }) + now / 1000
	return { wall_ms = wall * 1000, mono_ms = now, date = date, ts = os.date("!%Y-%m-%d %H:%M:%S", math.floor(wall)) }
end

--- Full source envelope expected from one controlled sampler invocation.
local function sample_event(action, now, date, metadata)
	local clock = sample_clock(now, date)
	return { action = action, metadata = metadata, ts = clock.ts, date = date }
end

--- Runs the sampler with the shell answering from a table.
--- @param answers table Array of { match = string, out = string }; answers.missing
---   names the commands this machine lacks (every other command is installed).
--- @param body function Receives the module.
local function with_shell(answers, body)
	local shell_name = "core.process.adapters.shell_runner"
	local module_name = "modules.keystats.system_metrics"
	local previous_shell = package.loaded[shell_name]
	local previous_module = package.loaded[module_name]
	local calendar = require("modules.keystats.calendar")
	local previous_clock = calendar.capture
	local clock, build_clock = nil, sample_clock

	--- @param command string
	--- @return string
	local function answer(command)
		for _, entry in ipairs(answers) do
			if command:find(entry.match, 1, true) then
				if type(entry.out) == "function" then return entry.out(command) end
				return entry.out
			end
		end
		return ""
	end

	package.loaded[shell_name] = {
		quote = function(v) return "'" .. tostring(v) .. "'" end,
		has_command = function(name) return not (answers.missing or {})[name] end,
		run = function() return true end,
		exec = answer,
		exec_line = answer,
	}
	package.loaded[module_name] = nil

	local ok, err = pcall(function()
		local metrics = require(module_name)
		metrics._reset()
		-- No load fixture unless a test gives one: the host's /proc would make
		-- every event list depend on the machine running the suite.
		metrics._set_proc_paths("/nonexistent/ergopti-stat", "/nonexistent/ergopti-meminfo")
		metrics.bind_event_capture(function() return true end)
		local function sample(now, date)
			clock = build_clock(now, date)
			return metrics.sample()
		end
		calendar.capture = function() assert(clock, "Missing sampler clock observation"); return clock end
		body(metrics, sample, function(provider) build_clock = provider end)
	end)

	calendar.capture = previous_clock
	package.loaded[shell_name] = previous_shell
	package.loaded[module_name] = previous_module
	helpers.assert_true(ok, "the sampler must not throw: " .. tostring(err))
end

--- Muted time over one sample interval, with the shell answering as given.
local function muted_ms(answers)
	local measured
	with_shell(answers, function(metrics, sample)
		local interval = metrics._sample_interval_ms()
		sample(0, "2026-01-02")
		measured = { sample(interval, "2026-01-02").audio_muted_ms, interval }
	end)
	return measured[1], measured[2]
end

--- An amixer simple-control report with one playback line per channel switch.
local function amixer(...)
	local lines = { "Simple mixer control 'Master',0", "  Capabilities: pvolume pswitch",
		"  Playback channels: Front Left - Front Right", "  Limits: Playback 0 - 87" }
	for index, switch in ipairs({ ... }) do
		lines[#lines + 1] = string.format("  %s: Playback 30 [47%%] [-34.50dB] [%s]",
			index == 1 and "Front Left" or "Front Right", switch)
	end
	return table.concat(lines, "\n") .. "\n"
end

helpers.describe("system audio without a sound server (linux-audio-alsa-fallback)", function()
	helpers.it("reads PipeWire's own wpctl when pactl is absent", function()
		for _, case in ipairs({ { "Volume: 0.40 [MUTED]", true }, { "Volume: 0.40", false } }) do
			local muted, interval = muted_ms({ missing = { pactl = true },
				{ match = "wpctl get-volume @DEFAULT_AUDIO_SINK@", out = case[1] } })
			helpers.assert_eq(muted, case[2] and interval or 0, case[1])
		end
	end)

	helpers.it("falls through a pactl with no server to the next stack", function()
		local muted, interval = muted_ms({
			{ match = "pactl get-sink-mute", out = "Connection failure: Connection refused" },
			{ match = "wpctl get-volume", out = "Volume: 1.00 [MUTED]" } })
		helpers.assert_eq(muted, interval, "a refused pactl is no answer, never 'unmuted'")
	end)

	helpers.it("reads the ALSA mixer when neither PulseAudio nor PipeWire is present", function()
		local no_server = { pactl = true, wpctl = true }
		for _, case in ipairs({
			{ amixer("off", "off"), true, "every channel off" },
			{ amixer("off", "on"), false, "one channel still on" },
			{ amixer("on"), false, "a mono control on" },
		}) do
			local muted, interval = muted_ms({ missing = no_server,
				{ match = "LC_ALL=C amixer sget 'Master'", out = case[1] } })
			helpers.assert_eq(muted, case[2] and interval or 0, case[3])
		end
		-- A card without a Master switch is read from its PCM control.
		local muted, interval = muted_ms({ missing = no_server,
			{ match = "amixer sget 'Master'", out = "Simple mixer control 'Master',0\n  Capabilities: pvolume\n" },
			{ match = "amixer sget 'PCM'", out = amixer("off") } })
		helpers.assert_eq(muted, interval)
	end)

	helpers.it("measures no muted time when no sound stack answers", function()
		helpers.assert_eq(muted_ms({ missing = { pactl = true, wpctl = true, amixer = true } }), 0)
		helpers.assert_eq(muted_ms({ missing = { pactl = true, wpctl = true },
			{ match = "amixer", out = "amixer: Unable to find simple control 'Master',0\n" } }), 0)
	end)
end)

helpers.describe("system audio native output locale", function()
	for _, locale in ipairs({ "French", "German" }) do
		for _, muted in ipairs({ true, false }) do
			helpers.it("linux-system-audio-locale: retains " .. locale .. " muted=" .. tostring(muted), function()
				with_shell({ { match = "pactl get-sink-mute", out = function(command)
					if command:match("^LC_ALL=C ") then return "Mute: " .. (muted and "yes" or "no") end
					if locale == "French" then return "Mute: " .. (muted and "oui" or "non") end
					return "Mute: " .. (muted and "ja" or "nein")
				end } }, function(metrics, sample)
					local interval = metrics._sample_interval_ms()
					sample(0, "2026-01-02")
					local day = sample(interval, "2026-01-02")
					helpers.assert_eq(day.audio_muted_ms, muted and interval or 0)
					helpers.assert_eq(day.awake_ms, 0, "unlocked time is no keep-awake time (KMD-3)")
				end)
			end)
		end
	end
end)




-- =================================================================
-- =================================================================
-- ======= 1/ Sampling =============================================
-- =================================================================
-- =================================================================

helpers.describe("system metrics: reading the machine", function()

	helpers.it("records the battery it was told", function()
		with_shell({ { match = "power_supply", out = "42" } }, function(metrics, sample)
			sample(0, "2026-08-06")
			local day = metrics.current()
			helpers.assert_not_nil(day, "agg_system_day was the last table nothing wrote")
			helpers.assert_eq(day.battery_count, 1)
			helpers.assert_eq(day.battery_sum, 42)
			helpers.assert_eq(day.battery_min, 42)
		end)
	end)

	helpers.it("keeps the lowest and highest charge of the day", function()
		with_shell({ { match = "power_supply", out = "80" } }, function(metrics, sample)
			local step = metrics._sample_interval_ms()
			sample(0, "2026-08-06")
			package.loaded["core.process.adapters.shell_runner"].exec_line = function(command)
				if command:find("power_supply", 1, true) then return "30" end
				return ""
			end
			sample(step, "2026-08-06")
			local day = metrics.current()
			helpers.assert_eq(day.battery_min, 30)
			helpers.assert_eq(day.battery_max, 80,
				"the highest charge of the day does not fall because the battery "
					.. "later drained")
		end)
	end)

	helpers.it("does not sample again before the interval has passed", function()
		with_shell({ { match = "power_supply", out = "50" } }, function(metrics, sample)
			sample(0, "2026-08-06")
			sample(1000, "2026-08-06")
			helpers.assert_eq(metrics.current().battery_count, 1,
				"the quantities move on a scale of minutes, and sampling faster "
					.. "spends subprocesses to learn the same answer")
		end)
	end)

	helpers.it("starts a fresh row on a new day", function()
		with_shell({ { match = "power_supply", out = "50" } }, function(metrics, sample)
			local step = metrics._sample_interval_ms()
			sample(0, "2026-08-06")
			sample(step, "2026-08-07")
			local day = metrics.current()
			helpers.assert_eq(day.date, "2026-08-07")
			helpers.assert_eq(day.battery_count, 1,
				"a day that carried yesterday's readings would make every figure "
					.. "cumulative for the life of the process")
		end)
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ Time, and the gap that is not time ===================
-- =================================================================
-- =================================================================

helpers.describe("system metrics: awake, locked, asleep", function()
	helpers.it("reads the native suspend-aware clock in Linux LuaJIT", function()
		if not jit then return end -- The supported Lua 5.4 test mode has no FFI.
		local clock = require("modules.keystats.calendar").capture(true)
		local file = assert(io.open("/proc/uptime", "r"))
		local line = assert(file:read("*l")); assert(file:close())
		local uptime = assert(tonumber(line:match("^[%d%.]+"))) * 1000
		helpers.assert_true(type(clock.boot_ms) == "number")
		helpers.assert_true(math.abs(clock.boot_ms - uptime) < 5000, "CLOCK_BOOTTIME matches kernel uptime")
	end)

	-- KMD-3 (decided by the maintainer on 2026-11-11): awake_ms is keep-awake
	-- time, as on Windows and macOS; unlocked uptime is no longer credited to it.
	helpers.it("credits no unlocked time to awake_ms (linux-awake-definition)", function()
		with_shell({
			{ match = "power_supply", out = "50" },
			{ match = "LockedHint", out = "no" },
		}, function(metrics, sample)
			local step = metrics._sample_interval_ms()
			sample(0, "2026-08-06")
			sample(step, "2026-08-06")
			helpers.assert_eq(metrics.current().awake_ms, 0)
			helpers.assert_eq(metrics.current().locked_ms, 0)
		end)
	end)

	helpers.it("a finished keep-awake session is the day's awake_ms and its passive row (linux-awake-definition)", function()
		with_shell({}, function(metrics, sample)
			sample(0, "2026-08-06")
			helpers.assert_eq(metrics.record_awake_session(90000.4), true)
			local day = metrics.current()
			helpers.assert_eq(day.awake_ms, 90000)
			helpers.assert_eq(day.passive_count, 1)
			helpers.assert_eq(metrics.take_events(), { sample_event("passive_period", 0, "2026-08-06",
				{ kind = "awake", duration_ms = 90000 }) })
		end)
	end)

	helpers.it("counts it as locked when the session was locked", function()
		with_shell({
			{ match = "power_supply", out = "50" },
			{ match = "LockedHint", out = "yes" },
		}, function(metrics, sample)
			local step = metrics._sample_interval_ms()
			sample(0, "2026-08-06")
			sample(step, "2026-08-06")
			local day = metrics.current()
			helpers.assert_eq(day.locked_ms, step)
			helpers.assert_eq(day.awake_ms, 0,
				"a locked screen is not the user working, and the panel this feeds "
					.. "exists to tell the two apart")
		end)
	end)

	helpers.it("linux-night-wake: a resume before the night's end counts once, a daytime one does not", function()
		with_shell({}, function(metrics, sample, set_clock)
			local step = metrics._sample_interval_ms()
			local hour = 3
			set_clock(function(now, date)
				local clock = sample_clock(now, date)
				-- The suspension ends at hour:00 local, the noon of sample_clock moved.
				clock.wall_ms = clock.wall_ms + (hour - 12) * 3600 * 1000
				clock.boot_ms = now; clock.mono_ms = now == 0 and 0 or step
				return clock
			end)
			sample(0, "2026-08-06"); sample(step * 8, "2026-08-06")
			helpers.assert_eq(metrics.current().night_wake_count, 1)
			hour = 12
			sample(step * 16, "2026-08-06")
			helpers.assert_eq(metrics.current().night_wake_count, 1, "a noon resume is no night wake")
		end)
	end)

	helpers.it("keeps a long active sampling delay out of sleep time", function()
		with_shell({ { match = "LockedHint", out = "yes" } }, function(metrics, sample, set_clock)
			local step = metrics._sample_interval_ms()
			set_clock(function(now, date)
				local clock = sample_clock(now, date); clock.boot_ms = now; return clock
			end)
			sample(0, "2026-08-06"); sample(step * 4, "2026-08-06")
			helpers.assert_eq(metrics.current().locked_ms, step * 4)
			helpers.assert_eq(metrics.current().sleep_ms, 0)
			helpers.assert_eq(metrics.take_events(), {})
		end)
	end)

	helpers.it("separates active and suspended time in one sampling interval", function()
		with_shell({}, function(metrics, sample, set_clock)
			local step = metrics._sample_interval_ms()
			set_clock(function(now, date)
				local clock = sample_clock(now, date)
				clock.boot_ms = now; clock.mono_ms = now == 0 and 0 or step * 2
				return clock
			end)
			sample(0, "2026-08-06"); sample(step * 8, "2026-08-06")
			helpers.assert_eq(metrics.current().awake_ms, 0)
			helpers.assert_eq(metrics.current().sleep_ms, step * 6)
			helpers.assert_eq(metrics.take_events(), { sample_event("wake", step * 8, "2026-08-06", { asleep_ms = step * 6 }),
				sample_event("passive_period", step * 8, "2026-08-06", { kind = "sleep", duration_ms = step * 6 }) })
			helpers.assert_eq(metrics.current().passive_count, 1)
		end)
	end)

	helpers.it("credits only active time to lock and mute across a suspension", function()
		with_shell({ { match = "LockedHint", out = "yes" }, { match = "pactl get-sink-mute", out = "Mute: yes" } },
			function(metrics, sample, set_clock)
				local step = metrics._sample_interval_ms()
				set_clock(function(now, date)
					local clock = sample_clock(now, date)
					clock.boot_ms = now; clock.mono_ms = now == 0 and 0 or step * 2
					return clock
				end)
				sample(0, "2026-08-06"); sample(step * 8, "2026-08-06")
				local day = metrics.current()
				helpers.assert_eq(day.sleep_ms, step * 6)
				helpers.assert_eq(day.locked_ms, step * 2)
				helpers.assert_eq(day.audio_muted_ms, step * 2)
				helpers.assert_eq(day.awake_ms, 0)
			end)
	end)

	helpers.it("counts suspension even when the Linux monotonic clock stops", function()
		with_shell({}, function(metrics, sample, set_clock)
			local step = metrics._sample_interval_ms()
			set_clock(function(now, date)
				local clock = sample_clock(now, date)
				clock.boot_ms = now
				clock.mono_ms = now == 0 and 0 or step
				return clock
			end)
			sample(0, "2026-08-06")
			sample(step * 100, "2026-08-06")
			helpers.assert_eq(metrics.current().sleep_ms, step * 99)
			helpers.assert_eq(metrics.current().awake_ms, 0)
			helpers.assert_eq(metrics.take_events(), { sample_event("wake", step * 100, "2026-08-06", { asleep_ms = step * 99 }),
				sample_event("passive_period", step * 100, "2026-08-06", { kind = "sleep", duration_ms = step * 99 }) })
		end)
	end)

	helpers.it("partitions a suspended interval at local midnight", function()
		with_shell({}, function(metrics, sample, set_clock)
			local midnight = assert(os.time({ year = 2026, month = 8, day = 7, hour = 0, min = 0, sec = 0 }))
			set_clock(function(now)
				local wall = midnight * 1000 - 60000 + now
				return { wall_ms = wall, mono_ms = now == 0 and 0 or 1000, boot_ms = now,
					date = os.date("%Y-%m-%d", wall / 1000), ts = os.date("!%Y-%m-%d %H:%M:%S", wall / 1000) }
			end)
			sample(0, "2026-08-06"); sample(120000, "2026-08-07")
			local days = metrics.snapshot().values
			helpers.assert_eq(days["2026-08-06"].sleep_ms, 59500)
			helpers.assert_eq(days["2026-08-07"].sleep_ms, 59500)
			helpers.assert_eq(days["2026-08-06"].awake_ms, 0)
			helpers.assert_eq(days["2026-08-07"].awake_ms, 0)
		end)
	end)

	helpers.it("retains the old clock domain when a suspend-aware reading fails", function()
		with_shell({ { match = "LockedHint", out = "yes" } }, function(metrics, sample, set_clock)
			local step, boot = metrics._sample_interval_ms(), 0
			set_clock(function(now, date)
				local clock = sample_clock(now, date)
				clock.boot_ms = boot
				return clock
			end)
			sample(0, "2026-08-06")
			boot = nil
			helpers.assert_nil(sample(step, "2026-08-06"))
			boot = step * 2
			sample(step * 2, "2026-08-06")
			helpers.assert_eq(metrics.current().locked_ms, step * 2)
		end)
	end)

	helpers.it("calls a long gap sleep rather than use", function()
		with_shell({
			{ match = "power_supply", out = "50" },
			{ match = "LockedHint", out = "no" },
		}, function(metrics, sample)
			local step = metrics._sample_interval_ms()
			sample(0, "2026-08-06")
			sample(step * 100, "2026-08-06")
			local day = metrics.current()
			helpers.assert_true(day.sleep_ms > 0)
			helpers.assert_eq(day.awake_ms, 0,
				"counting the gap as awake would report a laptop shut overnight as "
					.. "eight hours of use — the single most misleading number this "
					.. "table could produce")
			helpers.assert_eq(metrics.take_events(), { sample_event("wake", step * 100, "2026-08-06", { asleep_ms = step * 100 }),
				sample_event("passive_period", step * 100, "2026-08-06", { kind = "sleep", duration_ms = step * 100 }) })
		end)
	end)

	helpers.it("reports the lock and the unlock between two answers, never from 'cannot tell'", function()
		local locked = "no"
		with_shell({
			{ match = "power_supply", out = "50" },
			{ match = "LockedHint", out = function() return locked end },
		}, function(metrics, sample)
			local step = metrics._sample_interval_ms()
			sample(0, "2026-08-06")
			locked = "yes"
			sample(step, "2026-08-06")
			locked = "no"
			sample(step * 2, "2026-08-06")
			locked = ""
			sample(step * 3, "2026-08-06")
			locked = "yes"
			sample(step * 4, "2026-08-06")
			helpers.assert_eq(metrics.take_events(), { sample_event("lock", step, "2026-08-06"), sample_event("unlock", step * 2, "2026-08-06"),
				sample_event("passive_period", step * 2, "2026-08-06", { kind = "lock", duration_ms = step }) })
			helpers.assert_eq(metrics.current().passive_count, 1, "a lock with no observed start is no measured period")
		end)
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ The network ==========================================
-- =================================================================
-- =================================================================

helpers.describe("system metrics: network changes", function()

	helpers.it("keeps network changes readable under a translated nmcli locale", function()
		local real_shell = require("core.process.adapters.shell_runner")
		local dir = os.tmpname()
		os.remove(dir)
		assert(real_shell.run("mkdir -- " .. real_shell.quote(dir)))
		local executable = dir .. "/nmcli"
		local file = assert(io.open(executable, "w"))
		-- nmcli translates ACTIVE even in terse mode; its shell pipeline must
		-- receive a machine locale before filtering the English yes token.
		file:write('#!/bin/sh\ncase "${LC_ALL-}" in C) active=yes;; *) active=oui;; esac\n',
			'printf "%s:%s\\n" "$active" "$ERGOPTI_TEST_SSID"\n')
		assert(file:close())
		assert(real_shell.run("chmod +x -- " .. real_shell.quote(executable)))
		local okay, detail = pcall(function()
			local ssid = "maison"
			with_shell({ missing = { iwgetid = true } }, function(metrics, sample)
				local shell = package.loaded["core.process.adapters.shell_runner"]
				shell.exec_line = function(command)
					if not command:find("nmcli", 1, true) then return "" end
					return real_shell.exec_line("PATH=" .. real_shell.quote(dir .. ":/usr/bin:/bin")
						.. " LC_ALL=fr_FR.UTF-8 ERGOPTI_TEST_SSID=" .. real_shell.quote(ssid) .. " " .. command)
				end
				metrics._set_wireless_path(dir .. "/no-wireless")
				sample(0, "2026-08-06")
				ssid = "bureau"
				sample(metrics._sample_interval_ms(), "2026-08-06")
				helpers.assert_eq(metrics.current().wifi_changes, 1)
			end)
		end)
		os.remove(executable)
		assert(real_shell.run("rmdir -- " .. real_shell.quote(dir)))
		helpers.assert_true(okay, tostring(detail))
	end)

	helpers.it("counts a change of network", function()
		with_shell({
			{ match = "power_supply", out = "50" },
			{ match = "nmcli", out = "yes:maison" },
		}, function(metrics, sample)
			local step = metrics._sample_interval_ms()
			sample(0, "2026-08-06")
			package.loaded["core.process.adapters.shell_runner"].exec_line = function(command)
				if command:find("nmcli", 1, true) then return "yes:bureau" end
				if command:find("power_supply", 1, true) then return "50" end
				return ""
			end
			sample(step, "2026-08-06")
			helpers.assert_eq(metrics.current().wifi_changes, 1)
			helpers.assert_eq(metrics.take_events(), { sample_event("wifi_change", step, "2026-08-06") },
				"the event names no network: the name is a fingerprint, never stored")
			helpers.assert_eq(metrics.take_events(), {}, "taken once")
		end)
	end)

	helpers.it("does not mistake a different network reader for a network change", function()
		local nmcli, iwgetid = "yes:maison", ""
		with_shell({
			{ match = "nmcli", out = function() return nmcli end },
			{ match = "iwgetid", out = function() return iwgetid end },
		}, function(metrics, sample)
			local step = metrics._sample_interval_ms()
			sample(0, "2026-08-06")
			nmcli, iwgetid = "", "maison"
			sample(step, "2026-08-06")
			helpers.assert_eq(metrics.current().wifi_changes, 0, "the readers have different representations")
			iwgetid = "bureau"
			sample(step * 2, "2026-08-06")
			helpers.assert_eq(metrics.current().wifi_changes, 1, "the same reader still detects a change")
			helpers.assert_eq(metrics.take_events(), { sample_event("wifi_change", step * 2, "2026-08-06") })
		end)
	end)

	helpers.it("does not count a change to or from 'cannot tell'", function()
		with_shell({
			{ match = "power_supply", out = "50" },
			{ match = "nmcli", out = "yes:maison" },
		}, function(metrics, sample)
			local step = metrics._sample_interval_ms()
			sample(0, "2026-08-06")
			package.loaded["core.process.adapters.shell_runner"].exec_line = function(command)
				if command:find("power_supply", 1, true) then return "50" end
				return ""
			end
			sample(step, "2026-08-06")
			helpers.assert_eq(metrics.current().wifi_changes, 0,
				"a transition to or from an unanswerable reading is a fact about "
					.. "this module, not about the network")
		end)
	end)

	-- The last reader ran awk on /proc/net/wireless, and no package declares
	-- awk: an install without it never saw a network change. The shell here has
	-- an empty PATH, so only a reader that needs no tool passes; the stats move
	-- between samples, so only the interface's name counts as the network.
	helpers.it("reads the wireless interface with no tool on the PATH (wireless-without-awk)", function()
		local real_shell = require("core.process.adapters.shell_runner")
		local dir = os.tmpname()
		os.remove(dir)
		os.execute("mkdir " .. dir)
		local listing = dir .. "/wireless"
		local function listing_of(interface, quality)
			local fh = assert(io.open(listing, "w"))
			fh:write("Inter-| sta-|   Quality        |   Discarded packets               | Missed | WE\n",
				" face | tus | link level noise |  nwid  crypt   frag  retry   misc | beacon | 22\n",
				interface, ": 0000   ", quality, ".  -56.  -256        0      0      0      0     37        0\n")
			fh:close()
		end
		with_shell({}, function(metrics, sample)
			local shell = package.loaded["core.process.adapters.shell_runner"]
			shell.has_command = function() return false end
			shell.exec_line = function(command)
				if not command:find(listing, 1, true) then return "" end
				return real_shell.exec_line("PATH=" .. dir .. "; export PATH; " .. command)
			end
			metrics._set_wireless_path(listing)
			local step = metrics._sample_interval_ms()
			listing_of("wlan0", 54)
			sample(0, "2026-08-06")
			listing_of("wlp2s0", 54)
			sample(step, "2026-08-06")
			helpers.assert_eq(metrics.current().wifi_changes, 1, "another interface is another network")
			listing_of("wlp2s0", 31)
			sample(step * 2, "2026-08-06")
			helpers.assert_eq(metrics.current().wifi_changes, 1, "a weaker signal is the same network")
			local fh = assert(io.open(listing, "w"))
			fh:write("Inter-| sta-|   Quality\n face | tus | link level noise\n")
			fh:close()
			sample(step * 3, "2026-08-06")
			os.remove(listing)
			sample(step * 4, "2026-08-06")
			helpers.assert_eq(metrics.current().wifi_changes, 1,
				"no interface listed, then no listing at all, is no answer, not a network change")
		end)
		os.execute("rm -rf " .. dir)
	end)

	helpers.it("leaves the readings it cannot make at zero", function()
		with_shell({ { match = "power_supply", out = "50" } }, function(metrics, sample)
			sample(0, "2026-08-06")
			local day = metrics.current()
			helpers.assert_eq(day.space_switches, 0, "no desktop source: nothing is counted")
			helpers.assert_eq(metrics.space_change_availability(),
				{ measured = false, reason = "platform_reason.desktop_changes_need_workspace_interface" })
			helpers.assert_eq(day.night_wake_count, 0)
		end)
	end)

	helpers.it("linux-space-change: counts a change of the current desktop between two answers", function()
		with_shell({}, function(metrics, sample)
			sample(0, "2026-08-06")
			local desktop = 0
			metrics.bind_desktop_source(function() return desktop end)
			helpers.assert_eq(metrics.observe_desktop(), false, "the first answer is a baseline")
			desktop = 2
			helpers.assert_eq(metrics.observe_desktop(), true)
			helpers.assert_eq(metrics.observe_desktop(), false, "an unchanged desktop is no switch")
			desktop = nil
			helpers.assert_nil(metrics.observe_desktop())
			desktop = 1
			helpers.assert_eq(metrics.observe_desktop(), false, "no change is counted across an unanswered read")
			desktop = 0
			helpers.assert_eq(metrics.observe_desktop(), true)
			-- sway names its workspaces: a name is an identity like an index.
			desktop = "1:web"
			helpers.assert_eq(metrics.observe_desktop(), true, "a Wayland workspace name counts too")
			desktop = "1:web"
			helpers.assert_eq(metrics.observe_desktop(), false)
			desktop = ""
			helpers.assert_nil(metrics.observe_desktop(), "an empty name is no answer")
			helpers.assert_eq(metrics.current().space_switches, 3)
			local actions = {}
			for _, event in ipairs(metrics.take_events()) do actions[#actions + 1] = event.action end
			helpers.assert_eq(actions, { "space_change", "space_change", "space_change" })
			helpers.assert_eq(metrics.space_change_availability().measured, true)
		end)
	end)

	helpers.it("linux-system-load: samples CPU and memory from /proc as the Windows system_load event", function()
		with_shell({}, function(metrics, sample)
			local dir = os.tmpname()
			os.remove(dir)
			os.execute("mkdir -p " .. dir)
			local function write(name, text)
				local handle = assert(io.open(dir .. "/" .. name, "wb"))
				handle:write(text)
				handle:close()
			end
			write("stat", "cpu  100 0 50 800 50 0 0 0 0 0\ncpu0 1 1 1 1\n")
			write("meminfo", "MemTotal:        8000000 kB\nMemFree:  100 kB\nMemAvailable:    2000000 kB\n")
			metrics._set_proc_paths(dir .. "/stat", dir .. "/meminfo")
			sample(0, "2026-08-06")
			local first = metrics.take_events()
			helpers.assert_eq(#first, 1)
			helpers.assert_eq(first[1].action, "system_load")
			helpers.assert_eq(first[1].metadata, { ram_used_pct = 75, ram_total_mb = 7813, ram_free_mb = 1953 },
				"the first sample has no CPU interval yet")
			-- 1000 more ticks: 300 user, 100 system, 600 idle.
			write("stat", "cpu  400 0 150 1400 50 0 0 0 0 0\n")
			local poll = require("infra.timings").ms("keystats", "system_load_poll_ms")
			sample(metrics._sample_interval_ms(), "2026-08-06")
			helpers.assert_eq(metrics.take_events(), {}, "load waits for its own poll interval")
			for at = 2 * metrics._sample_interval_ms(), poll, metrics._sample_interval_ms() do sample(at, "2026-08-06") end
			local load = metrics.take_events()
			helpers.assert_eq(#load, 1)
			helpers.assert_eq(load[1].action, "system_load")
			helpers.assert_eq(load[1].metadata.cpu_pct, 40)
			helpers.assert_eq(load[1].metadata.cpu_user_percent, 30)
			os.execute("rm -rf " .. dir)
		end)
	end)

end)


helpers.describe("system metrics: owned restart hydration", function()
	-- Locked time witnesses the elapsed-time cursor: unlocked time is credited
	-- to no field since awake_ms counts keep-awake sessions (KMD-3).
	local function persisted(date, locked)
		return {
			date = date, wifi_changes = 4, space_switches = 0,
			battery_sum = 150, battery_count = 2, battery_min = 70, battery_max = 80,
			audio_muted_ms = 1000, locked_ms = locked, sleep_ms = 3000, awake_ms = 0,
			passive_count = 0, night_wake_count = 0,
		}
	end

	helpers.it("unbound-recovery: merges first binding without losing clocks or queued transitions", function()
		local network = "first"
		with_shell({ { match = "power_supply", out = "50" }, { match = "nmcli", out = function() return network end },
			{ match = "LockedHint", out = "yes" } },
			function(metrics, sample, set_clock)
				local base = os.time({ year = 2026, month = 10, day = 5, hour = 23, min = 59, sec = 45 })
				set_clock(function(now, date)
					return { wall_ms = base * 1000 + now, mono_ms = now, date = date,
						ts = os.date("!%Y-%m-%d %H:%M:%S", base + now / 1000) }
				end)
				sample(0, "2026-10-05")
				network = "second"
				sample(30000, "2026-10-06")
				local pending = metrics.snapshot()
				local attempts = 0
				local called = pcall(metrics.bind, "recovered", "device", function(date)
					attempts = attempts + 1
					return persisted(date, 4000), attempts ~= 2
				end)
				helpers.assert_eq(called, false, "partial date admission must fail explicitly")
				helpers.assert_eq(metrics.snapshot().values, pending.values, "a later refusal cannot mutate earlier retained dates")
				local loads = 0
				local function load(date) loads = loads + 1; return persisted(date, 4000), true end
				metrics.bind("recovered", "device", load)
				helpers.assert_eq(metrics.current().locked_ms, 19000, "current day must point at its merged owner")
				helpers.assert_eq(metrics.snapshot().values["2026-10-05"].locked_ms, 19000)
				helpers.assert_eq(metrics.current().battery_sum, 200)
				helpers.assert_eq(metrics.current().battery_count, 3)
				helpers.assert_eq(metrics.current().battery_min, 50)
				helpers.assert_eq(metrics.current().battery_max, 80)
				helpers.assert_eq(sample(60000, "2026-10-06").locked_ms, 49000, "binding must preserve the previous elapsed-time cursor")
				helpers.assert_eq(#metrics.take_events(), 1, "binding must preserve already-captured transitions")
				metrics.bind("recovered", "device", load)
				helpers.assert_eq(metrics.current().locked_ms, 49000)
				helpers.assert_eq(loads, 2, "same-owner binding must not merge the baseline twice")
				metrics._reset()
				helpers.assert_eq(metrics.snapshot().values, {}, "explicit reset must still purge all source")
			end)
	end)

	helpers.it("hydrates the owned cumulative row before its first sample", function()
		with_shell({ { match = "LockedHint", out = "yes" } }, function(metrics, sample)
			metrics.bind("owned-a", "device-a", function(date) return persisted(date, 4000), true end)
			local day = sample(500000, "2026-10-05")
			helpers.assert_eq(day.locked_ms, 4000)
			helpers.assert_eq(day.wifi_changes, 4)
			helpers.assert_eq(day.awake_ms, 0)
			helpers.assert_eq(day.audio_muted_ms, 1000)
			helpers.assert_eq(day.battery_count, 2)
		end)
	end)

	helpers.it("seeds an acknowledged absent row without invented history", function()
		with_shell({ { match = "LockedHint", out = "yes" } }, function(metrics, sample)
			metrics.bind("owned-a", "device-a", function() return nil, true end)
			local day = sample(500000, "2026-10-05")
			helpers.assert_eq(day.locked_ms, 0)
			helpers.assert_nil(day.battery_min)
		end)
	end)

	helpers.it("refuses unread history and retries without a writable zero day", function()
		with_shell({ { match = "LockedHint", out = "yes" } }, function(metrics, sample)
			local attempts = 0
			metrics.bind("owned-a", "device-a", function(date)
				attempts = attempts + 1
				if attempts == 1 then return nil, false end
				return persisted(date, 4000), true
			end)
			helpers.assert_nil(sample(500000, "2026-10-05"))
			helpers.assert_nil(metrics.current())
			helpers.assert_eq(sample(500001, "2026-10-05").locked_ms, 4000)
			helpers.assert_eq(attempts, 2)
		end)
	end)

	helpers.it("same database and device rebinding retains the accumulated day", function()
		with_shell({ { match = "LockedHint", out = "yes" } }, function(metrics, sample)
			local loads = 0
			local function load(date) loads = loads + 1; return persisted(date, 4000), true end
			metrics.bind("owned-a", "device-a", load)
			sample(0, "2026-10-05")
			sample(30000, "2026-10-05")
			metrics.bind("owned-a", "device-a", load)
			helpers.assert_eq(sample(60000, "2026-10-05").locked_ms, 64000)
			helpers.assert_eq(loads, 1)
		end)
	end)

	for _, identity in ipairs({ { "owned-b", "device-a" }, { "owned-a", "device-b" } }) do
		helpers.it("isolates changed database or device " .. table.concat(identity, "/"), function()
			with_shell({ { match = "LockedHint", out = "yes" } }, function(metrics, sample)
				metrics.bind("owned-a", "device-a", function(date) return persisted(date, 4000), true end)
				sample(0, "2026-10-05")
				metrics.bind(identity[1], identity[2], function(date) return persisted(date, 9000), true end)
				helpers.assert_nil(metrics.current())
				helpers.assert_eq(sample(900000, "2026-10-05").locked_ms, 9000)
				helpers.assert_eq(metrics.current().sleep_ms, 3000)
			end)
		end)
	end

	helpers.it("hydrates a new date and partitions its own elapsed sample clock", function()
		with_shell({ { match = "LockedHint", out = "yes" } }, function(metrics, sample, set_clock)
			local base = os.time({ year = 2026, month = 10, day = 5, hour = 23, min = 59, sec = 45 })
			set_clock(function(now, date)
				return { wall_ms = base * 1000 + now, mono_ms = now, date = date,
					ts = os.date("!%Y-%m-%d %H:%M:%S", base + now / 1000) }
			end)
			local loads = 0
			metrics.bind("owned-a", "device-a", function(date)
				loads = loads + 1
				return persisted(date, loads * 4000), true
			end)
			sample(0, "2026-10-05")
			local day = sample(30000, "2026-10-06")
			helpers.assert_eq(day.locked_ms, 8000 + 15000)
			helpers.assert_eq(day.sleep_ms, 3000)
			helpers.assert_eq(metrics.snapshot().values["2026-10-05"].locked_ms, 4000 + 15000)
			helpers.assert_eq(loads, 2)
		end)
	end)

	helpers.it("folds new battery readings into the persisted extrema and sum", function()
		with_shell({ { match = "power_supply", out = "50" }, { match = "LockedHint", out = "yes" } }, function(metrics, sample)
			metrics.bind("owned-a", "device-a", function(date) return persisted(date, 4000), true end)
			local day = sample(0, "2026-10-05")
			helpers.assert_eq(day.battery_sum, 200)
			helpers.assert_eq(day.battery_count, 3)
			helpers.assert_eq(day.battery_min, 50)
			helpers.assert_eq(day.battery_max, 80)
		end)
	end)

	helpers.it("a throwing loader cannot publish a destructive zero day", function()
		with_shell({ { match = "LockedHint", out = "yes" } }, function(metrics, sample)
			metrics.bind("owned-a", "device-a", function() error("owned read refused") end)
			helpers.assert_nil(sample(0, "2026-10-05"))
			helpers.assert_nil(metrics.current())
		end)
	end)

	helpers.it("reset clears the owned loader as well as the sampling state", function()
		with_shell({ { match = "LockedHint", out = "yes" } }, function(metrics, sample)
			metrics.bind("owned-a", "device-a", function() return nil, false end)
			metrics._reset()
			metrics.bind_event_capture(function() return true end)
			helpers.assert_eq(sample(0, "2026-10-05").locked_ms, 0)
		end)
	end)
end)

helpers.describe("capture calendar ownership", function()
	helpers.it("splits at the observation when the local timezone changes its date", function()
		local calendar = require("modules.keystats.calendar")
		local today = os.date("*t")
		local noon = os.time({ year = today.year, month = today.month, day = today.day, hour = 12 })
		local old_date = os.date("%Y-%m-%d", noon - 86400)
		local new_date = os.date("%Y-%m-%d", noon)
		local cuts = {}
		calendar.boundaries({ wall_ms = noon * 1000, mono_ms = 1000, date = old_date },
			{ wall_ms = (noon + 60) * 1000, mono_ms = 61000, date = new_date },
			function(...) cuts[#cuts + 1] = { ... } end)
		helpers.assert_eq(cuts, { { 61000, old_date, new_date, (noon + 60) * 1000 } })
	end)

	helpers.it("still splits at an observed local midnight", function()
		local calendar = require("modules.keystats.calendar")
		local today = os.date("*t")
		local noon = os.time({ year = today.year, month = today.month, day = today.day, hour = 12 })
		local midnight = calendar.next_midnight(noon * 1000)
		local previous_wall, current_wall = midnight - 60000, midnight + 60000
		local previous_date = os.date("%Y-%m-%d", previous_wall / 1000)
		local current_date = os.date("%Y-%m-%d", current_wall / 1000)
		local cuts = {}
		calendar.boundaries({ wall_ms = previous_wall, mono_ms = 1000, date = previous_date },
			{ wall_ms = current_wall, mono_ms = 121000, date = current_date },
			function(...) cuts[#cuts + 1] = { ... } end)
		helpers.assert_eq(cuts, { { 61000, previous_date, current_date, midnight } })
	end)
	helpers.it("retires closed sources only after their complete exact prefix is acknowledged", function()
		local calendar = require("modules.keystats.calendar")
		local store = calendar.new(function() return { count = 0 } end)
		local function project(value) return { count = value.count } end
		local before = store.app("2026-10-24", "app", 0)
		before.count = 1
		local prefix = store.snapshot(project)
		before.count = 2
		helpers.assert_eq(store.prune(prefix, project, "2026-10-25"), {})
		helpers.assert_true(rawequal(store.app("2026-10-24", "app", 0), before))
		local successor = store.snapshot(project)
		store.app("2026-10-24", "new-app", 0).count = 1
		helpers.assert_eq(store.prune(successor, project, "2026-10-25"), {}, "a newly admitted app is also unacknowledged source")
		local complete = store.snapshot(project)
		helpers.assert_eq(store.prune(complete, project, "2026-10-24"), {}, "the current day's counters remain cumulative")
		helpers.assert_eq(store.prune(complete, project, "2026-10-25"), { "2026-10-24" })
		local recreated = store.app("2026-10-24", "app", 0)
		recreated.count = 2
		helpers.assert_eq(store.prune(complete, project, "2026-10-25"), {}, "equal bytes never replace source ownership")
		helpers.assert_true(rawequal(store.app("2026-10-24", "app", 0), recreated))
	end)
end)

helpers.describe("system-event-capture-policy", function()
	helpers.it("refuses missing or malformed authority before sensor acquisition", function()
		local reads = 0
		with_shell({ { match = "power_supply", out = function() reads = reads + 1; return "50" end } }, function(metrics, sample)
			metrics._reset()
			helpers.assert_eq(pcall(sample, 0, "2026-10-05"), false)
			helpers.assert_eq(pcall(metrics.bind_event_capture, nil), false)
			for _, invalid in ipairs({ function() return nil end, function() return 1 end }) do
				metrics.bind_event_capture(invalid)
				helpers.assert_eq(pcall(sample, 0, "2026-10-05"), false)
			end
			helpers.assert_nil(metrics.current())
			helpers.assert_eq(metrics.take_events(), {})
			helpers.assert_eq(reads, 0, "invalid admission cannot acquire sensors or partially sample the day")
		end)
	end)

	helpers.it("samples the exact policy once per due observation without gating aggregates", function()
		local network, allowed, calls = "first", true, 0
		with_shell({ { match = "nmcli", out = function() return network end } }, function(metrics, sample)
			metrics.bind_event_capture(function() calls = calls + 1; return allowed end)
			local step = metrics._sample_interval_ms()
			sample(0, "2026-10-05")
			sample(step / 2, "2026-10-05")
			helpers.assert_eq(calls, 1)
			allowed, network = false, "second"
			sample(step, "2026-10-05")
			helpers.assert_eq(metrics.take_events(), {})
			helpers.assert_eq(metrics.current().wifi_changes, 1)
			allowed, network = true, "third"
			sample(step * 2, "2026-10-05")
			helpers.assert_eq(metrics.take_events(), { sample_event("wifi_change", step * 2, "2026-10-05") })
			helpers.assert_eq(metrics.current().wifi_changes, 2)
			helpers.assert_eq(calls, 3)
		end)
	end)
end)

for _, fault in ipairs({ "read_throw", "close_false", "close_throw" }) do
	helpers.it("wireless sample refuses an incomplete listing " .. fault, function()
		with_shell({ missing = { nmcli = true, iwgetid = true } }, function(metrics, sample)
			local original, failing, closes = io.open, false, 0
			io.open = function(path, mode)
				if path ~= "/proc/net/wireless" then return original(path, mode) end
				local lines = { "header", "header", failing and "wlan1: 0000" or "wlan0: 0000" }
				local index = 0
				return { read = function()
					index = index + 1
					if failing and fault == "read_throw" then error("injected read failure") end
					return lines[index]
				end, close = function()
					closes = closes + 1
					if failing and fault == "close_throw" then error("injected close failure") end
					return not (failing and fault == "close_false")
				end }
			end
			local called, detail = pcall(function()
				sample(0, "2026-08-06")
				failing = true
				sample(metrics._sample_interval_ms(), "2026-08-06")
			end)
			io.open = original
			assert(called, detail)
			helpers.assert_eq(closes, 2, "each listing is closed even after a read exception")
			helpers.assert_eq(metrics.current().wifi_changes, 0, "an unacknowledged listing is not a network change")
		end)
	end)
end
