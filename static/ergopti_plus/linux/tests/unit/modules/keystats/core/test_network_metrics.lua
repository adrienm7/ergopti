--- tests/unit/modules/keystats/core/test_network_metrics.lua

--- ==============================================================================
--- MODULE: Linux Connectivity Transitions
--- DESCRIPTION:
--- Windows records Internet and VPN transitions in events_network and Linux
--- recorded none. These tests pin the Windows kinds, the Windows reducer
--- (an unknown sample keeps the state) and the sysfs tunnel probe.
--- ==============================================================================

local helpers = require("tests.helpers")
local it = helpers.it

local Network = require("modules.keystats.network_metrics")

--- A sampler over scripted probes; returns it, the recorded rows and the controls.
local function scripted()
	local rows, pending, vpn, now = {}, nil, { "down" }, 0
	local sampler = Network.new({
		record = function(kind, fields) rows[#rows + 1] = { kind = kind, adapter = fields.adapter } end,
		lookup = function(_, callback) pending = callback end,
		vpn = function() return table.remove(vpn, 1) or "down" end,
		now_ms = function() return now end,
	})
	local control = {}
	function control.answer(err, addresses) local callback = pending; pending = nil; callback(err, addresses) end
	function control.advance(ms) now = now + ms end
	function control.vpn(states) vpn = states end
	return sampler, rows, control
end

helpers.describe("Linux connectivity transitions", function()
	it("linux-network-reducer: an unknown sample keeps the state, as on Windows", function()
		helpers.assert_eq(Network.reduce(true, "unknown"), { accepted = false, changed = false, next_up = true })
		helpers.assert_eq(Network.reduce(true, "down"), { accepted = true, changed = true, next_up = false })
		helpers.assert_eq(Network.classify_lookup(nil, { { addr = "1.2.3.4" } }), "up")
		helpers.assert_eq(Network.classify_lookup("EAI_NONAME: unknown node or service"), "down")
		helpers.assert_eq(Network.classify_lookup("EAI_AGAIN: temporary failure"), "down")
		helpers.assert_eq(Network.classify_lookup("ECANCELED: operation canceled"), "unknown")
	end)

	it("linux-network-vpn-probe: an up tunnel or PPP interface is a VPN, a down one or ethernet is not", function()
		local files = {
			["/n/eth0/type"] = "1", ["/n/eth0/flags"] = "0x1003",
			["/n/wg0/type"] = "65534", ["/n/wg0/flags"] = "0x1090",
			["/n/ppp0/type"] = "512", ["/n/ppp0/flags"] = "0x10d1",
		}
		local function list() return { { name = "eth0" }, { name = "wg0" }, { name = "ppp0" } } end
		local function read(path) return files[path] end
		helpers.assert_eq(Network.vpn_status("/n", list, read), "up", "ppp0 is up")
		files["/n/ppp0/flags"] = "0x1090"
		helpers.assert_eq(Network.vpn_status("/n", list, read), "down", "wg0 and ppp0 are down, eth0 is no tunnel")
		helpers.assert_eq(Network.vpn_status("/n", function() return nil end, read), "unknown")
	end)

	it("linux-network-transitions: the Windows kinds, starting from Internet up and no VPN", function()
		local sampler, rows, control = scripted()
		control.vpn({ "up" })
		sampler.tick()
		control.answer(nil, { { addr = "1.2.3.4" } })
		helpers.assert_eq(rows, { { kind = "vpn_connected", adapter = "vpn" } }, "Internet up at start is no row")
		control.advance(30000)
		control.vpn({ "unknown" })
		sampler.tick()
		control.answer("EAI_AGAIN: temporary failure")
		helpers.assert_eq(rows[2], { kind = "internet_down" })
		helpers.assert_eq(#rows, 2, "an unknown VPN sample changes nothing")
		control.advance(30000)
		control.vpn({ "down" })
		sampler.tick()
		control.answer(nil, { { addr = "1.2.3.4" } })
		helpers.assert_eq(rows[3], { kind = "vpn_disconnected", adapter = "vpn" })
		helpers.assert_eq(rows[4], { kind = "internet_up" })
	end)

	it("linux-network-probe-cadence: a lookup in flight is never doubled", function()
		local sampler, _, control = scripted()
		local lookups = 0
		sampler = Network.new({
			record = function() end,
			lookup = function() lookups = lookups + 1 end,
			vpn = function() return "down" end,
			now_ms = function() return 0 end,
		})
		sampler.tick()
		sampler.tick()
		helpers.assert_eq(lookups, 1)
		helpers.assert_true(control ~= nil)
	end)
end)
