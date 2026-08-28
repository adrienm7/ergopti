--- modules/llm/mlx_deps_checker.lua

--- ==============================================================================
--- MODULE: MLX Dependencies Checker
--- DESCRIPTION:
--- Auto-bootstraps the project-local Python virtualenv at
--- static/ergopti_plus/macos/.venv from pyproject.toml on every Hammerspoon
--- startup. The heavy lifting lives in modules/llm/ensure-mlx-deps.sh; this
--- module orchestrates the async invocation, streams stdout AND stderr to
--- surface granular progress through the unified download_window UI, and
--- reports the FINAL state to the user.
---
--- FEATURES & RATIONALE:
--- 1. Transparent fast path: the bash script hash-compares pyproject.toml
---    against a marker file and exits silently in milliseconds when nothing
---    changed. The Lua side never even shows the progress UI on a normal
---    reload — exactly what the user expects.
--- 2. Granular progress UX: the script prints identifiable markers
---    (UV_INSTALLING, PYTHON_INSTALLING, VENV_CREATING, DEPS_SYNCING) on
---    its stdout when about to start each long-running step. We forward
---    each marker to ui.download_window.set_step with a French label, and
---    every raw stderr line to ui.download_window.set_detail so the user sees
---    live verbose output (uv "Downloading torch (220 MB)…").
--- 3. Verbose live log: every line of the script's stderr is also
---    forwarded to Logger.info so 'tail -f <config>/logs/ErgoptiPlus_*.log' shows the
---    same live download progress instead of a 4-minute frozen silence.
--- 4. Final state reporting: a successful slow-path run posts a final
---    "Moteur IA prêt." step then auto-hides 1.5s later. Any failure
---    routes through ui.download_window.set_error with the actual stderr
---    tail from the script (network down, uv install blocked, etc.) so
---    the user sees the real cause.
--- 5. Non-blocking: full check + install runs in a background hs.task so
---    the Hammerspoon main loop is never frozen, even on a fresh clone
---    where bootstrapping uv + Python + the MLX wheels takes minutes.
--- 6. Tri-state lifecycle: callers branch on get_state() ("pending" /
---    "ready" / "failed"). The IA menu stays usable while bootstrap is
---    "pending" and only flips to "failed" if a real IA attempt occurs
---    after a definitive failure.
--- ==============================================================================

local M = {}
local hs           = hs
local Logger       = require("infra.logger")
local i18n         = require("infra.i18n")
local Paths        = require("infra.paths")
local llm_progress = require("ui.download_window")
local ApiCommon    = require("modules.llm.api_common")
local TaskLifecycle = require("adapters.task_lifecycle")
local TimerScheduler = require("adapters.timer_scheduler")
local Timings = require("infra.timings")
local BootstrapPauseOwner = require("modules.llm.dependency_bootstrap_pause_owner")
local PtyProcessGroup = require("modules.llm.pty_process_group")

local LOG = "mlx_deps"

-- Marker line printed by ensure-mlx-deps.sh on its FIRST stdout flush
-- whenever it is about to run a non-trivial sync. Absence of the marker
-- means the script took the silent fast path.
local SYNC_MARKER_LINE   = "VENV_SYNC_RAN"

-- Granular progress markers printed by the bash script before each
-- long-running step. Each maps to a French step label so the user
-- always knows exactly what is happening.
local MARKER_UV_INSTALL     = "UV_INSTALLING"
local MARKER_UV_INSTALLED   = "UV_INSTALLED"
local MARKER_PYTHON_INSTALL = "PYTHON_INSTALLING"
local MARKER_PYTHON_DONE    = "PYTHON_INSTALLED"
local MARKER_VENV_CREATE    = "VENV_CREATING"
local MARKER_VENV_CREATED   = "VENV_CREATED"
local MARKER_DEPS_SYNC      = "DEPS_SYNCING"
local MARKER_DEPS_SYNCED    = "DEPS_SYNCED"

-- Number of trailing characters of stderr/stdout to surface in the failure
-- message. Long enough to include the actual error from curl / uv, short
-- enough to fit on a single line of the progress UI.
local FAILURE_TAIL_CHARS = 280

-- Delay before auto-hiding the progress UI after a successful bootstrap.
-- Long enough for the user to register "moteur IA prêt", short enough to
-- not feel laggy.
local SUCCESS_AUTO_HIDE_SEC = 1.5
local BOOTSTRAP_TIMEOUT_SEC = Timings.sec("llm", "dependency_bootstrap_timeout_ms")

-- Keep UI hidden until the script proves a real sync is running by emitting
-- VENV_SYNC_RAN / progress markers. This avoids a startup flash when the
-- environment is already up to date and only quick validation is happening.

