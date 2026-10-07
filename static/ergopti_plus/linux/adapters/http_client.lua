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
local OutputTarget = require("infra.http_output_target")
local Proxy = require("adapters.system_proxy")
local PolicyBinding = require("infra.proxy_policy")
local RedirectBinding = require("infra.managed_redirect_policy")
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
		policy = policy, proxy = Proxy, curl = Curl.dispatch_owned, redirect = RedirectBinding.load, output = OutputTarget,
		clock = Monotonic.now_ms, deadline = Deadline.start, environment = PolicyBinding.environment,
		prepare_headers = Curl.rebind_prepared_headers,
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
	function operation:settled_result()
		return { ok = false, status = 0, body = "", error = message }
	end
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

--- Validates deliberate managed-hop ownership without guessing caller intent.
--- The scalar is captured only inside owned preparation; legacy ports never
--- gain permission from header values, URLs, owner names or later mutation.
local function redirect_option_error(request, owned_api)
	local affinity = request.etag_affinity
	if affinity ~= nil and type(affinity) ~= "boolean" then return "HTTP ETag affinity option is invalid" end
	if affinity == true and (request.method ~= "GET" or request.buffered ~= true
		or request.follow_redirects ~= true or request.output_path ~= nil or request.output_target ~= nil
		or request.etag_save == nil) then return "HTTP ETag affinity ownership is unavailable" end
	local paired = request.etag_compare ~= nil and request.etag_save ~= nil
	local singleton = (request.etag_compare ~= nil or request.etag_save ~= nil) and not paired
	local managed = request.managed_redirects
	if managed ~= nil and type(managed) ~= "boolean" then return "HTTP managed redirect option is invalid" end
	if managed == true and (owned_api ~= true or request.method ~= "GET" or request.buffered ~= true
		or request.follow_redirects ~= true or request.output_path ~= nil or request.output_target ~= nil or singleton) then
		return "HTTP managed redirect ownership is unavailable"
	end
end

local function retain_redirect_permission(request, native_follow)
	if request.managed_redirects ~= true and request.follow_redirects then
		if type(native_follow) ~= "boolean" then return "HTTP redirect admission unavailable" end
		request.follow_redirects = native_follow
	end
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
	request.single_hop_redirect, request.single_hop_receipt_bytes, request.single_hop_url_bytes = nil, nil, nil
	request.prepared_headers = nil
	request.owner = owner_name(request.owner)
	request.timeout_ms = tonumber(request.timeout_ms) or Curl.default_timeout_ms()
	if request.timeout_ms <= 0 or request.timeout_ms % 1 ~= 0 then return rejected("HTTP timeout is invalid", callback) end
	request.method, request.buffered, request.owned_api = method, buffered, owned_api
	local redirect_refusal = redirect_option_error(request, owned_api)
	if redirect_refusal then return rejected(redirect_refusal, callback) end
	local allowed, err, token, prepared, native_follow = Curl.preflight(url, headers, body, request)
	if not allowed then return rejected(err, callback) end
	if type(token) ~= "table" or type(prepared) ~= "table" then return rejected("HTTP prepared headers unavailable", callback) end
	local permission_refusal = retain_redirect_permission(request, native_follow)
	if permission_refusal then return rejected(permission_refusal, callback) end
	request.prepared_headers, headers = token, prepared
	local active, initialization_refusal = initialize()
	if not active then return rejected(initialization_refusal, callback) end
	return active.start(url, headers, body, request, on_chunk, callback)
end


