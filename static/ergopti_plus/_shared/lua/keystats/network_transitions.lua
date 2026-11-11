--- _shared/lua/keystats/network_transitions.lua

--- ==============================================================================
--- MODULE: Connectivity Transitions
--- DESCRIPTION:
--- The events_network rows of the Lua drivers: internet_up / internet_down and
--- vpn_connected / vpn_disconnected. Port of the Windows reachability and VPN
--- reducers (keystats_network.ahk, KL_Net_ReduceBinarySample), shared by the
--- Linux and macOS samplers so both record the same transitions.
---
--- FEATURES & RATIONALE:
--- 1. Same reducer as Windows: an unknown sample keeps the last accepted state,
---    and the starting states are Windows' own (Internet assumed up, no VPN), so
---    the first observed outage is a row.
--- 2. No OS calls: each driver passes two probes that answer through a
---    callback, so an asynchronous probe (a DNS lookup, a subprocess) never
---    blocks the driver's loop, and a synchronous one simply answers at once.
--- 3. The shared cadences: the caller passes [keystats] network_reach_tick_ms
---    and network_vpn_tick_ms; a probe still running is not started twice.
--- 4. Privacy as on Windows: the VPN rows carry the fixed `adapter` sentinel,
---    never an interface name, address or DNS answer.
--- ==============================================================================

local M = {}

--- The events_network kinds and the metadata keys each carries, as Windows writes them.
M.KINDS = {
	internet_up = {}, internet_down = {},
	vpn_connected = { "adapter" }, vpn_disconnected = { "adapter" },
}

--- The host Windows probes (KLNetConst.NCSI_HOST).
M.NCSI_HOST = "dns.msftncsi.com"

--- The adapter value a VPN row carries: no driver records the interface's name.
M.VPN_ADAPTER = "vpn"

--- The Windows binary-sample reducer.
--- @param previous_up boolean Last accepted state.
--- @param status string "up", "down" or "unknown".
--- @return table { accepted, changed, next_up }
function M.reduce(previous_up, status)
	if status ~= "up" and status ~= "down" then return { accepted = false, changed = false, next_up = previous_up } end
	local next_up = status == "up"
	return { accepted = true, changed = next_up ~= previous_up, next_up = next_up }
end

--- Creates the sampler.
--- @param opts table {
---   record fun(kind, fields)            The driver's recorder.
---   reach fun(answer fun(status))       Internet probe; answers "up", "down" or "unknown".
---   vpn fun(answer fun(status))         VPN probe; same answers.
---   now_ms fun():number                 Monotonic clock.
---   reach_ms number, vpn_ms number      The shared cadences.
---   on_error fun(message)               Reports a probe that failed to start or a throwing recorder. }
--- @return table sampler { tick }
function M.new(opts)
	assert(type(opts) == "table" and type(opts.record) == "function", "the network sampler needs a recorder")
	assert(type(opts.reach) == "function" and type(opts.vpn) == "function", "the network sampler needs two probes")
	assert(type(opts.now_ms) == "function" and type(opts.on_error) == "function",
		"the network sampler needs a clock and an error sink")
	assert(type(opts.reach_ms) == "number" and opts.reach_ms > 0 and type(opts.vpn_ms) == "number"
		and opts.vpn_ms > 0, "the network sampler needs positive cadences")
	local state = { internet_up = true, vpn_active = false, next_reach = 0, next_vpn = 0 }
	local probing = { reach = false, vpn = false }
	local self = {}

	local function apply_internet(status)
		local transition = M.reduce(state.internet_up, status)
		if not transition.accepted then return end
		state.internet_up = transition.next_up
		if transition.changed then opts.record(transition.next_up and "internet_up" or "internet_down", {}) end
	end

	local function apply_vpn(status)
		local transition = M.reduce(state.vpn_active, status)
		if not transition.accepted then return end
		state.vpn_active = transition.next_up
		if transition.changed then
			opts.record(transition.next_up and "vpn_connected" or "vpn_disconnected", { adapter = M.VPN_ADAPTER })
		end
	end

	--- Starts one probe; its answer may arrive now or later, outside the tick's guard.
	local function probe(name, port, apply)
		probing[name] = true
		local started, reason = pcall(port, function(status)
			probing[name] = false
			local applied, failure = pcall(apply, status)
			if not applied then opts.on_error(name .. " transition not recorded: " .. tostring(failure)) end
		end)
		if not started then
			probing[name] = false
			opts.on_error(name .. " probe could not start; the state is kept: " .. tostring(reason))
		end
	end

	--- Starts the due probes.
	function self.tick()
		local now = opts.now_ms()
		if now >= state.next_vpn and not probing.vpn then
			state.next_vpn = now + opts.vpn_ms
			probe("vpn", opts.vpn, apply_vpn)
		end
		if now >= state.next_reach and not probing.reach then
			state.next_reach = now + opts.reach_ms
			probe("reach", opts.reach, apply_internet)
		end
	end

	return self
end


--- Whether one events_network network_change row is a Wi-Fi change, by the
--- Windows rule (keystats_reader_db.ahk "wifi-day"): the poll also writes a
--- first baseline and signal-only rows, so only a connectivity change, an SSID
--- change while connected, or a disconnect from a known SSID counts.
--- @param meta table The row's decoded meta_json.
--- @return boolean
function M.is_wifi_change(meta)
	if type(meta) ~= "table" then return false end
	local state, previous = meta.connection_state, meta.prev_connection_state
	local hash, previous_hash = meta.ssid_hash, meta.prev_ssid_hash
	local function known(value) return type(value) == "string" and value ~= "" end
	if state == "connected" and previous == "disconnected" then return true end
	if state == "disconnected" and previous == "connected" then return true end
	if state == "connected" and (previous == "connected" or previous == nil)
		and known(hash) and known(previous_hash) and hash ~= previous_hash then return true end
	return state == "disconnected" and previous == nil and known(previous_hash)
end

return M
