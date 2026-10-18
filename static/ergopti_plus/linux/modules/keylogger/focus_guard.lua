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
---   capture_context?, capture_context_async?, retry_ms?, publish_context?
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
	local asynchronous = options.capture_context_async ~= nil
	local contextual = options.capture_context ~= nil or asynchronous or options.publish_context ~= nil
	if contextual and (type(options.publish_context) ~= "function"
		or asynchronous and (type(options.capture_context_async) ~= "function" or options.capture_context ~= nil)
		or not asynchronous and type(options.capture_context) ~= "function") then
		error("focus_guard context capture and publication must be provided together")
	end
	if asynchronous and (type(options.retry_ms) ~= "number" or options.retry_ms <= 0 or options.retry_ms % 1 ~= 0) then
		error("asynchronous focus context requires a positive integer retry interval")
	end
	local context_pending = contextual
	local context_generation = 0
	local joining_context = false
	local joining_identity = nil
	local joined_context = nil
	local joined_field = nil
	local reading_text_identity = false
	local context_request, attempted_generation = nil, nil
	local stopped = false
	local refreshing_context, retiring_context, notifying_context = false, false, false
	local retry_not_before_ms = nil

	local guard = {}
	local context_owner = "focus-context:" .. tostring(guard)

	--- Fences delivery before requesting native cancellation, retaining cleanup debt.
	--- @return boolean settled
	local function retire_context()
		local request = context_request
		if not request then return true end
		request.revoked, request.context = true, nil
		if retiring_context then return false end
		local operation = request.operation
		if not operation then
			if request.dispatch_failed == true then context_request = nil; return true end
			return false
		end
		if not request.valid_operation then return false end
		retiring_context = true
		pcall(operation.cancel, operation)
		local checked, settled = pcall(operation.is_settled, operation)
		retiring_context = false
		if checked and settled == true and context_request == request then context_request = nil; return true end
		return false
	end

	local function identity(snapshot)
		return snapshot and snapshot.bus .. "\0" .. snapshot.path .. "\0" .. tostring(snapshot.role) or nil
	end

	-- A native field receipt contains no application or private-window policy.
	-- Its listener can revoke old authority, but must never query or recursively
	-- pump native sources while another barrier is delivering that notification.
	local function revoke_context()
		context_generation = context_generation + 1
		retry_not_before_ms = nil
		if asynchronous then retire_context(); joining_context, joining_identity = false, nil end
		context_pending, observed, joined_context, joined_field = true, nil, nil, nil
		if detector and type(detector.invalidateFocus) == "function" then detector.invalidateFocus() end
		keylogger.set_secure_field(true)
		if prediction and type(prediction.cancel) == "function" then pcall(prediction.cancel) end
		reset_text()
	end

	--- Enters a new unknown epoch before the target application can accept text.
	--- @return number|nil epoch
	function guard.invalidate()
		if stopped then return nil end
		if asynchronous then retire_context(); joining_context, joining_identity = false, nil end
		if contextual then context_generation = context_generation + 1; context_pending, joined_context, joined_field = true, nil, nil end
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

	--- Reconciles an owned asynchronous capture only from the periodic refresh path.
	--- Native completion callbacks stage RAM; field admission is rechecked here.
	--- @param immediate boolean|nil Ignore an already-settled focus delay.
	--- @return boolean accepted
	local function refresh_async_context(immediate)
		if stopped then return false end
		watch.pump()
		local request = context_request
		if request and (request.revoked or request.generation ~= context_generation) then
			if not retire_context() then return false end
			request = nil
		end
		if request then
			local checked, settled
			if request.valid_operation then checked, settled = pcall(request.operation.is_settled, request.operation)
			elseif request.operation == nil then checked, settled = true, request.dispatch_failed == true end
			if not checked or settled ~= true then return false end
			-- Retire the exact request before any observer/publication can reenter.
			context_request = nil
			local context = request.context
			request.context = nil
			retry_not_before_ms = options.now_ms() + options.retry_ms
			if not request.completed or type(context) ~= "table" then return false end
			local after = watch.barrier()
			if identity(after) ~= request.expected or context_generation ~= request.generation
				or detector.currentEpoch() ~= request.epoch then return false end
			local published, accepted, protected = pcall(options.publish_context, context)
			if not published or accepted ~= true or type(protected) ~= "boolean"
				or context_generation ~= request.generation then return false end
			local admitted, committed = pcall(detector.publishFocus, request.before.role, request.epoch, protected)
			if not admitted or committed ~= true or context_generation ~= request.generation then return false end
			joining_context, joining_identity = false, nil
			retry_not_before_ms = nil
			observed, context_pending, pending_epoch = request.expected, false, nil
			joined_context = { app_id = context.app_id, title = context.title, native_identity = context.native_identity }
			joined_field = { bus = request.before.bus, path = request.before.path, role = request.before.role,
				generation = request.generation, epoch = request.epoch }
			keylogger.set_secure_field(request.before.role == 40 or protected)
			return true
		end
		if not context_pending and pending_epoch == nil then return false end
		if attempted_generation == context_generation
			and (retry_not_before_ms == nil or options.now_ms() < retry_not_before_ms) then return false end
		if pending_epoch ~= nil and immediate ~= true and options.now_ms() < probe_not_before_ms then return false end
		local before = watch.barrier()
		if not before or before.role == 40 then return false end
		if attempted_generation == context_generation then context_generation = context_generation + 1 end
		local generation = context_generation
		local epoch = detector.currentEpoch()
		request = { generation = generation, epoch = epoch, before = { bus = before.bus, path = before.path, role = before.role },
			expected = identity(before), revoked = false, completed = false }
		context_request, attempted_generation = request, generation
		joining_context, joining_identity = true, request.expected
		local function authorized()
			return not stopped and context_request == request and not request.revoked
				and context_generation == generation and detector.currentEpoch() == epoch
		end
		local called, operation = pcall(options.capture_context_async, request.before,
			{ owner = context_owner, authorized = authorized }, function(context)
				if not authorized() then return end
				request.completed = true
				if type(context) == "table" and type(context.app_id) == "string" and context.app_id ~= ""
					and type(context.title) == "string" and type(context.native_identity) == "string" and context.native_identity ~= "" then
					request.context = { app_id = context.app_id, title = context.title, native_identity = context.native_identity }
				end
			end)
		if not called or operation == nil then request.dispatch_failed = called; return false end
		if type(operation) ~= "table" then return false end
		request.operation = operation
		if type(operation.cancel) ~= "function" or type(operation.is_settled) ~= "function" then return false end
		request.valid_operation = true
		if request.revoked or not authorized() then retire_context() end
		return false
	end

	local function accept_watch(snapshot)
		if suppress_watch then return false end
		if snapshot and pending_epoch ~= nil and options.now_ms() < probe_not_before_ms then return false end
		local identity = snapshot and snapshot.bus .. "\0" .. snapshot.path .. "\0" .. tostring(snapshot.role) or nil
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
			local previous_notifying = notifying_context
			notifying_context = true
			if identity(snapshot) ~= (joining_context and joining_identity or observed) or snapshot == nil then revoke_context() end
			notifying_context = previous_notifying
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
		joined_field = { bus = before.bus, path = before.path, role = before.role, generation = generation, epoch = epoch }
		-- The publisher has already installed the incoming app/title policy.
		keylogger.set_secure_field(before.role == 40 or protected)
		return true
	end

	--- Publishes a fresh verdict when the navigation event has had time to land.
	--- @param immediate boolean|nil Ignore the settle delay for an already-observed
	--- focused window (startup or top-level focus callback).
	--- @return boolean accepted
	function guard.refresh(immediate)
		if stopped then return false end
		if asynchronous then
			if refreshing_context or retiring_context or notifying_context then return false end
			refreshing_context = true
			local ok, accepted = pcall(refresh_async_context, immediate)
			refreshing_context = false
			if not ok then error(accepted, 0) end
			return accepted
		end
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

	--- Checks live privacy and retains the exact receipt from its single barrier.
	--- @return boolean blocked
	--- @return table|nil snapshot Fresh resident native receipt.
	local function text_admission()
		if stopped then return true end
		if joining_context then return true end
		local snapshot
		if watch then
			watch.pump()
			if pending_epoch ~= nil and options.now_ms() < probe_not_before_ms then return true end
			snapshot = watch.barrier()
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
		return not ok or secure ~= false, snapshot
	end

	--- Returns whether text automation must be withheld right now.
	--- @return boolean
	function guard.blocks_text()
		local blocked = text_admission()
		return blocked
	end

	--- Captures a fresh exact AI text target without launching a native helper.
	--- A receipt cannot outlive its joined context, generation or detector epoch.
	--- @return string|nil identity Exact active non-password bus/object identity.
	function guard.focused_text_identity()
		if reading_text_identity or stopped or not contextual or not watch or context_pending or joining_context
			or not joined_field or not joined_context then return nil end
		local field, context = joined_field, joined_context
		reading_text_identity = true
		local called, result = pcall(function()
			if field.generation ~= context_generation or field.epoch == nil
				or detector.currentEpoch() ~= field.epoch then return nil end
			local blocked, snapshot = text_admission()
			if blocked or not snapshot or snapshot.role == 40
				or snapshot.bus ~= field.bus or snapshot.path ~= field.path or snapshot.role ~= field.role
				or detector.currentEpoch() ~= field.epoch or joined_field ~= field or joined_context ~= context
				or field.generation ~= context_generation or context_pending or joining_context or stopped then return nil end
			return "atspi:" .. field.bus .. ":" .. field.path
		end)
		reading_text_identity = false
		return called and result or nil
	end

	--- Fences all publication and retains helper resources until native retirement.
	--- @return boolean settled
	function guard.stop()
		stopped = true
		if contextual then revoke_context() end
		keylogger.set_secure_field(true)
		return retire_context()
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
