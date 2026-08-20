--- adapters/http_client.lua

--- ==============================================================================
--- MODULE: HttpClient Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the HttpClient port contract defined in
--- static/ergopti_plus/_shared/core/ports/HttpClient.spec.js. Wraps hs.http.asyncPost,
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
--- 2. Cancel via task reference: when asyncPost/asyncGet return a cancellable
---    task, the adapter holds it so cancel() can abort in-flight work. The
---    generation fence suppresses completion even when no task is returned.
--- 3. One request at a time per instance: a second post()/get() call while
---    isActive() is true cancels the previous request first.
--- 4. Timeout enforcement: a TimerScheduler transaction must commit before the
---    network request is dispatched. Exact cleanup debt blocks every successor.
--- 5. encodeForQuery: thin pass-through to hs.http.encodeForQuery so callers
---    (api_remote.lua) have no direct hs.http dependency for URL encoding.
--- 6. Generation guard: cancel()'s doc claims it "synchronously and
---    unconditionally" prevents a superseded callback from firing, but
---    hs.http.asyncPost/asyncGet may already have queued their OS-level
---    completion before cancel() runs (the task handle does not guarantee
---    the underlying NSURLSession delegate call is aborted in time). Each
---    post()/get() call is stamped with a monotonic generation captured by
---    its own wrapped callback; the callback checks it against the
---    instance's current generation before delivering, so a stale callback
---    from a superseded request (e.g. a warmup POST outlived by a real
---    inference POST sharing the same instance) is discarded instead of
---    delivering its result to the wrong caller. Mirrors modules/updater/init.lua's
---    _poll_generation pattern.
--- ==============================================================================

