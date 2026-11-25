--- modules/keystats/focus_guard.lua

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
--- 5. Every verdict read from a field reaches keystats.set_secure_field with
---    read = true, a password role included, so the context a touch began in
---    never outlives it (tap-click-touch-context); a withdrawal that carries
---    no news of the field, the focus worker's answer to an invalidation,
---    passes read = false.
--- 6. Text automation has three modes (text_automation): "field" when the
---    focused field is admitted; "window" when no field verdict exists for a
---    reason that is the desktop's (no accessibility worker, a window on no
---    application of the bus, an unanswered or ambiguous query, a context that
---    cannot be joined) and the window policy admits the focused window; and
---    "closed" otherwise. A password field seen and not yet left, a protected
---    context, the settle delay after navigation and a stopped guard always
---    close. Metrics and every other blocks_text() reader stay closed outside
---    "field" (decided 2026-11-25, see TODO.md).
--- ==============================================================================

local M = {}

-- How long an output boundary of a retained destination waits for the focus
-- worker's fresh answer: the worker's own native query deadline. The input
-- budget (focus_barrier_timeout_ms) holds a physical key; an output boundary
-- holds none, and right after an erase the application is still busy with
-- the Backspaces just sent to it. With the input budget an expansion failed
-- at random there as programmable_publication_stale (real-GTK field test).
local OUTPUT_BARRIER_MS = require("core.timing.engine.timings").ms("privacy", "atspi_probe_timeout_ms")

-- The closing reasons that are the desktop's, not the field's: with them alone
-- the window policy may still admit ordinary text automation (INVARIANTS 6).
local WINDOW_REASONS = {
	atspi_unavailable = true, no_accessible_window = true, no_focus_answer = true,
	context_pending = true, context_unavailable = true, field_unknown = true,
}
M.WINDOW_REASONS = WINDOW_REASONS





-- =================================
-- =================================
-- ======= 1/ Guard Factory ========
-- =================================
-- =================================

