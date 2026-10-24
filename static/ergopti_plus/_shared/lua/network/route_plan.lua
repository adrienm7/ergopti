--- _shared/lua/network/route_plan.lua

--- network/route_plan.lua

--- ==============================================================================
--- MODULE: Shared Per-Origin Route Plan
--- DESCRIPTION:
--- Turns the route a native lookup named for each origin of a download client
--- into the one environment a client without a PAC engine can honor: a single
--- relay plus a bypass list of the origins the lookup sent direct. Pure policy;
--- the platform owner supplies the lookups and exports the result.
---
--- FEATURES & RATIONALE:
--- 1. An environment-driven client (uv, a stock Ollama daemon) holds one relay,
---    so two different relays for the origins of one download are refused
---    instead of silently sending a host through the wrong one.
--- 2. A redirect re-evaluates its own target: a host the plan never looked up
---    is refused, because its route is unknown and a guess may leak it.
--- 3. Refusals are a closed enum (route_origins.json "refusals"); neither a
---    URL nor a relay address ever appears in a reason.
--- 4. The Go (go/route_plan/route_plan.go) and shell (network-retry.sh) twins
---    answer the same vectors (tests/corpus/network/route_plan_vectors.json).
--- ==============================================================================

local M = {}

--- The closed refusal reasons.
M.EMPTY = "route-plan-empty"
M.INVALID = "route-plan-invalid"
M.CONFLICT = "route-plan-conflict"
M.UNPLANNED_HOST = "route-plan-unplanned-host"

--- Relay schemes an exported HTTPS_PROXY may carry.
local RELAY_SCHEMES = { http = true, https = true, socks5 = true, socks5h = true }

--- Normalizes a DNS host: lowercase, no trailing dot, plain label characters.
--- @param host string
--- @return string|nil
local function dns_host(host)
	host = host:lower():gsub("%.$", "")
	if host == "" or #host > 253 or host:find("[^%w%.%-]") or host:find("%.%.") then return nil end
	return host
end

--- Parses a plain https origin (no path, query, port or credentials).
--- @param origin any
--- @return string|nil host
local function origin_host(origin)
	if type(origin) ~= "string" then return nil end
	local host = origin:match("^https://([^/?#@:%s]+)$")
	return host and dns_host(host) or nil
end

--- Accepts "direct" or an exportable relay with a port. The schemes are the
--- ones every environment-driven client honors (Go net/http, reqwest); the
--- optional userinfo keeps an authenticated desktop proxy usable, and an
--- apostrophe in it must be percent-encoded.
--- @param route any
--- @return boolean
local function valid_route(route)
	if route == "direct" then return true end
	if type(route) ~= "string" then return false end
	local scheme, rest = route:match("^(%l[%l%d]*)://(.+)$")
	if not RELAY_SCHEMES[scheme] then return false end
	local userinfo, address = rest:match("^([^@]*)@(.*)$")
	if userinfo and (userinfo == "" or userinfo:find("[^%w%._~%%!%$&%(%)%*%+,;=:%-]")) then return false end
	local host, port = (address or rest):match("^([^/%s@]+):(%d+)$")
	if not host or #port > 5 then return false end
	port = tonumber(port)
	if port < 1 or port > 65535 then return false end
	if host:sub(1, 1) == "[" then return host:match("^%[[%x:]+%]$") ~= nil end
	return host:find("[^%w%._%-]") == nil
end

--- Builds a plan from the ordered lookups of one client's origins.
--- @param entries table Array of { origin = "https://host", route = "direct"|relay }.
--- @return table|nil plan, string|nil reason
function M.plan(entries)
	if type(entries) ~= "table" or #entries == 0 then return nil, M.EMPTY end
	local hosts, order = {}, {}
	for _, entry in ipairs(entries) do
		local host = type(entry) == "table" and origin_host(entry.origin) or nil
		if not host or not valid_route(entry.route) then return nil, M.INVALID end
		order[#order + 1] = { host = host, route = entry.route }
	end
	local proxy, direct = nil, {}
	for _, item in ipairs(order) do
		if hosts[item.host] ~= nil and hosts[item.host] ~= item.route then return nil, M.CONFLICT end
		if hosts[item.host] == nil then
			hosts[item.host] = item.route
			if item.route == "direct" then
				direct[#direct + 1] = item.host
			elseif proxy ~= nil and proxy ~= item.route then
				return nil, M.CONFLICT
			else
				proxy = item.route
			end
		end
	end
	local plan = { proxy = proxy or "direct" }

	--- Comma list of the origins the lookup sent direct while a relay is set.
	--- @return string
	function plan.no_proxy()
		return proxy and table.concat(direct, ",") or ""
	end

	--- Re-evaluates one redirect target against the plan.
	--- @param url string Absolute https redirect target.
	--- @return string|nil route "proxy" or "direct", string|nil reason
	function plan.redirect(url)
		if type(url) ~= "string" or url:find("[%c%s\\]") then return nil, M.INVALID end
		local authority = url:match("^https://([^/?#]*)")
		if not authority then return nil, M.INVALID end
		authority = authority:gsub("^.*@", ""):gsub(":%d+$", "")
		local host = authority ~= "" and dns_host(authority) or nil
		if not host then return nil, M.INVALID end
		local route = hosts[host]
		if route == nil then return nil, M.UNPLANNED_HOST end
		return route == "direct" and "direct" or "proxy", nil
	end

	return plan
end

return M