local hs             = hs
local Logger         = require("infra.logger")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "adapters.http_client"

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
	local _active_task     = nil
	local _timeout_timer   = nil
	local _timeout_cleanup = {}
	local _request_active  = false
	local _cancelled       = false
	-- Bumped on every post()/get()/cancel() so a callback captured by an
	-- older generation can detect it has been superseded and self-discard,
	-- even if cancel() did not manage to abort the OS-level request in time.
	local _generation = 0

	-- ── Internal helpers ──────────────────────────────────────────────────

	--- Retains one exact scheduler handle once native release is uncertain.
	--- @param handle table|nil TimerScheduler handle.
	local function _retain_timeout_cleanup(handle)
		if type(handle) ~= "table" or handle.timer == nil then return end
		for _, retained in ipairs(_timeout_cleanup) do
			if retained == handle then return end
		end
		_timeout_cleanup[#_timeout_cleanup + 1] = handle
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
				table.remove(_timeout_cleanup, index)
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

	--- Cancels the optional native HTTP task after the generation was fenced.
	--- @return boolean settled True unless native cancellation explicitly failed.
	local function _cancel_active_task()
		local task = _active_task
		_active_task = nil
		if not task then return true end
		local ok, result_or_err = xpcall(function()
			if type(task.cancel) ~= "function" then return true end
			return task:cancel()
		end, debug.traceback)
		if not ok or result_or_err == false then
			Logger.error(LOG, "HTTP task cancellation failed after logical revocation: %s.",
				tostring(result_or_err))
			return false
		end
		return true
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
			return TimerScheduler.after(DEFAULT_TIMEOUT_MS / MS_PER_SEC, function()
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
				_cancel_active_task()
				Logger.warn(LOG, "Request timed out after %dms.", DEFAULT_TIMEOUT_MS)
				invoke_callback(callback, {
					ok = false,
					status = 0,
					body = "",
					error = TIMEOUT_ERROR,
				})
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

		_timeout_timer = timeout_handle
		return true
	end

	local function _make_cb(callback, my_generation)
		return function(status, response_body, _response_headers)
			-- Discard a stale callback from a superseded request: cancel() cannot
			-- guarantee the underlying OS request has not already queued its
			-- completion, so the generation check is the only reliable guard.
			if my_generation ~= _generation then
				Logger.debug(LOG, "Stale response discarded (gen %d != %d).", my_generation, _generation)
				return
			end
			if _cancelled or not _request_active then return end
			_cancelled = true
			_request_active = false
			_active_task = nil
			_stop_timeout()
			local is_ok  = type(status) == "number" and status >= 200 and status < 300
			local err_msg = nil
			if not is_ok then err_msg = string.format("HTTP %s", tostring(status)) end
			invoke_callback(callback, {
				ok     = is_ok,
				status = type(status) == "number" and status or 0,
				body   = type(response_body) == "string" and response_body or "",
				error  = err_msg,
			})
		end
	end

	--- Creates and publishes one request only after timeout cleanup and acquisition.
	--- @param callback function Completion callback.
	--- @return integer|nil generation New request generation, or nil on refusal.
	local function _prepare_request(callback)
		if _request_active or _timeout_timer or _active_task then inst.cancel() end
		if not _retry_timeout_cleanup() then
			Logger.error(LOG, "HTTP request refused while timeout cleanup remains pending.")
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
		if not _arm_timeout(callback, my_generation) then
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

	--- Dispatches one HTTP method after the timeout transaction commits.
	--- @param method string Native method name.
	--- @param url string Absolute URL.
	--- @param headers table Header map.
	--- @param body string|nil Request body for POST.
	--- @param callback function Completion callback.
	local function _dispatch(method, url, headers, body, callback)
		local my_generation = _prepare_request(callback)
		if not my_generation then return end

		local ok, task_or_err = pcall(function()
			if method == "post" then
				return hs.http.asyncPost(url, body, headers, _make_cb(callback, my_generation))
			end
			return hs.http.asyncGet(url, headers, _make_cb(callback, my_generation))
		end)
		if not ok or task_or_err == false then
			if my_generation ~= _generation or not _request_active then
				Logger.error(LOG,
					"%s(): native HTTP dispatch failed after terminal completion — %s. "
						.. "Duplicate result suppressed.", method, tostring(task_or_err))
				return
			end
			_cancelled = true
			_request_active = false
			_active_task = nil
			_stop_timeout()
			Logger.error(LOG, "%s(): native HTTP dispatch failed — %s.", method, tostring(task_or_err))
			invoke_callback(callback, {
				ok = false,
				status = 0,
				body = "",
				error = tostring(task_or_err),
			})
			return
		end

		-- A faithful Hammerspoon call returns nil. Activity is therefore tracked
		-- independently, and a synchronous test completion cannot resurrect it
		if my_generation == _generation and _request_active then
			_active_task = task_or_err
		end
	end

	-- ── Public methods ────────────────────────────────────────────────────

	--- Sends an HTTP POST request.
	--- @param url      string   Absolute URL.
	--- @param headers  table    Key→value header map.
	--- @param body     string   JSON-encoded request body.
	--- @param callback function Called with { ok, status, body, error }.
	function inst.post(url, headers, body, callback)
		_dispatch("post", url, headers, body, callback)
	end

	--- Sends an HTTP GET request.
	--- @param url      string   Absolute URL.
	--- @param headers  table    Key→value header map.
	--- @param callback function Called with { ok, status, body, error }.
	function inst.get(url, headers, callback)
		_dispatch("get", url, headers, nil, callback)
	end

	--- Aborts the in-flight request. The callback is NOT called after cancel().
	---
	--- "Aborts" means the RESULT is discarded, not that the socket is torn down.
	--- hs.http.asyncGet/asyncPost normally return nothing, so request activity is
	--- tracked independently and the OS completion self-discards on the generation
	--- check. Native task cancellation remains opportunistic for an implementation
	--- that does return a cancellable handle.
	function inst.cancel()
		_cancelled  = true
		_request_active = false
		_generation = _generation + 1
		_cancel_active_task()
		_stop_timeout()
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