--- Creates one daemon-owned focus guard.
--- @param opts table {
---   detector, keystats, prediction?, reset_text?, now_ms, settle_ms?,
---   capture_context?, capture_context_async?, retry_ms?, publish_context?,
---   window_policy?, on_state?
--- }
--- window_policy() -> allowed, reason: whether the focused window, as the
--- compositor names it, admits text automation without a field verdict.
--- on_state(mode, reason): called when the text automation mode changes.
--- @return table guard
function M.new(opts)
	local options = type(opts) == "table" and opts or {}
	if type(options.keystats) ~= "table"
		or type(options.keystats.set_secure_field) ~= "function"
	then
		error("focus_guard requires keystats.set_secure_field")
	end
	if type(options.now_ms) ~= "function" then
		error("focus_guard requires a monotonic now_ms function")
	end

	local detector = options.detector
	local keystats = options.keystats
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
	if options.window_policy ~= nil and type(options.window_policy) ~= "function" then
		error("focus_guard window_policy must be a function")
	end
	if options.on_state ~= nil and type(options.on_state) ~= "function" then
		error("focus_guard on_state must be a function")
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
	-- A password field seen and not left for another field: it closes even the
	-- window mode, whatever later answers fail to say (INVARIANTS 6).
	local password_latched = false
	-- Whether the worker left the latest input barrier unanswered (text_admission).
	local worker_unanswered = false
	-- Context joins that settled without a context since the last success.
	local context_failures = 0
	local state_mode, state_reason = "closed", "starting"

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
	--- @param answer boolean|nil True for the focus worker's answer to a
	--- refresh, which withdraws without reading the field (INVARIANTS 5).
	local function revoke_context(answer)
		context_generation = context_generation + 1
		retry_not_before_ms = nil
		if asynchronous then retire_context(); joining_context, joining_identity = false, nil end
		context_pending, observed, joined_context, joined_field = true, nil, nil, nil
		if detector and type(detector.invalidateFocus) == "function" then detector.invalidateFocus() end
		if answer == true then keystats.set_secure_field(true, false) else keystats.set_secure_field(true) end
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
		keystats.set_secure_field(true)
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
			if not request.completed or type(context) ~= "table" then context_failures = context_failures + 1; return false end
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
			context_failures = 0
			observed, context_pending, pending_epoch = request.expected, false, nil
			joined_context = { app_id = context.app_id, title = context.title, native_identity = context.native_identity }
			joined_field = { bus = request.before.bus, path = request.before.path, role = request.before.role,
				generation = request.generation, epoch = request.epoch }
			keystats.set_secure_field(request.before.role == 40 or protected, true)
			return true
		end
		if not context_pending and pending_epoch == nil then return false end
		if attempted_generation == context_generation
			and (retry_not_before_ms == nil or options.now_ms() < retry_not_before_ms) then return false end
		if pending_epoch ~= nil and immediate ~= true and options.now_ms() < probe_not_before_ms then return false end
		local before = watch.barrier()
		-- A password field is a verdict read, though it stays unknown here.
		if before and before.role == 40 then keystats.set_secure_field(true, true) end
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
		if not called or operation == nil then
			request.dispatch_failed = called
			context_failures = context_failures + 1
			return false
		end
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
		keystats.set_secure_field(true)
		if prediction and type(prediction.cancel) == "function" then pcall(prediction.cancel) end
		reset_text()
		pending_epoch = nil
		if not snapshot or not detector or type(detector.publishFocus) ~= "function" then return false end
		local ok, accepted = pcall(detector.publishFocus, snapshot.role, epoch)
		if not ok or accepted ~= true then return false end
		keystats.set_secure_field(snapshot.role == 40, true)
		return true
	end
	if watch then
		watch.on_change(function(snapshot)
			if suppress_watch then return false end
			if not contextual then return accept_watch(snapshot) end
			local previous_notifying = notifying_context
			notifying_context = true
			if snapshot then password_latched = snapshot.role == 40 end
			if snapshot and snapshot.role == 40 then keystats.set_secure_field(true, true) end
			if identity(snapshot) ~= (joining_context and joining_identity or observed) or snapshot == nil then
				revoke_context(true)
			end
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
		keystats.set_secure_field(before.role == 40 or protected, true)
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
			keystats.set_secure_field(true)
			return false
		end
		if pending_epoch == nil then return false end
		if immediate ~= true and options.now_ms() < probe_not_before_ms then return false end

		local epoch = pending_epoch
		local ok, accepted = pcall(detector.refresh, epoch)
		if not ok or accepted ~= true then
			keystats.set_secure_field(true)
			-- Do not hammer a missing accessibility service four times per second.
			-- The next physical/top-level focus transition schedules the next probe.
			pending_epoch = nil
			return false
		end

		local ok_secure, secure = pcall(detector.isSecureField)
		if not ok_secure or type(secure) ~= "boolean" then
			keystats.set_secure_field(true)
			pending_epoch = nil
			return false
		end
		keystats.set_secure_field(secure, true)
		pending_epoch = nil
		return true
	end

	--- Invalidates and immediately probes an already-settled focused window.
	--- @return boolean accepted
	function guard.prime()
		guard.invalidate()
		return guard.refresh(true)
	end

	--- Names the closing reason when no fresh field receipt exists.
	--- @return string reason
	local function authority_reason()
		local authority = watch and type(watch.authority) == "function" and watch.authority() or "unavailable"
		if authority == "unavailable" then return "atspi_unavailable" end
		if authority == "absent" then return "no_accessible_window" end
		return "no_focus_answer"
	end

	--- Names the closing reason while the field's context is not joined.
	--- @return string reason
	local function context_reason()
		return context_failures > 0 and "context_unavailable" or "context_pending"
	end

	--- Checks live privacy and retains the exact receipt from its single barrier.
	--- @param budget_ms number|nil Barrier answer deadline; nil for the input budget.
	--- @return boolean blocked
	--- @return table|nil snapshot Fresh resident native receipt.
	--- @return string reason Why text is admitted or withheld (INVARIANTS 6).
	local function text_admission(budget_ms)
		if stopped then return true, nil, "stopped" end
		if joining_context then return true, nil, context_reason() end
		local snapshot
		local protected = false
		if watch then
			watch.pump()
			if pending_epoch ~= nil and options.now_ms() < probe_not_before_ms then return true, nil, "settling" end
			-- No joined field: once the worker let one barrier's budget pass, a
			-- physical key reads its answers without waiting (KDE Wayland joins
			-- none, and each press and release used to wait the whole budget).
			-- Only a fresh answer to the latest request counts, as a barrier's;
			-- an output boundary's own budget still waits.
			if budget_ms == nil and contextual and context_pending and worker_unanswered then
				local answered
				snapshot, answered = watch.poll()
				if answered then worker_unanswered = false end
			else
				snapshot = watch.barrier(budget_ms)
				-- A watch without answer polling (a controlled double) keeps barriers.
				worker_unanswered = type(watch.poll) == "function" and type(watch.answered) == "function"
					and not watch.answered()
			end
			if snapshot then password_latched = snapshot.role == 40 end
			if contextual then
				if not snapshot or identity(snapshot) ~= observed then
					if not context_pending then revoke_context() end
					if snapshot and snapshot.role == 40 then return true, snapshot, "password_field" end
					return true, snapshot, snapshot and context_reason() or authority_reason()
				end
				if context_pending then
					return true, snapshot, snapshot.role == 40 and "password_field" or context_reason()
				end
				-- User filter choices can change without moving the native field.
				-- Re-evaluate policy in RAM, retaining the already joined metadata.
				local checked
				checked, protected = pcall(keystats.is_context_protected, joined_context.app_id, joined_context.title)
				if not checked or type(protected) ~= "boolean" then revoke_context(); return true, snapshot, "context_pending" end
				local epoch = detector and type(detector.currentEpoch) == "function" and detector.currentEpoch() or nil
				local published, accepted = pcall(function() return detector.publishFocus(snapshot.role, epoch, protected) end)
				if not published or accepted ~= true then revoke_context(); return true, snapshot, "context_pending" end
				keystats.set_secure_field(snapshot.role == 40 or protected, true)
			elseif not accept_watch(snapshot) then return true, snapshot, snapshot and "field_unknown" or authority_reason() end
		end
		if not detector or type(detector.isSecureField) ~= "function" then return true, snapshot, "no_detector" end
		local ok, secure = pcall(detector.isSecureField)
		if ok and secure == false then return false, snapshot, "field_admitted" end
		if snapshot and snapshot.role == 40 then return true, snapshot, "password_field" end
		if protected then return true, snapshot, "protected_context" end
		return true, snapshot, (snapshot or not watch) and "field_unknown" or authority_reason()
	end

	--- Records the text automation mode, telling on_state of a change.
	--- @param mode string "field", "window" or "closed".
	--- @param reason string
	local function publish_state(mode, reason)
		if mode == state_mode and reason == state_reason then return end
		state_mode, state_reason = mode, reason
		if options.on_state then options.on_state(mode, reason) end
	end

	--- Decides the window mode for a reason that left no field verdict.
	--- @param reason string The field admission's closing reason.
	--- @return boolean allowed
	--- @return string reason
	local function window_admission(reason)
		if not WINDOW_REASONS[reason] then return false, reason end
		-- A window on no application of the bus holds no field of one: an old
		-- password field cannot be focused there.
		if reason == "no_accessible_window" then password_latched = false end
		if password_latched then return false, "password_field" end
		if not options.window_policy then return false, reason end
		local called, allowed, why = pcall(options.window_policy)
		if not called then return false, "window_policy_failed" end
		if allowed ~= true then return false, type(why) == "string" and why or "protected_context" end
		return true, reason
	end

	--- Decides whether ordinary text automation (hotstrings, their erase and
	--- output) may act on the focused control right now (INVARIANTS 6).
	--- @param budget_ms number|nil Barrier answer deadline; nil for the input budget.
	--- @return boolean allowed
	--- @return string mode "field", "window" or "closed".
	--- @return string reason
	function guard.text_automation(budget_ms)
		local blocked, _, reason = text_admission(budget_ms)
		if not blocked then publish_state("field", reason); return true, "field", reason end
		local allowed, why = window_admission(reason)
		local mode = allowed and "window" or "closed"
		publish_state(mode, why)
		return allowed, mode, why
	end

	--- The last text automation mode and its reason, read from RAM.
	--- @return table state { mode, reason }
	function guard.automation_state()
		return { mode = state_mode, reason = state_reason }
	end

	--- Forgets a password field once the compositor reports another window.
	function guard.window_changed()
		password_latched = false
	end

	--- Returns whether text automation must be withheld right now.
	--- @return boolean
	function guard.blocks_text()
		local blocked = text_admission()
		return blocked
	end

	--- Captures a fresh exact AI text target without launching a native helper.
	--- A receipt cannot outlive its joined context, generation or detector epoch.
	--- @param budget_ms number|nil Barrier answer deadline; nil for the input budget.
	--- @return string|nil identity Exact active non-password bus/object identity.
	function guard.focused_text_identity(budget_ms)
		if reading_text_identity or stopped or not contextual or not watch or context_pending or joining_context
			or not joined_field or not joined_context then return nil end
		local field, context = joined_field, joined_context
		reading_text_identity = true
		local called, result = pcall(function()
			if field.generation ~= context_generation or field.epoch == nil
				or detector.currentEpoch() ~= field.epoch then return nil end
			local blocked, snapshot = text_admission(budget_ms)
			if blocked or not snapshot or snapshot.role == 40
				or snapshot.bus ~= field.bus or snapshot.path ~= field.path or snapshot.role ~= field.role
				or detector.currentEpoch() ~= field.epoch or joined_field ~= field or joined_context ~= context
				or field.generation ~= context_generation or context_pending or joining_context or stopped then return nil end
			return "atspi:" .. field.bus .. ":" .. field.path
		end)
		reading_text_identity = false
		return called and result or nil
	end


	-- Capture constructor-owned ports before any ordinary injection admission.
	local text_owner_ports = {
		focus = guard.focused_text_identity, barrier = watch and watch.barrier, pump = watch and watch.pump,
		snapshot = watch and watch.snapshot, epoch = detector and detector.currentEpoch,
		verdict = detector and detector.getVerdict, policy = keystats.is_context_protected,
	}

	--- Retains one ordinary text destination across blocking injection phases.
	--- Fresh checks use the resident barrier; per-DOWN checks only observe RAM.
	--- This cannot make compositor focus changes atomic with emitted keystrokes.
	--- @param expected_focus string|nil Exact target retained by an originating action.
	--- @return table|nil owner Full-phase and cached-key publication guards.
	function guard.capture_text_owner(expected_focus)
		local owner = guard.capture_field_owner(expected_focus)
		if owner or expected_focus ~= nil or state_mode ~= "window" or stopped then return owner end
		-- The window mode retains no field: its owner holds while no navigation,
		-- revocation or field verdict moves the guard, and the mode still holds.
		local generation = context_generation
		local window_owner = {}
		function window_owner.cached()
			if stopped or context_generation ~= generation or state_mode ~= "window" or password_latched then return false end
			if not options.window_policy then return false end
			local called, allowed = pcall(options.window_policy)
			return called and allowed == true
		end
		-- The input budget, never OUTPUT_BARRIER_MS: the window mode exists
		-- because the worker gives no field answer, so the long barrier only
		-- timed out, and an expansion's preflight waits here while the
		-- hook's forwarded trigger key is still down on the virtual keyboard.
		-- On KDE Wayland ",e" then autorepeated into ",eeeeeeeeeje" before the
		-- release reached the desktop (Arch field report, 2026-11-25). Once the
		-- worker left a barrier unanswered, text_admission polls without waiting.
		function window_owner.current()
			if not window_owner.cached() then return false end
			local allowed, mode = guard.text_automation()
			return allowed and mode == "window" and window_owner.cached()
		end
		return window_owner.cached() and window_owner or nil
	end

	--- Retains one exact admitted field across blocking injection phases.
	--- @param expected_focus string|nil Exact target retained by an originating action.
	--- @return table|nil owner Full-phase and cached-key publication guards.
	function guard.capture_field_owner(expected_focus)
		if not contextual or not watch or not detector then return nil end
		local focus, barrier, pump, snapshot = text_owner_ports.focus, text_owner_ports.barrier, text_owner_ports.pump, text_owner_ports.snapshot
		local epoch, verdict, policy = text_owner_ports.epoch, text_owner_ports.verdict, text_owner_ports.policy
		if type(focus) ~= "function" or type(barrier) ~= "function" or type(pump) ~= "function"
			or type(snapshot) ~= "function" or type(epoch) ~= "function" or type(verdict) ~= "function"
			or type(policy) ~= "function" then return nil end
		local function ports_current()
			return guard.focused_text_identity == focus and watch.barrier == barrier and watch.pump == pump
				and watch.snapshot == snapshot and detector.currentEpoch == epoch and detector.getVerdict == verdict
				and keystats.is_context_protected == policy
		end
		if not ports_current() then return nil end
		local captured, target = pcall(focus)
		if not captured or not target or (expected_focus ~= nil and target ~= expected_focus)
			or not ports_current() or not joined_field or not joined_context then return nil end
		local field, context, generation = joined_field, joined_context, context_generation
		local bus, path, role, field_epoch = field.bus, field.path, field.role, field.epoch
		local app, title, native = context.app_id, context.title, context.native_identity
		local function retained()
			return ports_current() and not stopped and not context_pending and not joining_context
				and rawequal(joined_field, field) and rawequal(joined_context, context) and context_generation == generation
				and field.bus == bus and field.path == path and field.role == role and field.epoch == field_epoch and field.generation == generation
				and context.app_id == app and context.title == title and context.native_identity == native
				and epoch() == field_epoch
		end
		local owner = {}
		function owner.cached()
			local checked, current = pcall(function()
				if not retained() or policy(app, title) ~= false or not retained() or verdict() ~= "insecure" then return false end
				local observed = snapshot()
				return retained() and type(observed) == "table" and getmetatable(observed) == nil and observed.bus == bus and observed.path == path
					and observed.role == role and role ~= 40
			end)
			return checked and current == true
		end
		function owner.current()
			local checked, current = pcall(function() return retained() and focus(OUTPUT_BARRIER_MS) == target and owner.cached() end)
			return checked and current == true
		end
		return owner.cached() and owner or nil
	end

	--- Reports retained context ownership without querying native focus.
	--- Idle reconciliation must not start fresh probes for unknown/password fields.
	--- @return boolean retained
	function guard.has_context_operation()
		return context_request ~= nil
	end

	--- Fences all publication and retains helper resources until native retirement.
	--- @return boolean settled
	function guard.stop()
		stopped = true
		publish_state("closed", "stopped")
		if contextual then revoke_context() end
		keystats.set_secure_field(true)
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