-- Module-level state so callers can branch on the bootstrap outcome without
-- re-running the script. The values are:
--   "pending" — bootstrap not finished yet (initial state).
--   "ready"   — venv is provisioned and pyproject.toml hash matches.
--   "failed"  — bootstrap failed; IA features must stay disabled.
local _bootstrap_state = "pending"

-- Last error message captured from the script (stderr tail). Surfaced by
-- callers that need to explain WHY an IA action was refused.
local _last_failure_message = nil

-- Callbacks registered while the script is running. Fired all at once when
-- the script exits so concurrent callers (startup probe + user click) each
-- get their on_complete called without launching a second bash process.
local _pending_callbacks = {}

-- Explicit boolean tracking whether a bootstrap task is currently running.
-- Cannot use #_pending_callbacks > 0 as the guard: when on_complete is nil
-- (most internal callers), no entry is added to the queue and the guard
-- never fires — allowing two concurrent bootstrap processes to race and
-- both write the same .venv directory.
local _task_running = false

-- GC root for the live bootstrap hs.task. The handle below is a FUNCTION-local, so
-- it goes out of scope as soon as the spawning function returns while the
-- subprocess is still running — an unreferenced hs.task can be collected mid-run,
-- killing the install and dropping its completion callback. Canonical spelling
-- recognised by tests/unit/meta/test_gc_retention.lua; released in the callback.
local _active_tasks = {}

-- Exact backend-local native owners. Timer candidates remain reachable even
-- when activation or cancellation refuses, and the task descriptor survives
-- until its one native terminal callback proves process settlement.
local _owned_timers = { initial = nil, hide = nil, deadline = nil }
local _task_owner = nil
local _resume_intent = nil
local _terminal_outcome = nil

local quiesce_owned_work
local replay_committed_intent
local schedule_initial_for_token
local schedule_hide_for_token
local fire_pending_callbacks

local _pause_controller = BootstrapPauseOwner.new({
	owner_name = "mlx_dependency_bootstrap",
	label = "MLX dependency",
	quiesce = function() return quiesce_owned_work() end,
	replay = function(token, epoch) return replay_committed_intent(token, epoch) end,
})





-- =====================================
-- =====================================
-- ======= 1/ Path Resolution ==========
-- =====================================
-- =====================================

--- Resolves the HS driver root from this file path.
--- @return string|nil hs_root Absolute path or nil.
local function resolve_hs_root()
	local source = debug.getinfo(1, "S").source or ""
	source = source:sub(1, 1) == "@" and source:sub(2) or source
	local root = source:match("^(.*)/modules/llm/mlx_deps_checker%.lua$")
	if root and root ~= "" and hs.fs.attributes(root, "mode") then
		return root
	end
	return nil
end

--- Resolves the absolute path to ensure-mlx-deps.sh in both dev and bundled
--- layouts by first using this module's own location, then falling back to an
--- upward search from hs.configdir.
--- @return string|nil script_path Absolute script path, or nil if not found.
local function resolve_bootstrap_script_path()
	local hs_root = resolve_hs_root()
	if hs_root then
		local script_path = hs_root .. "/modules/llm/ensure-mlx-deps.sh"
		if hs.fs.attributes(script_path, "mode") then
			return script_path
		end
	end

	return Paths.find_from_configdir("modules/llm/ensure-mlx-deps.sh", 12)
end

--- Shell-quotes an arbitrary string for safe insertion into /bin/bash -c.
--- @param value string Raw string.
--- @return string quoted Shell-safe quoted string.
local function shell_quote(value)
	local s = tostring(value or "")
	return "'" .. s:gsub("'", "'\\''") .. "'"
end





-- ==========================================
-- ==========================================
-- ======= 2/ Marker / Output Parsing =======
-- ==========================================
-- ==========================================

-- Set of all known protocol marker lines. Used to decide whether a stdout
-- line is protocol noise (skip) or genuine human-readable output (log).
local KNOWN_MARKERS = {
	[SYNC_MARKER_LINE]      = true,
	[MARKER_UV_INSTALL]     = true,
	[MARKER_UV_INSTALLED]   = true,
	[MARKER_PYTHON_INSTALL] = true,
	[MARKER_PYTHON_DONE]    = true,
	[MARKER_VENV_CREATE]    = true,
	[MARKER_VENV_CREATED]   = true,
	[MARKER_DEPS_SYNC]      = true,
	[MARKER_DEPS_SYNCED]    = true,
}

