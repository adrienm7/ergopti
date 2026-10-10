--- modules/llm/ollama_deps_checker.lua

--- ==============================================================================
--- MODULE: Ollama Dependencies Checker
--- DESCRIPTION:
--- Companion to mlx_deps_checker but for the Ollama backend: ensures the
--- `ollama` binary is installed, then delegates daemon start to ApiOllama's
--- exact lifecycle owner. The shell script never detaches a server process;
--- this module owns its install task, marker parsing, and progress UI.
---
--- FEATURES & RATIONALE:
--- 1. Consent-gated download: an existing Ollama (resolved by ollama_binary)
---    is always reused; the pinned release is downloaded only through
---    install_for_selection(), after the user selected the Ollama backend and
---    accepted the offer. Any other check settles as "missing" instead.
--- 2. Silent fast path: when the executable already exists, provisioning exits
---    silently and daemon acquisition remains under the Lua owner.
--- 3. Granular progress UX: the install marker and Lua-owned daemon transition
---    map to precise French steps in the unified download window.
--- 4. Split lifecycle verdicts: dependency provisioning and daemon acquisition
---    expose independent tri-state results, so a transient server-start refusal
---    never poisons the install state shared with mlx_deps_checker.
--- ==============================================================================

local M = {}
local hs           = hs
local Logger       = require("infra.logger")
local i18n         = require("infra.i18n")
local llm_progress = require("ui.download_window")
local OllamaBinary = require("modules.llm.ollama_binary")
local ApiOllama     = require("modules.llm.api_ollama")
local ApiCommon     = require("modules.llm.api_common")
local TaskLifecycle = require("adapters.task_lifecycle")
local TimerScheduler = require("adapters.timer_scheduler")
local Timings = require("infra.timings")
local BootstrapPauseOwner = require("modules.llm.dependency_bootstrap_pause_owner")
local PtyProcessGroup = require("modules.llm.pty_process_group")
local PythonInterpreter = require("adapters.python_interpreter")

local LOG = "ollama_deps"

local MARKER_INSTALLING = "OLLAMA_INSTALLING"
local MARKER_VERIFIED   = "OLLAMA_VERIFIED"
local MARKER_STARTING   = "OLLAMA_STARTING"
local MARKER_READY      = "OLLAMA_READY"
-- Followed by an integer percentage; drives the shared window's progress bar.
local DOWNLOAD_PROGRESS_PATTERN = "^OLLAMA_DOWNLOAD_PROGRESS (%d+)$"

-- Step labels keyed by marker. The "READY" marker also doubles as a
-- success-final-step we render before auto-hiding.
local PROGRESS_LABELS = {
	[MARKER_INSTALLING] = i18n.get("ollama.deps_step_installing"),
	[MARKER_VERIFIED]   = i18n.get("ollama.deps_step_verified"),
	[MARKER_STARTING]   = i18n.get("ollama.deps_step_starting"),
	[MARKER_READY]      = i18n.get("ollama.deps_step_ready"),
}

-- Failure markers the script prints before exiting, mapped to the localized
-- explanation the user sees instead of the English script tail.
local FAILURE_MESSAGES = {
	OLLAMA_ERROR_NETWORK  = "ollama.error_network",
	OLLAMA_ERROR_CHECKSUM = "ollama.error_checksum",
}

local KNOWN_MARKERS = {
	[MARKER_INSTALLING] = true,
	[MARKER_VERIFIED]   = true,
	[MARKER_STARTING]   = true,
	[MARKER_READY]      = true,
}
for marker, _ in pairs(FAILURE_MESSAGES) do KNOWN_MARKERS[marker] = true end

local FAILURE_TAIL_CHARS    = 280
local SUCCESS_AUTO_HIDE_SEC = 1.5
local BOOTSTRAP_TIMEOUT_SEC = Timings.sec("llm", "dependency_bootstrap_timeout_ms")

-- "pending" until the first check, "ready" once an executable is provisioned,
-- "missing" when none exists and nobody asked for the download, "failed".
local _bootstrap_state      = "pending"
local _last_failure_message = nil
local _daemon_state         = "pending"
local _last_daemon_failure_message = nil
local _native_pty_preflight_owner = nil
local _task_running         = false  -- reentrancy guard: prevents duplicate concurrent tasks
-- Download authority. Only install_for_selection() grants it, after the user
-- accepted the offer; the next check consumes it, so a boot, an AI enable with
-- another backend or an update can never start a download.
local _install_granted      = false
-- Last failure marker the running script printed, read at its terminal.
local _observed_failure_marker = nil

-- GC root for the live bootstrap hs.task. The handle below is a FUNCTION-local, so
-- it goes out of scope as soon as the spawning function returns while the
-- subprocess is still running — an unreferenced hs.task can be collected mid-run,
-- killing the install and dropping its completion callback. Canonical spelling
-- recognised by tests/unit/meta/test_gc_retention.lua; released in the callback.
local _active_tasks = {}

local _owned_timers = { initial = nil, hide = nil, deadline = nil }
local _task_owner = nil
local _resume_intent = nil
local _pending_callbacks = {}
local _terminal_outcome = nil

local quiesce_owned_work
local replay_committed_intent
local settle_replay_failure
local schedule_initial_for_token
local schedule_hide_for_token
local fire_pending_callbacks

local _pause_controller = BootstrapPauseOwner.new({
	owner_name = "ollama_dependency_bootstrap",
	label = "Ollama dependency",
	quiesce = function() return quiesce_owned_work() end,
	replay = function(token, epoch) return replay_committed_intent(token, epoch) end,
	replay_failure = function(token, reason) return settle_replay_failure(token, reason) end,
})






-- ==================================
-- ==================================
-- ======= 1/ Path Resolution =======
-- ==================================
-- ==================================

--- Resolves the project root from this file's own path.
--- @return string|nil project_root Absolute path or nil.
local function resolve_project_root()
	local source = debug.getinfo(1, "S").source or ""
	source = source:sub(1, 1) == "@" and source:sub(2) or source
	local root = source:match("^(.*)/static/ergopti_plus/macos/modules/llm/ollama_deps_checker%.lua$")
	if root and root ~= "" and hs.fs.attributes(root, "mode") then
		return root
	end
	return nil
end




-- ===========================================
-- ===========================================
-- ======= 2/ Marker / Output Parsing ========
-- ===========================================
-- ===========================================

local function chunk_contains(chunk, marker)
	if type(chunk) ~= "string" or chunk == "" then return false end
	for line in chunk:gmatch("([^\n\r]+)") do
		if line == marker then return true end
	end
	return false
