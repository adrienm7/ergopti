--- adapters/http_client.lua

--- ==============================================================================
--- MODULE: HttpClient Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the HttpClient port contract defined in
--- static/ergopti_plus/_shared/core/ports/HttpClient.spec.js. Wraps hs.http's
--- asynchronous request primitives and URL component encoding behind a stable adapter surface
--- so domain modules can make HTTP requests without a direct dependency on hs.http.
---
--- FACTORY PATTERN:
--- require("adapters.http_client").new(options) returns a fresh independent instance.
--- Each LLM backend owns its own instance so concurrent requests from different
--- backends do not cancel each other (the old singleton model allowed api_mlx's
--- warmup to cancel api_ollama's in-flight request).
--- The module table M itself is also a valid default singleton for callers that
--- only ever have one concurrent request at a time.
---
--- FEATURES & RATIONALE:
--- 1. Async with callback: hs.http is non-blocking. The callback is always
---    deferred to the next runloop cycle. Signature: { ok, status, body, error },
---    plus headers (the response headers, possibly empty) on a completed response.
--- 2. Cancel via task reference: when asyncPost/asyncGet return a cancellable
---    task, the adapter holds it so cancel() can abort in-flight work. The
---    generation fence suppresses completion even when no task is returned.
--- 3. One request at a time per instance: a second post()/get() call while
---    isActive() is true cancels the previous request first.
--- 4. Timeout enforcement: a TimerScheduler transaction must commit before the
---    network request is dispatched. Exact cleanup debt blocks every successor.
--- 5. encodeForQuery: uses hs.http.encodeForQuery when available and a local
---    RFC 3986 component encoder after a reported native refusal, so callers
---    never receive raw query syntax disguised as an encoded value.
--- 6. encodePathSegment: always applies the deterministic RFC 3986 encoder;
---    query-specific native substitutions can never leak into a URL path.
--- 7. Generation guard: cancel()'s doc claims it "synchronously and
---    unconditionally" prevents a superseded callback from firing, but
---    hs.http.asyncPost/asyncGet may already have queued their OS-level
---    completion before cancel() runs (the task handle does not guarantee
---    the underlying native connection callback is aborted in time). Each
---    post()/get() call is stamped with a monotonic generation captured by
---    its own wrapped callback; the callback checks it against the
---    instance's current generation before delivering, so a stale callback
---    from a superseded request (e.g. a warmup POST outlived by a real
---    inference POST sharing the same instance) is discarded instead of
---    delivering its result to the wrong caller. Mirrors modules/updater/init.lua's
---    _poll_generation pattern.
--- 8. Redirect ownership: requests carrying caller credentials, and every HTTPS
---    request, disable the native opaque auto-follow path. Same-origin hops
---    retain credentials; cross-origin hops strip them before dispatch,
---    HTTPS never downgrades to HTTP, and a hop back to an earlier URL is refused.
--- 9. Admission first: the URL (absolute HTTP/HTTPS, no control byte), headers
---    and body are validated before a replacement cancels the request in flight.
--- ==============================================================================

local hs             = hs
local Logger         = require("infra.logger")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "adapters.http_client"
local CACHE_POLICIES = {
	protocolCachePolicy = true, ignoreLocalCache = true, ignoreLocalAndRemoteCache = true,
	returnCacheOrLoad = true, returnCacheDontLoad = true, reloadRevalidatingCache = true,
}


--- Invokes a completion callback so a throw inside it cannot vanish.
---
--- Every response path here handed its result to the caller through a bare
--- `pcall(callback, …)` whose status was never inspected. That is not error
--- handling, it is error deletion: a throw in the LLM response handler — a
--- parser choking on a malformed body, a renderer hitting a nil field — became
--- indistinguishable from a request that never completed. No prediction, no
--- error, nothing to search the log for.
---
--- xpcall with a traceback rather than plain pcall: by the time the error
--- surfaces the stack is gone, and the traceback is the only thing that says
--- where the callback failed. The error is contained rather than rethrown
--- because these run from HTTP completion handlers and timer callbacks, where
--- an escaping exception is reported far from its cause.
--- @param callback function|nil The completion callback; a non-function is a no-op.
--- @param result table The response table to deliver.
local function invoke_callback(callback, result)
	if type(callback) ~= "function" then return end
	local ok, err = xpcall(function() return callback(result) end, debug.traceback)
	if not ok then
		Logger.error(LOG, "Completion callback raised: %s. This request is abandoned — nothing "
			.. "downstream retries it.", tostring(err))
	end
end



-- =========================================
-- =========================================
-- ======= 1/ Constants ====================
-- =========================================
-- =========================================

-- Timeout in milliseconds; matches HttpClient.spec.js DEFAULT_TIMEOUT_MS.
local DEFAULT_TIMEOUT_MS = 30000

-- Conversion factor from milliseconds to scheduler seconds
local MS_PER_SEC = 1000

-- Stable adapter errors let callers distinguish acquisition from expiry
local TIMEOUT_ERROR                 = "timeout"
local TIMEOUT_UNAVAILABLE_ERROR     = "timeout unavailable"
local TIMEOUT_CLEANUP_PENDING_ERROR = "timeout cleanup pending"

-- The shared redirect law's buffered_get.max_hops (data/http/redirect_policy.json),
-- pinned by tools/test/test-port-compliance.cjs. Kept literal so loading the
-- adapter never depends on finding the shared tree.
local MAX_REDIRECTS = 50

local REDIRECT_STATUSES = {
	[301] = true,
	[302] = true,
	[303] = true,
	[307] = true,
	[308] = true,
}

local SENSITIVE_HEADERS = {
	["api-key"] = true,
	["authorization"] = true,
	["cookie"] = true,
	["cookie2"] = true,
	["proxy-authorization"] = true,
	["x-api-key"] = true,
	["x-goog-api-key"] = true,
}

local ENTITY_HEADERS = {
	["content-length"] = true,
	["content-type"] = true,
	["transfer-encoding"] = true,
}

--- Returns one header value without trusting its original case.
--- @param headers table|nil Header map.
--- @param wanted string Lowercase header name.
--- @return string|nil value
local function header_value(headers, wanted)
	if type(headers) ~= "table" then return nil end
	for key, value in pairs(headers) do
		if type(key) == "string" and key:lower() == wanted
			and type(value) == "string" then
			return value
		end
	end
	return nil
end

--- Returns whether a caller supplied any credential-bearing header.
--- @param headers table|nil Header map.
--- @return boolean sensitive
local function has_sensitive_headers(headers)
	if type(headers) ~= "table" then return false end
	for key in pairs(headers) do
		if type(key) == "string" and SENSITIVE_HEADERS[key:lower()] then
			return true
		end
	end
	return false
end

--- Copies headers while applying the redirect's security and method policy.
--- @param headers table|nil Source headers.
--- @param strip_sensitive boolean Whether the next hop changed origin.
--- @param strip_entity boolean Whether the redirect converted the request to GET.
--- @return table copied
local function redirect_headers(headers, strip_sensitive, strip_entity)
	local copied = {}
	for key, value in pairs(type(headers) == "table" and headers or {}) do
		local lower = type(key) == "string" and key:lower() or ""
		if not (strip_sensitive and SENSITIVE_HEADERS[lower])
			and not (strip_entity and ENTITY_HEADERS[lower]) then
			copied[key] = value
		end
	end
	return copied
end

--- Parses the security-relevant components of an absolute HTTP URL.
--- @param url string Candidate absolute URL.
--- @return table|nil parsed
--- @return string|nil detail
local function parse_http_url(url)
	if type(url) ~= "string" or url == "" or url:find("[%c%s\\]") then
		return nil, "redirect URL is malformed"
	end
	local scheme, authority, tail = url:match("^([%a][%w+%.%-]*)://([^/?#]+)(.*)$")
	if not scheme or not authority or authority:find("@", 1, true) then
		return nil, "redirect URL has no safe authority"
	end
	scheme = scheme:lower()
	if scheme ~= "http" and scheme ~= "https" then
		return nil, "redirect URL uses an unsupported scheme"
	end

	local host, port
	if authority:sub(1, 1) == "[" then
		host, port = authority:match("^(%[[^%]]+%]):?(%d*)$")
	else
		host, port = authority:match("^([^:]+):?(%d*)$")
	end
	if not host or host == "" then return nil, "redirect URL has no host" end
	if port == "" then port = scheme == "https" and "443" or "80" end
	-- The shared redirect law admits ports 1 to 65535 and compares them as
	-- numbers, so a padded spelling names the same origin.
	port = port:match("^0*(%d+)$")
	local number = port and #port <= 5 and tonumber(port)
	if not number or number < 1 or number > 65535 then
		return nil, "redirect URL has an invalid port"
	end
	port = tostring(number)
	local path = tail:match("^([^?#]*)") or ""
	if path == "" then path = "/" end
	return {
		scheme = scheme,
		authority = authority,
		origin = scheme .. "://" .. host:lower() .. ":" .. port,
		path = path,
		query = tail:match("^[^?#]*(%?[^#]*)") or "",
	}
end

--- Returns why a request cannot be handed to hs.http, or nil when admissible.
--- Runs before any ownership change, so a refused replacement never cancels
--- the valid request in flight. The URL is never quoted: it can carry a key.
--- @param url any Candidate absolute URL.
--- @param headers any Candidate header map.
--- @param body any Candidate request body.
--- @return string|nil reason
local function request_refusal(url, headers, body)
	if type(url) ~= "string" or url == "" then return "the URL must be a non-empty string" end
	-- A control byte cannot be represented in a URL; the native bridge would have
	-- to guess (cut at NUL, or encode it) which resource is meant.
	if url:find("[%z\1-\31\127]") then return "the URL contains a control byte" end
	local scheme = url:match("^([%a][%w+%.%-]*)://")
	scheme = scheme and scheme:lower()
	if scheme ~= "http" and scheme ~= "https" then return "the URL must be absolute HTTP or HTTPS" end
	if headers ~= nil and type(headers) ~= "table" then return "headers must be a table" end
	if body ~= nil and type(body) ~= "string" then return "the body must be a string" end
	return nil
end

--- Returns whether an admitted URL is HTTPS, whatever the scheme's case.
--- @param url string Admitted absolute URL.
--- @return boolean
local function is_https(url)
	return url:match("^([%a][%w+%.%-]*)://"):lower() == "https"
end

--- Removes literal dot segments from one absolute path.
--- @param path string Absolute URL path.
--- @return string normalized
local function normalize_url_path(path)
	-- RFC 3986 section 5.2.4 moves complete segments, including empty ones:
	-- repeated slashes identify different resources and must remain intact.
	local output = ""
	while path ~= "" do
		if path:sub(1, 3) == "../" then
			path = path:sub(4)
		elseif path:sub(1, 2) == "./" then
			path = path:sub(3)
		elseif path:sub(1, 3) == "/./" then
			path = path:sub(3)
		elseif path == "/." then
			path = "/"
		elseif path:sub(1, 4) == "/../" or path == "/.." then
			path = path == "/.." and "/" or path:sub(4)
			output = output:gsub("/?[^/]*$", "")
		elseif path == "." or path == ".." then
			path = ""
		else
			local segment, remaining = path:match("^(/?[^/]*)(.*)$")
			output = output .. segment
			path = remaining
		end
	end
	return output
end

--- Resolves one Location value against the current absolute URL.
--- @param current_url string Current hop URL.
--- @param location string Location response header.
--- @return string|nil resolved
--- @return table|nil current_parts
--- @return table|string|nil next_parts_or_detail
local function resolve_redirect(current_url, location)
	local current, current_err = parse_http_url(current_url)
	if not current then return nil, nil, current_err end
	if type(location) ~= "string" or location == ""
		or location:find("[%c%s\\]") then
		return nil, nil, "redirect Location is malformed"
	end

	local resolved
	if location:match("^[%a][%w+%.%-]*://") then
		resolved = location
	elseif location:sub(1, 2) == "//" then
		resolved = current.scheme .. ":" .. location
	elseif location:sub(1, 1) == "/" then
		resolved = current.scheme .. "://" .. current.authority .. location
	elseif location:sub(1, 1) == "?" then
		resolved = current.scheme .. "://" .. current.authority .. current.path .. location
	elseif location:sub(1, 1) == "#" then
		resolved = current.scheme .. "://" .. current.authority .. current.path .. current.query .. location
	else
		local relative_path, suffix = location:match("^([^?#]*)(.*)$")
		local base_dir = current.path:match("^(.*)/") or ""
		resolved = current.scheme .. "://" .. current.authority
			.. base_dir .. "/" .. relative_path .. suffix
	end

	local prefix, path, suffix = resolved:match("^([%a][%w+%.%-]*://[^/?#]+)([^?#]*)(.*)$")
	-- Query and fragment references inherit the base path byte-for-byte.
	local inherits_path = location:sub(1, 1) == "?" or location:sub(1, 1) == "#"
	if prefix and not inherits_path then resolved = prefix .. normalize_url_path(path) .. suffix end
	local next_parts, next_err = parse_http_url(resolved)
	if not next_parts then return nil, nil, next_err end
	return resolved, current, next_parts
end


-- =========================================
-- =========================================
-- ======= 2/ Instance Constructor =========
-- =========================================
-- =========================================

--- Creates and returns a new independent HttpClient instance.
--- Each instance manages its own in-flight request slot and timeout timer,
--- so concurrent users (e.g. different LLM backends) do not interfere.
--- @param options table|nil Timeout settings, native cache_policy and an opt-in follow_redirects=false origin fence.
--- @return table A fresh HttpClient instance with post/get/cancel/isActive methods.
local function new(options)
	if options ~= nil and type(options) ~= "table" then
		error("HttpClient.new(): options must be a table", 2)
	end
	options = options or {}
	if options.follow_redirects ~= nil and type(options.follow_redirects) ~= "boolean" then
		error("HttpClient.new(): follow_redirects must be a boolean", 2)
	end
	local follow_redirects = options.follow_redirects ~= false
	local cache_policy = options.cache_policy
	if cache_policy ~= nil and (type(cache_policy) ~= "string" or CACHE_POLICIES[cache_policy] ~= true) then
		error("HttpClient.new(): cache_policy must name a supported native cache policy", 2)
	end
	local timeout_ms = options.timeout_ms
	if timeout_ms == nil then
		timeout_ms = DEFAULT_TIMEOUT_MS
	elseif type(timeout_ms) ~= "number"
		or timeout_ms ~= timeout_ms
		or timeout_ms == math.huge
		or timeout_ms == -math.huge
		or timeout_ms <= 0 then
		error("HttpClient.new(): timeout_ms must be a finite positive number", 2)
	end
	local inst = {}

	-- Per-instance state
	-- A logical request may supersede a native call which supplies no handle.
	-- Keep its exact terminal receipt independently of the current generation.
	local _native_requests = {}
	local _timeout_timer   = nil
	local _timeout_cleanup = {}
	local _observed_timeout_handles = {}
	local _settlement_observers = {}
	local _lifecycle_depth = 0
	local _settlement_notification_pending = false
	local _request_active  = false
	local _cancelled       = false
	-- Bumped on every post()/get()/cancel() so a callback captured by an
	-- older generation can detect it has been superseded and self-discard,
	-- even if cancel() did not manage to abort the OS-level request in time.
	local _generation = 0

	-- ── Internal helpers ──────────────────────────────────────────────────

	--- Returns whether every native capability owned by this instance settled.
	--- @return boolean settled
	local function _fully_settled()
		return _request_active ~= true
			and next(_native_requests) == nil
			and _timeout_timer == nil
			and #_timeout_cleanup == 0
	end

	--- Delivers settlement observers outside an active lifecycle mutation.
	local function _notify_settlement_observers()
		if not _fully_settled() then return end
		if _lifecycle_depth > 0 then
			_settlement_notification_pending = true
			return
		end
		_settlement_notification_pending = false
		local observers = _settlement_observers
		_settlement_observers = {}
		for _, observer in ipairs(observers) do
			invoke_callback(observer, { settled = true })
		end
	end

	--- Removes one exact timer debt without disturbing sibling capabilities.
	--- @param handle table TimerScheduler handle.
	local function _remove_timeout_cleanup(handle)
		for index = #_timeout_cleanup, 1, -1 do
			if _timeout_cleanup[index] == handle then
				table.remove(_timeout_cleanup, index)
			end
		end
	end

	--- Retains one exact scheduler handle once native release is uncertain.
	--- @param handle table|nil TimerScheduler handle.
	local function _retain_timeout_cleanup(handle)
		if type(handle) ~= "table" or handle.timer == nil then return end
		for _, retained in ipairs(_timeout_cleanup) do
			if retained == handle then
				return
			end
		end
		_timeout_cleanup[#_timeout_cleanup + 1] = handle
		if type(TimerScheduler.onSettled) == "function"
			and _observed_timeout_handles[handle] ~= true then
			_observed_timeout_handles[handle] = true
			local registered = TimerScheduler.onSettled(handle, function()
				_observed_timeout_handles[handle] = nil
				if _timeout_timer == handle then _timeout_timer = nil end
				_remove_timeout_cleanup(handle)
				_notify_settlement_observers()
			end)
			if registered ~= true then
				_observed_timeout_handles[handle] = nil
			end
		end
	end

	--- Attempts to release one exact timeout capability.
	--- @param handle table TimerScheduler handle.
	--- @param reason string Diagnostic operation.
	--- @return boolean settled True only when no native timer remains.
	local function _cancel_timeout_handle(handle, reason)
		local ok, settled_or_err = xpcall(function()
			return TimerScheduler.cancel(handle)
		end, debug.traceback)
		if not ok or settled_or_err ~= true then
			Logger.error(LOG, "%s could not release timeout timer; exact handle retained: %s.",
				tostring(reason), tostring(settled_or_err))
			return false
		end
		return true
	end

	--- Retries every exact timeout capability retained from an earlier refusal.
	--- @return boolean settled True only when no cleanup debt remains.
	local function _retry_timeout_cleanup()
		local settled = true
		for index = #_timeout_cleanup, 1, -1 do
			local handle = _timeout_cleanup[index]
			if _cancel_timeout_handle(handle, "Timeout cleanup retry") then
				-- TimerScheduler may synchronously notify settlement and remove
				-- this exact handle while cancel() is still on the stack.
				if _timeout_cleanup[index] == handle then
					table.remove(_timeout_cleanup, index)
				else
					_remove_timeout_cleanup(handle)
				end
			else
				settled = false
			end
		end
		return settled
	end

	--- Stops the current timeout and moves uncertain release into exact debt.
	--- @return boolean settled True only when the current timer was released.
	local function _stop_timeout()
		local handle = _timeout_timer
		_timeout_timer = nil
		if not handle then return true end
		if _cancel_timeout_handle(handle, "Current request") then return true end
		_retain_timeout_cleanup(handle)
		return false
	end

	--- Retires one optional task only after cancel acknowledgement or its callback.
	--- A nil handle cannot acknowledge native settlement.
	--- @param receipt table Exact native dispatch receipt.
	--- @return boolean settled
	local function _cancel_native_request(receipt)
		if not _native_requests[receipt] then return true end
		local task = receipt.task
		if task == nil then return false end
		local ok, result_or_err = xpcall(function()
			if type(task.cancel) ~= "function" then return false end
			return task:cancel()
		end, debug.traceback)
		-- A synchronous terminal callback is stronger than the later cancel result.
		if not _native_requests[receipt] then return true end
		if not ok or result_or_err ~= true then
			Logger.error(LOG, "HTTP task cancellation failed after logical revocation: %s.",
				tostring(result_or_err))
			return false
		end
		_native_requests[receipt] = nil
		return true
	end

	--- Cancels exact returned tasks; taskless native requests remain receipt-owned.
	--- @return boolean settled Whether every returned task settled.
	local function _cancel_native_tasks()
		local snapshot = {}
		for receipt in pairs(_native_requests) do snapshot[#snapshot + 1] = receipt end
		local settled = true
		for _, receipt in ipairs(snapshot) do
			if receipt.task ~= nil and not _cancel_native_request(receipt) then settled = false end
		end
		return settled
	end

	--- Reports task cleanup debt which must block immediate logical supersession.
	--- @return boolean pending
	local function _has_pending_tasks()
		for receipt in pairs(_native_requests) do
			if receipt.task ~= nil then return true end
		end
		return false
	end

	--- Wraps one native completion before acquisition, including synchronous calls.
	--- Terminal entry proves this exchange finished; upstream releases its callback
	--- reference after returning from Lua. Duplicate delivery cannot retire a sibling.
	--- @param receipt table Exact native dispatch receipt.
	--- @param callback function Terminal handler for this request or redirect hop.
	--- @return function completion
	local function _native_completion(receipt, callback)
		_native_requests[receipt] = true
		return function(...)
			if not _native_requests[receipt] then return end
			_native_requests[receipt] = nil
			return callback(...)
		end
	end

	--- Publishes an optional task without resurrecting a synchronously completed call.
	--- @param receipt table Exact native dispatch receipt.
	--- @param task any Optional native cancellation capability.
	local function _record_native_return(receipt, task)
		if not _native_requests[receipt] then return end
		receipt.task = task
		if receipt.generation ~= _generation or _cancelled or not _request_active then
			_cancel_native_request(receipt)
			_notify_settlement_observers()
		end
	end

	--- Arms the timeout transaction before any network request can be dispatched.
	--- @param callback function Completion callback.
	--- @param my_generation integer Request generation.
	--- @return boolean committed True only when the native timer is live and owned.
	local function _arm_timeout(callback, my_generation)
		-- Forward declaration is mandatory: the closure must capture this local,
		-- never a same-named nil global declared below it
		local timeout_handle
		local schedule_ok, handle_or_err, committed = xpcall(function()
			return TimerScheduler.after(timeout_ms / MS_PER_SEC, function()
				if _cancelled or not _request_active or my_generation ~= _generation
					or _timeout_timer ~= timeout_handle then
					return
				end

				_timeout_timer = nil
				-- TimerScheduler fences delivery before native stop. A non-nil
				-- timer here is the exact terminal cleanup debt it could not release
				_retain_timeout_cleanup(timeout_handle)
				_cancelled = true
				_request_active = false
				_cancel_native_tasks()
				Logger.warn(LOG, "Request timed out after %dms.", timeout_ms)
				invoke_callback(callback, {
					ok = false,
					status = 0,
					body = "",
					error = TIMEOUT_ERROR,
				})
				_notify_settlement_observers()
			end)
		end, debug.traceback)
		timeout_handle = schedule_ok and handle_or_err or nil

		if not schedule_ok or type(timeout_handle) ~= "table" or committed ~= true
			or timeout_handle.timer == nil then
			-- A failed start may have activated before raising. TimerScheduler
			-- returns the fenced candidate even when its immediate rollback refused
			_retain_timeout_cleanup(timeout_handle)
			Logger.error(LOG, "Timeout timer acquisition failed; HTTP dispatch refused: %s.",
				tostring(schedule_ok and "timer unavailable" or handle_or_err))
			return false
		end

		-- Scheduler cleanup may synchronously publish a newer request from an
		-- exact settlement observer. Retire only our unpublished candidate.
		if my_generation ~= _generation then
			if not _cancel_timeout_handle(timeout_handle, "Superseded request admission") then
				_retain_timeout_cleanup(timeout_handle)
			end
			return false
		end
		_timeout_timer = timeout_handle
		return true
	end

	local function _make_cb(callback, my_generation)
		return function(status, response_body, response_headers)
			-- Discard a stale callback from a superseded request: cancel() cannot
			-- guarantee the underlying OS request has not already queued its
			-- completion, so the generation check is the only reliable guard.
			if my_generation ~= _generation then
				Logger.debug(LOG, "Stale response discarded (gen %d != %d).", my_generation, _generation)
				_notify_settlement_observers()
				return
			end
			if _cancelled or not _request_active then
				_notify_settlement_observers()
				return
			end
			_cancelled = true
			_request_active = false
			_stop_timeout()
			local native_status = type(status) == "number" and status or 0
			local public_status = native_status >= 0 and native_status or 0
			local is_ok  = public_status >= 200 and public_status < 300
			local err_msg = nil
			if not is_ok then
				err_msg = native_status < 0 and "Network request failed"
					or string.format("HTTP %s", tostring(public_status))
			end
			invoke_callback(callback, {
				ok     = is_ok,
				status = public_status,
				body   = native_status >= 0 and type(response_body) == "string"
					and response_body or "",
				-- The response headers, for a conditional request's ETag.
				headers = native_status >= 0 and type(response_headers) == "table"
					and response_headers or {},
				error  = err_msg,
			})
			_notify_settlement_observers()
		end
	end

	--- Creates and publishes one request only after timeout cleanup and acquisition.
	--- @param callback function Completion callback.
	--- @return integer|nil generation New request generation, or nil on refusal.
	local function _prepare_request(callback)
		local admission_generation = _generation
		if _request_active or _timeout_timer or next(_native_requests) ~= nil then
			local cancelled = inst.cancel()
			admission_generation = admission_generation + 1
			-- cancel() notifies real settlement observers after its mutation.
			-- Their newer request/cancel intent supersedes this outer admission.
			if admission_generation ~= _generation then return nil end
			-- Taskless predecessors may overlap a replacement, as the public API
			-- already permits. They still prevent physical settlement. Returned-task
			-- and timer cleanup debt continue to block every successor.
			if cancelled ~= true and (_has_pending_tasks() or #_timeout_cleanup > 0) then
				Logger.error(LOG, "HTTP request refused while native cancellation remains pending.")
				if admission_generation ~= _generation then return nil end
				invoke_callback(callback, {
					ok = false,
					status = 0,
					body = "",
					error = TIMEOUT_CLEANUP_PENDING_ERROR,
				})
				return nil
			end
		end
		local cleanup_settled = _retry_timeout_cleanup()
		if admission_generation ~= _generation then return nil end
		if not cleanup_settled then
			Logger.error(LOG, "HTTP request refused while timeout cleanup remains pending.")
			if admission_generation ~= _generation then return nil end
			invoke_callback(callback, {
				ok = false,
				status = 0,
				body = "",
				error = TIMEOUT_CLEANUP_PENDING_ERROR,
			})
			return nil
		end

		_cancelled = false
		_generation = _generation + 1
		local my_generation = _generation
		local armed = _arm_timeout(callback, my_generation)
		if my_generation ~= _generation then return nil end
		if not armed then
			_cancelled = true
			invoke_callback(callback, {
				ok = false,
				status = 0,
				body = "",
				error = TIMEOUT_UNAVAILABLE_ERROR,
			})
			return nil
		end
		_request_active = true
		return my_generation
	end

	--- Calls the single configurable native entry for explicit cache and redirect policy.
	--- @param method string Lowercase HTTP method.
	--- @param url string Exact request URL.
	--- @param headers table Request headers.
	--- @param body string|nil Request body.
	--- @param callback function Native response callback.
	--- @param redirects boolean Whether the native request may follow redirects.
	--- @return any task Optional native cancellation capability.
	local function _native_request(method, url, headers, body, callback, redirects)
		-- Hammerspoon accepts cache policy at argument 6 and redirects at argument 7.
		-- Its legacy boolean argument 6 remains valid when no cache policy was selected.
		return hs.http.doAsyncRequest(url, method:upper(), body, headers, callback,
			cache_policy or redirects, redirects)
	end

	--- Dispatches one HTTP method after the timeout transaction commits.
	--- @param method string Native method name.
	--- @param url string Absolute URL.
	--- @param headers table Header map.
	--- @param body string|nil Request body for POST.
	--- @param callback function Completion callback.
	local function _dispatch(method, url, headers, body, callback)
		local my_generation = _prepare_request(callback)
		if not my_generation then return false end

		local receipt = { generation = my_generation }
		local native_callback = _native_completion(receipt, _make_cb(callback, my_generation))
		local ok, task_or_err = pcall(function()
			if follow_redirects == false or cache_policy ~= nil then
				return _native_request(method, url, headers, body,
					native_callback, follow_redirects)
			end
			if method == "post" then
				return hs.http.asyncPost(url, body, headers, native_callback)
			end
			return hs.http.asyncGet(url, headers, native_callback)
		end)
		if not ok or task_or_err == false then
			_native_requests[receipt] = nil
			if my_generation ~= _generation or not _request_active then
				Logger.error(LOG,
					"%s(): native HTTP dispatch failed after terminal completion — %s. "
						.. "Duplicate result suppressed.", method, tostring(task_or_err))
				_notify_settlement_observers()
				return false
			end
			_cancelled = true
			_request_active = false
			_stop_timeout()
			Logger.error(LOG, "%s(): native HTTP dispatch failed — %s.", method, tostring(task_or_err))
			invoke_callback(callback, {
				ok = false,
				status = 0,
				body = "",
				error = tostring(task_or_err),
				error_kind = "native_dispatch",
			})
			_notify_settlement_observers()
			return false
		end

		_record_native_return(receipt, task_or_err)
		return true
	end

	--- Dispatches a credentialed request with native redirect following disabled.
	--- Every intermediate hop remains inside the original generation and timeout.
	--- @param method string Lowercase request method.
	--- @param url string Absolute request URL.
	--- @param headers table Header map containing caller credentials.
	--- @param body string|nil Request body.
	--- @param callback function Completion callback.
	--- @return boolean accepted
	local function _dispatch_with_redirect_policy(method, url, headers, body, callback)
		local my_generation = _prepare_request(callback)
		if not my_generation then return false end
		local redirects = 0
		local terminal_callback = _make_cb(callback, my_generation)
		-- Hop identities without fragment, as the shared redirect law keys them:
		-- a chain that returns to an exact earlier URL can never terminate.
		local visited = {}
		local initial = parse_http_url(url)
		if initial then visited[initial.origin .. initial.path .. initial.query] = true end

		local dispatch_hop
		dispatch_hop = function(hop_method, hop_url, hop_headers, hop_body)
			local receipt = { generation = my_generation }
			local ok, result_or_err = pcall(function()
				return _native_request(
					hop_method,
					hop_url,
					hop_headers,
					hop_body,
					_native_completion(receipt, function(status, response_body, response_headers)
						if my_generation ~= _generation or _cancelled or not _request_active then
							_notify_settlement_observers()
							return
						end

						if REDIRECT_STATUSES[status] then
							if redirects >= MAX_REDIRECTS then
								terminal_callback(status, "", response_headers)
								return
							end
							local location = header_value(response_headers, "location")
							local next_url, current_parts, next_parts_or_err =
								resolve_redirect(hop_url, location)
							if not next_url then
								Logger.error(LOG, "Redirect refused: %s.", tostring(next_parts_or_err))
								terminal_callback(status, "", response_headers)
								return
							end
							local next_parts = next_parts_or_err
							if current_parts.scheme == "https" and next_parts.scheme ~= "https" then
								Logger.error(LOG, "Redirect refused: HTTPS cannot downgrade to HTTP.")
								terminal_callback(status, "", response_headers)
								return
							end

							local identity = next_parts.origin .. next_parts.path .. next_parts.query
							if visited[identity] then
								Logger.error(LOG, "Redirect refused: the chain returns to an earlier URL.")
								terminal_callback(status, "", response_headers)
								return
							end
							visited[identity] = true

							redirects = redirects + 1
							local changes_to_get = hop_method ~= "get"
								and (status == 301 or status == 302 or status == 303)
							local next_method = changes_to_get and "get" or hop_method
							local next_body = hop_body
							if changes_to_get then next_body = nil end
							local next_headers = redirect_headers(
								hop_headers,
								current_parts.origin ~= next_parts.origin,
								changes_to_get)
							if not dispatch_hop(next_method, next_url, next_headers, next_body)
								and my_generation == _generation and _request_active then
								terminal_callback(0, "", {})
							end
							return
						end

						terminal_callback(status, response_body, response_headers)
					end), false)
			end)

			if not ok or result_or_err == false then
				_native_requests[receipt] = nil
				if my_generation == _generation and _request_active then
					Logger.error(LOG, "%s(): redirect-aware HTTP dispatch failed: %s.",
						hop_method, tostring(result_or_err))
				end
				_notify_settlement_observers()
				return false
			end
			_record_native_return(receipt, result_or_err)
			return true
		end

		if not dispatch_hop(method, url, redirect_headers(headers, false, false), body) then
			if my_generation == _generation and _request_active then
				terminal_callback(0, "", {})
			end
			return false
		end
		return true
	end

	--- Admits one request and selects who follows its redirects.
	--- Native auto-follow is opaque: it would forward credentials to another
	--- origin and follow an HTTPS response to HTTP. Credentialed and HTTPS
	--- requests therefore follow through the adapter's own hop policy.
	--- @param method string Lowercase request method.
	--- @param url any Candidate absolute URL.
	--- @param headers any Candidate header map.
	--- @param body any Candidate request body.
	--- @param callback function Completion callback.
	--- @return boolean accepted
	local function _request(method, url, headers, body, callback)
		local refusal = request_refusal(url, headers, body)
		if refusal then
			Logger.error(LOG, "%s(): request refused before dispatch: %s.", method, refusal)
			invoke_callback(callback, {
				ok = false,
				status = 0,
				body = "",
				error = "invalid request: " .. refusal,
				error_kind = "invalid_request",
			})
			return false
		end
		if follow_redirects == true and (has_sensitive_headers(headers) or is_https(url)) then
			return _dispatch_with_redirect_policy(method, url, headers, body, callback)
		end
		return _dispatch(method, url, headers, body, callback)
	end

	-- ── Public methods ────────────────────────────────────────────────────

	--- Sends an HTTP POST request.
	--- @param url      string   Absolute URL.
	--- @param headers  table    Key→value header map.
	--- @param body     string   JSON-encoded request body.
	--- @param callback function Called with { ok, status, body, error }.
	function inst.post(url, headers, body, callback)
		return _request("post", url, headers, body, callback)
	end

	--- Sends an HTTP GET request.
	--- @param url      string   Absolute URL.
	--- @param headers  table    Key→value header map.
	--- @param callback function Called with { ok, status, body, headers, error }.
	function inst.get(url, headers, callback)
		return _request("get", url, headers, nil, callback)
	end

	--- Aborts the in-flight request. The callback is NOT called after cancel().
	---
	--- "Aborts" means the RESULT is discarded, not that the socket is torn down.
	--- hs.http.asyncGet/asyncPost normally return nothing, so request activity is
	--- tracked independently and the OS completion self-discards on the generation
	--- check. A taskless request remains physically pending until terminal delivery.
	--- Native task cancellation remains opportunistic for an implementation that
	--- does return a cancellable handle. False reports pending physical settlement;
	--- logical cancellation still fences the result synchronously.
	function inst.cancel()
		_lifecycle_depth = _lifecycle_depth + 1
		_cancelled  = true
		_request_active = false
		_generation = _generation + 1
		local task_settled = _cancel_native_tasks() == true
		_stop_timeout()
		-- _stop_timeout retains an uncertain timer in the exact cleanup ledger.
		-- Retry that ledger now and expose the final settlement to lifecycle owners;
		-- legacy nil made pause publish success while native timeout debt survived.
		local timers_settled = _retry_timeout_cleanup() == true
		-- A settlement observer may acquire a newer generation. Preserve the
		-- physical receipt for the revoked set before invoking that continuation;
		-- isSettled() still reports any newly acquired request as pending.
		local receipt_settled = task_settled and timers_settled and next(_native_requests) == nil
		_lifecycle_depth = _lifecycle_depth - 1
		_notify_settlement_observers()
		return receipt_settled
	end

	--- Registers a continuation for exact native settlement of this instance.
	--- It runs immediately when no request/task/timer capability remains, or once
	--- after a previously refused cancellation later settles autonomously.
	--- @param observer function Zero-arity settlement callback.
	--- @return boolean registered
	function inst.onSettled(observer)
		if type(observer) ~= "function" then return false end
		if _fully_settled() and _lifecycle_depth == 0 then
			invoke_callback(observer, { settled = true })
			return true
		end
		_settlement_observers[#_settlement_observers + 1] = observer
		return true
	end

	--- Reports physical settlement of this exact HTTP owner and its timers.
	--- An inactive business request may still retain native cleanup debt.
	--- @return boolean settled
	function inst.isSettled()
		return _fully_settled() and _lifecycle_depth == 0
	end

	--- Returns true when a request is currently in flight.
	--- @return boolean
	function inst.isActive()
		return _request_active
	end

	return inst
end


-- =========================================
-- =========================================
-- ======= 3/ Module-level API =============
-- =========================================
-- =========================================

--- Percent-encodes one query component without relying on native services.
--- Iterating bytes rather than codepoints is intentional: RFC 3986 encodes the
--- UTF-8 representation, and every byte outside the ASCII unreserved set must
--- become an uppercase `%HH` triplet.
--- @param value any Value to encode.
--- @return string encoded Percent-encoded component.
local function encode_rfc3986_component(value)
	local raw = tostring(value or "")
	local encoded = {}
	for index = 1, #raw do
		local byte = raw:byte(index)
		local unreserved = (byte >= 0x41 and byte <= 0x5A)
			or (byte >= 0x61 and byte <= 0x7A)
			or (byte >= 0x30 and byte <= 0x39)
			or byte == 0x2D or byte == 0x2E or byte == 0x5F or byte == 0x7E
		encoded[#encoded + 1] = unreserved and string.char(byte)
			or string.format("%%%02X", byte)
	end
	return table.concat(encoded)
end

--- URL-encodes a string for safe inclusion in a query string.
--- Native failures are reported without including the possibly sensitive value,
--- then handled by the deterministic in-process encoder above.
--- @param str string The string to encode.
--- @return string The percent-encoded string.
local function encodeForQuery(str)
	if hs and hs.http and hs.http.encodeForQuery then
		local ok, result = pcall(hs.http.encodeForQuery, str)
		if ok and type(result) == "string" then return result end
		Logger.error(LOG, "encodeForQuery(): native query encoder failed; using "
			.. "the internal percent encoder — %s.",
			ok and ("unexpected " .. type(result) .. " result") or "native exception")
	else
		Logger.error(LOG, "encodeForQuery(): native query encoder is unavailable; "
			.. "using the internal percent encoder.")
	end
	return encode_rfc3986_component(str)
end

--- Percent-encodes a string as one RFC 3986 path segment.
--- @param value any Value to encode.
--- @return string encoded Percent-encoded path segment.
local function encodePathSegment(value)
	return encode_rfc3986_component(value)
end

-- The module table is itself the default singleton instance, extended with
-- the factory constructor and encodeForQuery utility.
local M = new()
M.new            = new
M.encodeForQuery = encodeForQuery
M.encodePathSegment = encodePathSegment

return M