-- French step labels keyed by marker. Only the "starting" markers map to
-- a fresh step label — the matching *_INSTALLED / *_DONE markers are
-- absorbed silently because the next step's label supersedes them anyway.
local PROGRESS_LABELS = {
	[MARKER_UV_INSTALL]     = i18n.get("mlx.deps_step_uv"),
	[MARKER_PYTHON_INSTALL] = i18n.get("mlx.deps_step_python"),
	[MARKER_VENV_CREATE]    = i18n.get("mlx.deps_step_venv"),
	[MARKER_DEPS_SYNC]      = i18n.get("mlx.deps_step_sync"),
}

--- Detects whether a stdout chunk contains a specific marker line.
--- @param chunk string Stdout chunk (possibly multiple lines).
--- @param marker string Marker constant to match against.
--- @return boolean True when the chunk contains the exact marker.
local function chunk_contains(chunk, marker)
	if type(chunk) ~= "string" or chunk == "" then return false end
	for line in chunk:gmatch("([^\n\r]+)") do
		if line == marker then return true end
	end
	return false
end

--- Logs every non-empty line from a chunk at INFO level AND forwards it to
--- the progress UI's verbose detail line + scrollable terminal log,
--- skipping protocol markers.
--- @param chunk string A stdout or stderr chunk.
--- @param is_current function|nil Authorization predicate.
--- @param owns_ui function|nil Exact shared-window ownership predicate.
--- @return boolean delivered
local function forward_chunk(chunk, is_current, owns_ui)
	if type(chunk) ~= "string" or chunk == "" then return true end
	is_current = type(is_current) == "function" and is_current or function() return true end
	owns_ui = type(owns_ui) == "function" and owns_ui or function() return false end
	for line in chunk:gmatch("([^\n\r]+)") do
		if line:match("%S") and not KNOWN_MARKERS[line] then
			if not is_current() then return false end
			Logger.info(LOG, "[script] %s", line)
			-- The detail line shows the latest, the log area shows history.
			-- Both are wired so the user sees progress at a glance and the
			-- full audit trail — matching how model downloads already render.
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

-- Map each progress marker to a percentage so the bootstrap bar visibly
-- advances rather than sitting at 0%. Values are coarse on purpose: they
-- only need to show monotonic progress, not exact accuracy. uv resolution
-- and wheel downloads dominate the slow path, hence the wide gap from
-- DEPS_SYNCING (70%) to DEPS_SYNCED (100%) — the script can spend several
-- minutes there.
local MARKER_PROGRESS = {
	[MARKER_UV_INSTALL]     = 5,
	[MARKER_UV_INSTALLED]   = 15,
	[MARKER_PYTHON_INSTALL] = 25,
	[MARKER_PYTHON_DONE]    = 40,
	[MARKER_VENV_CREATE]    = 50,
	[MARKER_VENV_CREATED]   = 60,
	[MARKER_DEPS_SYNC]      = 70,
	[MARKER_DEPS_SYNCED]    = 100,
}

--- Returns the trailing N characters of `s`, trimmed of empty lines, so
--- the failure message carries the actual cause rather than a generic
--- "consultez la console".
--- @param s string Combined stdout+stderr of the script.
--- @return string Trimmed tail suitable for an error display.
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
	-- Keep only the last non-empty line for a single-line UI render
	local last = tail:match("([^\n]+)%s*$")
	return last or tail
end

--- @return boolean True when the Lua-side knows a real sync ran (slow path).
local function chunk_marked_real_sync(stdout)
	return chunk_contains(stdout or "", SYNC_MARKER_LINE)
end




-- ===============================================
-- ===============================================
-- ======= 3/ Streaming Progress Handler =========
-- ===============================================
-- ===============================================

--- Builds a closure that consumes stdout AND stderr chunks from the bash
--- script. Maintains per-marker dedupe state (each marker only fires once)
--- and lazily shows the progress UI on the first slow-path marker so a
--- silent fast-path run never paints anything on screen.
--- @return function streaming_callback Compatible with hs.task:setStreamingCallback.
-- Identity of the shared progress window at the moment THIS checker claimed it,
-- or nil while it owns nothing.
--
-- The window is a single-instance surface that the model download, the Ollama
-- bootstrap and this checker can each take over, so every later write or hide
-- has to prove it still owns what it is about to touch. Captured when the
-- window is CLAIMED rather than sampled at completion, which would read
-- whichever operation owns it by then -- precisely the one that must not be
-- touched.
--
-- Module-level on purpose: the streaming handler assigns it and the completion
-- path reads it, so a local inside either would be out of scope for the other
-- and would silently bind a nil global instead.
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

