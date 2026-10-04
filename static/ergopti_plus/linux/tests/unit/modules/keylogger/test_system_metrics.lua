--- tests/unit/modules/keylogger/test_system_metrics.lua

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
--- WHAT IS DELIBERATELY LEFT AT ZERO:
--- Virtual-desktop switches, because X11 and each Wayland compositor report them
--- differently and several not at all — there is no reading that means the same
--- thing on two machines. And the two macOS wake counters, which are derived
--- there from wake reasons the kernel does not expose here. A zero is honest; a
--- plausible number would not be.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs the sampler with the shell answering from a table.
--- @param answers table Array of { match = string, out = string }.
--- @param body function Receives the module.
local function with_shell(answers, body)
	local shell_name = "adapters.shell_runner"
	local module_name = "modules.keylogger.system_metrics"
	local previous_shell = package.loaded[shell_name]
	local previous_module = package.loaded[module_name]

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
		has_command = function() return true end,
		run = function() return true end,
		exec = answer,
		exec_line = answer,
	}
	package.loaded[module_name] = nil

	local ok, err = pcall(function()
		local metrics = require(module_name)
		metrics._reset()
		body(metrics)
	end)

	package.loaded[shell_name] = previous_shell
	package.loaded[module_name] = previous_module
	helpers.assert_true(ok, "the sampler must not throw: " .. tostring(err))
end