end

local function forward_chunk(chunk, is_current, owns_ui)
	if type(chunk) ~= "string" or chunk == "" then return true end
	is_current = type(is_current) == "function" and is_current or function() return true end
	owns_ui = type(owns_ui) == "function" and owns_ui or function() return false end
	for line in chunk:gmatch("([^\n\r]+)") do
		local percent = line:match(DOWNLOAD_PROGRESS_PATTERN)
		if FAILURE_MESSAGES[line] then
			_observed_failure_marker = line
		elseif percent then
			if not is_current() then return false end
			if owns_ui() then pcall(llm_progress.set_progress, tonumber(percent)) end
		elseif line:match("%S") and not KNOWN_MARKERS[line] then
			if not is_current() then return false end
			Logger.info(LOG, "[script] %s", line)
			-- set_detail shows the latest line at a glance; append_log preserves
			-- the full audit trail — mirroring the mlx_deps_checker behaviour.
			if owns_ui() then
				if not is_current() then return false end
				pcall(llm_progress.set_detail, line)
			end
			if owns_ui() then
				if not is_current() then return false end
				pcall(llm_progress.append_log, line)
			end
		end
	end
	return true
end

local function tail_for_error(s)
	if type(s) ~= "string" or s == "" then return "" end
	local n = #s
	local start = n > FAILURE_TAIL_CHARS and (n - FAILURE_TAIL_CHARS + 1) or 1
	local tail = s:sub(start)
	tail = tail:gsub("^[^\n]*\n", "")
	for marker, _ in pairs(KNOWN_MARKERS) do
		tail = tail:gsub(marker .. "\n?", "")
	end
	tail = tail:gsub("OLLAMA_DOWNLOAD_PROGRESS %d+\n?", "")
	tail = tail:gsub("[ \t]+\n", "\n"):gsub("\n\n+", "\n")
	local last = tail:match("([^\n]+)%s*$")
	return last or tail
end




-- ===============================================
-- ===============================================
-- ======= 3/ Streaming Progress Handler =========
-- ===============================================
-- ===============================================

-- Identity of the shared progress window at the moment THIS checker claimed it,
-- or nil while it owns nothing.
--
-- The window is a single-instance surface: the model download, the MLX
-- bootstrap and this checker can each take it over. Every later write or hide
-- must therefore prove it still owns what it is about to touch — and the
-- session has to be captured when the window is CLAIMED, not sampled at
-- completion, which reads whoever owns it by then.
--
-- Module-level on purpose. make_streaming_handler assigns it and the task
-- completion callback reads it; a local inside check_and_install_deps would be
-- out of scope for the handler, which would silently bind a nil global instead.
local _ui_session = nil
local _ui_claimed = false

local function owned_session()
	if type(llm_progress.session_id) ~= "function" then return nil end
	local ok, sid = pcall(llm_progress.session_id)
	return ok and sid or nil
end

--- True when the progress window still belongs to this checker. Defaults to
--- true when no session was ever recorded, so a build without session support
--- behaves exactly as before rather than silently doing nothing.
local function owns_window()
	if _ui_claimed ~= true then return false end
	if _ui_session == nil then return true end
	local current = owned_session()
	if current == nil then return true end
	return current == _ui_session
end

local function release_window_claim()
	_ui_claimed = false
	_ui_session = nil
end

--- Builds a closure consuming stdout/stderr chunks. Lazily shows the
--- progress UI on the first marker so a silent fast-path run never paints.
local function make_streaming_handler(is_current)
	is_current = type(is_current) == "function" and is_current or function() return true end
	local shown    = {}
	local ui_shown = false

	return function(_, stdout_chunk, stderr_chunk)
		if not is_current() then return false end
		if not forward_chunk(stderr_chunk, is_current, owns_window) then return false end
		if not forward_chunk(stdout_chunk, is_current, owns_window) then return false end

		if type(stdout_chunk) ~= "string" or stdout_chunk == "" then
			return true
		end

		for marker, label in pairs(PROGRESS_LABELS) do
			if not shown[marker] and chunk_contains(stdout_chunk, marker) then
				if not is_current() then return false end
				shown[marker] = true
				Logger.info(LOG, "Progress marker '%s' observed — updating UI.", marker)
				if not ui_shown then
					local active_ok, active = pcall(llm_progress.is_active)
					if not is_current() then return false end
					if active_ok and active ~= true then
						local shown_ok = pcall(llm_progress.show, {
							kind     = "ollama_install",
							title    = i18n.get("ollama.install_title"),
							subtitle = label,
						})
						if not is_current() then return false end
						if shown_ok then
							local claimed_session = owned_session()
							if not is_current() then return false end
							_ui_session = claimed_session
							_ui_claimed = true
							ui_shown = true
						end
					elseif owns_window() then
						ui_shown = true
						pcall(llm_progress.set_step, label)
						if not is_current() then return false end
					end
				elseif owns_window() then
					if not is_current() then return false end
					pcall(llm_progress.set_step, label)
				end
			end
		end
		return true
	end
end





-- ==========================================
-- ==========================================
-- ======= 4/ Pause-Owned Native Work =======
-- ==========================================
-- ==========================================

