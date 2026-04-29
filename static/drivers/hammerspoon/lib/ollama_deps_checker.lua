--- lib/ollama_deps_checker.lua

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
local llm_progress = require("ui.download_window")

local LOG = "ollama_deps"

local MARKER_INSTALLING = "OLLAMA_INSTALLING"
local MARKER_STARTING   = "OLLAMA_STARTING"
local MARKER_READY      = "OLLAMA_READY"

-- Step labels keyed by marker. The "READY" marker also doubles as a
-- success-final-step we render before auto-hiding.
local PROGRESS_LABELS = {
	[MARKER_INSTALLING] = "Installation d'Ollama…",
	[MARKER_STARTING]   = "Démarrage du serveur Ollama…",
	[MARKER_READY]      = "Serveur Ollama prêt.",
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
	local root = source:match("^(.*)/static/drivers/hammerspoon/lib/ollama_deps_checker%.lua$")
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
			pcall(llm_progress.set_detail, line)
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
						title    = "Initialisation du moteur IA (Ollama)",
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
	Logger.start(LOG, "Bootstrapping Ollama backend…")
	local project_root = resolve_project_root()
	if not project_root then
		Logger.error(LOG, "Project root introuvable depuis ollama_deps_checker.lua — bootstrap aborted.")
		_bootstrap_state = "failed"
		_last_failure_message = "Project root introuvable."
		return
	end

	local script_path = project_root .. "/static/drivers/hammerspoon/modules/llm/ensure-ollama-deps.sh"
	if not hs.fs.attributes(script_path, "mode") then
		Logger.error(LOG, "Script ensure-ollama-deps.sh introuvable à %s — bootstrap aborted.", script_path)
		_bootstrap_state = "failed"
		_last_failure_message = "Script ensure-ollama-deps.sh introuvable."
		return
	end

	local task
	task = hs.task.new("/bin/bash", function(exit_code, stdout, stderr)
		local combined = (stdout or "") .. (stderr or "")
		forward_chunk(stdout or "")
		forward_chunk(stderr or "")

		if exit_code == 0 then
			_bootstrap_state = "ready"
			_last_failure_message = nil
			Logger.success(LOG, "Ollama backend ready.")
			-- Only auto-hide if the UI was actually shown (slow path).
			if llm_progress.is_active() then
				pcall(llm_progress.set_step, "Serveur Ollama prêt.")
				pcall(llm_progress.set_progress, 100)
				hs.timer.doAfter(SUCCESS_AUTO_HIDE_SEC, function()
					pcall(llm_progress.hide)
				end)
			end
		else
			_bootstrap_state = "failed"
			local tail = tail_for_error(combined)
			if tail == "" then tail = "Cause inconnue. Consultez /tmp/ergopti.log." end
			_last_failure_message = tail
			Logger.error(LOG, "Ollama bootstrap failed (exit=%d) — %s",
				tonumber(exit_code) or -1, tail:gsub("\n", " | "))
			if not llm_progress.is_active() then
				pcall(llm_progress.show, {
					kind     = "ollama_install",
					title    = "Initialisation du moteur IA (Ollama)",
					subtitle = "Échec…",
				})
			end
			pcall(llm_progress.set_error, tail)
		end
	end, { script_path })

	if not task then
		Logger.error(LOG, "Failed to create hs.task for Ollama bootstrap script.")
		_bootstrap_state = "failed"
		_last_failure_message = "Impossible de créer la tâche hs.task."
		return
	end

	pcall(function() task:setStreamingCallback(make_streaming_handler()) end)

	if not pcall(function() task:start() end) then
		Logger.error(LOG, "Failed to start hs.task for Ollama bootstrap script.")
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

--- @return boolean True only when the Ollama server answers and the binary is on PATH.
function M.is_ready() return _bootstrap_state == "ready" end

--- @return boolean True while the bootstrap is still running.
function M.is_pending() return _bootstrap_state == "pending" end

--- @return boolean True when the bootstrap definitively failed.
function M.has_failed() return _bootstrap_state == "failed" end

--- @return string|nil Last failure message captured from the bash script.
function M.get_failure_message() return _last_failure_message end

return M
