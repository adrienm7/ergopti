--- adapters/http_client.lua

--- ==============================================================================
--- MODULE: Managed HttpClient Adapter (Linux)
--- DESCRIPTION:
--- Routes actual public HTTP requests through shared enterprise-network policy,
--- owned native desktop proxy admission and the existing isolated curl engine.
--- Public boolean ports retain logical publication while owned GET retains
--- physical settlement. Same-owner successors wait for actual retirement.
--- ==============================================================================

local M = {}
local Curl = require("adapters.curl_http_client")
local Proxy = require("adapters.system_proxy")
local PolicyBinding = require("infra.proxy_policy")
local Managed = require("infra.managed_http")
local Monotonic = require("infra.monotonic")
local Deadline = require("infra.managed_http_deadline")
local Logger = require("logger.shim")
local LOG = "adapters.http_client"
local initialized, coordinator, initialization_error = false, nil, nil

M.HAS_ASYNC = Curl.HAS_ASYNC


-- =========================================
-- =========================================
-- ======= 1/ Native Binding ===============
-- =========================================
-- =========================================

--- Initializes the one native coordinator without starting any subprocess.
--- @return table|nil
--- @return string|nil
local function initialize()
	if initialized then return coordinator, initialization_error end
	initialized = true
	local policy, err = PolicyBinding.load()
	if not policy then initialization_error = err; return nil, err end
	coordinator, initialization_error = Managed.new({
		policy = policy, proxy = Proxy, curl = Curl.dispatch_owned,
		clock = Monotonic.now_ms, deadline = Deadline.start, environment = PolicyBinding.environment,
		report = function(message) Logger.error(LOG, "%s", message) end,
	})
	return coordinator, initialization_error
end

--- Normalizes the existing public owner alias without inventing new scopes.
--- @param owner any
--- @return string
local function owner_name(owner)
	return type(owner) == "string" and owner ~= "" and owner or "default"
end

--- Publishes a preflight refusal with no acquired native resources.
--- @param message string
--- @param callback function|nil
--- @return table
local function rejected(message, callback)
	local operation = { started = false }
	function operation:is_settled() return true end
	function operation:cancel() return true end
	function operation:on_settled(listener)
		if type(listener) ~= "function" then return false end
		local ok = pcall(listener)
		if not ok then Logger.error(LOG, "HTTP refusal settlement callback raised.") end
		return true
	end
	if type(callback) == "function" then
		local ok = pcall(callback, { ok = false, status = 0, body = "", error = message })
		if not ok then Logger.error(LOG, "HTTP refusal callback raised.") end
	end
	return operation
end

--- Starts one fully preflighted actual public request.
--- @param url string
--- @param headers table
--- @param body string|nil
--- @param options table|nil
--- @param method string
--- @param buffered boolean
--- @param owned_api boolean
--- @param on_chunk function|nil
--- @param callback function
--- @return table
local function dispatch(url, headers, body, options, method, buffered, owned_api, on_chunk, callback)
	local request = {}
	for key, value in pairs(type(options) == "table" and options or {}) do request[key] = value end
	request.owner = owner_name(request.owner)
	request.timeout_ms = tonumber(request.timeout_ms) or Curl.default_timeout_ms()
	if request.timeout_ms <= 0 or request.timeout_ms % 1 ~= 0 then return rejected("HTTP timeout is invalid", callback) end
	request.method, request.buffered, request.owned_api = method, buffered, owned_api
	local allowed, err = Curl.preflight(url, headers, body, request)
	if not allowed then return rejected(err, callback) end
	local active, initialization_refusal = initialize()
	if not active then return rejected(initialization_refusal, callback) end
	return active.start(url, headers, body, request, on_chunk, callback)
end