--- Reserves the captured public owner before caller metadata or source callbacks.
--- The lazy preparation port runs only under the coordinator's exact reservation.
local function dispatch_owned(url, headers, body, options, method, buffered, on_chunk, callback, native_override)
	local authorized
	if type(options) == "table" then authorized = rawget(options, "authorized") end
	if authorized ~= nil and type(authorized) ~= "function" then
		return rejected("owned request authorization is invalid", nil)
	end
	local owner = owner_name(type(options) == "table" and rawget(options, "owner") or nil)
	local timeout = tonumber(type(options) == "table" and rawget(options, "timeout_ms") or nil) or Curl.default_timeout_ms()
	local timeout_valid = timeout > 0 and timeout % 1 == 0 and timeout ~= math.huge
	local absolute_deadline = type(options) == "table" and rawget(options, "absolute_deadline_ms") or nil
	local deadline_valid = absolute_deadline == nil or type(absolute_deadline) == "number"
		and absolute_deadline == absolute_deadline and absolute_deadline >= 0 and absolute_deadline < math.huge
	if method == "POST" and authorized == nil then authorized = function() return true end end
	local active, initialization_refusal = initialize()
	-- Without a coordinator reservation no caller source can authorize delivery.
	if not active then return rejected(initialization_refusal, nil) end
	local request = { owner = owner, timeout_ms = timeout_valid and timeout or 0, method = method, buffered = buffered, owned_api = true,
		absolute_deadline_ms = deadline_valid and absolute_deadline or nil }
	local function prepare()
		if not timeout_valid then return nil, "HTTP timeout is invalid" end
		if not deadline_valid then return nil, "HTTP absolute deadline is invalid" end
		local captured = {}
		if type(options) == "table" then
			for key, value in next, options do captured[key] = value end
		end
		captured.single_hop_redirect, captured.single_hop_receipt_bytes, captured.single_hop_url_bytes = nil, nil, nil
		captured.prepared_headers = nil
		captured.owner, captured.timeout_ms, captured.absolute_deadline_ms = owner, timeout, absolute_deadline
		captured.method, captured.buffered, captured.owned_api = method, buffered, true
		captured.authorized = authorized
		if native_override then
			local override_refusal = native_override(captured)
			if override_refusal then return nil, override_refusal end
		end
		local redirect_refusal = redirect_option_error(captured, true)
		if redirect_refusal then return nil, redirect_refusal end
		local allowed, err, token, prepared, native_follow = Curl.preflight(url, headers, body, captured)
		if not allowed then return nil, err end
		if type(token) ~= "table" or type(prepared) ~= "table" then return nil, "HTTP prepared headers unavailable" end
		local permission_refusal = retain_redirect_permission(captured, native_follow)
		if permission_refusal then return nil, permission_refusal end
		captured.prepared_headers = token
		return captured, nil, prepared
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
--- @return boolean Existing dispatch admission (first return is unchanged).
--- @return table Exact operation; settled_result() exposes only final physical data.
--- The second return is additive and observable; logical callback timing and
--- existing zero-argument on_settled listeners retain their original contracts.
function M.get(url, headers, options, callback)
	local operation = dispatch(url, type(headers) == "table" and headers or {}, nil,
		options, "GET", true, false, nil, callback)
	return operation.started, operation
end

--- Sends a GET retaining actual lookup/curl/process/pipe settlement ownership.
--- managed_redirects=true explicitly selects shared per-hop ownership; the
--- default preserves historical sensitive-header no-follow and HTTP receipts.
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

--- Receives an archive into one caller-owned private parent output target.
--- The exact source is mandatory; lookup/preflight occurs under its reservation.
--- This port cannot authorize path/body/ETag/native-follow or manual per-hop use.
--- @return table Retained physical operation; no writable descriptor is exposed.
function M.download_output_owned(url, headers, target, options, callback)
	local authorized = type(options) == "table" and rawget(options, "authorized") or nil
	if type(authorized) ~= "function" then
		return rejected("owned archive authorization unavailable", nil)
	end
	return dispatch_owned(url, type(headers) == "table" and headers or {}, nil,
		options, "GET", false, nil, callback, function(captured)
			if captured.output_target ~= nil and not rawequal(captured.output_target, target) then
				return "archive output target mismatch"
			end
			if captured.follow_redirects ~= nil and type(captured.follow_redirects) ~= "boolean" then return "archive redirect option is invalid" end
			captured.archive_redirects = captured.follow_redirects == true
			captured.output_target, captured.follow_redirects = target, false
		end)
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
