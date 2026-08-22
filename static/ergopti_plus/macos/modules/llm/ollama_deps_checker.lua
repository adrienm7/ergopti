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
--- 1. Self-bootstrapping: a fresh-out-of-the-box Mac with no Homebrew and
---    no Ollama gets a working server after one Hammerspoon reload.
--- 2. Silent fast path: when the executable already exists, provisioning exits
---    silently and daemon acquisition remains under the Lua owner.
--- 3. Granular progress UX: the install marker and Lua-owned daemon transition
---    map to precise French steps in the unified download window.
--- 4. Tri-state lifecycle: callers branch on get_state() ("pending" /
---    "ready" / "failed") just like mlx_deps_checker, so menu code can
---    treat the two backends with one shared pattern.
--- ==============================================================================

local M = {}
local hs           = hs
local Logger       = require("infra.logger")
local i18n         = require("infra.i18n")
local llm_progress = require("ui.download_window")
local OllamaBinary = require("modules.llm.ollama_binary")
local ApiOllama     = require("modules.llm.api_ollama")
local TaskLifecycle = require("adapters.task_lifecycle")
local TimerScheduler = require("adapters.timer_scheduler")
local BootstrapPauseOwner = require("modules.llm.dependency_bootstrap_pause_owner")
local PtyProcessGroup = require("modules.llm.pty_process_group")

local LOG = "ollama_deps"

local MARKER_INSTALLING = "OLLAMA_INSTALLING"
local MARKER_STARTING   = "OLLAMA_STARTING"
local MARKER_READY      = "OLLAMA_READY"

-- Step labels keyed by marker. The "READY" marker also doubles as a
-- success-final-step we render before auto-hiding.
local PROGRESS_LABELS = {
	[MARKER_INSTALLING] = i18n.get("ollama.deps_step_installing"),
	[MARKER_STARTING]   = i18n.get("ollama.deps_step_starting"),
	[MARKER_READY]      = i18n.get("ollama.deps_step_ready"),
}

local KNOWN_MARKERS = {
	[MARKER_INSTALLING] = true,
	[MARKER_STARTING]   = true,
	[MARKER_READY]      = true,
}

local FAILURE_TAIL_CHARS    = 280
local SUCCESS_AUTO_HIDE_SEC = 1.5

local _bootstrap_state      = "pending"
local _last_failure_message = nil
local _task_running         = false  -- reentrancy guard: prevents duplicate concurrent tasks

-- GC root for the live bootstrap hs.task. The handle below is a FUNCTION-local, so
-- it goes out of scope as soon as the spawning function returns while the
-- subprocess is still running — an unreferenced hs.task can be collected mid-run,
-- killing the install and dropping its completion callback. Canonical spelling
-- recognised by tests/unit/meta/test_gc_retention.lua; released in the callback.
local _active_tasks = {}

local _owned_timers = { initial = nil, hide = nil }
local _task_owner = nil
local _resume_intent = nil

local quiesce_owned_work
local replay_committed_intent
local schedule_initial_for_token
local schedule_hide_for_token

