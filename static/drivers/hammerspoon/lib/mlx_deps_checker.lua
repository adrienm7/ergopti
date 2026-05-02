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

-- Delay before proactively showing the progress UI when the script keeps
-- running without emitting any marker. Covers two cases that would
-- otherwise leave the user staring at a silent menubar:
--   1. uv sync downloads packages internally without producing one of our
--      protocol markers fast enough.
--   2. The python import probe at the fast-path gate stalls for a few
--      seconds while pulling in mlx_lm transitively.
-- Picked above the typical fast-path duration (~50 ms) so a silent reload
-- never flashes the UI, but well below the visible-stall threshold.
local PROACTIVE_UI_DELAY_SEC = 1.5

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
--- the progress UI's verbose detail line + scrollable terminal log,
--- skipping protocol markers.
--- @param chunk string A stdout or stderr chunk.
local function forward_chunk(chunk)
	if type(chunk) ~= "string" or chunk == "" then return end
	for line in chunk:gmatch("([^\n\r]+)") do
		if line:match("%S") and not KNOWN_MARKERS[line] then
			Logger.info(LOG, "[script] %s", line)
			-- The detail line shows the latest, the log area shows history.
			-- Both are wired so the user sees progress at a glance and the
			-- full audit trail — matching how model downloads already render.
			pcall(llm_progress.set_detail, line)
			pcall(llm_progress.append_log, line)
		end
	end
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
local function make_streaming_handler()
	-- Per-marker dedupe: stdout is line-buffered but each marker may arrive
	-- multiple times across chunks; we want exactly one transition each.
	local shown = {}
	-- The proactive-show fallback in M.check_and_install_deps can flip the
	-- progress UI on without going through this handler. Querying the UI
	-- directly each time is more reliable than a cached local: it lets the
	-- markers transition cleanly from "show" to "set_step" even when the UI
	-- is already visible from the fallback path.
	local function ui_already_visible()
		local ok, visible = pcall(llm_progress.is_active)
		return ok and visible == true
	end

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
			if not ui_already_visible() then
				pcall(llm_progress.show, {
					kind     = "mlx_install",
					title    = "Initialisation du moteur IA (MLX)",
					subtitle = "Préparation en cours…",
				})
			end
		end

		for marker, label in pairs(PROGRESS_LABELS) do
			if not shown[marker] and chunk_contains(stdout_chunk, marker) then
				shown[marker] = true
				Logger.info(LOG, "Progress marker '%s' observed — updating UI.", marker)
				if not ui_already_visible() then
					pcall(llm_progress.show, {
						kind     = "mlx_install",
						title    = "Initialisation du moteur IA (MLX)",
						subtitle = label,
					})
				else
					pcall(llm_progress.set_step, label)
				end
			end
		end

		-- Advance the progress bar on EVERY known marker, including the
		-- *_INSTALLED / *_DONE pair markers that PROGRESS_LABELS skips for
		-- step-label updates. Without this loop the bar would stay frozen at
		-- the first step's percentage even as later phases complete.
		for marker, pct in pairs(MARKER_PROGRESS) do
			local progress_key = "progress:" .. marker
			if not shown[progress_key] and chunk_contains(stdout_chunk, marker) then
				shown[progress_key] = true
				pcall(llm_progress.set_progress, pct)
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
--- @param on_complete function|nil Called when the script exits — receives
---   true on success, false on failure. Safe to call repeatedly; only the
---   first invocation runs the script, subsequent ones queue the callback.
-- Fires all pending callbacks with the given result and clears the queue.
local function fire_pending_callbacks(ok)
	local cbs = _pending_callbacks
	_pending_callbacks = {}
	for _, cb in ipairs(cbs) do
		pcall(cb, ok)
	end
end