helpers.describe("system audio native output locale", function()
	for _, locale in ipairs({ "French", "German" }) do
		for _, muted in ipairs({ true, false }) do
			helpers.it("linux-system-audio-locale: retains " .. locale .. " muted=" .. tostring(muted), function()
				with_shell({ { match = "pactl get-sink-mute", out = function(command)
					if command:match("^LC_ALL=C ") then return "Mute: " .. (muted and "yes" or "no") end
					if locale == "French" then return "Mute: " .. (muted and "oui" or "non") end
					return "Mute: " .. (muted and "ja" or "nein")
				end } }, function(metrics)
					local interval = metrics._sample_interval_ms()
					metrics.sample(0, "2026-01-02")
					local day = metrics.sample(interval, "2026-01-02")
					helpers.assert_eq(day.audio_muted_ms, muted and interval or 0)
					helpers.assert_eq(day.awake_ms, interval)
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
		with_shell({ { match = "power_supply", out = "42" } }, function(metrics)
			metrics.sample(0, "2026-08-06")
			local day = metrics.current()
			helpers.assert_not_nil(day, "agg_system_day was the last table nothing wrote")
			helpers.assert_eq(day.battery_count, 1)
			helpers.assert_eq(day.battery_sum, 42)
			helpers.assert_eq(day.battery_min, 42)
		end)
	end)

	helpers.it("keeps the lowest and highest charge of the day", function()
		with_shell({ { match = "power_supply", out = "80" } }, function(metrics)
			local step = metrics._sample_interval_ms()
			metrics.sample(0, "2026-08-06")
			package.loaded["adapters.shell_runner"].exec_line = function(command)
				if command:find("power_supply", 1, true) then return "30" end
				return ""
			end
			metrics.sample(step, "2026-08-06")
			local day = metrics.current()
			helpers.assert_eq(day.battery_min, 30)
			helpers.assert_eq(day.battery_max, 80,
				"the highest charge of the day does not fall because the battery "
					.. "later drained")
		end)
	end)

	helpers.it("does not sample again before the interval has passed", function()
		with_shell({ { match = "power_supply", out = "50" } }, function(metrics)
			metrics.sample(0, "2026-08-06")
			metrics.sample(1000, "2026-08-06")
			helpers.assert_eq(metrics.current().battery_count, 1,
				"the quantities move on a scale of minutes, and sampling faster "
					.. "spends subprocesses to learn the same answer")
		end)
	end)

	helpers.it("starts a fresh row on a new day", function()
		with_shell({ { match = "power_supply", out = "50" } }, function(metrics)
			local step = metrics._sample_interval_ms()
			metrics.sample(0, "2026-08-06")
			metrics.sample(step, "2026-08-07")
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

	helpers.it("counts the time between samples as awake", function()
		with_shell({
			{ match = "power_supply", out = "50" },
			{ match = "LockedHint", out = "no" },
		}, function(metrics)
			local step = metrics._sample_interval_ms()
			metrics.sample(0, "2026-08-06")
			metrics.sample(step, "2026-08-06")
			helpers.assert_eq(metrics.current().awake_ms, step)
		end)
	end)

	helpers.it("counts it as locked when the session was locked", function()
		with_shell({
			{ match = "power_supply", out = "50" },
			{ match = "LockedHint", out = "yes" },
		}, function(metrics)
			local step = metrics._sample_interval_ms()
			metrics.sample(0, "2026-08-06")
			metrics.sample(step, "2026-08-06")
			local day = metrics.current()
			helpers.assert_eq(day.locked_ms, step)
			helpers.assert_eq(day.awake_ms, 0,
				"a locked screen is not the user working, and the panel this feeds "
					.. "exists to tell the two apart")
		end)
	end)

	helpers.it("calls a long gap sleep rather than use", function()
		with_shell({
			{ match = "power_supply", out = "50" },
			{ match = "LockedHint", out = "no" },
		}, function(metrics)
			local step = metrics._sample_interval_ms()
			metrics.sample(0, "2026-08-06")
			metrics.sample(step * 100, "2026-08-06")
			local day = metrics.current()
			helpers.assert_true(day.sleep_ms > 0)
			helpers.assert_eq(day.awake_ms, 0,
				"counting the gap as awake would report a laptop shut overnight as "
					.. "eight hours of use — the single most misleading number this "
					.. "table could produce")
		end)
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ The network ==========================================
-- =================================================================
-- =================================================================

helpers.describe("system metrics: network changes", function()

	helpers.it("counts a change of network", function()
		with_shell({
			{ match = "power_supply", out = "50" },
			{ match = "nmcli", out = "yes:maison" },
		}, function(metrics)
			local step = metrics._sample_interval_ms()
			metrics.sample(0, "2026-08-06")
			package.loaded["adapters.shell_runner"].exec_line = function(command)
				if command:find("nmcli", 1, true) then return "yes:bureau" end
				if command:find("power_supply", 1, true) then return "50" end
				return ""
			end
			metrics.sample(step, "2026-08-06")
			helpers.assert_eq(metrics.current().wifi_changes, 1)
		end)
	end)

	helpers.it("does not count a change to or from 'cannot tell'", function()
		with_shell({
			{ match = "power_supply", out = "50" },
			{ match = "nmcli", out = "yes:maison" },
		}, function(metrics)
			local step = metrics._sample_interval_ms()
			metrics.sample(0, "2026-08-06")
			package.loaded["adapters.shell_runner"].exec_line = function(command)
				if command:find("power_supply", 1, true) then return "50" end
				return ""
			end
			metrics.sample(step, "2026-08-06")
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
		local real_shell = require("adapters.shell_runner")
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
		with_shell({}, function(metrics)
			local shell = package.loaded["adapters.shell_runner"]
			shell.has_command = function() return false end
			shell.exec_line = function(command)
				if not command:find(listing, 1, true) then return "" end
				return real_shell.exec_line("PATH=" .. dir .. "; export PATH; " .. command)
			end
			metrics._set_wireless_path(listing)
			local step = metrics._sample_interval_ms()
			listing_of("wlan0", 54)
			metrics.sample(0, "2026-08-06")
			listing_of("wlp2s0", 54)
			metrics.sample(step, "2026-08-06")
			helpers.assert_eq(metrics.current().wifi_changes, 1, "another interface is another network")
			listing_of("wlp2s0", 31)
			metrics.sample(step * 2, "2026-08-06")
			helpers.assert_eq(metrics.current().wifi_changes, 1, "a weaker signal is the same network")
			local fh = assert(io.open(listing, "w"))
			fh:write("Inter-| sta-|   Quality\n face | tus | link level noise\n")
			fh:close()
			metrics.sample(step * 3, "2026-08-06")
			os.remove(listing)
			metrics.sample(step * 4, "2026-08-06")
			helpers.assert_eq(metrics.current().wifi_changes, 1,
				"no interface listed, then no listing at all, is no answer, not a network change")
		end)
		os.execute("rm -rf " .. dir)
	end)

	helpers.it("leaves the readings it cannot make at zero", function()
		with_shell({ { match = "power_supply", out = "50" } }, function(metrics)
			metrics.sample(0, "2026-08-06")
			local day = metrics.current()
			helpers.assert_eq(day.space_switches, 0,
				"X11 and each Wayland compositor report virtual-desktop changes "
					.. "differently and several not at all — there is no reading that "
					.. "means the same thing on two machines, and a plausible number "
					.. "would be worse than a zero")
			helpers.assert_eq(day.night_wake_count, 0)
		end)
	end)

end)
