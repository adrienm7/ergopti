--- modules/llm/api_mlx.lua

--- ==============================================================================
--- MODULE: LLM API Controller (Apple MLX)
--- DESCRIPTION:
--- Manages communication with the local MLX server via its OpenAI-compatible endpoint.
--- ==============================================================================

local M = {}

local Logger         = require("lib.logger")
local Notifications  = require("lib.notifications")
local i18n           = require("lib.i18n")
local Profiles       = require("modules.llm.profiles")
local ApiCommon      = require("modules.llm.api_common")
local ApiMlxInference = require("modules.llm.api_mlx_inference")  -- request mechanics (post_and_parse / streaming)
local ApiMlxFetch    = require("modules.llm.api_mlx_fetch")   -- dispatch strategies (batch/parallel/sequential)
local ApiMlxDiscovery = require("modules.llm.api_mlx_discovery")  -- endpoint-route discovery + route/identifier cache
local _warmup_client = require("adapters.http_client").new()  -- Dedicated client for warmup POSTs; isolated so discovery probes cannot cancel an in-flight warmup
local _check_client  = require("adapters.http_client").new()  -- Dedicated client for check_availability() GETs
local JsonCodec      = require("adapters.json_codec")
local TimerScheduler = require("adapters.timer_scheduler")
local ShellRunner    = require("adapters.shell_runner")
local Timings        = require("lib.timings")
local Paths          = require("lib.paths")
local LOG            = "llm.api_mlx"

-- MLX warmup timeout comes from the shared cross-driver registry ([llm]).
local WARMUP_POST_TIMEOUT_SEC    = Timings.sec("llm", "warmup_post_timeout_ms")    -- Unblock _warmup_in_flight if the single-token POST never returns

-- MLX server bind address — single source of truth in _shared/modules/llm/mlx_server.json
-- so the port is never hardcoded across api_mlx, the models_manager_mlx launcher,
-- and the init.lua boot cleanup. Loaded once at module load; every consumer reads
-- the resolved value via M.get_port() / M.get_host() / M.get_base_url(). The
-- launcher passes this exact port to `mlx_lm server --port`, so the server and all
-- clients always agree. Resolution order: (1) per-user override from the LLM menu
-- (hs.settings key MLX_PORT_SETTING_KEY), (2) the shared JSON default, (3) the
-- hardcoded MLX_DEFAULT_PORT fallback for stripped builds / headless tests where
-- neither hs.configdir nor the JSON is reachable. Declared this early so
-- kill_zombie_on_mlx_port and the endpoint constants below can both reference MLX_PORT.
local MLX_DEFAULT_HOST = "127.0.0.1"
-- Dedicated, uncommon default — NOT mlx_lm.server's own 8080 (too commonly taken by
-- other local dev/LLM servers). 3460 is a stylized "ERGO" (leetspeak: 3=E, 4=R,
-- 6=G, 0=O), in the registered range so the kernel never assigns it as an ephemeral
-- port. See mlx_server.json.
local MLX_DEFAULT_PORT = 3460

-- Exposed so other modules (e.g. init.lua's boot sweep) can reach the canonical
-- default without re-typing it or falling back to the forbidden 8080.
M.DEFAULT_PORT = MLX_DEFAULT_PORT

-- hs.settings key holding the user's port override (set from the LLM menu). Lets a
-- user whose chosen port collides with another local server move Ergopti's MLX
-- server without editing any file. A valid override wins over the shared JSON.
local MLX_PORT_SETTING_KEY = "ergopti.llm.mlx_port"

-- Acceptable port bounds — reject nonsense overrides (privileged ports below 1024
-- need root; anything above 65535 is not a valid TCP port).
local MLX_PORT_MIN = 1024
local MLX_PORT_MAX = 65535

--- Reads a valid user port override from hs.settings, or nil when none is set.
--- @return integer|nil
local function read_user_port_override()
	if type(hs) ~= "table" or type(hs.settings) ~= "table" then return nil end
	local ok, v = pcall(hs.settings.get, MLX_PORT_SETTING_KEY)
	if not ok then return nil end
	v = tonumber(v)
	if type(v) ~= "number" or v < MLX_PORT_MIN or v > MLX_PORT_MAX then return nil end
	return math.floor(v)
end

local function load_mlx_server_config()
	local host, port = MLX_DEFAULT_HOST, MLX_DEFAULT_PORT
	-- 1) Shared JSON default (the value shipped with the repo). Resolved through
	-- the single shared-tree resolver (Paths.shared), which performs the dual-root
	-- upward walk — robust to packaged .app builds and symlinked setups alike.
	local p = Paths.shared("modules/llm/mlx_server.json")
	if type(p) == "string" and p ~= "" then
		local fh = io.open(p, "r")
		if fh then
			local raw = fh:read("*a")
			fh:close()
			local ok, parsed = pcall(hs.json.decode, raw)
			if ok and type(parsed) == "table" then
				if type(parsed.host) == "string" and parsed.host ~= "" then host = parsed.host end
				if type(parsed.port) == "number" and parsed.port > 0 then port = math.floor(parsed.port) end
			end
		end
	end
	-- 2) Per-user menu override wins over the shared default.
	local override = read_user_port_override()
	if override then port = override end
	return host, port
end

local MLX_HOST, MLX_PORT = load_mlx_server_config()

