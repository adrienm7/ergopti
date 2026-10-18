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
---   detector, keylogger, prediction?, reset_text?, now_ms, settle_ms?,
---   capture_context?, publish_context?
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
	local watch = options.watch
	local observed = nil
	local suppress_watch = false
	local pending_epoch = nil
	local probe_not_before_ms = 0
	local contextual = options.capture_context ~= nil or options.publish_context ~= nil
	if contextual and (type(options.capture_context) ~= "function" or type(options.publish_context) ~= "function") then
		error("focus_guard context capture and publication must be provided together")
	end
	local context_pending = contextual
	local context_generation = 0
	local joining_context = false
	local joining_identity = nil
	local joined_context = nil

	local guard = {}

	local function identity(snapshot)
		return snapshot and snapshot.bus .. snapshot.path .. tostring(snapshot.role) or nil
	end

	-- A native field receipt contains no application or private-window policy.
	-- Its listener can revoke old authority, but must never query or recursively
	-- pump native sources while another barrier is delivering that notification.
	local function revoke_context()
		context_generation = context_generation + 1
		context_pending, observed, joined_context = true, nil, nil
		if detector and type(detector.invalidateFocus) == "function" then detector.invalidateFocus() end
		keylogger.set_secure_field(true)
		if prediction and type(prediction.cancel) == "function" then pcall(prediction.cancel) end
		reset_text()
	end

	--- Enters a new unknown epoch before the target application can accept text.
	--- @return number|nil epoch
	function guard.invalidate()
		if contextual then context_generation = context_generation + 1; context_pending, joined_context = true, nil end
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
		observed = nil
		if watch then
			suppress_watch = true
			watch.invalidate()
			suppress_watch = false
		end
		return pending_epoch
	end

	local function accept_watch(snapshot)
		if suppress_watch then return false end
		if snapshot and pending_epoch ~= nil and options.now_ms() < probe_not_before_ms then return false end
		local identity = snapshot and snapshot.bus .. snapshot.path .. tostring(snapshot.role) or nil
		if identity == observed and pending_epoch == nil then return snapshot ~= nil end
		observed = identity
		local epoch = detector and type(detector.invalidateFocus) == "function" and detector.invalidateFocus() or nil
		keylogger.set_secure_field(true)
		if prediction and type(prediction.cancel) == "function" then pcall(prediction.cancel) end
		reset_text()
		pending_epoch = nil
		if not snapshot or not detector or type(detector.publishFocus) ~= "function" then return false end
		local ok, accepted = pcall(detector.publishFocus, snapshot.role, epoch)
		if not ok or accepted ~= true then return false end
		keylogger.set_secure_field(snapshot.role == 40)
		return true
	end
	if watch then
		watch.on_change(function(snapshot)
			if suppress_watch then return false end
			if not contextual then return accept_watch(snapshot) end
			if identity(snapshot) ~= (joining_context and joining_identity or observed) or snapshot == nil then revoke_context() end
			return false
		end)
	end

	--- Joins fresh metadata only off the input path, bracketed by native receipts.
	--- @param immediate boolean|nil Whether an already-settled window was observed.
	--- @return boolean accepted
	local function refresh_context(immediate)
		if joining_context then return false end
		if not context_pending and pending_epoch == nil then return false end
		if pending_epoch ~= nil and immediate ~= true and options.now_ms() < probe_not_before_ms then return false end
		local before = watch.barrier()
		if not before or before.role == 40 then return false end
		local expected = identity(before)
		local generation = context_generation
		local epoch = detector and type(detector.currentEpoch) == "function" and detector.currentEpoch() or nil
		joining_context, joining_identity = true, expected
		local captured, context = pcall(options.capture_context, before)
		local after = captured and type(context) == "table" and watch.barrier() or nil
		if not captured or type(context) ~= "table" or type(context.app_id) ~= "string" or context.app_id == ""
			or type(context.title) ~= "string" or type(context.native_identity) ~= "string" or context.native_identity == ""
			or identity(after) ~= expected
			or context_generation ~= generation then
			joining_context, joining_identity = false, nil
			return false
		end
		local published, accepted, protected = pcall(options.publish_context, context)
		if not published or accepted ~= true or type(protected) ~= "boolean"
			or context_generation ~= generation then
			joining_context, joining_identity = false, nil
			return false
		end
		local admitted, committed = pcall(function()
			return detector and type(detector.publishFocus) == "function"
				and detector.publishFocus(before.role, epoch, protected)
		end)
		joining_context, joining_identity = false, nil
		if not admitted or committed ~= true or context_generation ~= generation then return false end
		observed, context_pending, pending_epoch = expected, false, nil
		joined_context = { app_id = context.app_id, title = context.title, native_identity = context.native_identity }
		-- The publisher has already installed the incoming app/title policy.
		keylogger.set_secure_field(before.role == 40 or protected)
		return true
	end

	--- Publishes a fresh verdict when the navigation event has had time to land.
	--- @param immediate boolean|nil Ignore the settle delay for an already-observed
	--- focused window (startup or top-level focus callback).
	--- @return boolean accepted
	function guard.refresh(immediate)
		if joining_context then return false end
		if watch then
			watch.pump()
			if contextual then return refresh_context(immediate) end
			if pending_epoch == nil then return false end
			if immediate ~= true and options.now_ms() < probe_not_before_ms then return false end
			probe_not_before_ms = 0
			return accept_watch(watch.barrier())
		end
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
		if joining_context then return true end
		if watch then
			watch.pump()
			if pending_epoch ~= nil and options.now_ms() < probe_not_before_ms then return true end
			local snapshot = watch.barrier()
			if contextual then
				if not snapshot or identity(snapshot) ~= observed then
					if not context_pending then revoke_context() end
					return true
				end
				if context_pending then return true end
				-- User filter choices can change without moving the native field.
				-- Re-evaluate policy in RAM, retaining the already joined metadata.
				local checked, protected = pcall(keylogger.is_context_protected, joined_context.app_id, joined_context.title)
				if not checked or type(protected) ~= "boolean" then revoke_context(); return true end
				local epoch = detector and type(detector.currentEpoch) == "function" and detector.currentEpoch() or nil
				local published, accepted = pcall(function() return detector.publishFocus(snapshot.role, epoch, protected) end)
				if not published or accepted ~= true then revoke_context(); return true end
				keylogger.set_secure_field(snapshot.role == 40 or protected)
			elseif not accept_watch(snapshot) then return true end
		end
		if not detector or type(detector.isSecureField) ~= "function" then return true end
		local ok, secure = pcall(detector.isSecureField)
		return not ok or secure ~= false
	end

	--- Returns whether an invalidated navigation epoch still awaits its probe.
	--- @return boolean
	function guard.is_pending()
		return pending_epoch ~= nil or context_pending
	end

	--- Returns only metadata already joined to the current native field owner.
	--- Call blocks_text() before using it for a new asynchronous admission.
	--- @return table|nil context Detached application/title metadata, never unknown.
	function guard.current_context()
		if joining_context or context_pending or not joined_context then return nil end
		return { app_id = joined_context.app_id, title = joined_context.title,
			native_identity = joined_context.native_identity }
	end

	return guard
end

return M
