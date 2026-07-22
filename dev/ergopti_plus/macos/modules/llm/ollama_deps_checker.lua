--- modules/llm/ollama_deps_checker.lua

--- ==============================================================================
--- MODULE: Ollama Dependencies Checker
--- DESCRIPTION:
--- Companion to mlx_deps_checker but for the Ollama backend: ensures the
--- `ollama` binary is installed and the local server is reachable on
--- http://localhost:11434. The heavy lifting lives in
--- modules/llm/ensure-ollama-deps.sh; this module handles the async
--- invocation, marker parsing, and unified-progress-UI integration.
---
--- FEATURES & RATIONALE:
--- 1. Self-bootstrapping: a fresh-out-of-the-box Mac with no Homebrew and
---    no Ollama gets a working server after one Hammerspoon reload.
--- 2. Silent fast path: when the server already answers, the script exits
---    silently and we never paint anything on screen.
--- 3. Granular progress UX: the script emits OLLAMA_INSTALLING /
---    OLLAMA_STARTING / OLLAMA_READY markers; we map each to a French
---    step label in the unified download_window UI.
--- 4. Tri-state lifecycle: callers branch on get_state() ("pending" /
---    "ready" / "failed") just like mlx_deps_checker, so menu code can
---    treat the two backends with one shared pattern.
--- ==============================================================================

local M = {}
local hs           = hs
local Logger       = require("lib.logger")
local i18n         = require("lib.i18n")
local llm_progress = require("ui.download_window")

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

local function forward_chunk(chunk)
	if type(chunk) ~= "string" or chunk == "" then return end
	for line in chunk:gmatch("([^\n\r]+)") do
		if line:match("%S") and not KNOWN_MARKERS[line] then
			Logger.info(LOG, "[script] %s", line)
			-- set_detail shows the latest line at a glance; append_log preserves
			-- the full audit trail — mirroring the mlx_deps_checker behaviour.
			pcall(llm_progress.set_detail, line)
			pcall(llm_progress.append_log, line)
		end
	end
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

--- Builds a closure consuming stdout/stderr chunks. Lazily shows the
--- progress UI on the first marker so a silent fast-path run never paints.
local function make_streaming_handler()
	local shown    = {}
	local ui_shown = false

	return function(_, stdout_chunk, stderr_chunk)
		forward_chunk(stderr_chunk)
		forward_chunk(stdout_chunk)

		if type(stdout_chunk) ~= "string" or stdout_chunk == "" then
			return true
		end

		for marker, label in pairs(PROGRESS_LABELS) do
			if not shown[marker] and chunk_contains(stdout_chunk, marker) then
				shown[marker] = true
				Logger.info(LOG, "Progress marker '%s' observed — updating UI.", marker)
				if not ui_shown then
					pcall(llm_progress.show, {
						kind     = "ollama_install",
						title    = i18n.get("ollama.install_title"),
						subtitle = label,
					})
					ui_shown = true
				else
					pcall(llm_progress.set_step, label)
				end
			end
		end
		return true
	end
end




-- ========================================
-- ========================================
-- ======= 4/ Public Bootstrap API ========
-- ========================================
-- ========================================

--- Asynchronously verifies (and bootstraps) the Ollama backend. Safe to
--- call repeatedly: the underlying script is idempotent and exits silently
--- when nothing needs doing.
function M.check_and_install_deps()
	if _task_running then
		Logger.debug(LOG, "check_and_install_deps() called while a task is already running — ignoring duplicate call.")
		return
	end
	Logger.start(LOG, "Bootstrapping Ollama backend…")
	local project_root = resolve_project_root()
	if not project_root then
		Logger.error(LOG, "Project root introuvable depuis ollama_deps_checker.lua — bootstrap aborted.")
		_bootstrap_state = "failed"
		_last_failure_message = "Project root introuvable."
		return
	end

	local script_path = project_root .. "/static/ergopti_plus/macos/modules/llm/ensure-ollama-deps.sh"
	if not hs.fs.attributes(script_path, "mode") then
		Logger.error(LOG, "Script ensure-ollama-deps.sh introuvable à %s — bootstrap aborted.", script_path)
		_bootstrap_state = "failed"
		_last_failure_message = "Script ensure-ollama-deps.sh introuvable."
		return
	end

	local task
	task = hs.task.new("/bin/bash", function(exit_code, stdout, stderr)
		if task then _active_tasks[task] = nil end
		_task_running = false
		local combined = (stdout or "") .. (stderr or "")
		forward_chunk(stdout or "")
		forward_chunk(stderr or "")

		if exit_code == 0 then
			_bootstrap_state = "ready"
			_last_failure_message = nil
			Logger.success(LOG, "Ollama backend ready.")
			-- Only auto-hide if the UI was actually shown (slow path).
			if llm_progress.is_active() then
				pcall(llm_progress.set_step, i18n.get("ollama.deps_step_ready"))
				pcall(llm_progress.set_progress, 100)
				-- The progress window is a shared, single-instance surface: a model
				-- download or the MLX bootstrap can claim it during this delay.
				-- Capture whose window it is now and only hide THAT one, otherwise
				-- this timer tears down an unrelated operation's UI mid-flight while
				-- that operation keeps running with nothing on screen.
				local hide_session = type(llm_progress.session_id) == "function"
					and llm_progress.session_id() or nil
				hs.timer.doAfter(SUCCESS_AUTO_HIDE_SEC, function()
					if hide_session ~= nil then
						local ok_sid, current = pcall(llm_progress.session_id)
						if ok_sid and current ~= hide_session then
							Logger.debug(LOG, "Auto-hide skipped — the progress window now belongs to another operation.")
							return
						end
					end
					pcall(llm_progress.hide)
				end)
			end
		else
			_bootstrap_state = "failed"
			local tail = tail_for_error(combined)
			if tail == "" then tail = "Cause inconnue. Consultez " .. Logger.UNIFIED_LOG_FILE .. "." end
			_last_failure_message = tail
			Logger.error(LOG, "Ollama bootstrap failed (exit=%d) — %s",
				tonumber(exit_code) or -1, tail:gsub("\n", " | "))
			if not llm_progress.is_active() then
				pcall(llm_progress.show, {
					kind     = "ollama_install",
					title    = i18n.get("ollama.install_title"),
					subtitle = i18n.get("ollama.deps_failed"),
				})
			end
			pcall(llm_progress.set_error, tail)
		end
	end, { script_path })

	if not task then
		Logger.error(LOG, "Failed to create hs.task for Ollama bootstrap script.")
		_bootstrap_state = "failed"
		_last_failure_message = i18n.get("ollama.deps_task_create_failed")
		return
	end

	pcall(function() task:setStreamingCallback(make_streaming_handler()) end)

	_task_running = true
	if task then _active_tasks[task] = true end
	if not pcall(function() task:start() end) then
		if task then _active_tasks[task] = nil end
		_task_running = false
		Logger.error(LOG, "Failed to start hs.task for Ollama bootstrap script.")
		_bootstrap_state = "failed"
		_last_failure_message = i18n.get("ollama.deps_task_start_failed")
	end
end





-- =================================
--- ==================================
--- ======= 5/ State Accessors =======
--- ==================================
-- =================================

--- @return string The current bootstrap state ("pending" / "ready" / "failed").
function M.get_state() return _bootstrap_state end

--- @return boolean True only when the Ollama server answers and the binary is on PATH.
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