local function make_streaming_handler(is_current)
	is_current = type(is_current) == "function" and is_current or function() return true end
	-- Per-marker dedupe: stdout is line-buffered but each marker may arrive
	-- multiple times across chunks; we want exactly one transition each.
	local shown = {}
	-- Query the shared surface before every claim. An already visible window
	-- may belong to a model download or the sibling backend and is never ours
	-- merely because this task produced a progress marker.
	local function ui_already_visible()
		local ok, visible = pcall(llm_progress.is_active)
		-- An unreadable shared surface is potentially owned by somebody else.
		-- Treat uncertainty as occupied so this backend cannot take it over.
		return not ok or visible == true
	end

	return function(_, stdout_chunk, stderr_chunk)
		if not is_current() then return false end
		-- Forward stderr (uv's verbose output) so the live log AND the
		-- progress UI's detail line both reflect real-time progress.
		if not forward_chunk(stderr_chunk, is_current, owns_window) then return false end
		if not forward_chunk(stdout_chunk, is_current, owns_window) then return false end

		if type(stdout_chunk) ~= "string" or stdout_chunk == "" then
			return true
		end

		-- VENV_SYNC_RAN is the first thing emitted on a slow path: that's
		-- our cue to show the progress UI for the rest of the run.
		if not shown[SYNC_MARKER_LINE] and chunk_contains(stdout_chunk, SYNC_MARKER_LINE) then
			if not is_current() then return false end
			shown[SYNC_MARKER_LINE] = true
			Logger.debug(LOG, "Slow-path marker observed (real sync in progress).")
			local already_visible = ui_already_visible()
			if not is_current() then return false end
			if not already_visible then
				local shown_ok = pcall(llm_progress.show, {
					kind     = "mlx_install",
					title    = i18n.get("mlx.install_title"),
					subtitle = i18n.get("mlx.deps_preparing"),
				})
				if not is_current() then return false end
				local claimed_session = owned_session()
				if not is_current() then return false end
				if shown_ok then
					_ui_session = claimed_session
					_ui_claimed = true
				end
			end
		end

		for marker, label in pairs(PROGRESS_LABELS) do
			if not shown[marker] and chunk_contains(stdout_chunk, marker) then
				if not is_current() then return false end
				shown[marker] = true
				Logger.info(LOG, "Progress marker '%s' observed — updating UI.", marker)
				local already_visible = ui_already_visible()
				if not is_current() then return false end
				if not already_visible then
					local shown_ok = pcall(llm_progress.show, {
						kind     = "mlx_install",
						title    = i18n.get("mlx.install_title"),
						subtitle = label,
					})
					if not is_current() then return false end
					local claimed_session = owned_session()
					if not is_current() then return false end
					if shown_ok then
						_ui_session = claimed_session
						_ui_claimed = true
					end
				else
					if owns_window() then
						if not is_current() then return false end
						pcall(llm_progress.set_step, label)
					end
				end
			end
		end

		-- Advance the progress bar: collect all new matching marker pcts and
		-- call set_progress once with the maximum. pairs() has non-deterministic
		-- order so multiple matches per chunk could call set_progress with
		-- decreasing values, regressing the bar (lib-deps-2).
		local max_pct = nil
		for marker, pct in pairs(MARKER_PROGRESS) do
			local progress_key = "progress:" .. marker
			if not shown[progress_key] and chunk_contains(stdout_chunk, marker) then
				shown[progress_key] = true
				if not max_pct or pct > max_pct then max_pct = pct end
			end
		end
		if max_pct and owns_window() then
			if not is_current() then return false end
			pcall(llm_progress.set_progress, max_pct)
		end
		return true
	end
end





-- ==========================================
-- ==========================================
-- ======= 4/ Pause-Owned Native Work =======
-- ==========================================
-- ==========================================

--- Arms and retains one exact backend-local timer.
--- @param slot string Timer slot name.
--- @param delay_sec number Delay in seconds.
--- @param callback function Authorized user callback.
--- @param label string Diagnostic label.
--- @return boolean committed
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
		-- Publish observer ownership before registration because onSettled may
		-- synchronously call back for an already-settled native handle.
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

--- Cancels one exact timer without dropping refused native cleanup debt.
--- @param slot string Timer slot name.
--- @param label string Diagnostic label.
--- @return boolean settled
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

--- Releases one exact task only from its first native terminal delivery.
--- @param owner table Task lifecycle descriptor.
--- @return boolean released
local function release_task_owner(owner)
	if type(owner) ~= "table" or owner.settled == true then return false end
	owner.settled = true
	local task = owner.task
	if task ~= nil then _active_tasks[task] = nil end
	if _task_owner == owner then _task_owner = nil end
	_task_running = false
	return true
end

--- Signals one exact task and waits for its callback to prove settlement.
--- False, nil, throw, and accepted-but-pending results retain the same owner.
--- @param owner table Task lifecycle descriptor.
--- @param label string Diagnostic label.
--- @return boolean settled
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
	local initial_settled = cancel_owned_timer("initial", "MLX initial bootstrap")
	local hide_settled = cancel_owned_timer("hide", "MLX bootstrap auto-hide")
	local deadline_settled = cancel_owned_timer("deadline", "MLX dependency bootstrap deadline")
	local task_settled = terminate_task_owner(_task_owner, "MLX dependency bootstrap")
	return initial_settled == true and hide_settled == true
		and deadline_settled == true and task_settled == true
end

schedule_initial_for_token = function(token)
	local authorization = _pause_controller.capture(token)
	if authorization == nil then return false end
	_resume_intent = { kind = "initial" }
	local committed = arm_owned_timer("initial", 0, function()
		if not _pause_controller.is_current(token, authorization) then return false end
		return M.check_and_install_deps(nil, token)
	end, "MLX initial bootstrap")
	if committed ~= true then
		_pause_controller.complete(token)
		return false
	end
	if _pause_controller.commit(token) ~= true then
		cancel_owned_timer("initial", "MLX initial bootstrap rollback")
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
	end, "MLX bootstrap auto-hide")
	if committed ~= true then
		return false
	end
	if not _pause_controller.is_current(token, authorization) then
		cancel_owned_timer("hide", "MLX bootstrap auto-hide rollback")
		return false
	end
	_resume_intent = { kind = "hide", session = hide_session }
	return true