local function arm_owned_timer(slot, delay_sec, callback, label)
	local prior = _owned_timers[slot]
	if type(prior) == "table" and prior.settled ~= true then
		Logger.error(LOG, "%s timer acquisition refused while its predecessor remains owned.", label)
		return false
	end
	local owner = {
		acquiring = true,
		cancel_requested = false,
		acquisition_valid = false,
		delivery_requested = false,
		delivery_seen = false,
		delivery_during_acquisition = false,
		native_settled = false,
		observer_attached = false,
		settled = false,
		handle = nil,
		settlement_callbacks = {},
	}
	-- Publish identity before crossing TimerScheduler.after(): native start may
	-- synchronously re-enter ScriptControl PAUSE before the handle is returned.
	_owned_timers[slot] = owner
	local release_owner
	local deliver_owner
	local observe_owner
	release_owner = function()
		if owner.settled == true then return false end
		owner.settled = true
		if _owned_timers[slot] == owner then _owned_timers[slot] = nil end
		local callbacks = owner.settlement_callbacks
		owner.settlement_callbacks = {}
		for _, settled_callback in ipairs(callbacks) do
			local callback_ok, callback_error = xpcall(settled_callback, debug.traceback)
			if callback_ok ~= true then
				Logger.error(LOG, "%s timer settlement callback failed: %s.",
					label, tostring(callback_error))
			end
		end
		return true
	end
	observe_owner = function()
		if owner.settled == true or owner.observer_attached == true then return true end
		local handle = owner.handle
		if type(handle) ~= "table" or handle.timer == nil then
			owner.native_settled = true
			if owner.delivery_requested == true then
				return deliver_owner()
			end
			if owner.cancel_requested == true or owner.acquisition_valid ~= true then
				release_owner()
			end
			return true
		end
		owner.observer_attached = true
		local observed_ok, observed = xpcall(function()
			return TimerScheduler.onSettled(handle, function()
				owner.observer_attached = false
				owner.native_settled = true
				if owner.delivery_requested == true then
					deliver_owner()
				elseif owner.cancel_requested == true or owner.acquisition_valid ~= true then
					release_owner()
				end
			end)
		end, debug.traceback)
		if not observed_ok or observed ~= true then
			owner.observer_attached = false
			Logger.error(LOG, "%s timer settlement observer refused: %s.",
				label, tostring(observed_ok and observed or observed))
			return false
		end
		return true
	end
	deliver_owner = function()
		if owner.delivery_seen == true or owner.settled == true then return false end
		owner.delivery_requested = true
		if owner.acquiring == true then
			owner.delivery_during_acquisition = true
			return false
		end
		local handle = owner.handle
		if type(handle) == "table" and handle.timer ~= nil then
			observe_owner()
			return false
		end
		owner.native_settled = true
		local authorized = owner.acquisition_valid == true
			and owner.cancel_requested ~= true
			and _owned_timers[slot] == owner
		owner.delivery_seen = true
		release_owner()
		if not authorized then return false end
		callback()
		return true
	end
	local candidate
	local ok, handle_or_error, committed = xpcall(function()
		return TimerScheduler.after(delay_sec, function()
			deliver_owner()
		end)
	end, debug.traceback)
	if ok and type(handle_or_error) == "table" then candidate = handle_or_error end
	owner.handle = candidate
	owner.acquiring = false
	if ok and committed == true and type(candidate) == "table"
		and candidate.timer ~= nil and owner.delivery_during_acquisition ~= true
		and owner.cancel_requested ~= true
		and _owned_timers[slot] == owner then
		owner.acquisition_valid = true
		observe_owner()
		return true
	end
	owner.acquisition_valid = false
	owner.cancel_requested = true
	if type(candidate) == "table" and candidate.timer ~= nil then
		local cancel_ok, settled = xpcall(function()
			return TimerScheduler.cancel(candidate)
		end, debug.traceback)
		if cancel_ok and settled == true then
			owner.native_settled = true
			release_owner()
		else
			observe_owner()
		end
	else
		owner.native_settled = true
		release_owner()
	end
	Logger.error(LOG, "%s timer acquisition refused: %s.",
		label, tostring(ok and committed or handle_or_error))
	return false
end

local function cancel_owned_timer(slot, label)
	local owner = _owned_timers[slot]
	if type(owner) == "table" and owner.acquiring == true then
		owner.cancel_requested = true
		owner.acquisition_valid = false
		Logger.debug(LOG, "%s timer cancellation joined an in-flight acquisition.", label)
		return false
	end
	if type(owner) ~= "table" or owner.settled == true then
		_owned_timers[slot] = nil
		return true
	end
	owner.cancel_requested = true
	owner.acquisition_valid = false
	local handle = owner.handle
	if type(handle) ~= "table" or handle.timer == nil then
		owner.native_settled = true
		owner.settled = true
		if _owned_timers[slot] == owner then _owned_timers[slot] = nil end
		return true
	end
	local ok, settled_or_error = xpcall(function()
		return TimerScheduler.cancel(handle)
	end, debug.traceback)
	if ok and settled_or_error == true then
		owner.native_settled = true
		owner.settled = true
		if _owned_timers[slot] == owner then _owned_timers[slot] = nil end
		return true
	end
	Logger.error(LOG, "%s timer cancellation refused; exact handle retained: %s.",
		label, tostring(settled_or_error))
	return false
end

