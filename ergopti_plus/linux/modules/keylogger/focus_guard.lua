--- modules/keylogger/focus_guard.lua

--- ==============================================================================
--- MODULE: Accessible Focus Privacy Guard (Linux)
--- DESCRIPTION:
--- Owns the transition between a physical focus-navigation event and a fresh
--- secure-field verdict. Top-level window identity cannot see Tab/click movement
--- between controls, so those events enter an immediate fail-closed epoch and the
--- daemon probes later, after the desktop has delivered the navigation event.
---
--- INVARIANTS:
--- 1. invalidate() blocks metrics and automation synchronously.
--- 2. refresh() never re-enables them before the focus-settle deadline.
--- 3. Only a conclusive verdict for the current epoch can leave unknown state.
--- 4. Missing detectors and failed probes remain fail-closed.
--- ==============================================================================

local M = {}





-- =================================
-- =================================
-- ======= 1/ Guard Factory ========
-- =================================
-- =================================

--- Creates one daemon-owned focus guard.
--- @param opts table {
---   detector, keylogger, prediction?, reset_text?, now_ms, settle_ms?
--- }
--- @return table guard
function M.new(opts)
	local options = type(opts) == "table" and opts or {}
	if type(options.keylogger) ~= "table"
		or type(options.keylogger.set_secure_field) ~= "function"
	then
		error("focus_guard requires keylogger.set_secure_field")
	end
	if type(options.now_ms) ~= "function" then
		error("focus_guard requires a monotonic now_ms function")
	end

	local detector = options.detector
	local keylogger = options.keylogger
	local prediction = options.prediction
	local reset_text = type(options.reset_text) == "function" and options.reset_text or function() end
	local settle_ms = math.max(0, tonumber(options.settle_ms) or 0)
	local pending_epoch = nil
	local probe_not_before_ms = 0

	local guard = {}

	--- Enters a new unknown epoch before the target application can accept text.
	--- @return number|nil epoch
	function guard.invalidate()
		if detector and type(detector.invalidateFocus) == "function" then
			pending_epoch = detector.invalidateFocus()
		else
			pending_epoch = nil
		end
		probe_not_before_ms = options.now_ms() + settle_ms
		keylogger.set_secure_field(true)
		if prediction and type(prediction.cancel) == "function" then
			pcall(prediction.cancel)
		end
		reset_text()
		return pending_epoch
	end

	--- Publishes a fresh verdict when the navigation event has had time to land.
	--- @param immediate boolean|nil Ignore the settle delay for an already-observed
	--- focused window (startup or top-level focus callback).
	--- @return boolean accepted
	function guard.refresh(immediate)
		if not detector or type(detector.refresh) ~= "function" then
			keylogger.set_secure_field(true)
			return false
		end
		if pending_epoch == nil then return false end
		if immediate ~= true and options.now_ms() < probe_not_before_ms then return false end

		local epoch = pending_epoch
		local ok, accepted = pcall(detector.refresh, epoch)
		if not ok or accepted ~= true then
			keylogger.set_secure_field(true)
			-- Do not hammer a missing accessibility service four times per second.
			-- The next physical/top-level focus transition schedules the next probe.
			pending_epoch = nil
			return false
		end

		local ok_secure, secure = pcall(detector.isSecureField)
		if not ok_secure or type(secure) ~= "boolean" then
			keylogger.set_secure_field(true)
			pending_epoch = nil
			return false
		end
		keylogger.set_secure_field(secure)
		pending_epoch = nil
		return true
	end

	--- Invalidates and immediately probes an already-settled focused window.
	--- @return boolean accepted
	function guard.prime()
		guard.invalidate()
		return guard.refresh(true)
	end

	--- Returns whether text automation must be withheld right now.
	--- @return boolean
	function guard.blocks_text()
		if not detector or type(detector.isSecureField) ~= "function" then return true end
		local ok, secure = pcall(detector.isSecureField)
		return not ok or secure ~= false
	end

	--- Returns whether an invalidated navigation epoch still awaits its probe.
	--- @return boolean
	function guard.is_pending()
		return pending_epoch ~= nil
	end

	return guard
end

return M
