--- lib/mlx_deps_checker.lua

--- ==============================================================================
--- MODULE: MLX Dependencies Checker
--- DESCRIPTION:
--- Auto-bootstraps the project-local Python virtualenv at
--- static/drivers/hammerspoon/.venv from pyproject.toml on every Hammerspoon
--- startup. The heavy lifting lives in modules/llm/ensure-mlx-deps.sh; this
--- module orchestrates the async invocation and surfaces UX feedback only when
--- real work happens (first install or pyproject.toml drift).
---
--- FEATURES & RATIONALE:
--- 1. Transparent fast path: the bash script hash-compares pyproject.toml
---    against a marker file and exits silently in milliseconds when nothing
---    changed. The user sees nothing — exactly what they expect on a normal
---    reload.
--- 2. Progress UX on real work: when the script prints "VENV_SYNC_RAN" on its
---    first stdout line, this module immediately shows a French "patientez"
---    notification so the user knows the IA stack is initialising rather than
---    silently hanging.
--- 3. Final state reporting: a successful slow-path run posts a "moteur IA
---    prêt" notification; any failure surfaces a French error notification AND
---    flips an internal flag so callers can keep the IA features disabled
---    until the next reload fixes the venv.
--- 4. Non-blocking: full check + install runs in a background hs.task so the
---    Hammerspoon main loop is never frozen, even on a fresh clone where the
---    first sync downloads several gigabytes of MLX wheels.
--- ==============================================================================

local M = {}
local hs            = hs
local Logger        = require("lib.logger")
local notifications = require("lib.notifications")

local LOG = "mlx_deps"

-- Marker line printed by ensure-mlx-deps.sh on its FIRST stdout line whenever
-- it is about to run a non-trivial sync. Absence of the marker means the
-- script took the silent fast path.
local SYNC_MARKER_LINE = "VENV_SYNC_RAN"

-- Module-level state so callers can branch on the bootstrap outcome without
-- re-running the script. The values are:
--   "pending" — bootstrap not finished yet (initial state).
--   "ready"   — venv is provisioned and pyproject.toml hash matches.
--   "failed"  — bootstrap failed; IA features must stay disabled.
local _bootstrap_state = "pending"




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




-- ========================================
-- ========================================
-- ======= 2/ Dependency Validation =======
-- ========================================
-- ========================================

--- Detects whether the script's stdout contains the slow-path marker line.
--- Only checks line by line so the marker still matches even when interleaved
--- with the [MLX-DEPS] log lines that follow it.
--- @param stdout string Combined stdout of the script invocation.
--- @return boolean True when the script ran a real sync, false on fast path.
local function stdout_contains_sync_marker(stdout)
	if type(stdout) ~= "string" or stdout == "" then return false end
	for line in stdout:gmatch("([^\n\r]+)") do
		if line == SYNC_MARKER_LINE then return true end
	end
	return false
end

--- Logs every non-empty line from the script's combined output at INFO level.
--- The script reports the resolved version of every MLX package on success,
--- and emits a French error message on failure — both deserve to live in the
--- Hammerspoon log for post-mortem inspection.
--- @param combined string Concatenation of stdout and stderr.
local function forward_script_output(combined)
	for line in combined:gmatch("([^\n\r]+)") do
		if line:match("%S") then
			Logger.info(LOG, "%s", line)
		end
	end
end

