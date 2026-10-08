--- _shared/lua/network/proxy_policy.lua

--- network/proxy_policy.lua

--- ==============================================================================
--- MODULE: Shared Native Proxy Routing Policy
--- DESCRIPTION:
--- Interprets one validated canonical routing inventory without native calls.
--- Environment precedence, loopback admission and ordered failover are shared;
--- native adapters supply actual selections and positively verified receipts.
--- ==============================================================================

local M = {}

--- Validates a dense nonempty inventory and returns its membership set.
--- @param values table
--- @return table|nil
local function inventory(values)
	if type(values) ~= "table" or #values == 0 then return nil end
	local set, count = {}, 0
	for key, value in pairs(values) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #values
			or type(value) ~= "string" or value == "" or set[value] then return nil end
		set[value], count = true, count + 1
	end
	return count == #values and set or nil
end

--- Parses an admitted HTTP authority without exposing request data.
--- @param url string
--- @return string|nil scheme, string|nil host
local function authority(url)
	if type(url) ~= "string" or url:find("[%z\r\n]") then return nil end
	local scheme, value = url:match("^([%a][%w+%.%-]*)://([^/?#]+)")
	if not scheme then return nil end
	value = value:gsub("^.*@", "")
	local host
	if value:sub(1, 1) == "[" then
		local suffix
		host, suffix = value:match("^%[([^%]]+)%](.*)$")
		if not host or (suffix ~= "" and not suffix:match("^:%d+$")) then return nil end
	else
		host = value:match("^(.-):%d+$") or value
		if host:find(":", 1, true) or host == "" then return nil end
	end
	host = host:lower():gsub("%.$", "")
	return scheme:lower(), host
end

