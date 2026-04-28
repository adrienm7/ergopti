--- lib/mlx_deps_checker.lua

--- ==============================================================================
--- MODULE: MLX Dependencies Checker
--- DESCRIPTION:
--- Auto-bootstraps the project-local Python virtualenv at
--- static/drivers/hammerspoon/.venv from pyproject.toml on every Hammerspoon
--- startup. The heavy lifting lives in modules/llm/ensure-mlx-deps.sh; this
--- module orchestrates the async invocation, streams stdout AND stderr to
--- surface granular progress (uv install, Python install, venv creation,
--- deps sync) and reports the FINAL state to the user.
---
--- FEATURES & RATIONALE:
--- 1. Transparent fast path: the bash script hash-compares pyproject.toml
---    against a marker file and exits silently in milliseconds when nothing
---    changed. The user sees nothing — exactly what they expect on a normal
---    reload.
--- 2. Granular progress UX: the script prints identifiable markers
---    (UV_INSTALLING, PYTHON_INSTALLING, VENV_CREATING, DEPS_SYNCING) on its
---    stdout when about to start each long-running step. We stream stdout
---    line by line and show two simultaneous UX channels per marker:
---      - a hs.notify notification (persists in the notification centre);
---      - a persistent on-screen status banner pinned at the top of the
---        screen that updates in place as the bootstrap progresses, so the
---        user always sees the current step at a glance.
--- 3. Verbose live log: every line of the script's stderr (which carries
---    uv's verbose progress like "Downloading torch (220 MB)…") is forwarded
---    to Logger.info IN REAL TIME via the streaming callback. This means
---    `tail -f /tmp/ergopti.log` shows live download progress on a fresh
---    Mac, instead of a 4-minute frozen silence.
--- 4. Final state reporting: a successful slow-path run posts a "moteur IA
---    prêt" notification and dismisses the status banner; any failure
---    surfaces a French error notification that includes the actual stderr
---    tail from the script (network down, uv install blocked, etc.).
--- 5. Non-blocking: full check + install runs in a background hs.task so the
---    Hammerspoon main loop is never frozen, even on a fresh clone where
---    bootstrapping uv + Python + the MLX wheels takes minutes.
--- 6. Tri-state lifecycle: callers branch on get_state() ("pending" /
---    "ready" / "failed"). The IA menu stays usable while bootstrap is
---    "pending" and only flips to "failed" if a real IA attempt occurs
---    after a definitive failure.
--- ==============================================================================

local M = {}
local hs            = hs
local Logger        = require("lib.logger")
local notifications = require("lib.notifications")

local LOG = "mlx_deps"

-- Marker line printed by ensure-mlx-deps.sh on its FIRST stdout flush
-- whenever it is about to run a non-trivial sync. Absence of the marker
-- means the script took the silent fast path.
local SYNC_MARKER_LINE   = "VENV_SYNC_RAN"

-- Granular progress markers printed by the bash script before each
-- long-running step. Each maps to a French "patientez" notification so
-- the user always knows exactly what is happening — particularly on a
-- fresh-out-of-the-box Mac where uv and Python may need to be downloaded.
local MARKER_UV_INSTALL     = "UV_INSTALLING"
local MARKER_UV_INSTALLED   = "UV_INSTALLED"
local MARKER_PYTHON_INSTALL = "PYTHON_INSTALLING"
local MARKER_PYTHON_DONE    = "PYTHON_INSTALLED"
local MARKER_VENV_CREATE    = "VENV_CREATING"
local MARKER_VENV_CREATED   = "VENV_CREATED"
local MARKER_DEPS_SYNC      = "DEPS_SYNCING"
local MARKER_DEPS_SYNCED    = "DEPS_SYNCED"

-- Number of trailing characters of stderr/stdout to surface in the failure
-- notification. Long enough to include the actual error from curl / uv,
-- short enough to fit in a macOS notification center bubble.
local FAILURE_TAIL_CHARS = 400

-- Duration (in seconds) for the persistent status banner. Set to a value
-- much larger than any plausible bootstrap so the banner stays visible for
-- the full operation; we dismiss it explicitly when the task completes.
local BANNER_DURATION_SEC = 86400

-- Banner styling: pinned to the top edge of the main screen, dark
-- background, bright white text so it remains readable over any wallpaper.
local BANNER_STYLE = {
	atScreenEdge = 1,                                     -- 1 = top edge
	fillColor    = { red = 0.05, green = 0.05, blue = 0.10, alpha = 0.92 },
	strokeColor  = { red = 0.30, green = 0.55, blue = 0.95, alpha = 1.0 },
	strokeWidth  = 2,
	textColor    = { red = 1.0,  green = 1.0,  blue = 1.0,  alpha = 1.0 },
	textSize     = 16,
	radius       = 10,
	padding      = 18,
}