local _pause_controller = BootstrapPauseOwner.new({
	owner_name = "ollama_dependency_bootstrap",
	label = "Ollama dependency",
	quiesce = function() return quiesce_owned_work() end,
	replay = function(token, epoch) return replay_committed_intent(token, epoch) end,
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
		if line:match("%S") and not KNOWN_MARKERS[line] then
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
	local task_settled = terminate_task_owner(_task_owner, "Ollama dependency bootstrap")
	return initial_settled == true and hide_settled == true and task_settled == true
end

schedule_initial_for_token = function(token)
	local authorization = _pause_controller.capture(token)
	if authorization == nil then return false end
	_resume_intent = { kind = "initial" }
	local committed = arm_owned_timer("initial", 0, function()
		if not _pause_controller.is_current(token, authorization) then return false end
		return M.check_and_install_deps(token)
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
				_pause_controller.complete(token)
				return true
			end
		end
		pcall(llm_progress.hide)
		if not _pause_controller.is_current(token, authorization) then return false end
		release_window_claim()
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
	if intent.kind == "task" then return M.check_and_install_deps(token) end
	if intent.kind == "hide" then return schedule_hide_for_token(token, intent.session) end
	return false
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

--- Asynchronously verifies (and bootstraps) the Ollama backend. Safe to
--- call repeatedly: the underlying script is idempotent and exits silently
--- when nothing needs doing.
function M.check_and_install_deps(replay_token)
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
		Logger.debug(LOG, "check_and_install_deps() called while a task is already running — ignoring duplicate call.")
		return true
	end
	local token = replay_token or _pause_controller.begin()
	local authorization = token and _pause_controller.capture(token) or nil
	if token == nil or authorization == nil then
		Logger.debug(LOG, "Ollama dependency bootstrap intent acquisition refused.")
		return false
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
		return false
	end
	local function settle_stale_intent()
		if not _pause_controller.is_committed(token) then
			_pause_controller.complete(token)
		end
		return false
	end
	Logger.start(LOG, "Bootstrapping Ollama backend…")
	local project_root = resolve_project_root()
	if not project_root then
		Logger.error(LOG, "Project root introuvable depuis ollama_deps_checker.lua — bootstrap aborted.")
		return settle_preflight_failure("Project root introuvable.")
	end

	local script_path = project_root .. "/static/ergopti_plus/macos/modules/llm/ensure-ollama-deps.sh"
	if not hs.fs.attributes(script_path, "mode") then
		Logger.error(LOG, "Script ensure-ollama-deps.sh introuvable à %s — bootstrap aborted.", script_path)
		return settle_preflight_failure("Script ensure-ollama-deps.sh introuvable.")
	end

	-- The bootstrap installs the executable, but the Lua owner still supplies the
	-- canonical logging pipeline. This keeps fresh installs on the same rollover
	-- and quoting contract as both normal daemon launch paths.
	local resolved_bin, resolve_err, managed_override = OllamaBinary.resolve()
	if managed_override and not resolved_bin then
		Logger.error(LOG, "The launcher-owned Ollama executable is unavailable: %s",
			tostring(resolve_err))
		return settle_preflight_failure("The bundled Ollama executable is unavailable.")
	end
	if not _pause_controller.is_current(token, authorization) then
		return settle_stale_intent()
	end
	local pty_wrapper_path, wrapper_error = PtyProcessGroup.create("Ollama dependency")
	if not pty_wrapper_path then
		Logger.error(LOG, "Failed to publish the Ollama process-group wrapper: %s.",
			tostring(wrapper_error))
		return settle_preflight_failure(i18n.get("ollama.deps_task_create_failed"))
	end
	if not _pause_controller.is_current(token, authorization) then
		PtyProcessGroup.remove(pty_wrapper_path)
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
	}
	local task
	local function owner_is_current()
		return owner.authorized == true
			and _pause_controller.is_current(owner.token, owner.authorization)
	end
	local consume_stream = make_streaming_handler(owner_is_current)
	local function process_terminal(exit_code, stdout, stderr)
		local combined = (stdout or "") .. (stderr or "")
		if not forward_chunk(stdout or "", owner_is_current, owns_window) then return false end
		if not forward_chunk(stderr or "", owner_is_current, owns_window) then return false end

		local function publish_failure(message, failure_code)
			if not owner_is_current() then return false end
			Logger.error(LOG, "Ollama bootstrap failed (exit=%d) — %s",
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
			_bootstrap_state = "failed"
			_last_failure_message = message
			_pause_controller.complete(token)
			return true
		end

		if exit_code ~= 0 then
			local tail = tail_for_error(combined)
			if tail == "" then
				tail = "Cause inconnue. Consultez " .. Logger.UNIFIED_LOG_FILE .. "."
			end
			return publish_failure(tail, exit_code)
		end

		if not owner_is_current() then return false end
		local active_ok, active = pcall(llm_progress.is_active)
		if not owner_is_current() then return false end
		local owns_active_window = active_ok and active == true and owns_window()
		if not owner_is_current() then return false end
		if owns_active_window then
			pcall(llm_progress.set_step, i18n.get("ollama.deps_step_starting"))
			if not owner_is_current() then return false end
		end

		-- Daemon launch belongs exclusively to ApiOllama's already registered
		-- lifecycle owner. The dependency checker never detaches a child process.
		local daemon_ok, daemon_committed = xpcall(ApiOllama.ensure_running, debug.traceback)
		if not owner_is_current() then return false end
		if not daemon_ok or daemon_committed ~= true then
			return publish_failure("Démarrage du serveur Ollama impossible.", -1)
		end

		Logger.success(LOG, "Ollama binary ready and daemon start committed.")
		if not owner_is_current() then return false end
		local hide_committed = false
		if owns_active_window then
			pcall(llm_progress.set_step, i18n.get("ollama.deps_step_ready"))
			if not owner_is_current() then return false end
			pcall(llm_progress.set_progress, 100)
			if not owner_is_current() then return false end
			hide_committed = schedule_hide_for_token(token, _ui_session)
			if hide_committed ~= true and not _pause_controller.is_admitted() then
				return false
			end
		end
		if hide_committed == true then
			if not owner_is_current() then return false end
		elseif not owner_is_current() then
			return false
		end
		_bootstrap_state = "ready"
		_last_failure_message = nil
		if hide_committed ~= true then _pause_controller.complete(token) end
		return true
	end

	local function deliver_terminal(args)
		if owner.terminal_processed == true then return false end
		owner.terminal_processed = true
		release_task_owner(owner)
		PtyProcessGroup.remove(pty_wrapper_path)
		if owner.start_committed ~= true or not owner_is_current() then return false end
		return process_terminal(table.unpack(args, 1, args.n))
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

	task = TaskLifecycle.native("Ollama bootstrap", "/usr/bin/python3",
		completion_callback, streaming_callback,
		{ "-u", pty_wrapper_path, "/bin/bash", script_path, resolved_bin or "" })

	if not task then
		owner.authorized = false
		PtyProcessGroup.remove(pty_wrapper_path)
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

	local started = TaskLifecycle.start(task, "Ollama bootstrap")
	if started ~= true then
		owner.dispatching = false
		owner.authorized = false
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
		elseif not _pause_controller.is_committed(token) then
			_pause_controller.complete(token)
		end
		return false
	end
	owner.start_committed = true
	if _pause_controller.commit(token) ~= true then
		owner.dispatching = false
		owner.authorized = false
		if owner.pending_terminal ~= nil then
			deliver_terminal(owner.pending_terminal)
		else
			terminate_task_owner(owner, "Ollama bootstrap commit rollback")
		end
		if not _pause_controller.is_committed(token) then
			_pause_controller.complete(token)
		end
		return false
	end
	_resume_intent = { kind = "task" }
	owner.dispatching = false
	for _, args in ipairs(owner.pending_streams) do
		if not owner_is_current()
			or consume_stream(table.unpack(args, 1, args.n)) ~= true then
			owner.authorized = false
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

--- @return string The current bootstrap state ("pending" / "ready" / "failed").
function M.get_state() return _bootstrap_state end

--- @return boolean True only when binary provisioning and the canonical
--- ApiOllama daemon-start acquisition both committed.
function M.is_ready() return _bootstrap_state == "ready" end

--- @return boolean True while the bootstrap is still running.
function M.is_pending() return _bootstrap_state == "pending" end

--- @return boolean True when the bootstrap definitively failed.
function M.has_failed() return _bootstrap_state == "failed" end

--- @return string|nil Last failure message captured from the bash script.
function M.get_failure_message() return _last_failure_message end

--- Resets a definitively-"failed" bootstrap back to "pending" so the tray
--- menu's "install now" action can retry (F-LOW-10). check_and_install_deps()
--- here has no state-based early return, so it already re-runs the script on
--- a later call even without this reset — but exposing the same symmetric
--- reset API as mlx_deps_checker.lua lets callers treat both backends
--- identically and gives the UI an explicit "clear the failed state" action.
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
