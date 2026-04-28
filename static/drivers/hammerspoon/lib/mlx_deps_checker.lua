--- lib/mlx_deps_checker.lua

--- ==============================================================================
--- MODULE: MLX Dependencies Checker
--- DESCRIPTION:
--- Auto-bootstraps the project-local Python virtualenv at
--- static/drivers/hammerspoon/.venv from pyproject.toml on every Hammerspoon
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
---    forwarded to Logger.info so 'tail -f /tmp/ergopti.log' shows the
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
local Logger       = require("lib.logger")
local llm_progress = require("ui.download_window")

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

-- Module-level state so callers can branch on the bootstrap outcome without
-- re-running the script. The values are:
--   "pending" — bootstrap not finished yet (initial state).
--   "ready"   — venv is provisioned and pyproject.toml hash matches.
--   "failed"  — bootstrap failed; IA features must stay disabled.
local _bootstrap_state = "pending"

-- Last error message captured from the script (stderr tail). Surfaced by
-- callers that need to explain WHY an IA action was refused.
local _last_failure_message = nil




-- =====================================
-- =====================================
-- ======= 1/ Path Resolution ==========
-- =====================================
-- =====================================

--- Resolves the project root from this file's own path. Returns nil if the
--- expected layout is not found.
--- @return string|nil project_root Absolute path or nil.
local function resolve_project_root()
	local source = debug.getinfo(1, "S").source or ""
	source = source:sub(1, 1) == "@" and source:sub(2) or source
	-- Expected suffix: .../static/drivers/hammerspoon/lib/mlx_deps_checker.lua
	local root = source:match("^(.*)/static/drivers/hammerspoon/lib/mlx_deps_checker%.lua$")
	if root and root ~= "" and hs.fs.attributes(root, "mode") then
		return root
	end
	return nil
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
	[MARKER_UV_INSTALL]     = "Installation de uv…",
	[MARKER_PYTHON_INSTALL] = "Installation de Python…",
	[MARKER_VENV_CREATE]    = "Création du virtualenv local…",
	[MARKER_DEPS_SYNC]      = "Synchronisation des dépendances IA…",
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
--- the progress UI's verbose detail line, skipping protocol markers.
--- @param chunk string A stdout or stderr chunk.
local function forward_chunk(chunk)
	if type(chunk) ~= "string" or chunk == "" then return end
	for line in chunk:gmatch("([^\n\r]+)") do
		if line:match("%S") and not KNOWN_MARKERS[line] then
			Logger.info(LOG, "[script] %s", line)
			pcall(llm_progress.set_detail, line)
		end
	end