end

replay_committed_intent = function(token, _epoch)
	local intent = _resume_intent
	if type(intent) ~= "table" then return _pause_controller.complete(token) end
	if intent.kind == "initial" then return schedule_initial_for_token(token) end
	if intent.kind == "task" then return M.check_and_install_deps(nil, token) end
	if intent.kind == "hide" then
		return schedule_hide_for_token(token, intent.session)
	end
	return false
end

--- Registers the exact MLX dependency bootstrap pause owner.
--- @param script_control table ScriptControl facade.
--- @return boolean committed
function M.configure_pause_owner(script_control)
	return _pause_controller.configure(script_control)
end

--- Schedules the boot-time dependency check under an exact retained timer.
--- @return boolean committed
function M.schedule_initial_check()
	if not _pause_controller.is_admitted() then
		Logger.debug(LOG, "MLX initial bootstrap rejected by pause admission.")
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

--- Runs the bash script verifying python dependencies for MLX
--- asynchronously. The script is hash-gated: a no-op run finishes silently
--- and the progress UI never appears. A real sync prints SYNC_MARKER_LINE
--- first and then granular markers per long-running step which we surface
--- through ui.download_window.
--- @param on_complete function|nil Called when the script exits — receives
---   true on success, false on failure. Safe to call repeatedly; only the
---   first invocation runs the script, subsequent ones queue the callback.
-- Fires all pending callbacks with the given result and clears the queue.
-- Exact task settlement, not business callback delivery, owns _task_running.
fire_pending_callbacks = function(ok, is_current)
	while #_pending_callbacks > 0 do
		if type(is_current) == "function" and not is_current() then return false end
		local cb = table.remove(_pending_callbacks, 1)
		ApiCommon.protected_call(cb, "MLX dependency on_complete", ok)
	end
	return true
end

local function discard_pending_callbacks()
	_pending_callbacks = {}
	_terminal_outcome = nil
end

