--- _shared/lua/network/http_redirect.lua

--- ==============================================================================
--- MODULE: Shared Buffered GET Redirect Policy
--- DESCRIPTION:
--- Preserves bounded native observations and exact ownership receipts.
--- ==============================================================================

--- Pure shared buffered-GET redirect admission. Native curl resolves Location;
--- this policy admits only that completed single-hop observation.
local M = {}

local function integer(value, minimum, maximum)
	return type(value) == "number" and value == value and value >= minimum
		and value <= maximum and value % 1 == 0
end

local function copy_headers(headers, sensitive, strip)
	local result = {}
	for name, value in pairs(headers) do
		if not strip or not sensitive[tostring(name):lower()] then result[name] = value end
	end
	return result
end

local function ipv6(value)
	if value:find(".", 1, true) then
		local prefix, a, b, c, d = value:match("^(.*:)(%d+)%.(%d+)%.(%d+)%.(%d+)$")
		if not prefix then return false end
		for _, octet in ipairs({ a, b, c, d }) do
			if #octet > 3 or not integer(tonumber(octet), 0, 255) then return false end
		end
		value = prefix .. "0:0"
	end
	local compression = value:find("::", 1, true)
	if compression and value:find("::", compression + 2, true) then return false end
	local left, right = value, ""
	if compression then left, right = value:sub(1, compression - 1), value:sub(compression + 2) end
	local count = 0
	for _, part in ipairs({ left, right }) do
		if part ~= "" then
			if part:sub(1, 1) == ":" or part:sub(-1) == ":" then return false end
			for group in part:gmatch("[^:]+") do
				if #group > 4 or not group:match("^%x+$") then return false end
				count = count + 1
			end
		end
	end
	return compression and count < 8 or not compression and count == 8
end

--- Parses the authority of an already absolute native-resolved HTTP URL.
--- Unsupported authority forms are explicit refusal, never a guessed origin.
local function address(url, maximum)
	if type(url) ~= "string" or url == "" or #url > maximum
		or url:find("[%z\1-\32\127\\]") then return nil end
	local scheme, authority, rest = url:match("^([%a][%w+%.%-]*)://([^/?#]*)(.*)$")
	if not scheme or authority == "" or authority:find("@", 1, true) then return nil end
	scheme = scheme:lower()
	local host, port
	if authority:sub(1, 1) == "[" then
		local inside, suffix = authority:match("^%[([%x:%.]+)%](.*)$")
		if not inside or not ipv6(inside) then return nil end
		host = "[" .. inside:lower() .. "]"
		if suffix ~= "" then port = suffix:match("^:(%d+)$"); if not port then return nil end end
	else
		host, port = authority:match("^([%w_%.%-]+):(%d+)$")
		if not host then
			if not authority:match("^[%w_%.%-]+$") then return nil end
			host = authority
		end
		host = host:lower()
	end
	if port then
		-- Ports are bounded16-bit data; this is not an inode/uint64 conversion.
		port = port:gsub("^0+", "")
		if port == "" then port = "0" end
		if #port > 5 then return nil end
		port = tonumber(port)
		if not integer(port, 1, 65535) then return nil end
	else port = scheme == "https" and 443 or scheme == "http" and 80 or nil end
	local origin = scheme .. "://" .. host .. (port and ":" .. tostring(port) or "")
	local path = rest:gsub("#.*$", "")
	if path == "" then path = "/" elseif path:sub(1, 1) == "?" then path = "/" .. path end
	return { scheme = scheme, origin = origin, key = origin .. path }
end

