--- adapters/http_client.lua

--- ==============================================================================
--- MODULE: HttpClient Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the HttpClient port contract defined in
--- static/ergopti_plus/shared/ports/HttpClient.spec.js. Wraps hs.http.asyncPost,
--- hs.http.asyncGet, and hs.http.encodeForQuery behind a stable adapter surface
--- so domain modules can make HTTP requests without a direct dependency on hs.http.
---
--- FACTORY PATTERN:
--- require("adapters.http_client").new() returns a fresh independent instance.
--- Each LLM backend owns its own instance so concurrent requests from different
--- backends do not cancel each other (the old singleton model allowed api_mlx's
--- warmup to cancel api_ollama's in-flight request).
--- The module table M itself is also a valid default singleton for callers that
--- only ever have one concurrent request at a time.
---
--- FEATURES & RATIONALE:
--- 1. Async with callback: hs.http is non-blocking. The callback is always
---    deferred to the next runloop cycle. Signature: { ok, status, body, error }.
--- 2. Cancel via task reference: asyncPost/asyncGet return a task that supports
---    :cancel(). The adapter holds this reference so cancel() can abort in-flight
---    requests. After cancel() the callback is NOT called.
--- 3. One request at a time per instance: a second post()/get() call while
---    isActive() is true cancels the previous request first.
--- 4. Timeout enforcement: a fallback timer fires after DEFAULT_TIMEOUT_MS and
---    synthesizes an error callback when the OS request has not completed.
--- 5. encodeForQuery: thin pass-through to hs.http.encodeForQuery so callers
---    (api_remote.lua) have no direct hs.http dependency for URL encoding.
--- ==============================================================================

local hs     = hs
local Logger = require("lib.logger")

local LOG = "adapters.http_client"


-- =========================================
-- =========================================
-- ======= 1/ Constants ====================
-- =========================================
-- =========================================

-- Timeout in milliseconds; matches HttpClient.spec.js DEFAULT_TIMEOUT_MS.
local DEFAULT_TIMEOUT_MS = 30000

-- Conversion factor for the hs.timer.doAfter call (which takes seconds).
local MS_PER_SEC = 1000


-- =========================================
-- =========================================
-- ======= 2/ Instance Constructor =========
-- =========================================
-- =========================================

--- Creates and returns a new independent HttpClient instance.
--- Each instance manages its own in-flight request slot and timeout timer,
--- so concurrent users (e.g. different LLM backends) do not interfere.
--- @return table A fresh HttpClient instance with post/get/cancel/isActive methods.
local function new()
	local inst = {}

	-- Per-instance state
	local _active_task   = nil
	local _timeout_timer = nil
	local _cancelled     = false

	-- ── Internal helpers ──────────────────────────────────────────────────

	local function _arm_timeout(callback)
		_timeout_timer = hs.timer.doAfter(DEFAULT_TIMEOUT_MS / MS_PER_SEC, function()
			if _cancelled then return end
			_cancelled = true
			if _active_task then
				pcall(function() _active_task:cancel() end)
				_active_task = nil
			end
			Logger.warn(LOG, "request timed out after %dms.", DEFAULT_TIMEOUT_MS)
			if type(callback) == "function" then
				pcall(callback, { ok = false, status = 0, body = "", error = "timeout" })
			end
		end)
	end

	local function _stop_timeout()
		if _timeout_timer then
			pcall(function() _timeout_timer:stop() end)
			_timeout_timer = nil
		end
	end

	local function _make_cb(callback)
		return function(status, response_body, _response_headers)
			if _cancelled then return end
			_cancelled   = true
			_active_task = nil
			_stop_timeout()
			local is_ok  = type(status) == "number" and status >= 200 and status < 300
			local err_msg = is_ok and nil or string.format("HTTP %s", tostring(status))
			if type(callback) == "function" then
				pcall(callback, {
					ok     = is_ok,
					status = type(status) == "number" and status or 0,
					body   = type(response_body) == "string" and response_body or "",
					error  = err_msg,
				})
			end
		end
	end

	-- ── Public methods ────────────────────────────────────────────────────

	--- Sends an HTTP POST request.
	--- @param url      string   Absolute URL.
	--- @param headers  table    Key→value header map.
	--- @param body     string   JSON-encoded request body.
	--- @param callback function Called with { ok, status, body, error }.
	function inst.post(url, headers, body, callback)
		if _active_task then inst.cancel() end
		_cancelled = false
		_arm_timeout(callback)
		local ok, task_or_err = pcall(hs.http.asyncPost, url, body, headers, _make_cb(callback))
		if not ok then
			_cancelled = true
			_stop_timeout()
			Logger.error(LOG, "post(): hs.http.asyncPost failed — %s", tostring(task_or_err))
			if type(callback) == "function" then
				pcall(callback, { ok = false, status = 0, body = "", error = tostring(task_or_err) })
			end
			return
		end
		_active_task = task_or_err
	end

	--- Sends an HTTP GET request.
	--- @param url      string   Absolute URL.
	--- @param headers  table    Key→value header map.
	--- @param callback function Called with { ok, status, body, error }.
	function inst.get(url, headers, callback)
		if _active_task then inst.cancel() end
		_cancelled = false
		_arm_timeout(callback)
		local ok, task_or_err = pcall(hs.http.asyncGet, url, headers, _make_cb(callback))
		if not ok then
			_cancelled = true
			_stop_timeout()
			Logger.error(LOG, "get(): hs.http.asyncGet failed — %s", tostring(task_or_err))
			if type(callback) == "function" then
				pcall(callback, { ok = false, status = 0, body = "", error = tostring(task_or_err) })
			end
			return
		end
		_active_task = task_or_err
	end

	--- Aborts the in-flight request. The callback is NOT called after cancel().
	function inst.cancel()
		_cancelled = true
		if _active_task then
			pcall(function() _active_task:cancel() end)
			_active_task = nil
		end
		_stop_timeout()
	end

	--- Returns true when a request is currently in flight.
	--- @return boolean
	function inst.isActive()
		return _active_task ~= nil
	end

	return inst
end


-- =========================================
-- =========================================
-- ======= 3/ Module-level API =============
-- =========================================
-- =========================================

--- URL-encodes a string for safe inclusion in a query string.
--- Thin pass-through to hs.http.encodeForQuery with a fallback that returns
--- the input unchanged when hs is unavailable (headless unit tests).
--- @param str string The string to encode.
--- @return string The percent-encoded string.
local function encodeForQuery(str)
	if hs and hs.http and hs.http.encodeForQuery then
		local ok, result = pcall(hs.http.encodeForQuery, str)
		if ok then return result end
	end
	return tostring(str or "")
end

-- The module table is itself the default singleton instance, extended with
-- the factory constructor and encodeForQuery utility.
local M = new()
M.new            = new
M.encodeForQuery = encodeForQuery

return M