--- Reserves the captured public owner before caller metadata or source callbacks.
--- The lazy preparation port runs only under the coordinator's exact reservation.
local function dispatch_owned(url, headers, body, options, method, buffered, on_chunk, callback)
	local authorized
	if type(options) == "table" then authorized = rawget(options, "authorized") end
	if authorized ~= nil and type(authorized) ~= "function" then
		return rejected("owned request authorization is invalid", nil)
	end
	local owner = owner_name(type(options) == "table" and rawget(options, "owner") or nil)
	local timeout = tonumber(type(options) == "table" and rawget(options, "timeout_ms") or nil) or Curl.default_timeout_ms()
	local timeout_valid = timeout > 0 and timeout % 1 == 0 and timeout ~= math.huge
	if method == "POST" and authorized == nil then authorized = function() return true end end
	local active, initialization_refusal = initialize()
	-- Without a coordinator reservation no caller source can authorize delivery.
	if not active then return rejected(initialization_refusal, nil) end
	local request = { owner = owner, timeout_ms = timeout_valid and timeout or 0, method = method, buffered = buffered, owned_api = true }
	local function prepare()
		if not timeout_valid then return nil, "HTTP timeout is invalid" end
		local captured = {}
		if type(options) == "table" then
			for key, value in next, options do captured[key] = value end
		end
		captured.owner, captured.timeout_ms = owner, timeout
		captured.method, captured.buffered, captured.owned_api = method, buffered, true
		captured.authorized = authorized
		local allowed, err = Curl.preflight(url, headers, body, captured)
		if not allowed then return nil, err end
		return captured
	end
	return active.start(url, headers, body, request, on_chunk, callback,
		{ authorized = authorized, prepare = prepare })
end






-- =========================================
-- =========================================
-- ======= 2/ Existing Adapter Ports =======
-- =========================================
-- =========================================

--- Sends a buffered POST through actual managed network admission.
--- @param url string
--- @param headers table
--- @param body string
--- @param callback function
--- @param options table|nil
--- @return boolean Logical dispatch acceptance.
function M.post(url, headers, body, callback, options)
	return dispatch(url, type(headers) == "table" and headers or {}, type(body) == "string" and body or "",
		options, "POST", true, false, nil, callback).started
end

--- Sends a buffered GET while preserving the existing boolean port signature.
--- @param url string
--- @param headers table
--- @param options table|nil
--- @param callback function
--- @return boolean
function M.get(url, headers, options, callback)
	return dispatch(url, type(headers) == "table" and headers or {}, nil,
		options, "GET", true, false, nil, callback).started
end

--- Sends a GET retaining actual lookup/curl/process/pipe settlement ownership.
--- @param url string
--- @param headers table
--- @param options table|nil
--- @param callback function
--- @return table Operation with the existing colon cancellation/settlement API.
function M.get_owned(url, headers, options, callback)
	return dispatch_owned(url, type(headers) == "table" and headers or {}, nil,
		options, "GET", true, nil, callback)
end

--- Streams a POST under the same managed route and captured source reservation.
--- @return table Retained colon-API operation; cancellation remains physical.
function M.post_stream_owned(url, headers, body, options, on_chunk, on_done)
	return dispatch_owned(url, type(headers) == "table" and headers or {}, type(body) == "string" and body or "",
		options, "POST", false, on_chunk, on_done)
end

--- Downloads to a caller-owned native temporary destination.
--- @param url string
--- @param headers table
--- @param destination string
--- @param options table|nil
--- @param callback function
--- @return boolean
function M.download(url, headers, destination, options, callback)
	if type(destination) ~= "string" or destination:sub(1, 1) ~= "/" then
		return rejected("invalid download path", callback).started
	end
	local request = {}
	for key, value in pairs(type(options) == "table" and options or {}) do request[key] = value end
	request.output_path, request.follow_redirects = destination, true
	return dispatch(url, type(headers) == "table" and headers or {}, nil,
		request, "GET", true, false, nil, callback).started
end

--- Sends streaming POST through the same actual managed admission owner.
--- @param url string
--- @param headers table
--- @param body string
--- @param options table|nil
--- @param on_chunk function
--- @param on_done function
--- @return boolean
function M.postStream(url, headers, body, options, on_chunk, on_done)
	return dispatch(url, type(headers) == "table" and headers or {}, type(body) == "string" and body or "",
		options, "POST", false, false, on_chunk, on_done).started
end

--- Preserves logical native cancellation while physical ownership is retained.
--- @param owner string|nil
--- @return boolean
function M.cancel(owner)
	return not coordinator or coordinator.cancel(owner_name(owner))
end

--- Reports logical activity across lookup, active curl and a queued successor.
--- Native settlement remains separately observable through the owned operation.
--- @param owner string|nil
--- @return boolean
function M.isActive(owner)
	return coordinator ~= nil and coordinator.is_active(owner_name(owner))
end

return M