--- Constructs a pure policy from canonical redirect and transport data.
--- No file, clock, subprocess, descriptor or callback is acquired here.
function M.new(redirect_data, transport_data)
	local law = type(redirect_data) == "table" and redirect_data.buffered_get
	local names = type(redirect_data) == "table" and redirect_data.sensitive_headers
	local schemes = type(transport_data) == "table" and transport_data.allowed_schemes
	if type(law) ~= "table" or law.format ~= "curl-single-hop-v1"
		or not integer(law.status_min, 300, 300) or not integer(law.status_max, 399, 399)
		or not integer(law.max_hops, 1, 1000) or not integer(law.max_url_bytes, 1, 65536)
		or not integer(law.max_native_receipt_bytes, 1, 65536)
		or type(names) ~= "table" or #names == 0 or type(schemes) ~= "table" or #schemes == 0 then
		return nil, "HTTP redirect policy unavailable"
	end
	local sensitive, protocols, header_count, scheme_count = {}, {}, 0, 0
	for index, name in pairs(names) do
		if not integer(index, 1, #names) or type(name) ~= "string"
			or not name:match("^[a-z][a-z0-9%-]*$") or sensitive[name] then
			return nil, "HTTP redirect policy unavailable"
		end
		sensitive[name] = true
		header_count = header_count + 1
	end
	for index, scheme in pairs(schemes) do
		if not integer(index, 1, #schemes) or (scheme ~= "http" and scheme ~= "https") or protocols[scheme] then
			return nil, "HTTP redirect policy unavailable"
		end
		protocols[scheme] = true
		scheme_count = scheme_count + 1
	end
	if header_count ~= #names or scheme_count ~= #schemes then return nil, "HTTP redirect policy unavailable" end
	-- Freeze canonical scalar admission; callers cannot mutate this policy later.
	local status_min, status_max = law.status_min, law.status_max
	local max_hops, max_url_bytes = law.max_hops, law.max_url_bytes
	local policy = { format = law.format, max_native_receipt_bytes = law.max_native_receipt_bytes, max_url_bytes = max_url_bytes }
	function policy.address(url) return address(url, max_url_bytes) end
	function policy.transition(input)
		if type(input) ~= "table" or type(input.result) ~= "table" or type(input.https_floor) ~= "boolean" then
			return { action = "refuse", error = "HTTP redirect receipt refused" }
		end
		local status = input.result.status
		local redirect = integer(status, status_min, status_max)
		-- Preserve primary native/HTTP failures. Successful terminal responses
		-- still require the completed single-hop observation; absence is not ACK.
		if input.result.ok ~= true and not redirect then return { action = "terminal" } end
		local failure = input.result.failure_receipt
		if input.result.ok ~= true and type(failure) == "table"
			and type(failure.curl_exit) == "number" and failure.curl_exit ~= 0 then
			return { action = "terminal" }
		end
		local receipt = input.result.redirect_receipt
		if type(receipt) ~= "table" or receipt.format ~= "curl-single-hop-v1"
			or receipt.http_status ~= status or not integer(receipt.curl_exit, 0, 255)
			or receipt.num_redirects ~= 0 or type(receipt.redirect_url) ~= "string"
			or type(receipt.effective_url) ~= "string" then
			return { action = "refuse", error = "HTTP redirect receipt refused" }
		end
		if receipt.curl_exit ~= 0 then
			if input.result.ok ~= true then return { action = "terminal" } end
			return { action = "refuse", error = "HTTP redirect receipt refused" }
		end
		local current = address(receipt.effective_url, max_url_bytes)
		local requested = address(input.current_url, max_url_bytes)
		if not current or not requested or current.origin ~= requested.origin then
			return { action = "refuse", error = "HTTP redirect URL refused" }
		end
		if not protocols[current.scheme] then return { action = "refuse", error = "HTTP redirect protocol refused" } end
		if not redirect or receipt.redirect_url == "" then return { action = "terminal" } end
		local target_scheme = receipt.redirect_url:match("^([%a][%w+%.%-]*):")
		if target_scheme and not protocols[target_scheme:lower()] then
			return { action = "refuse", error = "HTTP redirect protocol refused" }
		end
		local target = address(receipt.redirect_url, max_url_bytes)
		if not target then
			return { action = "refuse", error = "HTTP redirect URL refused" }
		end
		if not protocols[target.scheme] or not protocols[current.scheme]
			or (input.https_floor == true and target.scheme ~= "https") then
			return { action = "refuse", error = "HTTP redirect protocol refused" }
		end
		if not integer(input.hops, 0, max_hops) then return { action = "refuse", error = "HTTP redirect limit reached" } end
		if input.hops == max_hops then return { action = "refuse", error = "HTTP redirect limit reached" } end
		if type(input.visited) ~= "table" or input.visited[target.key] or target.key == current.key then
			return { action = "refuse", error = "HTTP redirect loop refused" }
		end
		if type(input.headers) ~= "table" then return { action = "refuse", error = "HTTP redirect receipt refused" } end
		return {
			action = "follow", method = "GET", url = receipt.redirect_url, key = target.key,
			headers = copy_headers(input.headers, sensitive, current.origin ~= target.origin),
			hops = input.hops + 1,
			https_floor = input.https_floor == true,
		}
	end
	return policy
end

return M