--- Runs the bash script verifying python dependencies for MLX asynchronously.
--- The script is hash-gated: a no-op run finishes silently and no UI notification
--- is shown. A real sync prints the SYNC_MARKER_LINE first, which triggers the
--- "patientez" notification immediately and a "prêt" notification on success.
function M.check_and_install_deps()
	Logger.start(LOG, "Bootstrapping MLX virtualenv…")
	local project_root = resolve_project_root()
	if not project_root then
		Logger.error(LOG, "Project root introuvable depuis mlx_deps_checker.lua — bootstrap aborted.")
		_bootstrap_state = "failed"
		return
	end

	-- The script lives next to the LLM module (modules/llm/) so all MLX-related
	-- code stays co-located.
	local script_path = project_root .. "/static/drivers/hammerspoon/modules/llm/ensure-mlx-deps.sh"
	if not hs.fs.attributes(script_path, "mode") then
		Logger.error(LOG, "Script ensure-mlx-deps.sh introuvable à %s — bootstrap aborted.", script_path)
		pcall(notifications.notify, "❌ Moteur IA",
			"Script ensure-mlx-deps.sh introuvable. Impossible d'initialiser le venv.")
		_bootstrap_state = "failed"
		return
	end

	-- Forward the project root so the script knows where to find .venv even
	-- when launched outside the project directory (e.g. from launchd).
	local env_prefix = "PROJECT_ROOT=" .. project_root .. " "
	local bash_cmd = env_prefix .. "/bin/bash " .. script_path

	-- Tracks whether we already showed the "patientez" notification: the script
	-- buffers stdout so the marker may arrive in a single chunk together with
	-- subsequent log lines, and the streaming callback can fire multiple times
	-- on long syncs.
	local progress_notified = false

	Logger.debug(LOG, "Executing dependency validation script in background (root=%s)…", project_root)
	local task
	task = hs.task.new("/bin/bash", function(exit_code, stdout, stderr)
		local combined = (stdout or "") .. (stderr or "")
		forward_script_output(combined)

		local ran_real_sync = stdout_contains_sync_marker(stdout or "")

		if exit_code == 0 then
			_bootstrap_state = "ready"
			if ran_real_sync then
				Logger.success(LOG, "MLX virtualenv synchronised — engine ready.")
				pcall(notifications.notify, "✅ Moteur IA prêt",
					"Le virtualenv local a été synchronisé avec pyproject.toml.")
			else
				Logger.success(LOG, "MLX virtualenv already in sync — fast path.")
			end
		else
			_bootstrap_state = "failed"
			Logger.error(LOG, "MLX bootstrap failed (exit=%d) — IA features will stay disabled.",
				tonumber(exit_code) or -1)
			pcall(notifications.notify, "❌ Moteur IA",
				"L'initialisation du venv local a échoué. Consultez la console Hammerspoon puis relancez.")
		end
	end, { "-c", bash_cmd })

	if not task then
		Logger.error(LOG, "Failed to create hs.task for MLX bootstrap script.")
		_bootstrap_state = "failed"
		return
	end

	-- Streaming callback: fires every time the script flushes stdout. We use it
	-- to detect the "VENV_SYNC_RAN" marker line as soon as it lands, so the
	-- "patientez" notification appears before the slow uv operations run rather
	-- than after the task exits.
	pcall(function()
		task:setStreamingCallback(function(_, stdout_chunk, _)
			if not progress_notified and stdout_contains_sync_marker(stdout_chunk or "") then
				progress_notified = true
				Logger.info(LOG, "Slow-path marker detected — notifying user.")
				pcall(notifications.notify, "Moteur IA",
					"Initialisation du moteur IA, veuillez patienter…")
			end
			-- Returning true keeps the task running; nil is treated the same way.
			return true
		end)
	end)

	if not pcall(function() task:start() end) then
		Logger.error(LOG, "Failed to start hs.task for MLX bootstrap script.")
		_bootstrap_state = "failed"
	end
end




-- =================================
-- =================================
-- ======= 3/ State Accessors =======
-- =================================
-- =================================

--- @return string The current bootstrap state ("pending" / "ready" / "failed").
function M.get_state() return _bootstrap_state end

--- @return boolean True only when the venv is fully provisioned and matches
--- the pinned pyproject.toml. Callers that gate IA features on the bootstrap
--- outcome should use this predicate instead of inspecting raw state.
function M.is_ready() return _bootstrap_state == "ready" end

--- @return boolean True when the bootstrap definitively failed; IA features
--- must stay disabled until the user fixes the venv and reloads HS.
function M.has_failed() return _bootstrap_state == "failed" end

return M