end

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
local function make_streaming_handler()
	-- Per-marker dedupe: stdout is line-buffered but each marker may arrive
	-- multiple times across chunks; we want exactly one transition each.
	local shown = {}
	local ui_shown = false

	return function(_, stdout_chunk, stderr_chunk)
		-- Forward stderr (uv's verbose output) so the live log AND the
		-- progress UI's detail line both reflect real-time progress.
		forward_chunk(stderr_chunk)
		forward_chunk(stdout_chunk)

		if type(stdout_chunk) ~= "string" or stdout_chunk == "" then
			return true
		end

		-- VENV_SYNC_RAN is the first thing emitted on a slow path: that's
		-- our cue to show the progress UI for the rest of the run.
		if not shown[SYNC_MARKER_LINE] and chunk_contains(stdout_chunk, SYNC_MARKER_LINE) then
			shown[SYNC_MARKER_LINE] = true
			Logger.debug(LOG, "Slow-path marker observed (real sync in progress).")
			if not ui_shown then
				pcall(llm_progress.show, {
					kind     = "mlx_install",
					title    = "Initialisation du moteur IA (MLX)",
					subtitle = "Préparation en cours…",
				})
				ui_shown = true
			end
		end

		for marker, label in pairs(PROGRESS_LABELS) do
			if not shown[marker] and chunk_contains(stdout_chunk, marker) then
				shown[marker] = true
				Logger.info(LOG, "Progress marker '%s' observed — updating UI.", marker)
				if not ui_shown then
					pcall(llm_progress.show, {
						kind     = "mlx_install",
						title    = "Initialisation du moteur IA (MLX)",
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

--- Runs the bash script verifying python dependencies for MLX
--- asynchronously. The script is hash-gated: a no-op run finishes silently
--- and the progress UI never appears. A real sync prints SYNC_MARKER_LINE
--- first and then granular markers per long-running step which we surface
--- through ui.download_window.
function M.check_and_install_deps()
	Logger.start(LOG, "Bootstrapping MLX virtualenv…")
	local project_root = resolve_project_root()
	if not project_root then
		Logger.error(LOG, "Project root introuvable depuis mlx_deps_checker.lua — bootstrap aborted.")
		_bootstrap_state = "failed"
		_last_failure_message = "Project root introuvable."
		return
	end

	-- The script lives next to the LLM module (modules/llm/) so all
	-- MLX-related code stays co-located.
	local script_path = project_root .. "/static/drivers/hammerspoon/modules/llm/ensure-mlx-deps.sh"
	if not hs.fs.attributes(script_path, "mode") then
		Logger.error(LOG, "Script ensure-mlx-deps.sh introuvable à %s — bootstrap aborted.", script_path)
		_bootstrap_state = "failed"
		_last_failure_message = "Script ensure-mlx-deps.sh introuvable."
		return
	end

	-- Forward the project root so the script knows where to find .venv even
	-- when launched outside the project directory (e.g. from launchd).
	local env_prefix = "PROJECT_ROOT=" .. project_root .. " "
	local bash_cmd = env_prefix .. "/bin/bash " .. script_path

	Logger.debug(LOG, "Executing dependency validation script in background (root=%s)…", project_root)

	local task
	task = hs.task.new("/bin/bash", function(exit_code, stdout, stderr)
		local combined = (stdout or "") .. (stderr or "")
		-- Final pass: forward any residual lines the streaming callback may
		-- have missed if the task ended before its final flush.
		forward_chunk(stdout or "")
		forward_chunk(stderr or "")

		local ran_real_sync = chunk_marked_real_sync(stdout or "")

		if exit_code == 0 then
			_bootstrap_state = "ready"
			_last_failure_message = nil
			if ran_real_sync then
				Logger.success(LOG, "MLX virtualenv synchronised — engine ready.")
				pcall(llm_progress.set_step, "Moteur IA prêt.")
				pcall(llm_progress.set_progress, 100)
				hs.timer.doAfter(SUCCESS_AUTO_HIDE_SEC, function()
					pcall(llm_progress.hide)
				end)
			else
				Logger.success(LOG, "MLX virtualenv already in sync — fast path.")
				-- Fast path: never showed the UI, nothing to hide.
			end
		else
			_bootstrap_state = "failed"
			local tail = tail_for_error(combined)
			if tail == "" then tail = "Cause inconnue. Consultez /tmp/ergopti.log." end
			_last_failure_message = tail
			Logger.error(LOG, "MLX bootstrap failed (exit=%d) — %s",
				tonumber(exit_code) or -1, tail:gsub("\n", " | "))
			-- Make sure the UI is visible so the error is surfaced even when
			-- the failure happened before the slow-path marker was emitted.
			if not llm_progress.is_active() then
				pcall(llm_progress.show, {
					kind     = "mlx_install",
					title    = "Initialisation du moteur IA (MLX)",
					subtitle = "Échec…",
				})
			end
			pcall(llm_progress.set_error, tail)
		end
	end, { "-c", bash_cmd })

	if not task then
		Logger.error(LOG, "Failed to create hs.task for MLX bootstrap script.")
		_bootstrap_state = "failed"
		_last_failure_message = "Impossible de créer la tâche hs.task."
		return
	end

	-- Streaming callback: fires every time the script flushes stdout. The
	-- handler closure is per-task so reloading HS resets all marker state.
	pcall(function() task:setStreamingCallback(make_streaming_handler()) end)

	if not pcall(function() task:start() end) then
		Logger.error(LOG, "Failed to start hs.task for MLX bootstrap script.")
		_bootstrap_state = "failed"
		_last_failure_message = "Impossible de démarrer la tâche hs.task."
	end
end




-- =================================
-- =================================
-- ======= 5/ State Accessors ======
-- =================================
-- =================================

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

return M