function M.check_and_install_deps(on_complete, replay_token)
	if not _pause_controller.is_admitted() then
		Logger.debug(LOG, "MLX dependency bootstrap rejected by pause admission.")
		return false
	end
	-- If already done, fire the callback immediately — no need to re-run.
	if _bootstrap_state == "ready" then
		if replay_token ~= nil then
			local replay_authorization = _pause_controller.capture(replay_token)
			if replay_authorization == nil then return false end
			if fire_pending_callbacks(true, function()
				return _pause_controller.is_current(replay_token, replay_authorization)
			end) ~= true then return false end
			_terminal_outcome = nil
			return _pause_controller.complete(replay_token)
		end
		ApiCommon.protected_call(on_complete, "MLX dependency on_complete", true)
		return true
	end
	if _bootstrap_state == "failed" then
		if replay_token ~= nil then
			local replay_authorization = _pause_controller.capture(replay_token)
			if replay_authorization == nil then return false end
			if fire_pending_callbacks(false, function()
				return _pause_controller.is_current(replay_token, replay_authorization)
			end) ~= true then return false end
			_terminal_outcome = nil
			return _pause_controller.complete(replay_token)
		end
		ApiCommon.protected_call(on_complete, "MLX dependency on_complete", false)
		return true
	end

	-- Script is already running — queue the callback instead of launching a
	-- second bash process in parallel. Guard on _task_running (not on
	-- #_pending_callbacks) so nil-callback callers are also blocked.
	if _task_running then
		local owner = _task_owner
		if type(owner) ~= "table"
			or not _pause_controller.is_current(owner.token, owner.authorization) then
			Logger.debug(LOG, "Stale MLX dependency task cannot accept another caller.")
			return false
		end
		if type(on_complete) == "function" then
			table.insert(_pending_callbacks, on_complete)
		end
		Logger.debug(LOG, "Bootstrap already running — queued on_complete callback (%d total).", #_pending_callbacks)
		return true
	end

	local token = replay_token or _pause_controller.begin()
	local authorization = token and _pause_controller.capture(token) or nil
	if token == nil or authorization == nil then
		Logger.debug(LOG, "MLX dependency bootstrap intent acquisition refused.")
		return false
	end

	if type(on_complete) == "function" then
		table.insert(_pending_callbacks, on_complete)
	end
	-- Callback registration creates a terminal obligation even before the
	-- subprocess intent commits. A reentrant PAUSE may still make this call
	-- return false, but every registered waiter must then receive false once.
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

	Logger.start(LOG, "Bootstrapping MLX virtualenv…")
	local script_path = resolve_bootstrap_script_path()
	if not script_path then
		Logger.error(LOG, "Unable to resolve ensure-mlx-deps.sh from current runtime paths — bootstrap aborted.")
		return settle_preflight_failure("ensure-mlx-deps.sh introuvable.")
	end

	local hs_root = script_path:match("^(.*)/modules/llm/ensure%-mlx%-deps%.sh$") or ""
	if hs_root == "" then
		Logger.error(LOG, "Could not derive HS root from script path '%s' — bootstrap aborted.", script_path)
		return settle_preflight_failure("Chemin du script MLX invalide.")
	end

	-- Forward the project root so the script knows where to find .venv even
	-- when launched outside the project directory (e.g. from launchd).
	local env_prefix = "PROJECT_ROOT=" .. shell_quote(hs_root) .. " "
	local bash_cmd = env_prefix .. "/bin/bash " .. shell_quote(script_path)

	Logger.debug(LOG, "Executing dependency validation script in background (root=%s)…", hs_root)

	-- Surface the launched command in the terminal area so the user has
	-- visible proof that work has started — even before uv emits its first
	-- line. The step-line communicates the macro phase; the detail-line is
	-- left blank so the very first real subprocess line populates it.
	if not _pause_controller.is_current(token, authorization) then
		return settle_stale_intent()
	end
	if owns_window() then
		pcall(llm_progress.append_log, "$ " .. bash_cmd)
		if not _pause_controller.is_current(token, authorization) then
			return settle_stale_intent()
		end
		pcall(llm_progress.set_step, i18n.get("mlx.deps_step_bootstrap"))
		if not _pause_controller.is_current(token, authorization) then
			return settle_stale_intent()
		end
	end
	Logger.debug(LOG, "Full bash command: %s", bash_cmd)
	if not _pause_controller.is_current(token, authorization) then
		return settle_stale_intent()
	end

	local pty_wrapper_path, wrapper_error = PtyProcessGroup.create("MLX dependency")
	if not pty_wrapper_path then
		Logger.error(LOG, "Failed to publish the MLX process-group wrapper: %s.",
			tostring(wrapper_error))
		return settle_preflight_failure(i18n.get("mlx.deps_pty_write_failed"))
	end
	if not _pause_controller.is_current(token, authorization) then
		PtyProcessGroup.remove(pty_wrapper_path)
		return settle_stale_intent()
	end
	Logger.debug(LOG, "PTY wrapper created successfully at %s", pty_wrapper_path)

	-- Wrap the bash invocation in a tiny Python pty.spawn shim so the child
	-- processes (bash, uv, python install) see a real pseudo-TTY on their
	-- stdio. Without a pty, uv (Rust) and any libc-using subprocess switch
	-- to fully buffered stdio when piped, meaning their output only reaches
	-- our streaming callback when a 4 KB buffer fills — i.e., not for
	-- minutes. We use Python (built-in to macOS at /usr/bin/python3 since
	-- Catalina) rather than BSD `script` because macOS `script -F` does not
	-- mean "flush" (it means "write to named pipe") — `script` ends up
	-- buffering its own stdout output and we get nothing in real time.
	-- python -u + pty.spawn gives us unbuffered, line-by-line forwarding.

	Logger.debug(LOG, "Creating hs.task for PTY wrapper execution…")
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
		return owner.authorized == true
			and _pause_controller.is_current(owner.token, owner.authorization)
	end
	local consume_stream = make_streaming_handler(owner_is_current)
	local function process_terminal(exit_code, stdout, stderr)
		-- Completion callback: fires when the process exits
		local combined = (stdout or "") .. (stderr or "")

		-- Final pass: forward any residual lines the streaming callback may
		-- have missed if the task ended before its final flush.
		if not forward_chunk(stdout or "", owner_is_current, owns_window) then return false end
		if not forward_chunk(stderr or "", owner_is_current, owns_window) then return false end

		local ran_real_sync = chunk_marked_real_sync(stdout or "")

		if exit_code == 0 then
			if not owner_is_current() then return false end
			local hide_committed = false
			if ran_real_sync then
				Logger.success(LOG, "MLX virtualenv synchronised — engine ready.")
				if owns_window() then
					if not owner_is_current() then return false end
					pcall(llm_progress.set_step, i18n.get("mlx.deps_step_ready"))
					if not owner_is_current() then return false end
					pcall(llm_progress.set_progress, 100)
					-- The progress window is a shared, single-instance surface. Arm
					-- hide only for the exact session this checker already claimed.
					local hide_session = _ui_session
					hide_committed = schedule_hide_for_token(token, hide_session)
					if hide_committed ~= true and not _pause_controller.is_admitted() then
						return false
					end
				end
			else
				Logger.success(LOG, "MLX virtualenv already in sync — fast path.")
				-- A replay can take the fast path while this checker's earlier
				-- progress session remains visible. Hide only that exact session.
				if not owner_is_current() then return false end
				if owns_window() then
					if not owner_is_current() then return false end
					pcall(llm_progress.hide)
					if not owner_is_current() then return false end
					release_window_claim()
				else
					Logger.debug(LOG, "Fast-path hide skipped: the window now belongs to another operation.")
				end
				if not owner_is_current() then return false end
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
		else
			if not owner_is_current() then return false end
			local tail = tail_for_error(combined)
			if tail == "" then tail = "Cause inconnue. Consultez " .. Logger.UNIFIED_LOG_FILE .. "." end
			Logger.error(LOG, "MLX bootstrap failed (exit=%d) — %s",
				tonumber(exit_code) or -1, tail:gsub("\n", " | "))
			-- Make sure the UI is visible so the error is surfaced even when
			-- the failure happened before the slow-path marker was emitted.
			if not owner_is_current() then return false end
			local active_ok, active = pcall(llm_progress.is_active)
			if not owner_is_current() then return false end
			if active_ok and active ~= true then
				if not owner_is_current() then return false end
				local shown_ok = pcall(llm_progress.show, {
					kind     = "mlx_install",
					title    = i18n.get("mlx.install_title"),
					subtitle    = i18n.get("mlx.deps_failed"),
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
				pcall(llm_progress.set_error, tail)
				if not owner_is_current() then return false end
			end
			_bootstrap_state = "failed"
			_last_failure_message = tail
			_terminal_outcome = false
			local callbacks_delivered = fire_pending_callbacks(false, owner_is_current)
			if callbacks_delivered == true then
				_terminal_outcome = nil
				_pause_controller.complete(token)
			end
			return callbacks_delivered
		end
	end

	local function process_settled_terminal(args)
		if owner.terminal_processed == true then return false end
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
		if cancel_owned_timer("deadline", "MLX dependency bootstrap deadline") ~= true then
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

	-- Construct the full Python invocation: python3 executes the PTY wrapper,
	-- passing bash_cmd so the child process receives the exact shell command.
	task = TaskLifecycle.native("MLX dependency bootstrap", "/usr/bin/python3",
		completion_callback, streaming_callback,
		{ "-u", pty_wrapper_path, "/bin/bash", "-c", bash_cmd })

	if not task then
		owner.authorized = false
		PtyProcessGroup.remove(pty_wrapper_path)
		return settle_preflight_failure(i18n.get("mlx.deps_task_create_failed"))
	end
	owner.task = task
	_task_owner = owner
	_task_running = true
	_active_tasks[task] = true
	Logger.debug(LOG, "hs.task created successfully")
	if owner.pending_terminal ~= nil then
		owner.dispatching = false
		deliver_terminal(owner.pending_terminal)
		return settle_preflight_failure(i18n.get("mlx.deps_task_start_failed"))
	end
	local deadline_committed = arm_owned_timer("deadline", BOOTSTRAP_TIMEOUT_SEC, function()
		if owner.terminal_received == true or owner.timed_out == true
			or owner.start_committed ~= true or not owner_is_current() then
			return false
		end
		owner.timed_out = true
		local message = i18n.get("mlx.deps_failed")
		Logger.error(LOG,
			"MLX dependency bootstrap timed out after %.1f seconds; terminating the exact child.",
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
		terminate_task_owner(owner, "MLX dependency bootstrap timeout")
		return true
	end, "MLX dependency bootstrap deadline")
	if deadline_committed ~= true then
		owner.dispatching = false
		owner.authorized = false
		release_task_owner(owner)
		PtyProcessGroup.remove(pty_wrapper_path)
		return settle_preflight_failure(i18n.get("mlx.deps_failed"))
	end

	Logger.debug(LOG, "Starting hs.task…")
	local started = TaskLifecycle.start(task, "MLX dependency bootstrap")
	if started ~= true then
		owner.dispatching = false
		owner.authorized = false
		cancel_owned_timer("deadline", "MLX dependency bootstrap deadline")
		if owner.pending_terminal ~= nil then
			deliver_terminal(owner.pending_terminal)
		else
			terminate_task_owner(owner, "MLX dependency bootstrap start rollback")
		end
		local current = _pause_controller.is_current(token, authorization)
		if current then
			_bootstrap_state = "failed"
			_last_failure_message = i18n.get("mlx.deps_task_start_failed")
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
	if _pause_controller.commit(token) ~= true then
		owner.dispatching = false
		owner.authorized = false
		cancel_owned_timer("deadline", "MLX dependency bootstrap deadline")
		if owner.pending_terminal ~= nil then
			deliver_terminal(owner.pending_terminal)
		else
			terminate_task_owner(owner, "MLX dependency bootstrap commit rollback")
		end
		if not _pause_controller.is_committed(token) then
			_pause_controller.complete(token)
			discard_pending_callbacks()
		end
		return false
	end
	_resume_intent = { kind = "task" }
	owner.dispatching = false
	for _, args in ipairs(owner.pending_streams) do
		if not owner_is_current()
			or consume_stream(table.unpack(args, 1, args.n)) ~= true then
			owner.authorized = false
			cancel_owned_timer("deadline", "MLX dependency bootstrap deadline")
			terminate_task_owner(owner, "MLX dependency bootstrap stream rollback")
			return false
		end
	end
	owner.pending_streams = {}
	if owner.pending_terminal ~= nil then deliver_terminal(owner.pending_terminal) end
	Logger.debug(LOG, "hs.task started successfully")
	return true
end





--- ==================================
--- ==================================
--- ======= 6/ State Accessors =======
--- ==================================
--- ==================================

--- @return string The current bootstrap state ("pending" / "ready" / "failed").
function M.get_state() return _bootstrap_state end

--- @return boolean True only when the venv is fully provisioned and matches
--- the pinned pyproject.toml. Callers that gate IA features on the bootstrap
--- outcome should use this predicate instead of inspecting raw state.
function M.is_ready() return _bootstrap_state == "ready" end

--- @return boolean True while the bootstrap is still running (initial state).
--- Menus should NOT disable IA features in this state — the bootstrap is
--- expected to flip to "ready" within seconds on a normal reload.
function M.is_pending() return _bootstrap_state == "pending" end

--- @return boolean True when the bootstrap definitively failed; IA features
--- must stay disabled until the user fixes the venv and reloads HS.
function M.has_failed() return _bootstrap_state == "failed" end

--- @return string|nil Last failure message captured from the bash script
--- (stderr tail), or nil when bootstrap is pending or successful.
function M.get_failure_message() return _last_failure_message end

--- Resets a definitively-"failed" bootstrap back to "pending" so the tray
--- menu's "install now" action (or any subsequent check_and_install_deps
--- call) can retry instead of hitting the permanent dead end the "failed"
--- state used to be (F-LOW-10). Without this, a TRANSIENT failure (network
--- down during the uv/Python download, a momentarily-locked file) required a
--- full Hammerspoon reload to recover from — check_and_install_deps() short-
--- circuits unconditionally on "failed" with no way back to "pending".
--- A no-op while a bootstrap task is already running (retrying mid-flight
--- would race the in-progress hs.task).
--- @return boolean True if the reset was applied, false if a no-op (already
--- pending/ready, or a bootstrap task is currently running).
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
	Logger.info(LOG, "Resetting MLX bootstrap state from 'failed' back to 'pending' — retry now possible.")
	_bootstrap_state      = "pending"
	_last_failure_message = nil
	_terminal_outcome     = nil
	return true
end

return M