-- Minimum interval between zombie-kill attempts during discovery. Without this
-- guard, every 1-second poll tick would fire a separate lsof+kill task, creating
-- a cascade of overlapping processes while the kernel is still processing the
-- first kill signal.
local ZOMBIE_KILL_MIN_INTERVAL_SEC = Timings.sec("llm", "zombie_kill_min_interval_ms")

local _last_zombie_kill_at  = 0    -- epoch time of the most-recent kill attempt
-- PGID of the newly-launched server process group. Set by models_manager_mlx as soon
-- as the bash script prints "[MLX] Server started with PID XXXX PGID YYYY". Every
-- process in this group (bash wrapper + Python mlx_lm child) shares this PGID and
-- must be excluded from zombie kills. Using PGID instead of PID is required because
-- SO_REUSEPORT means lsof -ti TCP:8080 only returns the bash wrapper PID (it holds
-- the FIFO), not the Python child that actually answers HTTP — yet both must survive.
local _active_server_pgid   = nil
-- Forward declaration: kill_zombie_on_mlx_port is defined below but called from
-- set_active_server_pgid, which is declared before it. Lua locals are only visible after
-- their declaration point; the forward reference here lets the upvalue resolve correctly.
local kill_zombie_on_mlx_port

-- True from the moment a new server launch begins (reset_endpoints called) until the
-- bash script reports "[MLX] Server started with PID X PGID Y" and set_active_server_pgid
-- is called. During this window the new Python process is already alive but its PGID is
-- unknown, so any unguarded kill -9 would massacre it. Block all zombie kills while pending.
local _server_pgid_pending  = false
-- Safety-timeout handle: if the Python server crashes before printing its PGID line,
-- set_active_server_pgid() is never called and _server_pgid_pending stays true forever,
-- permanently disabling kill_zombie_on_mlx_port. The timer clears the flag after 15 s.
local _pgid_pending_timeout = nil

-- Optional callback registered by models_manager_mlx so api_mlx can request a fresh
-- server launch when discovery detects a model-ID mismatch that the zombie killer
-- cannot resolve (e.g. cross-session leftover whose PGID was wrongly adopted as the
-- active guard). The hook receives the expected short model name and is responsible
-- for invoking start_server with the correct target.
local _restart_hook = nil

--- Registers a callback that api_mlx invokes when it cannot recover from a model-ID
--- mismatch on its own and needs the menu layer to relaunch the server.
--- @param fn function|nil Callback receiving the expected model name, or nil to clear.
function M.set_restart_hook(fn)
	_restart_hook = (type(fn) == "function") and fn or nil
	Logger.debug(LOG, "Restart hook %s.", _restart_hook and "registered" or "cleared")
end

--- Cooldown so we don't spam restart requests when the discovery loop fires repeatedly
--- before the new server has had time to come up. 10 s is enough for bash to do its
--- kill+lsof loop and for the new mlx_lm to start binding port 8080.
local RESTART_HOOK_MIN_INTERVAL_SEC = Timings.sec("llm", "restart_hook_min_interval_ms")
local _last_restart_hook_at = 0

-- Timestamp of the most recent set_active_server_pgid() call. Used by discover_endpoints
-- to grant a "fresh launch" grace window during which a mismatched /v1/models model ID
-- is tolerated: mlx_lm.server starts answering HTTP before the requested weights finish
-- loading, and during that window /v1/models can report a stale or placeholder ID even
-- though we passed the correct --model argv. Forcing a restart in this window creates
-- an infinite restart loop. Only trust the model-ID check once the launch is "old".
local _active_server_pgid_set_at = 0
local FRESH_LAUNCH_GRACE_SEC     = Timings.sec("llm", "fresh_launch_grace_ms")  -- 8B-class models can take up to ~60s to load weights

--- Records the PGID of the currently-launched server process group so zombie kills
--- can exclude the entire group. Called by models_manager_mlx immediately after the
--- bash script writes the "[MLX] Server started with PID XXXX PGID YYYY" line.
--- @param pgid number|nil The PGID to protect, or nil to clear the guard.
function M.set_active_server_pgid(pgid)
	_active_server_pgid  = tonumber(pgid) or nil
	_server_pgid_pending = false  -- PGID now known; zombie kills can safely use the guard
	_active_server_pgid_set_at = TimerScheduler.now()
	Logger.debug(LOG, "Active server PGID guard set to %s.", tostring(_active_server_pgid))
	-- Immediately fire a guarded kill now that we know which PGID to protect. Any
	-- zombie that was deferred during the pending window is still alive at this point;
	-- without this call it would survive until the next discovery mismatch (which may
	-- never arrive if the zombie answered first and discovery already resolved).
	-- Reset the cooldown so this first post-PGID kill is never skipped by the interval guard.
	_last_zombie_kill_at = 0
	kill_zombie_on_mlx_port()
end

