--- tests/unit/modules/keystats/storage/test_network_transition_rows.lua

--- ==============================================================================
--- MODULE: macOS Connectivity Transition Rows
--- DESCRIPTION:
--- Windows and Linux record Internet and VPN transitions in events_network;
--- macOS recorded none, and build_inserts discarded such an entry as an
--- unknown type. These tests drive the real watcher over scripted ports, the
--- real adapter probes over a stubbed reachability target and ifconfig, and
--- the real writer, so the join from the reading to the row is proven.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.network_transitions_contract").register(helpers)

--- Starts a fresh watcher over scripted ports.
--- @return table watcher, table entries, table control
local function scripted()
	local Watcher = helpers.load_with_stubs("modules.keystats.network_watcher")
	local Timings = require("infra.timings")
	local entries, now, vpn_answers, control = {}, 0, {}, { watched = nil, stopped = false }
	helpers.assert_true(Watcher.start({
		append = function(entry) entries[#entries + 1] = entry end,
		app = function() return "Code" end,
		ports = {
			watch_reachability = function(host, on_status)
				control.host, control.watched = host, on_status
				return { stop = function() control.stopped = true end }
			end,
			probe_vpn = function(answer) vpn_answers[#vpn_answers + 1] = answer; return true end,
			now_ms = function() return now end,
		},
	}))
	local reach_ms = Timings.ms("keystats", "network_reach_tick_ms")
	function control.tick() Watcher.tick(); now = now + reach_ms end
	function control.vpn(status) table.remove(vpn_answers, 1)(status) end
	return Watcher, entries, control
end

helpers.describe("macOS connectivity transitions: the watcher", function()
	helpers.it("macos-network-internet: the resolver's answer is reduced at the reach cadence", function()
		local Watcher, entries, control = scripted()
		helpers.assert_eq(control.host, "dns.msftncsi.com")
		control.tick()
		helpers.assert_eq(#entries, 0, "no answer yet is unknown: Internet stays up")
		control.watched("down")
		helpers.assert_eq(#entries, 0, "an answer is not a row before the next tick")
		control.tick()
		control.watched("unknown")
		control.tick()
		control.watched("up")
		control.tick()
		helpers.assert_eq(entries, { { type = "internet_down", app = "Code" }, { type = "internet_up", app = "Code" } })
		Watcher.stop()
		helpers.assert_true(control.stopped, "stop releases the reachability watch")
	end)

	helpers.it("macos-network-vpn: a tunnel answer is a vpn row with the Windows sentinel", function()
		local Watcher, entries, control = scripted()
		control.tick()
		control.vpn("up")
		control.tick()
		control.vpn("unknown")
		control.tick()
		control.vpn("down")
		helpers.assert_eq(entries, {
			{ type = "vpn_connected", app = "Code", adapter = "vpn" },
			{ type = "vpn_disconnected", app = "Code", adapter = "vpn" },
		})
		Watcher.stop()
	end)

	helpers.it("macos-network-stop: a tunnel read answering after stop records nothing", function()
		local Watcher, entries, control = scripted()
		control.tick()
		Watcher.stop()
		control.vpn("up")
		helpers.assert_eq(#entries, 0)
		helpers.assert_eq(Watcher.is_running(), false)
	end)
end)

helpers.describe("macOS connectivity transitions: the adapter probes", function()
	--- Loads the adapter over a stubbed reachability target and ifconfig.
	--- shell_runner captures `hs` at require time, so it is reloaded too.
	local function adapter(ifconfig_exit, ifconfig_stdout)
		local target = { started = false }
		function target:setCallback(fn) self.callback = fn; return self end
		function target:start() self.started = true; return self end
		function target:stop() self.started = false; return self end
		package.loaded["adapters.shell_runner"] = nil
		local NetworkInfo = helpers.load_with_stubs("adapters.network_info", {
			task = {
				new = function(_, callback)
					return {
						start = function() callback(ifconfig_exit, ifconfig_stdout, ""); return true end,
						isRunning = function() return false end,
						terminate = function() end,
					}
				end,
			},
			network = {
				reachability = {
					flags = { reachable = 2, connectionRequired = 4 },
					forHostName = function(host) target.host = host; return target end,
				},
			},
		})
		return NetworkInfo, target
	end

	helpers.it("macos-network-reachability: reachable without a connection to set up is up", function()
		local NetworkInfo, target = adapter(0, "")
		local seen = {}
		local watch = NetworkInfo.watch_host_reachability("dns.msftncsi.com", function(s) seen[#seen + 1] = s end)
		helpers.assert_true(target.started and target.host == "dns.msftncsi.com")
		target.callback(target, 2)
		target.callback(target, 2 | 4)
		target.callback(target, 0)
		helpers.assert_eq(seen, { "up", "down", "down" })
		helpers.assert_eq(NetworkInfo.classify_reachability_flags(nil), "unknown")
		watch.stop()
		helpers.assert_eq(target.started, false)
	end)

	helpers.it("macos-network-tunnels: an addressed utun, ipsec or ppp is a VPN, a failed read unknown", function()
		local function status(exit_code, stdout)
			local NetworkInfo = adapter(exit_code, stdout)
			local seen
			helpers.assert_true(NetworkInfo.probe_vpn_status(function(s) seen = s end))
			return seen
		end
		local baseline = "utun0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380\n"
			.. "\tinet6 fe80::1%utun0 prefixlen 64 scopeid 0x10\n"
		helpers.assert_eq(status(0, baseline), "down", "a baseline utun with a link-local address is no VPN")
		helpers.assert_eq(status(0, baseline .. "ppp0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280\n"
			.. "\tinet 10.0.0.2 --> 10.0.0.1 netmask 0xff000000\n"), "up")
		helpers.assert_eq(status(0, "ipsec0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1400\n"
			.. "\tinet 172.16.4.2 --> 172.16.4.2 netmask 0xffff0000\n"), "up")
		helpers.assert_eq(status(0, "en0: flags=8863<UP,BROADCAST,RUNNING> mtu 1500\n\tinet 192.168.1.4 netmask 0xff\n"),
			"down", "an ethernet address is no tunnel")
		helpers.assert_eq(status(1, ""), "unknown", "a failed ifconfig is unknown, not down")
	end)
end)

helpers.describe("macOS connectivity transitions: the writer", function()
	helpers.it("macos-network-rows: each kind is an INSERT into events_network with its metadata", function()
		local Writer = helpers.load_with_stubs("modules.keystats.sqlite_writer")
		Writer.init({
			paths = { db = "/tmp/ergopti_test.db" },
			device_obj = { id = "test-device" },
			device_id = "00000000-0000-4000-8000-000000000001",
		})
		local vpn = Writer.build_inserts({ type = "vpn_connected", timestamp = "2026-11-11 10:00:00.000",
			app = "Code", adapter = "vpn" })
		helpers.assert_eq(#vpn, 1)
		helpers.assert_true(vpn[1]:find("INSERT OR IGNORE INTO events_network", 1, true) == 1, vpn[1])
		helpers.assert_true(vpn[1]:find("'vpn_connected', 'Code', '{\"adapter\":\"vpn\"}'", 1, true) ~= nil, vpn[1])
		local down = Writer.build_inserts({ type = "internet_down", timestamp = "2026-11-11 10:00:00.000", app = "Code" })
		helpers.assert_true(down[1]:find("'internet_down', 'Code'", 1, true) ~= nil, down[1])
	end)
end)
