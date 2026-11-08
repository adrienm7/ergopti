--- modules/keystats/network_metrics.lua

--- ==============================================================================
--- MODULE: Connectivity Transitions (Linux)
--- DESCRIPTION:
--- Records Internet reachability and VPN adapter transitions as the Windows
--- events_network rows (keystats_network.ahk): internet_up / internet_down
--- and vpn_connected / vpn_disconnected with the same `adapter` sentinel.
---
--- FEATURES & RATIONALE:
--- 1. Same reducer as Windows (KL_Net_ReduceBinarySample): an unknown sample
---    keeps the last accepted state, and the starting states are Windows' own
---    (Internet assumed up, no VPN), so the first observed outage is a row.
--- 2. Reachability resolves the Windows NCSI host asynchronously through libuv:
---    the daemon's loop also reads the keyboard, so no lookup may block it. A
---    name-resolution refusal is "down"; any other failure is unknown.
--- 3. A VPN is an administratively up interface of the kinds tunnels use: no
---    link layer (tun, WireGuard, ARPHRD_NONE) or point-to-point (PPP). The
---    adapter's name is not recorded, as on Windows, whose port exposes none.
--- 4. Privacy as on Windows: no address, packet, DNS answer or interface name
---    reaches a row; the keystats recorder applies the collection consent.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Timings = require("infra.timings")

local LOG = "modules.keystats.network_metrics"

--- The events_network kinds and the metadata keys each carries, as Windows writes them.
M.KINDS = {
	internet_up = {}, internet_down = {},
	vpn_connected = { "adapter" }, vpn_disconnected = { "adapter" },
}

--- The host Windows probes (KLNetConst.NCSI_HOST).
M.NCSI_HOST = "dns.msftncsi.com"

--- ARPHRD values of tunnel interfaces (linux/if_arp.h) and IFF_UP (linux/if.h).
local ARPHRD_PPP, ARPHRD_NONE, IFF_UP = 512, 65534, 0x1

--- getaddrinfo refusals that mean "no answer from the network".
local DOWN_ERRORS = { EAI_NONAME = true, EAI_AGAIN = true, EAI_FAIL = true, EAI_NODATA = true }

--- The Windows binary-sample reducer.
--- @param previous_up boolean Last accepted state.
--- @param status string "up", "down" or "unknown".
--- @return table { accepted, changed, next_up }
function M.reduce(previous_up, status)
	if status ~= "up" and status ~= "down" then return { accepted = false, changed = false, next_up = previous_up } end
	local next_up = status == "up"
	return { accepted = true, changed = next_up ~= previous_up, next_up = next_up }
end

--- Classifies a getaddrinfo outcome.
--- @param err string|nil libuv error ("EAI_NONAME: ..."), nil on success.
--- @param addresses table|nil Resolved addresses.
--- @return string status
function M.classify_lookup(err, addresses)
	if err == nil then return type(addresses) == "table" and #addresses > 0 and "up" or "down" end
	local code = tostring(err):match("^(EAI_[%u_]+)")
	return DOWN_ERRORS[code] and "down" or "unknown"
end

--- Whether any tunnel interface is up.
--- @param root string The sysfs net directory.
--- @param list fun(path):table|nil Directory entries { name, kind }.
--- @param read fun(path):string|nil First line of a file.
--- @return string status "up", "down" or "unknown".
function M.vpn_status(root, list, read)
	local entries = list(root)
	if entries == nil then return "unknown" end
	for _, entry in ipairs(entries) do
		local kind = tonumber(read(root .. "/" .. entry.name .. "/type") or "")
		local flags = tonumber(read(root .. "/" .. entry.name .. "/flags") or "")
		if (kind == ARPHRD_NONE or kind == ARPHRD_PPP) and flags and flags % 2 == IFF_UP then return "up" end
	end
	return "down"
end

--- Creates the sampler.
--- @param opts table { record fun(kind, fields), lookup fun(host, callback(err, addresses)),
---   vpn fun():string, now_ms fun():number }
--- @return table sampler { tick }
function M.new(opts)
	assert(type(opts) == "table" and type(opts.record) == "function", "the network sampler needs a recorder")
	local reach_ms = Timings.ms("keystats", "network_reach_tick_ms")
	local vpn_ms = Timings.ms("keystats", "network_vpn_tick_ms")
	local state = { internet_up = true, vpn_active = false, next_reach = 0, next_vpn = 0, probing = false }
	local self = {}

	local function apply_internet(status)
		local transition = M.reduce(state.internet_up, status)
		if not transition.accepted then
			Logger.debug(LOG, "Internet state is unknown; keeping the last accepted state.")
			return
		end
		state.internet_up = transition.next_up
		if transition.changed then opts.record(transition.next_up and "internet_up" or "internet_down", {}) end
	end

	--- Starts the due probes. Reachability answers later, through the lookup's callback.
	function self.tick()
		local now = opts.now_ms()
		if now >= state.next_vpn then
			state.next_vpn = now + vpn_ms
			local transition = M.reduce(state.vpn_active, opts.vpn())
			if transition.accepted then
				state.vpn_active = transition.next_up
				if transition.changed then
					opts.record(transition.next_up and "vpn_connected" or "vpn_disconnected", { adapter = "vpn" })
				end
			end
		end
		if now >= state.next_reach and not state.probing then
			state.next_reach = now + reach_ms
			state.probing = true
			local started = pcall(opts.lookup, M.NCSI_HOST, function(err, addresses)
				state.probing = false
				-- The answer arrives from the event loop, outside the tick's guard.
				local applied, reason = pcall(apply_internet, M.classify_lookup(err, addresses))
				if not applied then Logger.error(LOG, "Internet transition not recorded: %s.", tostring(reason)) end
			end)
			if not started then
				state.probing = false
				Logger.warn(LOG, "The Internet reachability probe could not start; the state is kept.")
			end
		end
	end

	return self
end

--- The daemon's ports: libuv's asynchronous getaddrinfo and the sysfs reads.
--- @param record fun(kind, fields) The keystats recorder.
--- @return table sampler
function M.start(record)
	local uv = require("luv")
	local NativeDirectory = require("infra.native_directory")
	local function read(path)
		local handle = io.open(path, "rb")
		if not handle then return nil end
		local line = handle:read("*l")
		handle:close()
		return line
	end
	local sampler = M.new({
		record = record,
		lookup = function(host, callback)
			assert(uv.getaddrinfo(host, nil, { socktype = "stream" }, callback))
		end,
		vpn = function()
			return M.vpn_status("/sys/class/net", function(path) return NativeDirectory.entries(path) end, read)
		end,
		now_ms = function() return require("infra.monotonic").now_ms() end,
	})
	Logger.info(LOG, "Connectivity transitions are recorded.")
	return sampler
end

--- The daemon's tick: starts the one sampler on first use, then runs it.
--- @param record fun(kind, fields) The keystats recorder.
function M.daemon_tick(record)
	if M._disabled then return end
	local ok, reason = pcall(function()
		M._daemon = M._daemon or M.start(record)
		M._daemon.tick()
	end)
	if not ok then
		-- Once, rather than one error per daemon tick.
		M._disabled = true
		Logger.error(LOG, "Connectivity transitions are no longer recorded: %s.", tostring(reason))
	end
end

return M