-- Module-level state so callers can branch on the bootstrap outcome without
-- re-running the script. The values are:
--   "pending" — bootstrap not finished yet (initial state).
--   "ready"   — venv is provisioned and pyproject.toml hash matches.
--   "failed"  — bootstrap failed; IA features must stay disabled.
local _bootstrap_state = "pending"

-- Last error message captured from the script (stderr tail). Surfaced by
-- callers that need to explain WHY an IA action was refused.
local _last_failure_message = nil

-- UUID of the currently displayed status banner, if any. We track it so we
-- can dismiss the previous banner before drawing a new one (replacing the
-- text in place from the user's perspective) and clear it on completion.
local _banner_uuid = nil




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




-- ============================================
-- ============================================
-- ======= 2/ Persistent Status Banner ========
-- ============================================
-- ============================================

--- Replaces the on-screen status banner with a new message. Calling this
--- repeatedly produces the visual effect of a single banner whose text
--- updates as the bootstrap progresses through its stages.
--- @param message string French status text.
local function update_banner(message)
	-- Dismiss the previous banner so the text effectively "updates" rather
	-- than stacking multiple banners on top of each other.
	if _banner_uuid then
		pcall(hs.alert.closeSpecific, _banner_uuid)
		_banner_uuid = nil
	end
	local ok, uuid = pcall(hs.alert.show, message, BANNER_STYLE, BANNER_DURATION_SEC)
	if ok and type(uuid) == "string" then
		_banner_uuid = uuid
	end
end

--- Dismisses the persistent banner if one is currently shown. Called when
--- the bootstrap finishes (success OR failure) so the screen returns to a
--- clean state.
local function dismiss_banner()
	if _banner_uuid then
		pcall(hs.alert.closeSpecific, _banner_uuid)
		_banner_uuid = nil
	end
end




-- ==========================================
-- ==========================================
-- ======= 3/ Marker / Output Parsing =======
-- ==========================================
-- ==========================================

-- Set of all known protocol marker lines. Used to decide whether a stderr
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

--- Detects whether a stdout chunk contains a specific marker line. Marker
--- lines are emitted on their own line by the bash script, but the chunk
--- may also include subsequent log noise — so we scan line-by-line.
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

--- Logs every non-empty line from a chunk at INFO level, skipping protocol
--- markers. Used in real-time inside the streaming callback so the live
--- 'tail -f /tmp/ergopti.log' shows uv's verbose output as it happens.
--- @param chunk string A stdout or stderr chunk.
local function log_chunk_lines(chunk)
	if type(chunk) ~= "string" or chunk == "" then return end
	for line in chunk:gmatch("([^\n\r]+)") do
		if line:match("%S") and not KNOWN_MARKERS[line] then
			Logger.info(LOG, "[script] %s", line)
		end
	end
end

--- Returns the trailing N characters of `s`, trimmed of empty lines, so the
--- failure notification carries the actual cause (curl error, uv install
--- failure, etc.) rather than a generic "consultez la console" message.
--- @param s string Combined stdout+stderr of the script.
--- @return string Trimmed tail suitable for a notification body.
local function tail_for_notification(s)
	if type(s) ~= "string" or s == "" then return "" end
	local n = #s
	local start = n > FAILURE_TAIL_CHARS and (n - FAILURE_TAIL_CHARS + 1) or 1
	local tail = s:sub(start)
	-- Strip leading partial line so the message starts on a clean boundary.
	tail = tail:gsub("^[^\n]*\n", "")
	-- Drop our protocol markers from the tail; they confuse the user.
	for marker, _ in pairs(KNOWN_MARKERS) do
		tail = tail:gsub(marker .. "\n?", "")
	end
	-- Collapse whitespace for a denser notification body.
	tail = tail:gsub("[ \t]+\n", "\n"):gsub("\n\n+", "\n")
	return tail
end

--- @return boolean True when the Lua-side knows a real sync ran (slow path).
local function chunk_marked_real_sync(stdout)
	return chunk_contains(stdout or "", SYNC_MARKER_LINE)
end




-- ===============================================
-- ===============================================
-- ======= 4/ Streaming Progress Handler =========
-- ===============================================
-- ===============================================

--- Builds a closure that consumes stdout AND stderr chunks from the bash
--- script and shows the user a precise French notification + updates a
--- persistent on-screen banner the first time each marker is observed.
--- Returning a closure keeps the per-task state isolated.
--- @return function streaming_callback Compatible with hs.task:setStreamingCallback.
local function make_streaming_handler()
	-- Per-marker dedupe: stdout is line-buffered but each marker may arrive
	-- multiple times across chunks; we want exactly one notification each.
	local shown = {}

	-- French progress messages keyed by marker. DEPS_SYNCING follows
	-- VENV_SYNC_RAN immediately and gives a more precise label, so the
	-- generic VENV_SYNC_RAN line stays as a silent state-change.
	local progress_label = {
		[MARKER_UV_INSTALL]     = "Installation de uv en cours, veuillez patienter…",
		[MARKER_UV_INSTALLED]   = "uv installé avec succès.",
		[MARKER_PYTHON_INSTALL] = "Installation de Python en cours, veuillez patienter…",
		[MARKER_PYTHON_DONE]    = "Python installé avec succès.",
		[MARKER_VENV_CREATE]    = "Création du virtualenv local en cours…",
		[MARKER_VENV_CREATED]   = "Virtualenv créé avec succès.",
		[MARKER_DEPS_SYNC]      = "Synchronisation des dépendances IA en cours, veuillez patienter…",
		[MARKER_DEPS_SYNCED]    = "Dépendances IA synchronisées.",
	}

	-- Show the initial banner immediately so the user has visual feedback
	-- the moment the streaming callback fires for the first time. The
	-- banner is replaced in place as soon as the first marker arrives.
	local banner_initialised = false

	return function(_, stdout_chunk, stderr_chunk)
		-- Forward stderr (uv's verbose output) line by line to the live log
		-- so the user can `tail -f /tmp/ergopti.log` and see real progress
		-- instead of a frozen silence during the multi-minute deps sync.
		log_chunk_lines(stderr_chunk)
		log_chunk_lines(stdout_chunk)

		if type(stdout_chunk) ~= "string" or stdout_chunk == "" then
			return true
		end

		-- VENV_SYNC_RAN is the first thing emitted on a slow path: flag it
		-- so the post-mortem callback knows a real sync ran.
		if not shown[SYNC_MARKER_LINE] and chunk_contains(stdout_chunk, SYNC_MARKER_LINE) then
			shown[SYNC_MARKER_LINE] = true
			Logger.debug(LOG, "Slow-path marker observed (real sync in progress).")
			if not banner_initialised then
				update_banner("Moteur IA — préparation en cours…")
				banner_initialised = true
			end
		end

		for marker, label in pairs(progress_label) do
			if not shown[marker] and chunk_contains(stdout_chunk, marker) then
				shown[marker] = true
				Logger.info(LOG, "Progress marker '%s' observed — notifying user.", marker)
				pcall(notifications.notify, "Moteur IA", label)
				update_banner("Moteur IA : " .. label)
				banner_initialised = true
			end
		end
		-- Returning true keeps the task running; nil is treated the same way.
		return true
	end
end




-- ========================================
-- ========================================
-- ======= 5/ Public Bootstrap API ========
-- ========================================
-- ========================================

--- Runs the bash script verifying python dependencies for MLX asynchronously.
--- The script is hash-gated: a no-op run finishes silently and no UI
--- notification is shown. A real sync prints the SYNC_MARKER_LINE first and
--- then granular markers per long-running step (UV_INSTALLING,
--- PYTHON_INSTALLING, VENV_CREATING, DEPS_SYNCING) which we surface as
--- progress notifications and a persistent on-screen banner. On failure,
--- the actual stderr tail is shown.
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
		pcall(notifications.notify, "❌ Moteur IA",
			"Script ensure-mlx-deps.sh introuvable. Impossible d'initialiser le venv.")
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
		-- Final pass: log any line we may have missed if the task ended
		-- before the streaming callback flushed its final chunk.
		log_chunk_lines(stdout or "")
		log_chunk_lines(stderr or "")

		local ran_real_sync = chunk_marked_real_sync(stdout or "")

		-- Always dismiss the banner: the bootstrap is done one way or another
		-- and we never want a stale "patientez" message to linger on screen.
		dismiss_banner()

		if exit_code == 0 then
			_bootstrap_state = "ready"
			_last_failure_message = nil
			if ran_real_sync then
				Logger.success(LOG, "MLX virtualenv synchronised — engine ready.")
				pcall(notifications.notify, "✅ Moteur IA prêt",
					"Le virtualenv local a été synchronisé avec pyproject.toml.")
			else
				Logger.success(LOG, "MLX virtualenv already in sync — fast path.")
			end
		else
			_bootstrap_state = "failed"
			local tail = tail_for_notification(combined)
			if tail == "" then tail = "Cause inconnue. Consultez la console Hammerspoon." end
			_last_failure_message = tail
			Logger.error(LOG, "MLX bootstrap failed (exit=%d) — %s",
				tonumber(exit_code) or -1, tail:gsub("\n", " | "))
			pcall(notifications.notify, "❌ Moteur IA — initialisation échouée", tail)
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
		dismiss_banner()
	end
end




-- =================================
-- =================================
-- ======= 6/ State Accessors ======
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
--- (stderr tail), or nil when bootstrap is pending or successful. Callers
--- that surface a "venv not ready" notification should include this so the
--- user sees the real cause (network, uv install blocked, etc.).
function M.get_failure_message() return _last_failure_message end

return M