--- Asynchronously kills all mlx_lm Python processes whose PGID differs from the
--- active server's PGID. Uses ps+awk filtered on COMM (executable basename) instead
--- of lsof because SO_REUSEPORT lets multiple processes share port 8080 and lsof only
--- sees one of them at any instant. Filtering on COMM (rather than a bare pgrep -f)
--- is critical: the bash wrapper's argv contains the literal script text including
--- "python -m mlx_lm", so a pgrep -f 'python.*mlx_lm' would also match the wrapper.
--- Restricting $2 ~ /^[Pp]ython/ guarantees only real python processes qualify.
kill_zombie_on_mlx_port = function()
	-- A new server was launched but its PGID is not yet known. Any unguarded kill
	-- would hit the new Python process (already alive, PGID unknown) and crash it
	-- before it can serve a single request. Block all zombie kills in this window;
	-- once set_active_server_pgid() fires, _server_pgid_pending becomes false and
	-- subsequent discovery mismatches will trigger guarded kills normally.
	if _server_pgid_pending then
		Logger.debug(LOG, "Zombie kill deferred — new server PGID not yet known.")
		return
	end
	local now = TimerScheduler.now()
	if now - _last_zombie_kill_at < ZOMBIE_KILL_MIN_INTERVAL_SEC then
		Logger.debug(LOG, "Zombie kill skipped — last attempt was %.1fs ago (min interval %.1fs).",
			now - _last_zombie_kill_at, ZOMBIE_KILL_MIN_INTERVAL_SEC)
		return
	end
	_last_zombie_kill_at = now
	Logger.warn(LOG, "Killing zombie mlx_lm Python process(es) via ps+awk (excluding PGID %s)…",
		tostring(_active_server_pgid or "none"))
	-- Target only real Python processes via COMM filter, never the bash wrapper.
	-- Earlier versions used `pgrep -f 'python.*mlx_lm'`, but the wrapper argv is
	-- '/bin/bash -c <SCRIPT>' and the script text literally contains 'python -m mlx_lm',
	-- so pgrep -f matched the wrapper too. The wrapper has a different PGID than the
	-- new Python child (set -m gives Python a fresh PGID), so the PGID guard let it
	-- through and kill -9 brought down the wrapper, closing the FIFO and forcing the
	-- Python child into SIGPIPE — the very crash this routine was supposed to prevent.
	if not _active_server_pgid then
		-- PGID was never set (server launched but exited before reporting its PGID,
		-- or reset_endpoints was called without a subsequent server start). Skip
		-- rather than killing blindly — a kill without a guard would hit whatever
		-- mlx_lm process happens to be running, including a legitimate server.
		Logger.warn(LOG, "Zombie kill skipped — no active PGID guard available.")
		return
	end
	local pgid_str = tostring(_active_server_pgid)
	-- Two complementary detection paths, unioned to catch zombies the awk filter
	-- alone would miss:
	--   1. ps+awk on COMM=python AND argv contains mlx_lm — catches well-formed
	--      mlx_lm.server processes regardless of port.
	--   2. lsof -ti TCP:8080 — catches anything listening on the port even if its
	--      argv was rewritten, truncated, or the COMM is not "python" (e.g., a
	--      relinked binary, or a child fork whose argv was replaced).
	-- For each candidate PID, compare its PGID against the active server's PGID;
	-- kill -9 only if PGID differs. This preserves the legitimate server.
	local cmd = "PIDS_AWK=$(ps -axo pid=,comm=,args= | awk '$2 ~ /^[Pp]ython/ && /mlx_lm/ {print $1}'); " ..
		"PIDS_PORT=$(lsof -ti TCP:" .. MLX_PORT .. " 2>/dev/null); " ..
		"PIDS=$(printf '%s\\n%s\\n' \"$PIDS_AWK\" \"$PIDS_PORT\" | sort -u | grep -v '^$'); " ..
		"[ -z \"$PIDS\" ] && echo 'none' && exit 0; " ..
		"ZOMBIES=$(echo \"$PIDS\" | while read P; do " ..
		"  PG=$(ps -o pgid= -p \"$P\" 2>/dev/null | tr -d ' '); " ..
		"  [ -n \"$PG\" ] && [ \"$PG\" != \"" .. pgid_str .. "\" ] && echo \"$P\"; " ..
		"done); " ..
		"[ -n \"$ZOMBIES\" ] && echo \"$ZOMBIES\" | xargs kill -9 2>/dev/null && echo \"killed: $ZOMBIES\" || echo 'none'"
	local kill_task = ShellRunner.spawn("/bin/bash", {"-c", cmd}, function(exit_code, stdout, _stderr)
		if exit_code == 0 then
			Logger.warn(LOG, "Zombie kill completed; stdout: %s", tostring(stdout):gsub("\n", " "))
		else
			Logger.debug(LOG, "Zombie kill exit %d.", exit_code)
		end
	end, nil)
	kill_task.start()
end

-- Shared streaming-task state. Mutated both here (cancel_streaming) and by the
-- request engine in api_mlx_inference.lua (which runs the curl -N task) — passed
-- to it by reference through ApiMlxInference.init(), so a single table is the one
-- source of truth for the in-flight stream. The streaming flag itself is owned by
-- modules/llm/init.lua and passed per-call.
--   task       — current in-flight hs.task; cancelled when a new stream starts.
--   timeout    — hard-timeout timer handle for the current stream task.
--   generation — monotonic counter; each new stream gets its own ID.
--   has_chunks — true once the current stream has received at least one SSE chunk.
local _stream = { task = nil, timeout = nil, generation = 0, has_chunks = false }