--- Expands an IPv6 address for policy comparison without resolving DNS.
--- @param address string
--- @return string|nil
local function ipv6(address)
	if not address:find(":", 1, true) or address:find("[^%x:]") or address:find(":::" , 1, true) then return nil end
	local left, right = address:match("^(.-)::(.-)$")
	if right and right:find("::", 1, true) then return nil end
	local words = {}
	local function append(part)
		if part == "" then return true end
		if part:sub(1, 1) == ":" or part:sub(-1) == ":" then return false end
		for word in part:gmatch("[^:]+") do
			if #word > 4 then return false end
			words[#words + 1] = tonumber(word, 16)
		end
		return true
	end
	if left then
		if not append(left) then return nil end
		local first_count = #words
		local tail = {}
		if right ~= "" and (right:sub(1, 1) == ":" or right:sub(-1) == ":") then return nil end
		for word in right:gmatch("[^:]+") do
			if #word > 4 then return nil end
			tail[#tail + 1] = tonumber(word, 16)
		end
		if first_count + #tail >= 8 then return nil end
		for _ = 1, 8 - first_count - #tail do words[#words + 1] = 0 end
		for _, word in ipairs(tail) do words[#words + 1] = word end
	elseif not append(address) or #words ~= 8 then return nil end
	return #words == 8 and table.concat(words, ":") or nil
end

--- Parses a standard dotted IPv4 address to a numeric inventory value.
--- @param address string
--- @return number|nil
local function ipv4(address)
	local words = {}
	for word in address:gmatch("[^%.]+") do
		if not word:match("^%d+$") or #word > 3 or (#word > 1 and word:sub(1, 1) == "0") then return nil end
		local value = tonumber(word)
		if value > 255 then return nil end
		words[#words + 1] = value
	end
	if #words ~= 4 or address:sub(1, 1) == "." or address:sub(-1) == "." or address:find("..", 1, true) then return nil end
	return ((words[1] * 256 + words[2]) * 256 + words[3]) * 256 + words[4]
end

--- Creates an initialized policy interpreter or explicitly refuses bad data.
--- @param data table Canonical policy decoded by the caller's native owner.
--- @return table|nil policy, string|nil error
function M.new(data)
	local function invalid() return nil, "proxy-policy-invalid" end
	if type(data) ~= "table" or data.schema_version ~= 1 or type(data.environment_precedence) ~= "table"
		or type(data.loopback) ~= "table" or type(data.failover) ~= "table"
		or data.missing_native_capability ~= "environment"
		or data.selected_proxy_bypass ~= "environment" then return invalid() end
	local schemes = inventory(data.allowed_proxy_schemes)
	local hosts = inventory(data.loopback.dns_hosts)
	local suffixes = inventory(data.loopback.dns_suffixes)
	local v4_ranges = inventory(data.loopback.ipv4_cidrs)
	local v6_names = inventory(data.loopback.ipv6_addresses)
	if not schemes or not hosts or not suffixes or not v4_ranges or not v6_names then return invalid() end
	if type(data.max_selections) ~= "number" or data.max_selections < 1 or data.max_selections % 1 ~= 0
		or type(data.max_proxy_bytes) ~= "number" or data.max_proxy_bytes < 1 or data.max_proxy_bytes % 1 ~= 0 then return invalid() end
	local max_selections, max_proxy_bytes = data.max_selections, data.max_proxy_bytes
	local missing_capability = data.missing_native_capability
	local selected_proxy_bypass = data.selected_proxy_bypass
	local unavailable_errors = inventory(data.unavailable_native_errors)
	if not unavailable_errors then return invalid() end
	for code in pairs(unavailable_errors) do
		if not code:match("^proxy%-%l[%l%-]*%-unavailable$") then return invalid() end
	end
	local env_orders = {}
	if not inventory(data.system_lookup_environment_exclusions) then return invalid() end
	local exclusions = {}
	for index, name in ipairs(data.system_lookup_environment_exclusions) do
		if not name:match("^[%a_][%w_]*$") then return invalid() end
		exclusions[index] = name
	end
	for scheme, order in pairs(data.environment_precedence) do
		if type(scheme) ~= "string" or not inventory(order) then return invalid() end
		env_orders[scheme] = {}
		for index, name in ipairs(order) do
			if not name:match("^[%a_][%w_]*$") then return invalid() end
			env_orders[scheme][index] = name
		end
	end
	if not env_orders.http or not env_orders.https then return invalid() end
	local ranges, v6 = {}, {}
	for name in pairs(v4_ranges) do
		local base, bits = name:match("^([^/]+)/(%d+)$")
		base, bits = base and ipv4(base), tonumber(bits)
		if not base or not bits or bits < 0 or bits > 32 then return invalid() end
		local block = 2 ^ (32 - bits)
		if base % block ~= 0 then return invalid() end
		ranges[#ranges + 1] = { base = base, block = block }
	end
	for name in pairs(v6_names) do
		local expanded = ipv6(name)
		if not expanded then return invalid() end
		v6[expanded] = true
	end
	local function exit_inventory(values)
		if type(values) ~= "table" or #values == 0 then return nil end
		local result, count = {}, 0
		for index, code in pairs(values) do
			if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #values
				or type(code) ~= "number" or code < 1 or code % 1 ~= 0 or result[code] then return nil end
			result[code], count = true, count + 1
		end
		return count == #values and result or nil
	end
	local name_exits = exit_inventory(data.failover.proxy_name_resolution_exits)
	local connect_exits = exit_inventory(data.failover.proxy_connect_exits)
	if not name_exits or not connect_exits then return invalid() end
	for _, key in ipairs({ "requires_zero_http_status", "requires_zero_connect_status", "requires_no_delivered_bytes",
		"requires_verified_native_receipt", "connect_requires_actual_proxy_used" }) do
		if data.failover[key] ~= true then return invalid() end
	end
	local policy = {}

	--- Returns only the canonical native environment names, never their values.
	--- @return table
	function policy.environment_names()
		local names, seen = {}, {}
		for _, order in pairs(env_orders) do
			for _, name in ipairs(order) do
				if not seen[name] then names[#names + 1], seen[name] = name, true end
			end
		end
		table.sort(names)
		return names
	end

	--- Selects an environment/DIRECT fast path or an actual native lookup.
	--- @param url string
	--- @param environment table Private native environment snapshot.
	--- @return table|nil route, string|nil error
	function policy.route(url, environment)
		local scheme, host = authority(url)
		if not scheme or not env_orders[scheme] or type(environment) ~= "table" then return nil, "proxy-route-invalid" end
		local local_host = hosts[host] == true
		for suffix in pairs(suffixes) do
			if #host > #suffix and host:sub(-#suffix) == suffix then local_host = true end
		end
		local address = ipv4(host)
		if address then
			for _, range in ipairs(ranges) do
				if address >= range.base and address < range.base + range.block then local_host = true end
			end
		end
		local expanded = ipv6(host)
		if expanded and v6[expanded] then local_host = true end
		if local_host then return { mode = "direct" } end
		for _, name in ipairs(env_orders[scheme]) do
			local value = environment[name]
			if type(value) == "string" and value ~= "" then return { mode = "environment" } end
		end
		local native_exclusions = {}
		for index, name in ipairs(exclusions) do native_exclusions[index] = name end
		return { mode = "system", environment_exclusions = native_exclusions }
	end

	--- Validates and preserves the complete ordered native selection.
	--- @param receipt table Native GIO selection receipt.
	--- @return table|nil choices, string|nil error
	function policy.selection(receipt)
		if type(receipt) ~= "table" or type(receipt.ok) ~= "boolean" then return nil, "proxy-selection-invalid" end
		if receipt.ok == false then
			-- Only the native helper's explicit capability-absence ACK can admit
			-- ordinary curl routing. Lookup/supervision/packet failures are refusal.
			if type(receipt.error) ~= "string" then return nil, "proxy-selection-invalid" end
			if unavailable_errors[receipt.error] then
				return { { mode = missing_capability, capability = "unavailable" } }
			end
			if not receipt.error:match("^proxy%-%l[%l%-]+$") then return nil, "proxy-selection-invalid" end
			return nil, receipt.error
		end
		local values = receipt.proxies
		if type(values) ~= "table" or #values == 0 or #values > max_selections then return nil, "proxy-selection-invalid" end
		local choices, count = {}, 0
		for index, value in pairs(values) do
			if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #values
				or type(value) ~= "string" or value == "" or #value > max_proxy_bytes or value:find("[%z\r\n]") then
				return nil, "proxy-selection-invalid"
			end
			if value == "direct://" then choices[index] = { mode = "direct" }
			else
				local scheme, host = authority(value)
				if not scheme or not host or not schemes[scheme] then return nil, "proxy-selection-unsupported" end
				choices[index] = { mode = "selected", proxy = value, bypass = selected_proxy_bypass }
			end
			count = count + 1
		end
		return count == #values and choices or nil, count ~= #values and "proxy-selection-invalid" or nil
	end

	--- Admits only verified pre-response proxy failures to ordered relay.
	--- @param receipt table Safe typed native receipt.
	--- @param state table Trusted coordinator state.
	--- @return boolean
	function policy.can_retry(receipt, state)
		if type(receipt) ~= "table" or type(state) ~= "table" or state.selection_mode ~= "selected"
			or state.delivered_bytes ~= 0 or receipt.backend ~= "curl" or receipt.failure_provenance ~= "verified"
			or receipt.http_status ~= 0 or receipt.proxy_connect_status ~= 0 then return false end
		if receipt.stage == "proxy_resolve" and name_exits[receipt.curl_exit] then return true end
		return receipt.stage == "proxy_connect" and connect_exits[receipt.curl_exit] == true and state.proxy_used == true
	end
	return policy
end

return M
