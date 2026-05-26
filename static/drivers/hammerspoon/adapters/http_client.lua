--- adapters/http_client.lua

--- ==============================================================================
--- MODULE: HttpClient Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the HttpClient port contract defined in
--- static/drivers/_shared/ports/HttpClient.spec.js. Wraps hs.http.asyncPost
--- behind the three canonical port methods (post, cancel, isActive) so domain
--- modules can make HTTP requests without a direct dependency on hs.http.
---
--- FEATURES & RATIONALE:
--- 1. Async with callback: hs.http is non-blocking. The callback is always
---    deferred to the next runloop cycle, matching the contract note for async
---    adapters. The callback signature is { ok, status, body, error }.
--- 2. Cancel via task reference: hs.http.asyncPost returns a task object that
---    supports :cancel(). The adapter holds this reference so cancel() can abort
---    the in-flight request. After cancel() the callback is NOT called.
--- 3. One request at a time: a second post() call while isActive() is true
---    cancels the previous request first, preventing callback fan-out.
--- 4. Timeout enforcement: a fallback timer fires after DEFAULT_TIMEOUT_MS and
---    synthesizes an error callback if the OS request hasn't completed, matching
---    the contract's timeout guarantee.
--- ==============================================================================

local M = {}

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
-- ======= 2/ Internal State ===============
-- =========================================
-- =========================================

local _active_task    = nil   -- hs.http task reference (nil when idle)
local _timeout_timer  = nil   -- hs.timer handle for the fallback timeout
local _cancelled      = false -- Set by cancel() to suppress the callback


-- =====================================
-- =====================================
-- ======= 3/ Adapter Methods ==========
-- =====================================
-- =====================================

--- Sends an HTTP POST request.
--- @param url      string   Absolute HTTPS URL.
--- @param headers  table    Key→value header map.
--- @param body     string   JSON-encoded request body.
--- @param callback function Called with { ok, status, body, error } on completion.
function M.post(url, headers, body, callback)
	-- Cancel any in-flight request before starting a new one.
	if _active_task then M.cancel() end

	_cancelled = false

	-- Arm the fallback timeout so the callback is never silently dropped.
	_timeout_timer = hs.timer.doAfter(DEFAULT_TIMEOUT_MS / MS_PER_SEC, function()
		if _cancelled then return end
		_cancelled = true
		if _active_task then
			pcall(function() _active_task:cancel() end)
			_active_task = nil
		end
		Logger.warn(LOG, "post(): request timed out after %dms.", DEFAULT_TIMEOUT_MS)
		if type(callback) == "function" then
			pcall(callback, { ok = false, status = 0, body = "", error = "timeout" })
		end
	end)

	local ok, task_or_err = pcall(hs.http.asyncPost, url, body, headers,
		function(status, response_body, _response_headers)
			-- Discard stale callbacks after cancel() or timeout.
			if _cancelled then return end
			_cancelled = true
			_active_task = nil
			if _timeout_timer then
				pcall(function() _timeout_timer:stop() end)
				_timeout_timer = nil
			end
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
	)

	if not ok then
		_cancelled = true
		if _timeout_timer then
			pcall(function() _timeout_timer:stop() end)
			_timeout_timer = nil
		end
		Logger.error(LOG, "post(): hs.http.asyncPost failed — %s", tostring(task_or_err))
		if type(callback) == "function" then
			pcall(callback, { ok = false, status = 0, body = "", error = tostring(task_or_err) })
		end
		return
	end
	_active_task = task_or_err
end

--- Aborts any in-flight request. The callback is NOT called after cancel().
function M.cancel()
	_cancelled = true
	if _active_task then
		pcall(function() _active_task:cancel() end)
		_active_task = nil
	end
	if _timeout_timer then
		pcall(function() _timeout_timer:stop() end)
		_timeout_timer = nil
	end
end

--- Returns true if a request is currently in flight.
--- @return boolean
function M.isActive()
	return _active_task ~= nil
end

return M