--- Registers one continuation behind an exact timer settlement.
--- @param slot string Timer slot name.
--- @param callback function Continuation invoked after native settlement.
--- @return boolean registered
local function when_owned_timer_settled(slot, callback)
	local owner = _owned_timers[slot]
	if type(callback) ~= "function" then return false end
	if type(owner) ~= "table" or owner.settled == true then
		callback()
		return true
	end
	owner.settlement_callbacks[#owner.settlement_callbacks + 1] = callback
	return true
end

local function release_task_owner(owner)
	if type(owner) ~= "table" or owner.settled == true then return false end
	owner.settled = true
	local task = owner.task
	if task ~= nil then _active_tasks[task] = nil end
	if _task_owner == owner then _task_owner = nil end
	_task_running = false
	return true
end

local function terminate_task_owner(owner, label)
	if type(owner) ~= "table" or owner.settled == true then return true end
	owner.authorized = false
	if type(owner.native_terminal_retry) == "function" then
		owner.native_terminal_retry()
		if owner.settled == true then return true end
	end
	if owner.termination_accepted == true then return false end
	local accepted = TaskLifecycle.terminate(owner.task, label)
	if owner.settled == true then return true end
	if accepted ~= true then return false end
	owner.termination_accepted = true
	Logger.debug(LOG, "%s termination accepted; awaiting exact completion.", label)
	return false
end

quiesce_owned_work = function()
	local initial_settled = cancel_owned_timer("initial", "Ollama initial bootstrap")
	local hide_settled = cancel_owned_timer("hide", "Ollama bootstrap auto-hide")
	local deadline_settled = cancel_owned_timer("deadline", "Ollama dependency bootstrap deadline")
	local task_settled = terminate_task_owner(_task_owner, "Ollama dependency bootstrap")
	local preflight_settled = true
	if _native_pty_preflight_owner ~= nil then
		preflight_settled = _native_pty_preflight_owner.rollback() == true
		if preflight_settled then _native_pty_preflight_owner = nil end
	end
	return initial_settled == true and hide_settled == true
		and deadline_settled == true and task_settled == true and preflight_settled == true
end

schedule_initial_for_token = function(token)
	local authorization = _pause_controller.capture(token)
	if authorization == nil then return false end
	_resume_intent = { kind = "initial" }
	local committed = arm_owned_timer("initial", 0, function()
		if not _pause_controller.is_current(token, authorization) then return false end
		return M.check_and_install_deps(nil, token)
	end, "Ollama initial bootstrap")
	if committed ~= true then
		_pause_controller.complete(token)
		return false
	end
	if _pause_controller.commit(token) ~= true then
		cancel_owned_timer("initial", "Ollama initial bootstrap rollback")
		_pause_controller.complete(token)
		return false
	end
	return true
end

schedule_hide_for_token = function(token, hide_session)
	local authorization = _pause_controller.capture(token)
	if authorization == nil then return false end
	local committed = arm_owned_timer("hide", SUCCESS_AUTO_HIDE_SEC, function()
		if not _pause_controller.is_current(token, authorization) then return false end
		if hide_session ~= nil then
			local ok_sid, current = pcall(llm_progress.session_id)
			if not _pause_controller.is_current(token, authorization) then return false end
			if ok_sid and current ~= hide_session then
				Logger.debug(LOG,
					"Auto-hide skipped — the progress window now belongs to another operation.")
				release_window_claim()
				if _terminal_outcome ~= nil then
					if fire_pending_callbacks(_terminal_outcome, function()
						return _pause_controller.is_current(token, authorization)
					end) ~= true then return false end
					_terminal_outcome = nil
				end
				_pause_controller.complete(token)
				return true
			end
		end
		pcall(llm_progress.hide)
		if not _pause_controller.is_current(token, authorization) then return false end
		release_window_claim()
		if _terminal_outcome ~= nil then
			if fire_pending_callbacks(_terminal_outcome, function()
				return _pause_controller.is_current(token, authorization)
			end) ~= true then return false end
			_terminal_outcome = nil
		end
		_pause_controller.complete(token)
		return true
	end, "Ollama bootstrap auto-hide")
	if committed ~= true then
		return false
	end
	if not _pause_controller.is_current(token, authorization) then
		cancel_owned_timer("hide", "Ollama bootstrap auto-hide rollback")
		return false
	end
	_resume_intent = { kind = "hide", session = hide_session }
	return true
end

replay_committed_intent = function(token, _epoch)
	local intent = _resume_intent
	if type(intent) ~= "table" then return _pause_controller.complete(token) end
	if intent.kind == "initial" then return schedule_initial_for_token(token) end
	if intent.kind == "task" and _terminal_outcome ~= nil then
		local authorization = _pause_controller.capture(token)
		if authorization == nil then return false end
		if fire_pending_callbacks(_terminal_outcome, function()
			return _pause_controller.is_current(token, authorization)
		end) ~= true then return false end
		_terminal_outcome = nil
		return _pause_controller.complete(token)
	end
	if intent.kind == "task" then return M.check_and_install_deps(nil, token) end
	if intent.kind == "hide" then return schedule_hide_for_token(token, intent.session) end
	return false
end

settle_replay_failure = function(token, _reason)
	if not _pause_controller.is_committed(token) then return token.cancelled == true end
	local intent = _resume_intent
	_resume_intent = nil
	if type(intent) == "table" and intent.kind == "hide" then return true end
	_bootstrap_state = "failed"
	_last_failure_message = i18n.get("ollama.deps_failed")
	_terminal_outcome = false
	if fire_pending_callbacks(false) ~= true then return false end
	_terminal_outcome = nil
	return true
end

function M.configure_pause_owner(script_control)
	return _pause_controller.configure(script_control)
end

function M.schedule_initial_check()
	if not _pause_controller.is_admitted() then
		Logger.debug(LOG, "Ollama initial bootstrap rejected by pause admission.")
		return false
	end
	if _task_running or _owned_timers.initial ~= nil then return true end
	local token = _pause_controller.begin()
	if token == nil then return false end
	return schedule_initial_for_token(token)
end




-- ========================================
-- ========================================
-- ======= 5/ Public Bootstrap API ========
-- ========================================
-- ========================================

--- Delivers every registered completion in FIFO order.
--- @param ok boolean Terminal bootstrap result.
--- @param is_current function|nil Optional authorization predicate.
--- @return boolean delivered
fire_pending_callbacks = function(ok, is_current)
	while #_pending_callbacks > 0 do
		if type(is_current) == "function" and not is_current() then return false end
		local callback = table.remove(_pending_callbacks, 1)
		ApiCommon.protected_call(callback, "Ollama dependency on_complete", ok)
	end
	return true
end

local function discard_pending_callbacks()
	_pending_callbacks = {}
	_terminal_outcome = nil
end

--- Asynchronously verifies (and bootstraps) the Ollama backend. Safe to
--- call repeatedly: the underlying script is idempotent and exits silently
--- when nothing needs doing.
--- @param on_complete function|nil Called exactly once with the terminal result.
--- @param replay_token table|nil Internal pause-owner replay capability.
--- @return boolean accepted
function M.check_and_install_deps(on_complete, replay_token, native_choice)
	-- Every call consumes the selection's grant, whatever path it takes: one
	-- left behind by a selection that found Ollama would let a later plain
	-- check download without the offer.
	local install_granted = _install_granted == true
	_install_granted = false
	if not _pause_controller.is_admitted() then
		Logger.debug(LOG, "Ollama dependency bootstrap rejected by pause admission.")
		return false
	end
	if _task_running then
		local owner = _task_owner
		if type(owner) ~= "table"
			or not _pause_controller.is_current(owner.token, owner.authorization) then
			Logger.debug(LOG, "Stale Ollama dependency task cannot accept another caller.")
			return false
		end
		if type(on_complete) == "function" then
			_pending_callbacks[#_pending_callbacks + 1] = on_complete
		end
		Logger.debug(LOG,
			"Ollama bootstrap already running; queued on_complete callback (%d total).",
			#_pending_callbacks)
		return true
	end
	local token = replay_token or _pause_controller.begin()
	local authorization = token and _pause_controller.capture(token) or nil
	if token == nil or authorization == nil then
		Logger.debug(LOG, "Ollama dependency bootstrap intent acquisition refused.")
		return false
	end
	if type(on_complete) == "function" then
		_pending_callbacks[#_pending_callbacks + 1] = on_complete
	end
	local function settle_registered_callbacks()
		if fire_pending_callbacks(false) ~= true then
			discard_pending_callbacks()
			return false
		end
		_terminal_outcome = nil
		return true
	end
	local function settle_preflight_failure(message)
		local current = _pause_controller.is_current(token, authorization)
		if current then
			_bootstrap_state = "failed"
			_last_failure_message = message
			_pause_controller.complete(token)
		elseif not _pause_controller.is_committed(token) then
			_pause_controller.complete(token)
		end
		settle_registered_callbacks()
		return false
	end
	local function settle_stale_intent()
		if not _pause_controller.is_committed(token) then
			_pause_controller.complete(token)
		end
		settle_registered_callbacks()
		return false
	end
	Logger.start(LOG, "Bootstrapping Ollama backend…")
	local project_root = resolve_project_root()
	if not project_root then
		Logger.error(LOG, "Project root introuvable depuis ollama_deps_checker.lua — bootstrap aborted.")
		return settle_preflight_failure("Project root introuvable.")
	end

	local script_path = project_root .. "/static/ergopti_plus/macos/modules/llm/"
		.. (native_choice and "ensure-ollama-native-deps.sh" or "ensure-ollama-deps.sh")
	if not hs.fs.attributes(script_path, "mode") then
		Logger.error(LOG, "Script ensure-ollama-deps.sh introuvable à %s — bootstrap aborted.", script_path)
		return settle_preflight_failure("Script ensure-ollama-deps.sh introuvable.")
	end

	-- Detection belongs to the resolver; the script only publishes a download
	-- into the folder that same resolver searches.
	local resolved_bin, resolve_err, resolved_source = OllamaBinary.resolve()
	local install_dir = nil
	if native_choice ~= nil then
		-- Native migration has its own issued choice. The generic historical
		-- download boolean cannot authorize this target or borrow its source.
		if type(native_choice) ~= "table" or native_choice.source_path ~= (resolved_bin or "")
			or native_choice.source_kind ~= resolved_source
			or native_choice.native_target ~= OllamaBinary.native_managed_install_dir() then
			return settle_preflight_failure(i18n.get("ollama.deps_failed"))
		end
		install_dir = native_choice.native_target
	elseif resolved_bin then
		Logger.info(LOG, "Ollama executable found (%s): %s", tostring(resolved_source), resolved_bin)
	else
		-- Only a replayed download the user accepted may download again; a
		-- replayed fast path for a found executable never had that consent.
		-- Any other caller needs the grant install_for_selection() gives.
		local replaying_install = replay_token ~= nil and type(_resume_intent) == "table"
			and _resume_intent.kind == "task" and _resume_intent.download == true
		local install_allowed = install_granted or replaying_install
		if not install_allowed then
			Logger.warn(LOG, "Ollama is not installed (%s); no download without the user's consent.",
				tostring(resolve_err))
			if _pause_controller.is_current(token, authorization) then
				_bootstrap_state = "missing"
				_last_failure_message = i18n.get("ollama.runtime_missing_body")
				_pause_controller.complete(token)
			elseif not _pause_controller.is_committed(token) then
				_pause_controller.complete(token)
			end
			settle_registered_callbacks()
			Logger.success(LOG, "Ollama bootstrap settled without a download (not installed).")
			return true
		end
		install_dir = OllamaBinary.managed_install_dir()
		if not install_dir then
			Logger.error(LOG, "HOME is unusable; the Ollama install folder cannot be named.")
			return settle_preflight_failure(i18n.get("ollama.deps_failed"))
		end
		Logger.info(LOG, "Ollama download accepted; installing into %s.", install_dir)
	end
	if not _pause_controller.is_current(token, authorization) then
		return settle_stale_intent()
	end
	-- A native interpreter keeps the existing PTY wrapper. Without Python,
	-- the signed guardian runs this exact pinned installer and returns its
	-- physical closure receipt before provisioning or daemon acquisition.
	local python_bin, python_state = PythonInterpreter.resolve()
	local native_pty, native_context_current, native_bind_environment
	local function native_context_admitted()
		if native_choice == nil then return true end
		if type(native_context_current) ~= "function"
			or not _pause_controller.is_current(token, authorization) then return false end
		local ok, current = pcall(native_context_current)
		return ok == true and current == true
			and _pause_controller.is_current(token, authorization)
	end
	if native_choice ~= nil then
		if _native_pty_preflight_owner ~= nil then
			if _native_pty_preflight_owner.rollback() ~= true then
				return settle_preflight_failure(i18n.get("ollama.deps_failed"))
			end
			_native_pty_preflight_owner = nil
		end
		local prepared, context
		native_pty, prepared, context = require("adapters.managed_ollama_bootstrap").prepare(
			native_choice.decision, native_choice.source_path, native_choice.source_kind,
			native_choice.native_target, native_choice.model_store, BOOTSTRAP_TIMEOUT_SEC * 1000)
		-- Capture the issued continuation immediately. Currency can refuse
		-- acquisition, but cannot release or substitute this partial owner.
		if type(context) == "table" then
			native_context_current, native_bind_environment = context.is_current, context.bind_environment
		end
		if prepared ~= true or type(native_bind_environment) ~= "function"
			or not native_context_admitted() then
			if native_pty ~= nil and native_pty.rollback() ~= true then _native_pty_preflight_owner = native_pty end
			return settle_preflight_failure(i18n.get("ollama.deps_failed"))
		end
	elseif not python_bin then
		local NativePty = require("adapters.native_bootstrap_pty")
		local environment = {
			{ "PROJECT_ROOT", project_root .. "/static/ergopti_plus/macos" },
			{ "ERGOPTI_NATIVE_ARCH", PythonInterpreter.native_arch() or "" },
			{ "ERGOPTI_NATIVE_PYTHONS", table.concat(PythonInterpreter.native_candidates(), ":") },
			{ "ERGOPTI_BOOTSTRAP_OLLAMA_RESOLVED_BIN", resolved_bin or "" },
			{ "ERGOPTI_BOOTSTRAP_OLLAMA_INSTALL_DIR", install_dir or "" },
			{ "ERGOPTI_BOOTSTRAP_PYTHON", "" },
		}
		if _native_pty_preflight_owner ~= nil then
			if _native_pty_preflight_owner.rollback() ~= true then
				return settle_preflight_failure(i18n.get("ollama.deps_failed"))
			end
			_native_pty_preflight_owner = nil
		end
		local prepared
		native_pty, prepared = NativePty.prepare(script_path, environment, BOOTSTRAP_TIMEOUT_SEC * 1000)
		if prepared ~= true then
			if native_pty ~= nil and native_pty.rollback() ~= true then _native_pty_preflight_owner = native_pty end
			if install_granted then require("ui.python_runtime_offer").offer(python_state) end
			return settle_preflight_failure(i18n.get("ollama.deps_failed"))
		end
	end
	local pty_wrapper_path, wrapper_error
	if native_pty == nil then pty_wrapper_path, wrapper_error = PtyProcessGroup.create("Ollama dependency") end
	if native_pty == nil and not pty_wrapper_path then
		Logger.error(LOG, "Failed to publish the Ollama process-group wrapper: %s.",
			tostring(wrapper_error))
		return settle_preflight_failure(i18n.get("ollama.deps_task_create_failed"))
	end
	if not _pause_controller.is_current(token, authorization) or not native_context_admitted() then
		PtyProcessGroup.remove(pty_wrapper_path)
		if native_pty ~= nil and native_pty.rollback() ~= true then _native_pty_preflight_owner = native_pty end
		return settle_stale_intent()
	end

	local owner = {
		token = token,
		authorization = authorization,
		task = nil,
		authorized = true,
		dispatching = true,
		start_committed = false,
		settled = false,
		terminal_received = false,
		terminal_processed = false,
		pending_terminal = nil,
		pending_streams = {},
		termination_accepted = false,
		deadline_wait_registered = false,
		timed_out = false,
	}
	local task
	local function owner_is_current()
		if owner.authorized ~= true then return false end
		local admitted = _pause_controller.is_current(owner.token, owner.authorization)
		-- Public admission queries can synchronously revoke this retained token.
		-- Refence only captured in-memory custody after that callback boundary.
		return admitted == true and owner.authorized == true
			and owner.token == token and token.cancelled ~= true
			and token.authorized == true and token.authorization == owner.authorization
	end
	local consume_stream = make_streaming_handler(owner_is_current)
	local function process_terminal(exit_code, stdout, stderr)
		local combined = (stdout or "") .. (stderr or "")
		if not forward_chunk(stdout or "", owner_is_current, owns_window) then return false end
		if not forward_chunk(stderr or "", owner_is_current, owns_window) then return false end

		local function publish_failure(message, failure_code, failure_domain)
			if not owner_is_current() then return false end
			local failure_label = failure_domain == "daemon" and "daemon start" or "bootstrap"
			Logger.error(LOG, "Ollama %s failed (exit=%d) — %s", failure_label,
				tonumber(failure_code) or -1, message:gsub("\n", " | "))
			local active_ok, active = pcall(llm_progress.is_active)
			if not owner_is_current() then return false end
			if active_ok and active ~= true then
				local shown_ok = pcall(llm_progress.show, {
					kind     = "ollama_install",
					title    = i18n.get("ollama.install_title"),
					subtitle = i18n.get("ollama.deps_failed"),
				})
				if not owner_is_current() then return false end
				if shown_ok then
					local claimed_session = owned_session()
					if not owner_is_current() then return false end
					_ui_session = claimed_session
					_ui_claimed = true
				end
			end
			if not owner_is_current() then return false end
			if owns_window() then
				pcall(llm_progress.set_error, message)
				if not owner_is_current() then return false end
			end
			if failure_domain == "daemon" then
				_bootstrap_state = "ready"
				_last_failure_message = nil
				_daemon_state = "failed"
				_last_daemon_failure_message = message
			else
				_bootstrap_state = "failed"
				_last_failure_message = message
			end
			_terminal_outcome = false
			local callbacks_delivered = fire_pending_callbacks(false, owner_is_current)
			if callbacks_delivered == true then
				_terminal_outcome = nil
				_pause_controller.complete(token)
			end
			return callbacks_delivered
		end

		if exit_code ~= 0 then
			local failure_key = FAILURE_MESSAGES[_observed_failure_marker or ""]
			if failure_key then return publish_failure(i18n.get(failure_key), exit_code) end
			local tail = tail_for_error(combined)
			if tail == "" then
				tail = "Cause inconnue. Consultez " .. Logger.today_log_path() .. "."
			end
			return publish_failure(tail, exit_code)
		end
		_bootstrap_state = "ready"
		_last_failure_message = nil
		_daemon_state = "pending"
		_last_daemon_failure_message = nil

		if not owner_is_current() then return false end
		local active_ok, active = pcall(llm_progress.is_active)
		if not owner_is_current() then return false end
		local owns_active_window = active_ok and active == true and owns_window()
		if not owner_is_current() then return false end
		if owns_active_window then
			pcall(llm_progress.set_step, i18n.get("ollama.deps_step_starting"))
			if not owner_is_current() then return false end
		end

		local external_runtime = native_choice == nil and (install_dir ~= nil
			or resolved_bin ~= nil and require("core.llm.ollama_runtime_choice").classify(resolved_source) == "foreign")
		local function finish_provisioning(daemon_ready)
		if not owner_is_current() then return false end

		_daemon_state = daemon_ready and "ready" or "pending"
		_last_daemon_failure_message = nil

		Logger.success(LOG, "Ollama binary provisioned; daemon readiness=%s.", tostring(daemon_ready))
		if not owner_is_current() then return false end
		-- Native startup may settle after another operation replaces the window.
		-- The earlier bootstrap observation cannot authorize these final writes.
		local active_ok, active = pcall(llm_progress.is_active)
		if not owner_is_current() then return false end
		local owns_active_window = active_ok and active == true and owns_window()
		if not owner_is_current() then return false end
		local hide_committed = false
		if owns_active_window then
			pcall(llm_progress.set_step, i18n.get(daemon_ready and "ollama.deps_step_ready" or "ollama.deps_step_verified"))
			if not owner_is_current() then return false end
			pcall(llm_progress.set_progress, 100)
			if not owner_is_current() then return false end
			hide_committed = schedule_hide_for_token(token, _ui_session)
			if hide_committed ~= true then
				if not owner_is_current() then return false end
				if owns_window() then
					if not owner_is_current() then return false end
					pcall(llm_progress.hide)
					if not owner_is_current() then return false end
				else
					Logger.debug(LOG,
						"Immediate hide skipped: the progress window now belongs to another operation.")
				end
				if not owner_is_current() then return false end
				release_window_claim()
			end
		end
		if hide_committed == true then
			if not owner_is_current() then return false end
		elseif not owner_is_current() then
			return false
		end
		_bootstrap_state = "ready"
		_last_failure_message = nil
		_terminal_outcome = true
		local callbacks_delivered = fire_pending_callbacks(true, owner_is_current)
		if callbacks_delivered == true then
			_terminal_outcome = nil
			if hide_committed ~= true then _pause_controller.complete(token) end
		end
		return callbacks_delivered
		end
		if external_runtime then
			-- Installation presence permits client reuse, not daemon ownership.
			return finish_provisioning(false)
		end
		local daemon_ok, daemon_accepted = xpcall(function()
			return ApiOllama.ensure_running({
				is_authorized = owner_is_current,
				on_settled = function(ready)
					if not owner_is_current() then return end
					if ready ~= true then
						return publish_failure(i18n.get("ollama.daemon_fail"), -1, "daemon")
					end
					return finish_provisioning(true)
				end,
			})
		end, debug.traceback)
		if not daemon_ok or daemon_accepted ~= true then
			if owner_is_current() then return publish_failure(i18n.get("ollama.daemon_fail"), -1, "daemon") end
			return false
		end
		return true
	end

	local function process_settled_terminal(args)
		if owner.terminal_processed == true then return false end
		if native_pty ~= nil and native_pty.settle(args[1]) ~= true then
			owner.native_terminal_retry = function() return process_settled_terminal(args) end
			Logger.error(LOG, "Native Ollama bootstrap retained: physical receipt or cleanup remains unsettled.")
			if owner_is_current() then
				_bootstrap_state = "failed"
				_last_failure_message = i18n.get("ollama.deps_failed")
				if owns_window() then pcall(llm_progress.set_error, _last_failure_message) end
			end
			return false
		end
		owner.native_terminal_retry = nil
		owner.terminal_processed = true
		release_task_owner(owner)
		PtyProcessGroup.remove(pty_wrapper_path)
		if owner.start_committed ~= true or not owner_is_current() then return false end
		return process_terminal(table.unpack(args, 1, args.n))
	end

	local function deliver_terminal(args)
		if owner.terminal_processed == true or owner.deadline_wait_registered == true then
			return false
		end
		if cancel_owned_timer("deadline", "Ollama dependency bootstrap deadline") ~= true then
			owner.pending_terminal = args
			owner.deadline_wait_registered = true
			when_owned_timer_settled("deadline", function()
				owner.deadline_wait_registered = false
				local pending = owner.pending_terminal
				owner.pending_terminal = nil
				if pending ~= nil then process_settled_terminal(pending) end
			end)
			return false
		end
		return process_settled_terminal(args)
	end

	local function completion_callback(...)
		if owner.terminal_received == true then return false end
		owner.terminal_received = true
		local args = table.pack(...)
		if owner.dispatching == true then
			owner.pending_terminal = args
			return true
		end
		return deliver_terminal(args)
	end

	local function streaming_callback(...)
		if owner.terminal_received == true or not owner_is_current() then return false end
		local args = table.pack(...)
		if owner.dispatching == true then
			owner.pending_streams[#owner.pending_streams + 1] = args
			return true
		end
		return consume_stream(table.unpack(args, 1, args.n))
	end

	_observed_failure_marker = nil
	local task_executable, task_arguments = python_bin,
		{ "-u", pty_wrapper_path, "/bin/bash", script_path, resolved_bin or "", install_dir or "", python_bin }
	if native_pty ~= nil then task_executable, task_arguments = native_pty.executable, native_pty.arguments end
	if native_context_admitted() then
		task = TaskLifecycle.native("Ollama bootstrap", task_executable,
			completion_callback, streaming_callback, task_arguments)
	end
	if task ~= nil and native_choice ~= nil then
		local bound, accepted = pcall(native_bind_environment, task)
		if not bound or accepted ~= true or not native_context_admitted() then task = nil end
	end
	if task ~= nil and native_pty ~= nil then
		if not native_context_admitted() or native_pty.bind_input(task) ~= true
			or not native_context_admitted() then task = nil end
	end

	if not task then
		owner.authorized = false
		PtyProcessGroup.remove(pty_wrapper_path)
		if native_pty ~= nil and native_pty.rollback() ~= true then _native_pty_preflight_owner = native_pty end
		return settle_preflight_failure(i18n.get("ollama.deps_task_create_failed"))
	end
	owner.task = task
	_task_owner = owner
	_task_running = true
	_active_tasks[task] = true
	if owner.pending_terminal ~= nil then
		owner.dispatching = false
		deliver_terminal(owner.pending_terminal)
		return settle_preflight_failure(i18n.get("ollama.deps_task_start_failed"))
	end
	local deadline_committed = arm_owned_timer("deadline", BOOTSTRAP_TIMEOUT_SEC, function()
		if owner.terminal_received == true or owner.timed_out == true
			or owner.start_committed ~= true or not owner_is_current() then
			return false
		end
		owner.timed_out = true
		local message = i18n.get("ollama.deps_failed")
		Logger.error(LOG,
			"Ollama dependency bootstrap timed out after %.1f seconds; terminating the exact child.",
			BOOTSTRAP_TIMEOUT_SEC)
		if owns_window() then pcall(llm_progress.set_error, message) end
		_bootstrap_state = "failed"
		_last_failure_message = message
		_terminal_outcome = false
		if fire_pending_callbacks(false, owner_is_current) ~= true then
			discard_pending_callbacks()
		else
			_terminal_outcome = nil
		end
		_pause_controller.complete(token)
		terminate_task_owner(owner, "Ollama dependency bootstrap timeout")
		return true
	end, "Ollama dependency bootstrap deadline")
	if deadline_committed ~= true or not native_context_admitted() then
		-- A committed deadline remains an original native owner after currency withdrawal.
		-- Acquisition refusal keeps its existing cleanup debt without another attempt.
		if deadline_committed == true then
			cancel_owned_timer("deadline", "Ollama dependency bootstrap deadline")
		end
		owner.dispatching = false
		owner.authorized = false
		release_task_owner(owner)
		PtyProcessGroup.remove(pty_wrapper_path)
		if native_pty ~= nil and native_pty.rollback() ~= true then _native_pty_preflight_owner = native_pty end
		return settle_preflight_failure(i18n.get("ollama.deps_failed"))
	end

	if not native_context_admitted()
		or (native_pty ~= nil and native_pty.mark_start_attempted() ~= true) then
		owner.dispatching = false
		owner.authorized = false
		cancel_owned_timer("deadline", "Ollama dependency bootstrap deadline")
		release_task_owner(owner)
		if native_pty.rollback() ~= true then _native_pty_preflight_owner = native_pty end
		return settle_preflight_failure(i18n.get("ollama.deps_task_start_failed"))
	end
	-- A failed post-marker fence keeps both original owners quarantined.
	-- The PTY marker may no longer permit rollback; absence of start is not
	-- permission to erase its receipt or task pin.
	if not native_context_admitted() then
		owner.dispatching = false
		owner.authorized = false
		cancel_owned_timer("deadline", "Ollama dependency bootstrap deadline")
		return settle_preflight_failure(i18n.get("ollama.deps_task_start_failed"))
	end
	local started = TaskLifecycle.start(task, "Ollama bootstrap")
	if started ~= true then
		owner.dispatching = false
		owner.authorized = false
		cancel_owned_timer("deadline", "Ollama dependency bootstrap deadline")
		if owner.pending_terminal ~= nil then
			deliver_terminal(owner.pending_terminal)
		else
			terminate_task_owner(owner, "Ollama bootstrap start rollback")
		end
		local current = _pause_controller.is_current(token, authorization)
		if current then
			_bootstrap_state = "failed"
			_last_failure_message = i18n.get("ollama.deps_task_start_failed")
			_pause_controller.complete(token)
			if fire_pending_callbacks(false, _pause_controller.is_admitted) ~= true then
				discard_pending_callbacks()
			end
		elseif not _pause_controller.is_committed(token) then
			_pause_controller.complete(token)
			discard_pending_callbacks()
		end
		return false
	end
	owner.start_committed = true
	if not native_context_admitted() or _pause_controller.commit(token) ~= true
		or not native_context_admitted() then
		owner.dispatching = false
		owner.authorized = false
		cancel_owned_timer("deadline", "Ollama dependency bootstrap deadline")
		if owner.pending_terminal ~= nil then
			deliver_terminal(owner.pending_terminal)
		else
			terminate_task_owner(owner, "Ollama bootstrap commit rollback")
		end
		if not _pause_controller.is_committed(token) then
			_pause_controller.complete(token)
			discard_pending_callbacks()
		end
		return false
	end
	_resume_intent = { kind = "task", download = install_dir ~= nil and native_choice == nil }
	owner.dispatching = false
	for _, args in ipairs(owner.pending_streams) do
		if not owner_is_current()
			or consume_stream(table.unpack(args, 1, args.n)) ~= true then
			owner.authorized = false
			cancel_owned_timer("deadline", "Ollama dependency bootstrap deadline")
			terminate_task_owner(owner, "Ollama bootstrap stream rollback")
			return false
		end
	end
	owner.pending_streams = {}
	if owner.pending_terminal ~= nil then deliver_terminal(owner.pending_terminal) end
	return true
end





--- ==================================
--- ==================================
--- ======= 6/ State Accessors =======
--- ==================================
--- ==================================

--- @return string The dependency provisioning state ("pending" / "ready" / "missing" / "failed").
function M.get_state() return _bootstrap_state end

--- @return boolean True only when binary provisioning committed.
function M.is_ready() return _bootstrap_state == "ready" end

--- @return boolean True while dependency provisioning is still pending.
function M.is_pending() return _bootstrap_state == "pending" end

--- @return boolean True when dependency provisioning definitively failed.
function M.has_failed() return _bootstrap_state == "failed" end

--- @return string|nil Last failure message captured from the bash script.
function M.get_failure_message() return _last_failure_message end

--- @return string The current daemon acquisition state.
function M.get_daemon_state() return _daemon_state end

--- @return boolean True only when the canonical daemon start committed.
function M.is_daemon_ready() return _daemon_state == "ready" end

--- @return boolean True when daemon acquisition failed after successful provisioning.
function M.has_daemon_failed() return _daemon_state == "failed" end

--- @return string|nil Last daemon-start failure message.
function M.get_daemon_failure_message() return _last_daemon_failure_message end

--- @return boolean True when the last check found no Ollama and downloaded nothing.
function M.is_missing() return _bootstrap_state == "missing" end

--- @return boolean True while a provisioning task (an accepted download or a
--- found executable's fast path) is running; a new caller joins it.
function M.is_task_running() return _task_running == true end

--- Reports exact provisioning admission without acquiring or cancelling owners.
--- A healthy success-window hide is independent UI work; refused cleanup remains debt.
--- @return boolean idle
function M.provisioning_idle()
	if _task_running == true or _task_owner ~= nil or _native_pty_preflight_owner ~= nil
		or next(_active_tasks) ~= nil then return false end
	for slot, owner in pairs(_owned_timers) do
		if slot ~= "hide" or owner.cancel_requested == true or owner.acquisition_valid ~= true
			or owner.acquiring == true then return false end
	end
	return true
end

--- Reports whether an Ollama executable exists, with stat-only probes.
--- @return boolean available
function M.runtime_available()
	local path = OllamaBinary.resolve()
	return path ~= nil
end

--- The only download entry: the user selected the Ollama backend and, when no
--- executable exists, accepted the offer. A resolvable executable is reused and
--- the grant is simply consumed without any network access.
--- @param on_complete function|nil Called once with the terminal result.
--- @return boolean accepted
function M.install_for_selection(on_complete)
	Logger.info(LOG, "Ollama backend selected; download authorized if Ollama is absent.")
	-- A running task is either an accepted download or a found executable's
	-- fast path: joining it needs no grant, and a leftover one must not leak.
	_install_granted = not _task_running
	if _bootstrap_state == "failed" or _bootstrap_state == "missing" then
		_bootstrap_state = "pending"
		_last_failure_message = nil
	end
	local accepted = M.check_and_install_deps(on_complete)
	if accepted ~= true then _install_granted = false end
	return accepted
end

--- Installs the separately owned native runtime under this original task owner.
--- Consent is a shared issued choice, consumed by the native preparation port.
--- A stock grant or a paused replay never supplies that choice implicitly.
function M.install_native_for_selection(decision, source_path, source_kind, native_target, model_store, on_complete)
	if M.provisioning_idle() ~= true then return false end
	return M.check_and_install_deps(on_complete, nil, {
		decision = decision, source_path = source_path, source_kind = source_kind,
		native_target = native_target, model_store = model_store,
	}) == true
end

--- Resets a definitively-"failed" bootstrap back to "pending" so the tray
--- menu's "install now" action can retry (F-LOW-10). check_and_install_deps()
--- here has no state-based early return, so it already re-runs the script on
--- a later call even without this reset — but exposing the same symmetric
--- reset API as mlx_deps_checker.lua lets callers treat both backends
--- identically and gives the UI an explicit "clear the failed state" action.
--- Daemon acquisition has its own verdict and is never mutated by this reset.
--- A no-op while a bootstrap task is already running.
--- @return boolean True if the reset was applied, false if a no-op.
function M.reset_bootstrap_state()
	if not _pause_controller.is_admitted() then
		Logger.debug(LOG, "reset_bootstrap_state(): rejected by pause admission.")
		return false
	end
	if _task_running then
		Logger.debug(LOG, "reset_bootstrap_state(): a bootstrap task is already running — ignoring.")
		return false
	end
	if _bootstrap_state ~= "failed" then
		return false
	end
	Logger.info(LOG, "Resetting Ollama bootstrap state from 'failed' back to 'pending' — retry now possible.")
	_bootstrap_state      = "pending"
	_last_failure_message = nil
	return true
end

return M
