--- _shared/tests/lua/core/network_transitions_contract.lua

--- ==============================================================================
--- MODULE: Connectivity Transitions Contract
--- DESCRIPTION:
--- Replays keystats.network_transitions on both Lua drivers: the Windows kinds
--- and NCSI host read from keystats_network.ahk, the Windows reducer (an unknown
--- sample keeps the state) and the sampler over asynchronous probes.
--- ==============================================================================

local M = {}

local function read(path)
	local handle = assert(io.open(path, "rb"), "cannot open " .. path)
	local text = handle:read("*a")
	handle:close()
	return text
end

--- A sampler over scripted asynchronous probes.
--- @return table sampler, table rows, table control
local function scripted(Transitions)
	local rows, errors, pending, now = {}, {}, {}, 0
	local sampler = Transitions.new({
		record = function(kind, fields) rows[#rows + 1] = { kind = kind, adapter = fields.adapter } end,
		reach = function(answer) pending.reach = answer end,
		vpn = function(answer) pending.vpn = answer end,
		now_ms = function() return now end,
		reach_ms = 30, vpn_ms = 20,
		on_error = function(message) errors[#errors + 1] = message end,
	})
	local control = { errors = errors, pending = pending }
	function control.answer(name, status)
		local answer = assert(pending[name], "no " .. name .. " probe in flight")
		pending[name] = nil
		answer(status)
	end
	function control.advance(ms) now = now + ms end
	return sampler, rows, control
end

--- Registers the connectivity checks in a driver's existing owner.
--- @param helpers table The driver's describe/it/assertion functions.
function M.register(helpers)
	local Transitions = require("metrics.engine.system.network_transitions")
	local Paths = require("core.fs.engine.paths")

	helpers.describe("connectivity transitions (network-transitions)", function()
		helpers.it("network-windows-kinds: the kinds and the NCSI host are the Windows ones", function()
			local ahk = read(Paths.shared("") .. "/../windows/modules/keystats/keystats_network.ahk")
			for kind in pairs(Transitions.KINDS) do
				helpers.assert_true(ahk:find('"' .. kind .. '"', 1, true) ~= nil, kind .. " is a Windows kind")
			end
			helpers.assert_true(ahk:find('NCSI_HOST := "' .. Transitions.NCSI_HOST .. '"', 1, true) ~= nil)
			helpers.assert_eq(Transitions.KINDS.vpn_connected, { "adapter" })
			helpers.assert_eq(Transitions.KINDS.internet_up, {})
		end)

		helpers.it("network-reducer: an unknown sample keeps the state, as on Windows", function()
			helpers.assert_eq(Transitions.reduce(true, "unknown"), { accepted = false, changed = false, next_up = true })
			helpers.assert_eq(Transitions.reduce(true, nil), { accepted = false, changed = false, next_up = true })
			helpers.assert_eq(Transitions.reduce(true, "down"), { accepted = true, changed = true, next_up = false })
			helpers.assert_eq(Transitions.reduce(false, "down"), { accepted = true, changed = false, next_up = false })
		end)

		helpers.it("network-sampler: late answers record the transitions from Internet up and no VPN", function()
			local sampler, rows, control = scripted(Transitions)
			sampler.tick()
			control.answer("reach", "up")
			control.answer("vpn", "up")
			helpers.assert_eq(rows, { { kind = "vpn_connected", adapter = "vpn" } }, "Internet up at start is no row")
			control.advance(30)
			sampler.tick()
			control.answer("reach", "down")
			control.answer("vpn", "unknown")
			helpers.assert_eq(rows[2], { kind = "internet_down" })
			helpers.assert_eq(#rows, 2, "an unknown VPN sample changes nothing")
			control.advance(30)
			sampler.tick()
			control.answer("vpn", "down")
			control.answer("reach", "up")
			helpers.assert_eq(rows[3], { kind = "vpn_disconnected", adapter = "vpn" })
			helpers.assert_eq(rows[4], { kind = "internet_up" })
		end)

		helpers.it("network-cadence: a probe in flight is never doubled, and each waits for its cadence", function()
			local sampler, _, control = scripted(Transitions)
			sampler.tick()
			control.advance(100)
			sampler.tick()
			helpers.assert_true(control.pending.reach ~= nil and control.pending.vpn ~= nil)
			control.answer("vpn", "down")
			control.advance(10)
			sampler.tick()
			helpers.assert_true(control.pending.vpn ~= nil, "the VPN probe restarts once its answer is in")
			control.answer("vpn", "down")
			sampler.tick()
			helpers.assert_eq(control.pending.vpn, nil, "not before vpn_ms")
		end)

		helpers.it("network-probe-failure: a probe that cannot start is reported and retried", function()
			local starts, errors = 0, {}
			local sampler = Transitions.new({
				record = function() error("no row expected") end,
				reach = function() starts = starts + 1; error("spawn refused") end,
				vpn = function(answer) answer("down") end,
				now_ms = function() return starts * 30 end,
				reach_ms = 30, vpn_ms = 20,
				on_error = function(message) errors[#errors + 1] = message end,
			})
			sampler.tick()
			sampler.tick()
			helpers.assert_eq(starts, 2, "a failed start does not latch the probe")
			helpers.assert_true(#errors == 2 and errors[1]:find("spawn refused", 1, true) ~= nil, errors[1])
		end)
	end)
end

return M