-- Readiness flag: true once warmup has confirmed the model is loaded and the server
-- can answer inference requests. perform_check gates on this so the loading tooltip
-- and stream dispatch do not happen before the backend is actually responsive
local _is_ready          = false
-- Guard against concurrent warmup requests: set_llm_enabled and set_llm_model both
-- schedule a warmup, the menu fires another after the requirements check, etc. Without
-- this flag the user's log showed 4 simultaneous warmup POSTs piling up against an
-- MLX server that can only process one request at a time, which is the very reason
-- the warmup never received a 200
local _warmup_in_flight  = false
local _warmup_gen        = 0     -- bumped on reset/load-failure; a warmup callback whose captured gen is stale must NOT flip _is_ready (F-L4)
local _warmup_timeout    = nil   -- hard-timeout timer; cleared on callback or cancellation
local _warmup_stopped    = false -- set by stop_warmup(); blocks the self-retry chain during pause/disable (M-3)

-- Permanent load-failure surface. Warmup retries on every non-200, which is correct
-- for a model that is merely SLOW to load — but a model that can NEVER load (an
-- architecture the installed mlx-lm does not understand, a corrupt download, a hung
-- generate thread) would otherwise retry forever, leaving the status dot stuck on
-- the orange "still loading…" colour with no error the user can see. Once we give up
-- (or the launcher's crash detector reports an incompatible architecture), _load_failed
-- flips true: the menu paints the dot RED and a one-time error notification fires, so a
-- broken model is always visible instead of an eternal orange spinner.
local _load_failed         = false  -- true once the current model is known to be unloadable
local _warmup_started_at   = nil    -- epoch of the first warmup attempt for the current model
local _warmup_fail_notified = false -- guards against firing the failure notification twice
-- Give-up budget: after this much CONTINUOUS warmup failure we stop retrying and surface
-- the error. Deliberately generous — far longer than any legitimate cold load (8B-class
-- weights map into GPU memory in ~60-90 s) so it only ever fires for a genuinely broken
-- model, never for one that is merely slow. The launcher's traceback detector
-- (models_manager_mlx) is the FAST path for the common arch-mismatch case; this is the
-- model-agnostic backstop for failures that print no recognizable traceback.
local WARMUP_GIVE_UP_SEC   = 120

-- The MLX server base URL — single source of truth in _shared/modules/llm/mlx_server.json.
-- Derived from MLX_HOST/MLX_PORT (loaded at the top of this file). Endpoint route
-- discovery and the cached working URLs now live in api_mlx_discovery; this URL is
-- handed to it via ApiMlxDiscovery.init() and refreshed on a port change.
local MLX_BASE_URL          = string.format("http://%s:%d", MLX_HOST, MLX_PORT)

-- The endpoint-discovery + route-cache subsystem owns the live route URLs and the
-- model identifiers a request payload must echo; it is a leaf (depends only on
-- adapters), so warmup, set_port, reset_endpoints, and the inference ctx all read
-- routes through its getters.
ApiMlxDiscovery.init({ base_url = MLX_BASE_URL })

-- M.is_thinking_model is injected by init.lua

--- Returns true when the backend has confirmed it can answer inference requests.
--- Flipped to true on the first successful warmup (HTTP 200), back to false on
--- subsequent failures so the tooltip layer can hide the loading spinner cleanly.
--- @return boolean
function M.is_ready()
	return _is_ready
end

--- Returns true once the current model has been given up on (warmup exhausted its
--- budget, or the launcher reported an incompatible architecture). The menu paints
--- the status dot RED while this holds, so a model that will never load is never
--- shown as an eternal orange "still loading" spinner. Cleared by reset_endpoints()
--- when a new server launch begins.
--- @return boolean
function M.is_load_failed()
	return _load_failed
end

--- Marks the current model as permanently unloadable: flips readiness to false, stops
--- the warmup retry loop, and — when notify is true — fires a single user-facing error
--- notification. Called both by the internal warmup give-up path and by the launcher's
--- crash detector (models_manager_mlx) so an architecture mismatch turns the dot red
--- immediately instead of waiting out the full give-up budget.
--- @param model_name string The model that failed (for the log/notification).
--- @param notify boolean When true, fire the one-time error notification from here.
function M.mark_load_failed(model_name, notify)
	_is_ready = false
	_warmup_gen = _warmup_gen + 1  -- invalidate any in-flight warmup callback (F-L4)
	if _warmup_timeout then
		-- Use TimerScheduler.cancel (not :stop()) — the handle is a {fired,id,timer}
		-- table with no :stop method; calling :stop() raises and the underlying timer
		-- keeps running, leaking an orphaned timer that fires and clobbers a future warmup.
		TimerScheduler.cancel(_warmup_timeout)
		_warmup_timeout = nil
	end
	_warmup_in_flight = false
	if not _load_failed then
		_load_failed = true
		Logger.error(LOG, "MLX model '%s' marked as failed to load — status dot will show red.",
			tostring(model_name))
	end
	if notify and not _warmup_fail_notified then
		_warmup_fail_notified = true
		-- Reuse the fully-translated "incompatible — choose another model" message:
		-- it is the correct, actionable advice for any model that never becomes ready,
		-- whether the cause is an unsupported architecture or a hung load.
		pcall(Notifications.notify, "MLX incompatible",
			string.format(i18n.get("mlx.model_incompatible"), tostring(model_name)), "error")
	end
end

--- Stops the api_mlx self-retry warmup chain (M-3).
--- Bumps the generation counter (invalidates any in-flight callback), cancels the
--- hard-timeout timer, and sets _warmup_stopped so any 2s retry that fires from
--- the TimerScheduler queue self-discards inside M.warmup().
--- Called from script_control.pause_all() alongside warmup_controller.stop().
function M.stop_warmup()
	_warmup_gen     = _warmup_gen + 1
	_warmup_stopped = true
	_warmup_in_flight = false
	if _warmup_timeout then
		TimerScheduler.cancel(_warmup_timeout)
		_warmup_timeout = nil
	end
	Logger.debug(LOG, "stop_warmup() — gen bumped to %d, self-retry chain stopped.", _warmup_gen)
end

--- Clears the _warmup_stopped flag so M.warmup() may proceed (M-3).
--- Called from script_control.resume_all() before re-arming warmup_controller.
function M.resume_warmup()
	_warmup_stopped = false
	Logger.debug(LOG, "resume_warmup() — self-retry chain re-enabled.")
end

--- @return integer The MLX server port (override > shared JSON > dedicated default 3460).
function M.get_port() return MLX_PORT end

--- @return string The MLX server host (loopback).
function M.get_host() return MLX_HOST end

--- @return string The MLX server base URL, e.g. "http://127.0.0.1:3460".
function M.get_base_url() return MLX_BASE_URL end

--- @return integer, integer The accepted port bounds [min, max] for the user override.
function M.get_port_bounds() return MLX_PORT_MIN, MLX_PORT_MAX end

--- @return integer The dedicated default port shipped with the repo (no override applied).
function M.get_default_port() return MLX_DEFAULT_PORT end

--- Changes the MLX server port at runtime and persists it as the per-user override.
--- Rebuilds the base URL and cached endpoint routes, and resets endpoint discovery so
--- the next warmup re-probes the server on the new port. The caller (LLM menu) is
--- responsible for relaunching the server on the new port — this only updates the
--- address api_mlx talks to; it does NOT move an already-running server.
--- @param port integer The new port; must be within [MLX_PORT_MIN, MLX_PORT_MAX].
--- @return boolean ok True when the port was accepted and applied.
function M.set_port(port)
	port = tonumber(port)
	if type(port) ~= "number" or port < MLX_PORT_MIN or port > MLX_PORT_MAX then
		Logger.error(LOG, "set_port: '%s' is out of range [%d, %d] — ignored.",
			tostring(port), MLX_PORT_MIN, MLX_PORT_MAX)
		return false
	end
	port = math.floor(port)
	if port == MLX_PORT then
		Logger.debug(LOG, "set_port: already on %d — no change.", port)
		return true
	end
	-- Persist so the new port survives a Hammerspoon reload. read_user_port_override()
	-- picks it up at the next module load; this in-memory update covers the live session.
	if type(hs) == "table" and type(hs.settings) == "table" then
		pcall(hs.settings.set, MLX_PORT_SETTING_KEY, port)
	end
	MLX_PORT             = port
	MLX_BASE_URL         = string.format("http://%s:%d", MLX_HOST, MLX_PORT)
	-- Push the new address into the discovery subsystem so its cached routes are
	-- rebuilt for the new port; the next warmup re-probes there.
	ApiMlxDiscovery.set_base_url(MLX_BASE_URL)
	Logger.info(LOG, "MLX server port set to %d (base URL %s).", MLX_PORT, MLX_BASE_URL)
	M.reset_endpoints()
	return true
end

--- Records the full HuggingFace repository path (e.g.
--- "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit") used to launch the server.
--- Called by models_manager_mlx immediately after reset_endpoints() so the
--- discovery bypass and warmup can fall back to this authoritative path when
--- /v1/models returns a stale model ID during weight loading.
--- @param hf_path string The full HF repo path passed to `mlx_lm server --model`.
function M.set_model_hf_path(hf_path)
	ApiMlxDiscovery.set_model_hf_path(hf_path)
end

--- Resets the endpoint discovery state so the next warmup re-probes the live
--- server. Called after an mlx-lm upgrade, because a new wheel may expose
--- different route paths than the previously cached ones.
function M.reset_endpoints()
	-- Discovery flags, pending callbacks, and the model identifiers live in the
	-- discovery subsystem; clear them there. Readiness + zombie-kill state below
	-- belong to this controller.
	ApiMlxDiscovery.reset()
	_is_ready                    = false
	-- Invalidate any in-flight warmup POST: its 200 response is for the OLD server/
	-- model and must NOT flip _is_ready=true after this reset switched servers (F-L4).
	-- Also clear the in-flight flag so a fresh warmup for the new model is not blocked.
	_warmup_gen                  = _warmup_gen + 1
	_warmup_in_flight            = false
	_active_server_pgid          = nil   -- cleared until the new server reports its PGID
	_server_pgid_pending         = true  -- block zombie kills until set_active_server_pgid() fires
	_last_zombie_kill_at         = 0     -- allow an immediate kill on the first mismatch after PGID is known
	-- Cancel any previous safety timeout so rapid successive resets don't stack.
	if _pgid_pending_timeout then
		pcall(TimerScheduler.cancel, _pgid_pending_timeout)
		_pgid_pending_timeout = nil
	end
	-- Safety-timeout: if the server crashes before emitting its PID line, this clears
	-- the pending flag so kill_zombie_on_mlx_port is not blocked for the whole session.
	_pgid_pending_timeout = TimerScheduler.after(15.0, function()
		if _server_pgid_pending then
			Logger.warn(LOG, "PGID pending timeout (15s) — unblocking zombie kills.")
			_server_pgid_pending  = false
			_pgid_pending_timeout = nil
		end
	end)
	-- A fresh launch deserves a fresh verdict: clear any previous load-failure so a
	-- newly selected (or relaunched) model is given the full warmup budget again.
	_load_failed                 = false
	_warmup_started_at           = nil
	_warmup_fail_notified        = false
	Logger.warn(LOG, "Endpoint discovery state reset.")
end

--- Supersedes the in-flight streaming task.
--- Always terminates the curl process to free the TCP connection to the MLX server,
--- which can only handle one request at a time. Keeping stale connections open blocks
--- subsequent requests and causes a deadlock where no prediction ever completes.
--- Called when a newer request supersedes the current one.
function M.cancel_streaming()
	if _stream.timeout then
		TimerScheduler.cancel(_stream.timeout)
		_stream.timeout = nil
	end
	-- Bump generation so all callbacks from the old stream become no-ops
	_stream.generation = _stream.generation + 1

	if _stream.task then
		-- Always terminate to free the MLX server connection; leaving prefill-phase
		-- curls running blocks the server from answering the next request
		_stream.task.terminate()
		local phase = _stream.has_chunks and "mid-flight" or "prefill"
		Logger.debug(LOG, "Active MLX stream terminated (%s).", phase)
		_stream.task    = nil
		_stream.has_chunks = false
	end
end

--- Sends a minimal 1-token inference to load model weights into GPU memory.
--- Primes the MLX server KV cache with the static portion of the active profile's
--- system prompt. MLX-LM caches computed KV states and reuses them when a subsequent
--- request shares the same token prefix, so this warmup eliminates the prefill cost
--- of the invariant tokens (up to ~350 tokens for the advanced profile) from the
--- first real request onward.
--- @param model_name string The MLX model identifier (logged only).
--- @param profile table|nil The active profile object; falls back to a minimal ping.
function M.warmup(model_name, profile)
	Logger.debug(LOG, "warmup() called — model='%s' _is_ready=%s _warmup_in_flight=%s _endpoints_discovered=%s.",
		tostring(model_name), tostring(_is_ready), tostring(_warmup_in_flight), tostring(ApiMlxDiscovery.is_discovered()))
	-- Skip if the backend already answered a previous warmup successfully — the
	-- model is loaded, no need to re-prime
	if _is_ready then
		Logger.debug(LOG, "MLX warmup skipped — backend already ready.")
		return
	end
	-- Stop dead once the model has been given up on — retrying a known-unloadable
	-- model would spin forever and the user has already been shown the error.
	if _load_failed then
		Logger.debug(LOG, "MLX warmup skipped — model '%s' already marked as failed to load.", tostring(model_name))
		return
	end
	-- Bail when the driver is paused or LLM has been disabled: stop_warmup() sets this
	-- flag so that any 2s retry still in the TimerScheduler queue self-discards here
	-- rather than firing a POST mid-pause or after set_llm_enabled(false) (M-3).
	if _warmup_stopped then
		Logger.debug(LOG, "MLX warmup skipped — warmup stopped (paused or LLM disabled).")
		return
	end
	-- Skip if a warmup is already in flight; otherwise the user's log shows 4
	-- simultaneous POST requests piling up against the single-threaded server
	if _warmup_in_flight then
		Logger.debug(LOG, "MLX warmup skipped — request already in flight.")
		return
	end

	-- Make sure we know which routes the live mlx-lm install exposes BEFORE we
	-- send the warmup itself. Without this, a route rename in a freshly
	-- installed mlx-lm wheel turns every warmup into a 404 with no recovery.
	-- NOTE: the give-up timer is stamped AFTER this short-circuit so that the
	-- discovery window (up to DISCOVERY_MAX_WAIT_SEC = 180s) does not eat into
	-- the warmup budget (WARMUP_GIVE_UP_SEC = 120s) — a large model that takes
	-- 120-180s to map into GPU would otherwise trigger a false failure.
	if not ApiMlxDiscovery.is_discovered() then
		Logger.debug(LOG, "warmup() — endpoints not yet discovered, triggering discovery…")
		-- Record the model we are waiting for so the discovery poll can reject a
		-- /v1/models 200 from the old server (still alive for ~2 s during model switch).
		ApiMlxDiscovery.set_expected_model_id(model_name)
		ApiMlxDiscovery.discover(function() M.warmup(model_name, profile) end)
		return
	end

	-- Track CONTINUOUS warmup duration across every retry/discovery re-entry, and give
	-- up once it exceeds the budget. This is the model-agnostic backstop that turns an
	-- eternal orange "still loading" dot into a red "failed" dot + notification when a
	-- model never becomes ready and prints no traceback the launcher could recognize.
	if not _warmup_started_at then _warmup_started_at = TimerScheduler.now() end
	local warmup_elapsed = TimerScheduler.now() - _warmup_started_at
	if warmup_elapsed >= WARMUP_GIVE_UP_SEC then
		Logger.error(LOG, "MLX warmup for '%s' gave up after %.0fs of failure — surfacing as load failure.",
			tostring(model_name), warmup_elapsed)
		M.mark_load_failed(model_name, true)
		return
	end

	Logger.info(LOG, "warmup() — sending warmup POST to '%s' for model '%s'…",
		ApiMlxDiscovery.get_completions_endpoint(), tostring(model_name))

	local Profiles  = require("modules.llm.profiles")
	local endpoint  = ApiMlxDiscovery.get_completions_endpoint()
	local payload
	-- Use the server's canonical model ID (fetched from /v1/models during discovery).
	-- Fall back to the HF path stored at server launch time (_model_hf_path) when
	-- _server_model_id was cleared because /v1/models returned a stale model ID
	-- (bypass scenario). This avoids the 404 validation error that would result from
	-- sending the wrong model name to mlx-lm 0.26+.
	-- Prefer the exact --model arg the bash launcher wrote to disk: when the
	-- server was started with a local snapshot path (the common offline case),
	-- the payload MUST echo that same path or model_provider.load() will
	-- attempt a fresh snapshot_download on the repo id and fail.
	local effective_model = ApiMlxDiscovery.read_active_model_arg() or ApiMlxDiscovery.get_server_model_id() or ApiMlxDiscovery.get_model_hf_path() or model_name

	-- Build the full prompt the server will actually see on real requests so that its
	-- KV cache entry for the static prefix is immediately useful.
	local sys = (type(profile) == "table")
		and Profiles.resolve_system_prompt(profile, 1)
		or  ""

	if type(sys) == "string" and sys ~= "" then
		-- Substitute template variables with minimal dummy values
		sys = sys:gsub("{context}", "Bonjour")
		         :gsub("{min_words}", "1")
		         :gsub("{max_words}", "5")
		         :gsub("{n}", "1")

		local is_advanced  = sys:find("TAIL_CORRECTED", 1, true) ~= nil
		local uses_pf_tail = sys:find("PREFIX") and sys:find("TAIL")

		if is_advanced or uses_pf_tail then
			-- Advanced / correction profiles use the chat endpoint with a separate
			-- user message — prime the full static system block (~350 tokens).
			local user_msg = uses_pf_tail and 'PREFIX: "Bonjour"\nTAIL: "Bonjour"' or "Bonjour"
			local merged   = sys .. "\n\n" .. user_msg
			endpoint = ApiMlxDiscovery.get_chat_endpoint()
			local enc, _ = JsonCodec.encode({
				model       = effective_model,
				messages    = { { role = "user", content = merged } },
				max_tokens  = 1,
				temperature = 0,
				stream      = false,
			})
			if enc then payload = enc end
		else
			-- Basic / raw profiles fold the context into the system prompt; only the
			-- static prefix before {context} is shared, so a completions ping suffices.
			local enc, _ = JsonCodec.encode({
				model       = effective_model,
				prompt      = sys,
				max_tokens  = 1,
				temperature = 0,
				stream      = false,
			})
			if enc then payload = enc end
		end
	end

	-- Fallback: if profile resolution failed, send a minimal ping to confirm the model
	-- is loaded without risking a crash.
	if not payload then
		local enc, enc_err = JsonCodec.encode({
			model       = effective_model,
			prompt      = " ",
			max_tokens  = 1,
			temperature = 0,
		})
		if not enc then
			Logger.error(LOG, "warmup: fallback encode failed — %s", tostring(enc_err))
			return
		end
		payload = enc
	end

	_warmup_in_flight = true
	-- Snapshot the warmup generation: if reset_endpoints()/mark_load_failed() bump it
	-- while this POST is in flight, the response is for a now-stale server/model and
	-- its callback must discard itself rather than flip _is_ready=true (F-L4).
	local my_warmup_gen = _warmup_gen
	-- Hard timeout: hs.http.asyncPost has no built-in timeout, so if the server
	-- accepts the TCP connection but never sends a response (e.g. during model
	-- weight loading or a stale GPU stream), _warmup_in_flight would stay true
	-- forever, silently blocking every subsequent warmup call.
	if _warmup_timeout then TimerScheduler.cancel(_warmup_timeout) end
	local _wt_handle = TimerScheduler.after(WARMUP_POST_TIMEOUT_SEC, function()
		_warmup_timeout = nil
		if not _warmup_in_flight then return end
		_warmup_in_flight = false
		-- Retire the generation before scheduling the retry. Abandoning a POST does
		-- not stop the server answering it, and without this bump that late reply
		-- still matched the generation check and flipped _is_ready — describing a
		-- request nobody was waiting for any more, on behalf of the retry that had
		-- meanwhile taken its place.
		_warmup_gen = _warmup_gen + 1
		Logger.warn(LOG, "Warmup POST timed out after %.0fs — unblocking and retrying in 2s (gen %d).",
			WARMUP_POST_TIMEOUT_SEC, _warmup_gen)
		TimerScheduler.after(2, function() M.warmup(model_name, profile) end)
	end)
	_warmup_timeout = _wt_handle
	_warmup_client.post(endpoint, { ["Content-Type"] = "application/json" }, payload,
		function(r)
			local status, body = r.status, r.body
			-- Cancel THIS request's timeout, not whichever one happens to be
			-- stored. After a timeout-triggered retry the slot holds the NEW
			-- POST's timer, so a late reply from the abandoned request disarmed
			-- the live request's only hard timeout — and warmup POSTs piled up
			-- with nothing left to bound them.
			if _warmup_timeout == _wt_handle then
				TimerScheduler.cancel(_wt_handle)
				_warmup_timeout = nil
			end
			-- Discard a stale warmup: a reset/load-failure since this POST was issued
			-- means its result describes the OLD server. Do NOT touch _is_ready (F-L4).
			if my_warmup_gen ~= _warmup_gen then
				Logger.debug(LOG, "Discarding stale warmup response (gen %d != %d).", my_warmup_gen, _warmup_gen)
				return
			end
			_warmup_in_flight = false
			-- A 200 with an empty or choices-less body means the server accepted the
			-- request but the generation thread crashed (e.g. mlx RuntimeError in the
			-- GPU stream during model hot-swap). Treat it as not-ready so the next
			-- warmup attempt actually re-probes rather than locking _is_ready = true
			-- against a broken server.
			local has_tokens = type(body) == "string" and body:find("choices", 1, true) ~= nil
			Logger.warn(LOG, "warmup POST response: status=%s has_tokens=%s body_len=%s.",
				tostring(status), tostring(has_tokens),
				tostring(type(body) == "string" and #body or "nil"))
			if status == 200 and has_tokens then
				local became_ready = (_is_ready ~= true)
				_is_ready = true
				-- A successful warmup clears the failure-tracking state so a later
				-- transient hiccup starts its give-up budget fresh rather than from
				-- this model's original launch time.
				_warmup_started_at    = nil
				_load_failed          = false
				_warmup_fail_notified = false
				Logger.warn(LOG, "MLX KV cache primed (profile: %s) — backend ready.",
					(type(profile) == "table" and profile.id) or "default")
				if became_ready then
					Notifications.notify(i18n.get("llm.server_ready_title"), i18n.get("llm.server_mlx_ready_body"), "success")
				end
			else
				_is_ready = false
				-- Reset discovery when the warmup itself returns 404 so the next
				-- retry re-probes the live routes instead of hitting the same dead
				-- endpoint indefinitely. Covers two cases: (a) model still loading
				-- in Thread-1 when discovery ran but the subsequent warmup POST
				-- came too late for the lazy-load cache, and (b) chat route absent
				-- in older mlx-lm while completions works — re-discovery picks up
				-- whichever endpoint actually answers.
				if status == 404 then
					ApiMlxDiscovery.mark_undiscovered()
				end
				Logger.warn(LOG, "MLX warmup returned %s (has_tokens=%s) — model not ready; retrying in 2s.",
					tostring(status), tostring(has_tokens))
				-- Retry automatically so the user does not have to manually trigger
				-- set_llm_enabled / set_llm_model after a slow model load or a
				-- generation-thread crash during the server hot-swap window.
				TimerScheduler.after(2, function()
					M.warmup(model_name, profile)
				end)
			end
		end
	)
end





-- =====================================
-- =====================================
-- ======= 1/ Check Availability =======
-- =====================================
-- =====================================

--- Asynchronously checks if the MLX server is reachable and loaded.
--- @param model_name string Name of the model (not strictly checked in MLX).
--- @param on_available function Callback if server answers.
--- @param on_missing function Callback if server fails to answer.
function M.check_availability(model_name, on_available, on_missing)
	Logger.debug(LOG, "Checking MLX server availability…")
	_check_client.get(MLX_BASE_URL .. "/v1/models", {}, function(r)
		if r.status == 200 then
			Logger.info(LOG, "MLX server is available.")
			if type(on_available) == "function" then ApiCommon.protected_call(on_available, "on_available") end
		else
			Logger.warn(LOG, "MLX server is missing or unreachable.")
			if type(on_missing) == "function" then ApiCommon.protected_call(on_missing, "on_missing", false) end
		end
	end)
end





--- =================================
--- =================================
--- ======= 2/ Request Wiring =======
--- =================================
--- =================================

-- The request mechanics (post_and_parse / streaming) live in api_mlx_inference.lua
-- and the dispatch strategies in api_mlx_fetch.lua — both state-free, fed by
-- injection from this controller, which owns the warmup / streaming state machine.
-- The request engine reads the live endpoint routes and the model identifiers from
-- the discovery subsystem (its getters are closures, so a later set_port /
-- discovery / cancel is always seen), plus the shared streaming-task table here;
-- the dispatch layer sits on top of it. The fetch_* functions below delegate into
-- it so the public controller surface stays on this module.
ApiMlxInference.init({
	completions_endpoint  = ApiMlxDiscovery.get_completions_endpoint,
	chat_endpoint         = ApiMlxDiscovery.get_chat_endpoint,
	server_model_id       = ApiMlxDiscovery.get_server_model_id,
	model_hf_path         = ApiMlxDiscovery.get_model_hf_path,
	read_active_model_arg = ApiMlxDiscovery.read_active_model_arg,
	stream                = _stream,
})

ApiMlxFetch.init({
	post_and_parse           = ApiMlxInference.post_and_parse,
	post_and_parse_streaming = ApiMlxInference.post_and_parse_streaming,
	dedup_enabled            = ApiMlxInference.DEDUPLICATION_ENABLED,
})

--- Dispatches a single request asking for N clustered predictions.
--- @see modules.llm.api_mlx_fetch M.fetch_batch for the full contract.
function M.fetch_batch(...)
	return ApiMlxFetch.fetch_batch(...)
end

--- Dispatches predictions with per-variant temperature spread (sequential under the hood).
--- @see modules.llm.api_mlx_fetch M.fetch_parallel for the full contract.
function M.fetch_parallel(...)
	return ApiMlxFetch.fetch_parallel(...)
end

--- Dispatches sequential requests to avoid parallel connection dropping.
--- @see modules.llm.api_mlx_fetch M.fetch_sequential for the full contract.
function M.fetch_sequential(...)
	return ApiMlxFetch.fetch_sequential(...)
end

return M