function M.check_and_install_deps(on_complete)
	-- If already done, fire the callback immediately — no need to re-run.
	if _bootstrap_state == "ready" then
		if type(on_complete) == "function" then on_complete(true) end
		return
	end
	if _bootstrap_state == "failed" then
		if type(on_complete) == "function" then on_complete(false) end
		return
	end

	-- Script is already running — queue the callback instead of launching a
	-- second bash process in parallel.
	if #_pending_callbacks > 0 then
		if type(on_complete) == "function" then
			table.insert(_pending_callbacks, on_complete)
		end
		Logger.debug(LOG, "Bootstrap already running — queued on_complete callback (%d total).", #_pending_callbacks)
		return
	end

	if type(on_complete) == "function" then
		table.insert(_pending_callbacks, on_complete)
	end

	Logger.start(LOG, "Bootstrapping MLX virtualenv…")
	local project_root = resolve_project_root()
	if not project_root then
		Logger.error(LOG, "Project root introuvable depuis mlx_deps_checker.lua — bootstrap aborted.")
		_bootstrap_state = "failed"
		_last_failure_message = "Project root introuvable."
		fire_pending_callbacks(false)
		return
	end

	-- The script lives next to the LLM module (modules/llm/) so all
	-- MLX-related code stays co-located.
	local script_path = project_root .. "/static/drivers/hammerspoon/modules/llm/ensure-mlx-deps.sh"
	if not hs.fs.attributes(script_path, "mode") then
		Logger.error(LOG, "Script ensure-mlx-deps.sh introuvable à %s — bootstrap aborted.", script_path)
		_bootstrap_state = "failed"
		_last_failure_message = "Script ensure-mlx-deps.sh introuvable."
		fire_pending_callbacks(false)
		return
	end

	-- Forward the project root so the script knows where to find .venv even
	-- when launched outside the project directory (e.g. from launchd).
	local env_prefix = "PROJECT_ROOT=" .. project_root .. " "
	local bash_cmd = env_prefix .. "/bin/bash " .. script_path

	Logger.debug(LOG, "Executing dependency validation script in background (root=%s)…", project_root)

	-- Surface the launched command in the terminal area so the user has
	-- visible proof that work has started — even before uv emits its first
	-- line. The step-line communicates the macro phase; the detail-line is
	-- left blank so the very first real subprocess line populates it.
	pcall(llm_progress.append_log, "$ " .. bash_cmd)
	pcall(llm_progress.set_step, "Démarrage du script d'installation…")
	Logger.debug(LOG, "Full bash command: %s", bash_cmd)

	-- Write the PTY wrapper to a temp file so we can pass it to Python properly
	local random_suffix = math.random(100000, 999999)
	local pty_wrapper_path = "/tmp/hs_pty_wrapper_" .. random_suffix .. ".py"
	Logger.debug(LOG, "Creating PTY wrapper at %s…", pty_wrapper_path)
	local pty_file = io.open(pty_wrapper_path, "w")
	if not pty_file then
		Logger.error(LOG, "Failed to write PTY wrapper to %s — aborting bootstrap.", pty_wrapper_path)
		_bootstrap_state = "failed"
		_last_failure_message = "Impossible d'écrire le fichier PTY wrapper."
		return
	end
	-- pty.spawn() alone doesn't forward PTY output to stdout (the Python
	-- process's stdout pipe). We must use os.openpty() and manually forward
	-- the PTY master fd to sys.stdout so hs.task's streaming callback sees
	-- the output. The child process runs with its stdin/stdout/stderr all
	-- wired to the PTY slave, so it behaves as if attached to a real terminal
	-- and never switches to block-buffered I/O.
	pty_file:write("import os, sys, select, subprocess\n")
	pty_file:write("master_fd, slave_fd = os.openpty()\n")
	pty_file:write("proc = subprocess.Popen(sys.argv[1:], stdin=slave_fd, stdout=slave_fd, stderr=slave_fd, close_fds=True)\n")
	pty_file:write("os.close(slave_fd)\n")
	pty_file:write("buf = b''\n")
	pty_file:write("while True:\n")
	pty_file:write("    try:\n")
	pty_file:write("        r, _, _ = select.select([master_fd], [], [], 0.05)\n")
	pty_file:write("    except (OSError, ValueError): break\n")
	pty_file:write("    if r:\n")
	pty_file:write("        try:\n")
	pty_file:write("            data = os.read(master_fd, 4096)\n")
	pty_file:write("        except OSError: break\n")
	pty_file:write("        if not data: break\n")
	pty_file:write("        sys.stdout.buffer.write(data)\n")
	pty_file:write("        sys.stdout.buffer.flush()\n")
	pty_file:write("    elif proc.poll() is not None: break\n")
	pty_file:write("proc.wait()\n")
	pty_file:write("os.close(master_fd)\n")
	pty_file:write("sys.exit(proc.returncode)\n")
	pty_file:close()
	os.execute("chmod +x " .. pty_wrapper_path)
	Logger.debug(LOG, "PTY wrapper created successfully at %s", pty_wrapper_path)

	-- Proactive UI fallback: if no marker has surfaced within
	-- PROACTIVE_UI_DELAY_SEC the user is staring at silence — show the
	-- download_window so they have visible feedback that work is happening.
	-- The streaming handler will keep refining the message as markers arrive.
	local proactive_timer
	proactive_timer = hs.timer.doAfter(PROACTIVE_UI_DELAY_SEC, function()
		if not llm_progress.is_active() then
			Logger.info(LOG, "Bootstrap silent for %.1fs — surfacing progress UI proactively.", PROACTIVE_UI_DELAY_SEC)
			pcall(llm_progress.show, {
				kind     = "mlx_install",
				title    = "Initialisation du moteur IA (MLX)",
				subtitle = "Préparation en cours…",
			})
			-- Seed the bar at a small visible value so the user sees movement
			-- immediately. The streaming handler will override per-marker.
			pcall(llm_progress.set_progress, 3)
		end
	end)

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
	local task
	-- Construct the full Python invocation: python3 executes the PTY wrapper,
	-- passing bash_cmd as the first argument so pty.spawn(sys.argv[1:]) receives ["/bin/bash", "-c", bash_cmd].
	-- The signature is: hs.task.new(launchPath, completionCallback, streamingCallback, arguments)
	task = hs.task.new("/usr/bin/python3", function(exit_code, stdout, stderr)
		-- Completion callback: fires when the process exits
		-- Cancel the proactive-show fallback as soon as the script finishes
		-- so a fast-path completion (~50 ms) never flashes the UI.
		if proactive_timer and type(proactive_timer.stop) == "function" then
			pcall(function() proactive_timer:stop() end)
		end
		local combined = (stdout or "") .. (stderr or "")
		-- Clean up the temporary PTY wrapper script
		os.execute("rm -f " .. pty_wrapper_path)

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
				-- Fast path can race with the proactive UI fallback (e.g. the
				-- import probe took just over the threshold). Hide the UI so a
				-- transient "Préparation en cours" stays out of the way once the
				-- bootstrap is actually done.
				pcall(llm_progress.hide)
			end
			fire_pending_callbacks(true)
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
					subtitle    = "Échec…",
				})
			end
			pcall(llm_progress.set_error, tail)
			fire_pending_callbacks(false)
		end
	end, make_streaming_handler(), { "-u", pty_wrapper_path, "/bin/bash", "-c", bash_cmd })

	if not task then
		Logger.error(LOG, "Failed to create hs.task for MLX bootstrap script.")
		_bootstrap_state = "failed"
		_last_failure_message = "Impossible de créer la tâche hs.task."
		os.execute("rm -f " .. pty_wrapper_path)
		return
	end
	Logger.debug(LOG, "hs.task created successfully")

	Logger.debug(LOG, "Starting hs.task…")
	if not pcall(function() task:start() end) then
		Logger.error(LOG, "Failed to start hs.task for MLX bootstrap script.")
		_bootstrap_state = "failed"
		_last_failure_message = "Impossible de démarrer la tâche hs.task."
		os.execute("rm -f " .. pty_wrapper_path)
		fire_pending_callbacks(false)
	else
		Logger.debug(LOG, "hs.task started successfully")
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
