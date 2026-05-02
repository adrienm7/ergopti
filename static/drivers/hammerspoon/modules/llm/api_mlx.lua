--- modules/llm/api_mlx.lua

--- ==============================================================================
--- MODULE: LLM API Controller (Apple MLX)
--- DESCRIPTION:
--- Manages communication with the local MLX server via its OpenAI-compatible endpoint.
--- ==============================================================================

local M = {}

local hs       = hs
local Logger   = require("lib.logger")
local Parser   = require("modules.llm.parser")
local Profiles = require("modules.llm.profiles")
local ApiCommon = require("modules.llm.api_common")
local LOG      = "llm.api_mlx"

local ok_kl, keylogger = pcall(require, "modules.keylogger")
if not ok_kl then keylogger = nil end

local _req_counter = 0
local DEDUPLICATION_ENABLED = false
local RETRY_FAILED_PREDICTION_ENABLED = true
local RETRY_FAILED_PREDICTION_MAX_MULTIPLIER = 2
local STREAM_CONNECT_TIMEOUT_SEC = 5    -- Fail fast if the MLX server does not accept the TCP connection
local STREAM_HARD_TIMEOUT_SEC    = 90   -- Kill the task if the server accepts but never sends a token; large models need up to 60 s to load weights
local WARMUP_POST_TIMEOUT_SEC    = 30   -- Unblock _warmup_in_flight if the single-token POST never returns

-- Minimum interval between zombie-kill attempts during discovery. Without this
-- guard, every 1-second poll tick would fire a separate lsof+kill task, creating
-- a cascade of overlapping processes while the kernel is still processing the
-- first kill signal.
local ZOMBIE_KILL_MIN_INTERVAL_SEC = 3.0

local _last_zombie_kill_at  = 0    -- epoch time of the most-recent kill attempt
-- PGID of the newly-launched server process group. Set by models_manager_mlx as soon
-- as the bash script prints "[MLX] Server started with PID XXXX PGID YYYY". Every
-- process in this group (bash wrapper + Python mlx_lm child) shares this PGID and
-- must be excluded from zombie kills. Using PGID instead of PID is required because
-- SO_REUSEPORT means lsof -ti TCP:8080 only returns the bash wrapper PID (it holds
-- the FIFO), not the Python child that actually answers HTTP — yet both must survive.
local _active_server_pgid   = nil
-- Forward declaration: kill_zombie_on_port_8080 is defined below but called from
-- set_active_server_pgid, which is declared before it. Lua locals are only visible after
-- their declaration point; the forward reference here lets the upvalue resolve correctly.
local kill_zombie_on_port_8080

-- True from the moment a new server launch begins (reset_endpoints called) until the
-- bash script reports "[MLX] Server started with PID X PGID Y" and set_active_server_pgid
-- is called. During this window the new Python process is already alive but its PGID is
-- unknown, so any unguarded kill -9 would massacre it. Block all zombie kills while pending.
local _server_pgid_pending  = false

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
local RESTART_HOOK_MIN_INTERVAL_SEC = 10.0
local _last_restart_hook_at = 0

-- Timestamp of the most recent set_active_server_pgid() call. Used by discover_endpoints
-- to grant a "fresh launch" grace window during which a mismatched /v1/models model ID
-- is tolerated: mlx_lm.server starts answering HTTP before the requested weights finish
-- loading, and during that window /v1/models can report a stale or placeholder ID even
-- though we passed the correct --model argv. Forcing a restart in this window creates
-- an infinite restart loop. Only trust the model-ID check once the launch is "old".
local _active_server_pgid_set_at = 0
local FRESH_LAUNCH_GRACE_SEC     = 90  -- 8B-class models can take up to ~60s to load weights

--- Records the PGID of the currently-launched server process group so zombie kills
--- can exclude the entire group. Called by models_manager_mlx immediately after the
--- bash script writes the "[MLX] Server started with PID XXXX PGID YYYY" line.
--- @param pgid number|nil The PGID to protect, or nil to clear the guard.
function M.set_active_server_pgid(pgid)
	_active_server_pgid  = tonumber(pgid) or nil
	_server_pgid_pending = false  -- PGID now known; zombie kills can safely use the guard
	_active_server_pgid_set_at = hs.timer.secondsSinceEpoch()
	Logger.debug(LOG, "Active server PGID guard set to %s.", tostring(_active_server_pgid))
	-- Immediately fire a guarded kill now that we know which PGID to protect. Any
	-- zombie that was deferred during the pending window is still alive at this point;
	-- without this call it would survive until the next discovery mismatch (which may
	-- never arrive if the zombie answered first and discovery already resolved).
	-- Reset the cooldown so this first post-PGID kill is never skipped by the interval guard.
	_last_zombie_kill_at = 0
	kill_zombie_on_port_8080()
end

--- Asynchronously kills all mlx_lm Python processes whose PGID differs from the
--- active server's PGID. Uses ps+awk filtered on COMM (executable basename) instead
--- of lsof because SO_REUSEPORT lets multiple processes share port 8080 and lsof only
--- sees one of them at any instant. Filtering on COMM (rather than a bare pgrep -f)
--- is critical: the bash wrapper's argv contains the literal script text including
--- "python -m mlx_lm", so a pgrep -f 'python.*mlx_lm' would also match the wrapper.
--- Restricting $2 ~ /^[Pp]ython/ guarantees only real python processes qualify.
kill_zombie_on_port_8080 = function()
	-- A new server was launched but its PGID is not yet known. Any unguarded kill
	-- would hit the new Python process (already alive, PGID unknown) and crash it
	-- before it can serve a single request. Block all zombie kills in this window;
	-- once set_active_server_pgid() fires, _server_pgid_pending becomes false and
	-- subsequent discovery mismatches will trigger guarded kills normally.
	if _server_pgid_pending then
		Logger.debug(LOG, "Zombie kill deferred — new server PGID not yet known.")
		return
	end
	local now = hs.timer.secondsSinceEpoch()
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
		"PIDS_PORT=$(lsof -ti TCP:8080 2>/dev/null); " ..
		"PIDS=$(printf '%s\\n%s\\n' \"$PIDS_AWK\" \"$PIDS_PORT\" | sort -u | grep -v '^$'); " ..
		"[ -z \"$PIDS\" ] && echo 'none' && exit 0; " ..
		"ZOMBIES=$(echo \"$PIDS\" | while read P; do " ..
		"  PG=$(ps -o pgid= -p \"$P\" 2>/dev/null | tr -d ' '); " ..
		"  [ -n \"$PG\" ] && [ \"$PG\" != \"" .. pgid_str .. "\" ] && echo \"$P\"; " ..
		"done); " ..
		"[ -n \"$ZOMBIES\" ] && echo \"$ZOMBIES\" | xargs kill -9 2>/dev/null && echo \"killed: $ZOMBIES\" || echo 'none'"
	local kill_task = hs.task.new("/bin/bash", function(exit_code, stdout, _stderr)
		if exit_code == 0 then
			Logger.warn(LOG, "Zombie kill completed; stdout: %s", tostring(stdout):gsub("\n", " "))
		else
			Logger.debug(LOG, "Zombie kill exit %d.", exit_code)
		end
	end, {"-c", cmd})
	pcall(function() kill_task:start() end)
end

-- Holds the current in-flight hs.task; cancelled when a new streaming request starts.
-- The streaming flag itself is owned by modules/llm/init.lua and passed per-call.
local _active_stream_task       = nil
local _active_stream_timeout    = nil  -- Hard-timeout timer for the current stream task
local _stream_generation        = 0    -- Monotonic counter; each new stream gets its own ID
local _active_stream_has_chunks = false  -- True once the current stream has received at least one SSE chunk

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
local _warmup_timeout    = nil   -- hard-timeout timer; cleared on callback or cancellation

-- Discovered endpoint paths. Different mlx-lm releases have shipped completions
-- and chat-completions under different routes (with/without the `/v1/` prefix);
-- a silent route rename in a freshly-pulled wheel turns every request into a
-- 404 with no obvious cause. Rather than hard-coding one set of paths, we probe
-- the live server once per process to discover what it actually exposes, cache
-- the working URLs here, and let everything else resolve through these vars.
-- Initial values are the OpenAI-standard paths used by the long-stable
-- mlx-lm 0.18→0.21 series; discover_endpoints overrides them at runtime
-- whenever a probe finds a different working route.
local MLX_BASE_URL          = "http://127.0.0.1:8080"
local _completions_endpoint = MLX_BASE_URL .. "/v1/completions"
local _chat_endpoint        = MLX_BASE_URL .. "/v1/chat/completions"
local _endpoints_discovered = false
local _endpoint_probe_in_flight = false
-- Callbacks waiting for the current discovery probe to complete; each
-- discover_endpoints() call during a probe enqueues its on_done here so no
-- caller is silently dropped when a second warmup fires mid-poll.
local _discovery_pending_callbacks = {}
-- Canonical model ID reported by the server via GET /v1/models.
-- mlx-lm 0.26+ validates the model field in request payloads against the ID
-- of the loaded model (typically the full HF path, e.g.
-- "mlx-community/Qwen3.5-2B-4bit") and returns 404 when the short local name
-- is sent instead. We read this once during discovery Phase 1 and substitute
-- it everywhere we build a request payload.
local _server_model_id = nil
-- Short model name we are waiting for (set by warmup() before triggering
-- discovery). The discovery poll rejects a /v1/models 200 whose reported
-- model ID does not contain this string, preventing a stale old server
-- (alive for 2 s after kill -9, during the bash sleep) from satisfying the
-- probe intended for the newly launched server.
local _expected_model_id = nil
-- Full HuggingFace repository path used to launch the current server (e.g.
-- "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit"). Set by models_manager_mlx
-- immediately after reset_endpoints() so warmup and inference payloads always
-- have a reliable model identifier even when /v1/models reports a stale ID
-- during weight loading (bypass scenario).
local _model_hf_path = nil

-- Reads the runtime model identifier the bash launcher passed to mlx_lm via
-- --model. mlx_lm.server routes every POST request through model_provider.load(),
-- keyed by the payload's "model" field; if the payload sends the HF repo id
-- but the server was launched with a local snapshot path (or vice-versa),
-- the server tries to snapshot_download that mismatched id and fails offline.
-- The bash launcher writes the exact --model argument it used to this file so
-- payloads can mirror it byte-for-byte and hit the cached model.
local ACTIVE_MODEL_FILE = "/tmp/mlx_active_model.txt"
local function read_active_model_arg()
	local fh = io.open(ACTIVE_MODEL_FILE, "r")
	if not fh then return nil end
	local raw = fh:read("*a")
	fh:close()
	if type(raw) ~= "string" then return nil end
	local trimmed = raw:gsub("^%s+", ""):gsub("%s+$", "")
	return trimmed ~= "" and trimmed or nil
end

-- Candidate paths tried in order. The first probe whose POST returns ANYTHING
-- other than 404 is treated as the live endpoint — 200 is a success, 400 and
-- 422 are validation errors that still prove the route is registered (so a
-- tiny "ping" payload is enough). We do NOT accept -1 as a hit: -1 from
-- hs.http means connection refused / timeout, i.e. the server is not yet
-- listening — that proves nothing about the route and forces us to retry.
local COMPLETIONS_CANDIDATES = {
	"/v1/completions",
	"/completions",
}
local CHAT_CANDIDATES = {
	"/v1/chat/completions",
	"/chat/completions",
}

local DISCOVERY_MAX_WAIT_SEC        = 60   -- Stop polling /v1/models after this much real time
local DISCOVERY_POLL_PERIOD_SEC     = 1.0  -- Wait between /v1/models probes during the wait phase
-- After this many seconds of persistent model-ID mismatch, bypass the check and
-- proceed to POST probes. A mismatch beyond this window means either (a) the old
-- server's socket lingered in CLOSE_WAIT and the zombie killer couldn't find the
-- process, or (b) the new server itself reports a stale model ID while loading
-- its weights from GPU cache. In both cases waiting longer achieves nothing.
local DISCOVERY_MODEL_ID_BYPASS_SEC = 20

--- Probes the MLX server to discover which endpoint paths are valid in this
--- mlx-lm install. Two phases:
---   1. Wait for /v1/models to return 200 (proof the server is actually
---      listening). A repeating hs.timer drives the poll so it is immune to
---      lost asyncGet callbacks — when the old server is killed mid-request the
---      callback may never fire, which used to leave _endpoint_probe_in_flight
---      stuck at true forever. The timer fires regardless of pending callbacks.
---   2. POST a minimal payload to each candidate, accepting any HTTP status
---      other than 404 / -1 as a live route.
--- Idempotent: the timer runs only once; subsequent calls enqueue their
--- on_done callback and return.
--- @param on_done function|nil Optional callback invoked once the probe finishes.
local function discover_endpoints(on_done)
	if _endpoints_discovered then
		if type(on_done) == "function" then pcall(on_done) end
		return
	end
	-- Enqueue the callback so it fires when the in-flight probe completes —
	-- previously we returned silently here, dropping the caller's on_done and
	-- causing every warmup issued during the server boot window to be lost.
	if type(on_done) == "function" then
		_discovery_pending_callbacks[#_discovery_pending_callbacks + 1] = on_done
	end
	if _endpoint_probe_in_flight then return end
	_endpoint_probe_in_flight = true

	local probe_completions = hs.json.encode({ prompt = " ", max_tokens = 1 })
	local probe_chat        = hs.json.encode({
		messages   = { { role = "user", content = " " } },
		max_tokens = 1,
	})
	local headers    = { ["Content-Type"] = "application/json" }
	local started_at = hs.timer.secondsSinceEpoch()

	local function finish_discovery(success)
		-- Stop the poll timer before firing callbacks so a callback that calls
		-- reset_endpoints() + discover_endpoints() again does not find the timer
		-- still running and incorrectly skip starting a fresh one.
		_endpoint_probe_in_flight = false
		if success then
			_endpoints_discovered = true
			Logger.warn(LOG, "MLX endpoints resolved: completions=%s, chat=%s.",
				_completions_endpoint, _chat_endpoint)
		end
		-- Fire only the most-recent callback — it reflects the currently
		-- active model. Earlier callbacks are stale (issued before a model
		-- switch) and would trigger warmup POSTs for the wrong model, which
		-- causes an avalanche of discovery + warmup cycles on the new server.
		local cbs = _discovery_pending_callbacks
		_discovery_pending_callbacks = {}
		if #cbs > 0 then pcall(cbs[#cbs]) end
	end

	local function run_post_probes()
		-- payloads indexed by kind so each probe uses the correct API format;
		-- using the wrong format on some mlx-lm versions returns 404 (not 422)
		local probe_by_kind = { completions = probe_completions, chat = probe_chat }

		local function probe_one(candidates, idx, found_so_far, kind, on_resolved)
			if idx > #candidates then
				pcall(on_resolved, found_so_far)
				return
			end
			local path = candidates[idx]
			local payload = probe_by_kind[kind] or probe_completions
			hs.http.asyncPost(MLX_BASE_URL .. path, payload, headers, function(status, _)
				if status and status ~= 404 and status ~= -1 then
					Logger.info(LOG, "Endpoint discovery (%s): %s -> HTTP %s — accepted as live route.",
						kind, path, tostring(status))
					pcall(on_resolved, MLX_BASE_URL .. path)
				else
					Logger.debug(LOG, "Endpoint discovery (%s): %s -> %s, trying next candidate.",
						kind, path, tostring(status))
					probe_one(candidates, idx + 1, found_so_far, kind, on_resolved)
				end
			end)
		end

		probe_one(COMPLETIONS_CANDIDATES, 1, nil, "completions", function(found)
			if found then _completions_endpoint = found end
			if found then
				-- Completions route confirmed — resolve immediately. Do NOT wait for
				-- the chat probe: after a server-side RuntimeError (e.g. mlx-lm batch
				-- crash), subsequent POST requests may block indefinitely, leaving
				-- _endpoint_probe_in_flight=true forever and silently starving all
				-- future warmup attempts. Probing chat opportunistically in the
				-- background means its URL gets cached when it eventually responds,
				-- without blocking the critical path.
				finish_discovery(true)
				probe_one(CHAT_CANDIDATES, 1, nil, "chat", function(found_chat)
					-- Only update the cached URL — never call finish_discovery here.
					-- By the time this fires, reset_endpoints() may have run for a new
					-- model; calling finish_discovery would corrupt the new server's state.
					if found_chat then _chat_endpoint = found_chat end
				end)
				return
			end
			-- Completions route not found — fall through to chat so the user still
			-- gets predictions on mlx-lm builds that only expose the chat route.
			probe_one(CHAT_CANDIDATES, 1, nil, "chat", function(found_chat)
				if found_chat then _chat_endpoint = found_chat end
				if not found_chat then
					-- All routes returned 404. The model is likely still loading in
					-- Thread-1 (mlx-lm lazy-loads on first inference request and returns
					-- 404 on inference routes until the load completes). Do NOT mark
					-- discovery done — clear the in-flight flag so the repeating timer
					-- triggers a fresh attempt on the next warmup.
					Logger.warn(LOG,
						"MLX endpoint discovery: all candidates returned 404 — " ..
						"model may still be loading. Will retry on next warmup.")
					finish_discovery(false)
				else
					finish_discovery(true)
				end
			end)
		end)
	end

	-- Phase 1: use a repeating hs.timer to poll /v1/models so the loop
	-- survives dropped asyncGet callbacks (which happen when the old server
	-- process is killed mid-request — the connection resets and Hammerspoon
	-- never fires the callback, leaving a recursive doAfter chain dead).
	local poll_timer = nil
	local function do_poll()
		-- Guard: if discovery was reset externally (model switch) while the
		-- timer was in flight, stop quietly without firing callbacks.
		if not _endpoint_probe_in_flight then
			if poll_timer then pcall(function() poll_timer:stop() end) end
			poll_timer = nil
			return
		end
		local elapsed = hs.timer.secondsSinceEpoch() - started_at
		if elapsed >= DISCOVERY_MAX_WAIT_SEC then
			if poll_timer then pcall(function() poll_timer:stop() end) end
			poll_timer = nil
			Logger.warn(LOG,
				"Endpoint discovery: gave up waiting for MLX server after %.1fs. " ..
				"Falling back to default routes; warmup will keep retrying.", elapsed)
			finish_discovery(false)
			return
		end
		Logger.warn(LOG, "Endpoint discovery: polling /v1/models (elapsed=%.1fs)…", elapsed)
		-- Use curl instead of hs.http.asyncGet so we can pass --no-keepalive.
		-- Hammerspoon's HTTP client pools TCP connections and will reuse a keep-alive
		-- socket to a zombie server (whose process was kill -9'd but whose socket
		-- lingers in CLOSE_WAIT), making the poll see the zombie's stale model ID
		-- indefinitely. curl --no-keepalive forces a fresh TCP handshake every call,
		-- so the moment the zombie's socket closes the next poll reaches the new server.
		local curl_task = hs.task.new("/usr/bin/curl", function(exit_code, stdout, _stderr)
			if poll_timer then pcall(function() poll_timer:stop() end) end
			poll_timer = nil
			local status = (exit_code == 0) and 200 or -1
			local body   = stdout or ""
			Logger.warn(LOG, "Endpoint discovery: /v1/models -> HTTP %s.", tostring(status))
			if not _endpoint_probe_in_flight then return end  -- reset externally
			if status == 200 then
				-- mlx_lm.server's /v1/models endpoint returns the LIST of models
				-- discoverable in the local HF cache, NOT the currently loaded
				-- model. data[] can have 30+ entries and their order is dictated
				-- by cache ordering, not load state. Earlier code read data[1].id
				-- as if it were the loaded model and then tried to "fix" mismatches
				-- via zombie kills and forced restarts — all chasing a phantom.
				-- The right semantic: a 200 here means the server is reachable.
				-- The model we passed to --model in bash is the one that actually
				-- gets loaded; trust that and proceed straight to POST probes.
				-- For the warmup payload's "model" field, prefer _model_hf_path
				-- (the canonical --model arg) over anything from /v1/models.
				_server_model_id = nil
				if type(body) == "string" and type(_expected_model_id) == "string"
					and _expected_model_id ~= "" then
					-- Informational: confirm the expected model is at least
					-- visible in the cache list. If it is not, the user likely
					-- has a misconfigured preset; log a warning but do not block.
					local needle = _expected_model_id:lower()
					if not body:lower():find(needle, 1, true) then
						Logger.warn(LOG,
							"Endpoint discovery: expected model '%s' not visible in /v1/models cache list — POST may 404 if mlx_lm cannot resolve it.",
							_expected_model_id)
					end
				end
				if not _endpoint_probe_in_flight then return end
				Logger.warn(LOG, "Endpoint discovery: server reachable on /v1/models — starting POST probes.")
				run_post_probes()
			else
				-- Server not ready yet — restart the timer for the next poll tick
				poll_timer = hs.timer.doAfter(DISCOVERY_POLL_PERIOD_SEC, do_poll)
			end
		end, {
			"--silent", "--max-time", "5", "--no-keepalive",
			"-H", "Connection: close",
			MLX_BASE_URL .. "/v1/models",
		})
		pcall(function() curl_task:start() end)
	end

	poll_timer = hs.timer.doAfter(0, do_poll)
end

-- M.is_thinking_model is injected by init.lua

--- Returns true when the backend has confirmed it can answer inference requests.
--- Flipped to true on the first successful warmup (HTTP 200), back to false on
--- subsequent failures so the tooltip layer can hide the loading spinner cleanly.
--- @return boolean
function M.is_ready()
	return _is_ready
end

--- Records the full HuggingFace repository path (e.g.
--- "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit") used to launch the server.
--- Called by models_manager_mlx immediately after reset_endpoints() so the
--- discovery bypass and warmup can fall back to this authoritative path when
--- /v1/models returns a stale model ID during weight loading.
--- @param hf_path string The full HF repo path passed to `mlx_lm server --model`.
function M.set_model_hf_path(hf_path)
	_model_hf_path = type(hf_path) == "string" and hf_path or nil
	Logger.debug(LOG, "Model HF path set to '%s'.", tostring(_model_hf_path))
end

--- Resets the endpoint discovery state so the next warmup re-probes the live
--- server. Called after an mlx-lm upgrade, because a new wheel may expose
--- different route paths than the previously cached ones.
function M.reset_endpoints()
	_endpoints_discovered        = false
	_endpoint_probe_in_flight    = false
	_discovery_pending_callbacks = {}
	_is_ready                    = false
	_server_model_id             = nil
	_expected_model_id           = nil
	_model_hf_path               = nil
	_active_server_pgid          = nil   -- cleared until the new server reports its PGID
	_server_pgid_pending         = true  -- block zombie kills until set_active_server_pgid() fires
	_last_zombie_kill_at         = 0     -- allow an immediate kill on the first mismatch after PGID is known
	Logger.warn(LOG, "Endpoint discovery state reset.")
end

--- Supersedes the in-flight streaming task.
--- Always terminates the curl process to free the TCP connection to the MLX server,
--- which can only handle one request at a time. Keeping stale connections open blocks
--- subsequent requests and causes a deadlock where no prediction ever completes.
--- Called when a newer request supersedes the current one.
function M.cancel_streaming()
	if _active_stream_timeout then
		pcall(function() _active_stream_timeout:stop() end)
		_active_stream_timeout = nil
	end
	-- Bump generation so all callbacks from the old stream become no-ops
	_stream_generation = _stream_generation + 1

	if _active_stream_task then
		-- Always terminate to free the MLX server connection; leaving prefill-phase
		-- curls running blocks the server from answering the next request
		pcall(function() _active_stream_task:terminate() end)
		local phase = _active_stream_has_chunks and "mid-flight" or "prefill"
		Logger.debug(LOG, "Active MLX stream terminated (%s).", phase)
		_active_stream_task    = nil
		_active_stream_has_chunks = false
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
	-- Log at warn so the line appears in logs regardless of configured log level
	Logger.warn(LOG, "warmup() called — model='%s' _is_ready=%s _warmup_in_flight=%s _endpoints_discovered=%s.",
		tostring(model_name), tostring(_is_ready), tostring(_warmup_in_flight), tostring(_endpoints_discovered))
	-- Skip if the backend already answered a previous warmup successfully — the
	-- model is loaded, no need to re-prime
	if _is_ready then
		Logger.warn(LOG, "MLX warmup skipped — backend already ready.")
		return
	end
	-- Skip if a warmup is already in flight; otherwise the user's log shows 4
	-- simultaneous POST requests piling up against the single-threaded server
	if _warmup_in_flight then
		Logger.warn(LOG, "MLX warmup skipped — request already in flight.")
		return
	end

	-- Make sure we know which routes the live mlx-lm install exposes BEFORE we
	-- send the warmup itself. Without this, a route rename in a freshly
	-- installed mlx-lm wheel turns every warmup into a 404 with no recovery.
	if not _endpoints_discovered then
		Logger.warn(LOG, "warmup() — endpoints not yet discovered, triggering discovery…")
		-- Record the model we are waiting for so the discovery poll can reject a
		-- /v1/models 200 from the old server (still alive for ~2 s during model switch).
		_expected_model_id = model_name
		discover_endpoints(function() M.warmup(model_name, profile) end)
		return
	end

	Logger.warn(LOG, "warmup() — sending warmup POST to '%s' for model '%s'…",
		_completions_endpoint, tostring(model_name))

	local Profiles  = require("modules.llm.profiles")
	local endpoint  = _completions_endpoint
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
	local effective_model = read_active_model_arg() or _server_model_id or _model_hf_path or model_name

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
			endpoint = _chat_endpoint
			local ok_enc, enc = pcall(hs.json.encode, {
				model       = effective_model,
				messages    = { { role = "user", content = merged } },
				max_tokens  = 1,
				temperature = 0,
				stream      = false,
			})
			if ok_enc then payload = enc end
		else
			-- Basic / raw profiles fold the context into the system prompt; only the
			-- static prefix before {context} is shared, so a completions ping suffices.
			local ok_enc, enc = pcall(hs.json.encode, {
				model       = effective_model,
				prompt      = sys,
				max_tokens  = 1,
				temperature = 0,
				stream      = false,
			})
			if ok_enc then payload = enc end
		end
	end

	-- Fallback: if profile resolution failed, send a minimal ping to confirm the model
	-- is loaded without risking a crash.
	if not payload then
		local ok_enc, enc = pcall(hs.json.encode, {
			model       = effective_model,
			prompt      = " ",
			max_tokens  = 1,
			temperature = 0,
		})
		if not ok_enc then return end
		payload = enc
	end

	_warmup_in_flight = true
	-- Hard timeout: hs.http.asyncPost has no built-in timeout, so if the server
	-- accepts the TCP connection but never sends a response (e.g. during model
	-- weight loading or a stale GPU stream), _warmup_in_flight would stay true
	-- forever, silently blocking every subsequent warmup call.
	if _warmup_timeout then pcall(function() _warmup_timeout:stop() end) end
	_warmup_timeout = hs.timer.doAfter(WARMUP_POST_TIMEOUT_SEC, function()
		_warmup_timeout = nil
		if not _warmup_in_flight then return end
		_warmup_in_flight = false
		Logger.warn(LOG, "Warmup POST timed out after %.0fs — unblocking and retrying in 2s.",
			WARMUP_POST_TIMEOUT_SEC)
		hs.timer.doAfter(2, function() M.warmup(model_name, profile) end)
	end)
	hs.http.asyncPost(endpoint, payload, { ["Content-Type"] = "application/json" },
		function(status, body)
			if _warmup_timeout then
				pcall(function() _warmup_timeout:stop() end)
				_warmup_timeout = nil
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
				_is_ready = true
				Logger.warn(LOG, "MLX KV cache primed (profile: %s) — backend ready.",
					(type(profile) == "table" and profile.id) or "default")
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
					_endpoints_discovered = false
				end
				Logger.warn(LOG, "MLX warmup returned %s (has_tokens=%s) — model not ready; retrying in 2s.",
					tostring(status), tostring(has_tokens))
				-- Retry automatically so the user does not have to manually trigger
				-- set_llm_enabled / set_llm_model after a slow model load or a
				-- generation-thread crash during the server hot-swap window.
				hs.timer.doAfter(2, function()
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
	hs.http.asyncGet("http://127.0.0.1:8080/v1/models", {}, function(status, body)
		if status == 200 then
			Logger.info(LOG, "MLX server is available.")
			if type(on_available) == "function" then pcall(on_available) end
		else
			Logger.warn(LOG, "MLX server is missing or unreachable.")
			if type(on_missing) == "function" then pcall(on_missing, false) end
		end
	end)
end





-- ======================================
-- ======================================
-- ======= 2/ Core Request Engine =======
-- ======================================
-- ======================================

-- Builds the options payload for the OpenAI API format (MLX Server) - optimized
local STOP_BASE_MLX  = { "<|eot_id|>", "<|im_end|>", "[/INST]", "PREFIX:" }
local STOP_LINE_MLX  = { "<|eot_id|>", "<|im_end|>", "[/INST]", "PREFIX:", "\n\n", "</", "Suite finale", "SUITE", "NEXT_WORDS:" }

local function build_options(temperature, num_predict_tokens, is_batch, line_mode)
    local opts = {
        temperature = tonumber(temperature) or 0.1,
        max_tokens  = tonumber(num_predict_tokens),
        stop        = (line_mode and not is_batch) and STOP_LINE_MLX or STOP_BASE_MLX,
    }
    return opts
end

--- Posts data to the local MLX LLM and parses the response.
--- @param model_name string Model identifier.
--- @param system_prompt string System instructions.
--- @param full_text string Context text.
--- @param tail_text string Recent context text.
--- @param temperature number Model temperature.
--- @param num_predict_tokens number Token limits.
--- @param num_predictions number Expected completions count.
--- @param is_batch boolean True if batch format requested.
--- @param on_success function Success callback.
--- @param on_fail function Failure callback.
--- @param dedup_stats table Dedup stats object.
--- @param force_line_mode boolean Force line completion parsing.
local function post_and_parse(model_name, system_prompt, full_text, tail_text,
                               temperature, num_predict_tokens, num_predictions, is_batch,
                               on_success, on_fail, dedup_stats, force_line_mode)
    _req_counter = _req_counter + 1
    local req_id = _req_counter
    local messages = {}

	local final_sys = system_prompt
	if type(final_sys) == "string" then
		final_sys = final_sys:gsub("%{n%}", tostring(num_predictions))
	end

	local user_prompt = ""
	if type(final_sys) == "string" and final_sys:find("PREFIX") and final_sys:find("TAIL") then
		user_prompt = string.format("PREFIX: \"%s\"\nTAIL: \"%s\"", full_text or "", tail_text or "")
	else
		local context_str = type(full_text) == "string" and full_text or ""
		if type(final_sys) == "string" and final_sys:find("{context}", 1, true) then
			final_sys = final_sys:gsub("%{context%}", function() return context_str end)
			user_prompt = final_sys
			final_sys = nil
		else
			user_prompt = context_str
		end
	end

    -- MLX OpenAI-compatible endpoint can reject system roles for some models
    -- Fold instructions into a single user message to keep compatibility
    local merged_prompt = user_prompt
    if type(final_sys) == "string" and final_sys ~= "" then
        merged_prompt = final_sys .. "\n\n" .. (user_prompt or "")
    end

    -- Disable reasoning mode globally (Qwen3, DeepSeek-R1, Hermes-3-think,
    -- etc.). See the streaming path below for the rationale; in short, these
    -- models otherwise burn the entire token budget on <think>…</think>
    -- monologue and emit zero final-answer content. /no_think is honoured
    -- as an in-prompt directive even when the chat template ignores
    -- chat_template_kwargs.
    table.insert(messages, { role = "user", content = merged_prompt .. "\n\n/no_think" })

    local t0_req = hs.timer.secondsSinceEpoch()

    -- Advanced mode is only the strict correction profile
    local is_advanced_prompt = type(final_sys) == "string" and final_sys:find("TAIL_CORRECTED", 1, true) ~= nil
    local line_mode = (force_line_mode == true) or ((not is_batch) and (not is_advanced_prompt))

    local opts = build_options(temperature, num_predict_tokens, is_batch, line_mode)
    local payload
    local endpoint = _chat_endpoint
    local prompt_preview = merged_prompt

    -- See read_active_model_arg() rationale at top of file: must mirror the
    -- exact --model arg the bash launcher passed to mlx_lm or the server
    -- treats it as a different model and tries snapshot_download (offline 404).
    local effective_model = read_active_model_arg() or _server_model_id or _model_hf_path or model_name
    if line_mode then
        -- For plain autocomplete, completion endpoint is more reliable than chat formatting
        local ctx = type(full_text) == "string" and full_text or ""
        local prompt = (#ctx > 240) and ctx:sub(#ctx - 239) or ctx
        prompt_preview = prompt
        endpoint = _completions_endpoint
        payload = {
            model       = effective_model,
            prompt      = prompt,
            stream      = false,
            temperature = opts.temperature,
            max_tokens  = tonumber(opts.max_tokens) or 50,
            stop        = { "\n\n", "</", "\"", "- " }
        }
    else
        payload = {
            model               = effective_model,
            messages            = messages,
            stream              = false,
            temperature         = opts.temperature,
            max_tokens          = opts.max_tokens,
            stop                = opts.stop,
            chat_template_kwargs = { enable_thinking = false },
            chat_template_args   = { enable_thinking = false },
        }
    end

    Logger.debug(LOG, "[%s] #%d PROMPT (%d chars) -> %s", model_name, req_id, #prompt_preview, prompt_preview:sub(1, 250))
    Logger.debug(LOG, "[%s] #%d MODE is_batch=%s line_mode=%s max_tokens=%s endpoint=%s", model_name, req_id, tostring(is_batch), tostring(line_mode), tostring(opts.max_tokens), endpoint)

	local ok, encoded = pcall(hs.json.encode, payload)
	if not ok or not encoded then
		Logger.error(LOG, "Failed to encode MLX payload.")
		if type(on_fail) == "function" then pcall(on_fail) end
		return
	end

    local done = false
    local timeout_timer = hs.timer.doAfter(8, function()
        if done then return end
        done = true
        Logger.warn(LOG, "[%s] #%d TIMEOUT after 8s", model_name, req_id)
        if type(on_fail) == "function" then pcall(on_fail) end
    end)

    hs.http.asyncPost(endpoint, encoded, { ["Content-Type"] = "application/json" },
        function(status, body, _)
            if done then return end
            done = true
            if timeout_timer and type(timeout_timer.stop) == "function" then timeout_timer:stop() end

            if status ~= 200 then
                Logger.error(LOG, "MLX HTTP %s :: %s", tostring(status), tostring((body or ""):sub(1, 260)))
                if type(on_fail) == "function" then pcall(on_fail) end
                return
            end
            
            local ok_dec, resp = pcall(hs.json.decode, body)
            if not ok_dec or type(resp) ~= "table" or type(resp.choices) ~= "table" or not resp.choices[1] then
                Logger.debug(LOG, "[%s] #%d Unusable response (decode/choices), body='%s'", model_name, req_id, tostring((body or ""):sub(1, 220)))
				if type(on_fail) == "function" then pcall(on_fail) end
				return
			end

			local choice = resp.choices[1]
			local content = nil

			-- OpenAI-like format extraction
			if type(choice.message) == "table" then
				if type(choice.message.content) == "string" then
					content = choice.message.content
				elseif type(choice.message.content) == "table" then
					local chunks = {}
					for _, item in ipairs(choice.message.content) do
						if type(item) == "table" and type(item.text) == "string" then
							table.insert(chunks, item.text)
						elseif type(item) == "string" then
							table.insert(chunks, item)
						end
					end
					if #chunks > 0 then content = table.concat(chunks, "") end
				end
			end

			-- Legacy completion fallback execution
			if not content and type(choice.text) == "string" then
				content = choice.text
			end

            if type(content) ~= "string" or content == "" then
                local has_reasoning = type(choice.message) == "table" and type(choice.message.reasoning) == "string" and choice.message.reasoning ~= ""
                if has_reasoning then
                    Logger.debug(LOG, "[%s] #%d Reasoning-only response detected (empty content).", model_name, req_id)
                end
                Logger.debug(LOG, "[%s] #%d Empty content in choices[1]", model_name, req_id)
                if type(on_fail) == "function" then pcall(on_fail) end
                return
            end

            local raw     = Parser.strip_thinking(content)
            local ms_req  = math.floor((hs.timer.secondsSinceEpoch() - t0_req) * 1000)
            Logger.debug(LOG, "[%s] #%d RAW (%dms, %d chars) -> %s", model_name, req_id, ms_req, #raw, raw:sub(1, 250))
            local results = {}

            if not is_batch then
                local pred = Parser.process_prediction(full_text, tail_text, raw)
                if pred then ApiCommon.insert_prediction(results, pred, dedup_stats, DEDUPLICATION_ENABLED, Logger, LOG) end
            else
                for _, block in ipairs(Parser.split_blocks(raw)) do
                    if #results >= num_predictions then break end
                    local pred = Parser.process_prediction(full_text, tail_text, block)
                    if pred then ApiCommon.insert_prediction(results, pred, dedup_stats, DEDUPLICATION_ENABLED, Logger, LOG) end
                end
            end

            if #results == 0 then
                Logger.debug(LOG, "[%s] #%d PARSED -> 0 result (parser failure)", model_name, req_id)
                if type(on_fail) == "function" then pcall(on_fail) end return
            end
            Logger.debug(LOG, "[%s] #%d PARSED -> %d result(s)", model_name, req_id, #results)
            if keylogger and type(keylogger.log_llm) == "function" then pcall(keylogger.log_llm, full_text, results) end
            if type(on_success) == "function" then pcall(on_success, results) end
        end
    )
end





--- Streaming variant of post_and_parse using hs.task + curl -N.
--- Calls on_partial(accumulated_raw_text) after each received token so the
--- caller can update the UI incrementally. Calls on_success with the final
--- parsed result when the stream ends.
--- @param model_name string
--- @param system_prompt string
--- @param full_text string
--- @param tail_text string
--- @param temperature number
--- @param num_predict_tokens number
--- @param num_predictions number
--- @param is_batch boolean
--- @param on_success function Called once with final parsed results.
--- @param on_fail function Called on error.
--- @param dedup_stats table
--- @param on_partial function|nil Called with accumulated raw text as each token arrives.
local function post_and_parse_streaming(model_name, system_prompt, full_text, tail_text,
                                         temperature, num_predict_tokens, num_predictions, is_batch,
                                         on_success, on_fail, dedup_stats, on_partial)
	-- Supersede any previous stream: always terminate to free the MLX server connection
	if _active_stream_task then
		pcall(function() _active_stream_task:terminate() end)
		_active_stream_task    = nil
		_active_stream_has_chunks = false
	end

	_stream_generation = _stream_generation + 1
	local my_generation = _stream_generation

	_req_counter = _req_counter + 1
	local req_id = _req_counter

	-- Replicate message/endpoint building from post_and_parse
	local final_sys = system_prompt
	if type(final_sys) == "string" then
		final_sys = final_sys:gsub("%{n%}", tostring(num_predictions))
	end

	local user_prompt = ""
	if type(final_sys) == "string" and final_sys:find("PREFIX") and final_sys:find("TAIL") then
		user_prompt = string.format("PREFIX: \"%s\"\nTAIL: \"%s\"", full_text or "", tail_text or "")
	else
		local context_str = type(full_text) == "string" and full_text or ""
		if type(final_sys) == "string" and final_sys:find("{context}", 1, true) then
			final_sys = final_sys:gsub("%{context%}", function() return context_str end)
			user_prompt = final_sys
			final_sys = nil
		else
			user_prompt = context_str
		end
	end

	local merged_prompt = user_prompt
	if type(final_sys) == "string" and final_sys ~= "" then
		merged_prompt = final_sys .. "\n\n" .. (user_prompt or "")
	end

	local is_advanced_prompt = type(final_sys) == "string" and final_sys:find("TAIL_CORRECTED", 1, true) ~= nil
	local line_mode = (not is_batch) and (not is_advanced_prompt)
	local opts = build_options(temperature, num_predict_tokens, is_batch, line_mode)

	-- See read_active_model_arg() rationale at top of file: must mirror the
	-- exact --model arg the bash launcher passed to mlx_lm or the server
	-- treats it as a different model and tries snapshot_download (offline 404).
	local effective_model = read_active_model_arg() or _server_model_id or model_name
	local payload, endpoint, prompt_preview
	if line_mode then
		local ctx    = type(full_text) == "string" and full_text or ""
		local prompt = (#ctx > 240) and ctx:sub(#ctx - 239) or ctx
		prompt_preview = prompt
		endpoint = _completions_endpoint
		payload = {
			model       = effective_model,
			prompt      = prompt,
			stream      = true,
			temperature = opts.temperature,
			max_tokens  = tonumber(opts.max_tokens) or 50,
			stop        = { "\n\n", "</", "\"", "- " },
		}
	else
		-- Disable reasoning / "thinking" mode globally. Qwen3, DeepSeek-R1,
		-- Hermes-3-think and other reasoning models otherwise spend their
		-- entire token budget producing <think>…</think> internal monologue
		-- and emit zero final-answer content, which surfaces as
		-- STREAM_DONE → empty raw → "parse yielded 0 result(s)".
		--
		-- Belt-and-braces:
		--   1. chat_template_kwargs / chat_template_args: the standard
		--      mlx-lm 0.31+ knob to flip Jinja templates that gate
		--      <think> blocks behind `enable_thinking`.
		--   2. /no_think suffix on the user message: Qwen3 honours this as
		--      a literal in-prompt directive even if the chat template
		--      does not pick up the kwarg (e.g. older snapshots).
		local user_content    = merged_prompt .. "\n\n/no_think"
		prompt_preview = user_content
		endpoint = _chat_endpoint
		payload = {
			model               = effective_model,
			messages            = { { role = "user", content = user_content } },
			stream              = true,
			temperature         = opts.temperature,
			max_tokens          = opts.max_tokens,
			stop                = opts.stop,
			chat_template_kwargs = { enable_thinking = false },
			chat_template_args   = { enable_thinking = false },
		}
	end

	Logger.debug(LOG, "[%s] #%d STREAM_PROMPT (%d chars) -> %s",
		model_name, req_id, #prompt_preview, prompt_preview:sub(1, 250))

	local ok, encoded = pcall(hs.json.encode, payload)
	if not ok or not encoded then
		Logger.error(LOG, "Failed to encode MLX streaming payload.")
		if type(on_fail) == "function" then pcall(on_fail) end
		return
	end

	local accumulated   = ""
	local line_buf      = ""
	local in_reasoning  = false  -- Currently accumulating delta.reasoning(_content) tokens — close </think> on transition or end
	local t0_req        = hs.timer.secondsSinceEpoch()

	-- Parse one SSE line (data: {...} or data: [DONE]) and append its token to accumulated
	local function process_sse_line(line)
		Logger.debug(LOG, "[%s] #%d SSE line: '%s'", model_name, req_id, line:sub(1, 120))
		if line:sub(1, 6) ~= "data: " then return end
		local json_str = line:sub(7)
		if json_str == "[DONE]" then return end
		local ok_dec, obj = pcall(hs.json.decode, json_str)
		if not ok_dec or type(obj) ~= "table" or type(obj.choices) ~= "table" or not obj.choices[1] then
			Logger.debug(LOG, "[%s] #%d SSE decode fail: ok=%s type_obj=%s",
				model_name, req_id, tostring(ok_dec), type(obj))
			return
		end
		local choice = obj.choices[1]
		-- Chat completions streaming. Reasoning models (Qwen3, DeepSeek-R1,
		-- Hermes-3 in think mode) route their thought tokens through
		-- delta.reasoning(_content) and the final answer through
		-- delta.content. We accumulate both into a single string,
		-- inserting a single <think>…</think> wrapper around the reasoning
		-- segment so Parser.strip_thinking() can remove it cleanly at the
		-- end. Without this branch, the reasoning chunks were silently
		-- dropped and the chat-completions stream finished with "empty
		-- accumulation" even when the server emitted hundreds of tokens.
		local reasoning_chunk = nil
		local content_chunk   = nil
		if type(choice.delta) == "table" then
			if type(choice.delta.content) == "string" and choice.delta.content ~= "" then
				content_chunk = choice.delta.content
			end
			if type(choice.delta.reasoning_content) == "string" and choice.delta.reasoning_content ~= "" then
				reasoning_chunk = choice.delta.reasoning_content
			elseif type(choice.delta.reasoning) == "string" and choice.delta.reasoning ~= "" then
				reasoning_chunk = choice.delta.reasoning
			end
		elseif type(choice.text) == "string" and choice.text ~= "" then
			-- Completions endpoint streaming: text directly
			content_chunk = choice.text
		end

		local appended = false
		if reasoning_chunk then
			if not in_reasoning then
				accumulated = accumulated .. "<think>"
				in_reasoning = true
			end
			accumulated = accumulated .. reasoning_chunk
			appended = true
		end
		if content_chunk then
			if in_reasoning then
				accumulated = accumulated .. "</think>"
				in_reasoning = false
			end
			accumulated = accumulated .. content_chunk
			appended = true
		end
		if appended and type(on_partial) == "function" then
			pcall(on_partial, accumulated)
		end
	end

	-- Drain line_buf, processing every complete SSE line found
	local function flush_lines()
		while true do
			local nl = line_buf:find("\n", 1, true)
			if not nl then break end
			local line = line_buf:sub(1, nl - 1)
			line_buf   = line_buf:sub(nl + 1)
			if line ~= "" then process_sse_line(line) end
		end
	end

	-- Streaming callback: fired each time curl writes a chunk to stdout
	local function on_chunk(_, chunk, stderr_chunk)
		if not chunk or chunk == "" then return true end
		-- Generation check: if a newer request superseded us, discard chunks silently
		if my_generation ~= _stream_generation then return false end
		-- First chunk received — server is alive; cancel the hard-timeout watchdog and mark stream active
		if not _active_stream_has_chunks then
			_active_stream_has_chunks = true
			if _active_stream_timeout then
				pcall(function() _active_stream_timeout:stop() end)
				_active_stream_timeout = nil
			end
		end
		Logger.debug(LOG, "[%s] #%d STREAM chunk (%d bytes): '%s'",
			model_name, req_id, #chunk, chunk:sub(1, 120))
		line_buf = line_buf .. chunk
		flush_lines()
		return true
	end

	-- Completion callback: fired when curl exits
	local function on_done(exit_code, remaining, stderr_out)
		Logger.debug(LOG, "[%s] #%d STREAM on_done: exit=%s remaining_len=%d stderr='%s'",
			model_name, req_id, tostring(exit_code),
			(remaining and #remaining or -1),
			tostring((stderr_out or ""):sub(1, 200)))

		-- Generation check: a newer request superseded this stream — discard result silently
		-- and DO NOT touch _active_stream_task: it now belongs to the newer request,
		-- and clearing it would untrack the active stream so subsequent cancel_streaming
		-- calls would no-op, leaking curl processes that hold the MLX connection
		if my_generation ~= _stream_generation then
			Logger.debug(LOG, "[%s] #%d STREAM: superseded by newer request (gen %d vs %d) — no callbacks.",
				model_name, req_id, my_generation, _stream_generation)
			return
		end

		-- This stream is still the current one — clear active state
		_active_stream_task    = nil
		_active_stream_has_chunks = false
		if _active_stream_timeout then
			pcall(function() _active_stream_timeout:stop() end)
			_active_stream_timeout = nil
		end

		-- SIGTERM (15) means this stream was explicitly terminated (mid-flight cancel)
		if exit_code == 15 then
			Logger.debug(LOG, "[%s] #%d STREAM: terminated mid-flight — no callbacks.", model_name, req_id)
			return
		end

		if remaining and remaining ~= "" then
			line_buf = line_buf .. remaining
			flush_lines()
		end

		-- Close any unterminated reasoning segment so Parser.strip_thinking
		-- can remove the entire <think>…</think> block; without this,
		-- a reasoning-only stream that never transitions to content would
		-- leave "<think>…" unbalanced and strip_thinking would no-op.
		if in_reasoning then
			accumulated  = accumulated .. "</think>"
			in_reasoning = false
		end

		if accumulated == "" then
			Logger.warn(LOG, "[%s] #%d STREAM: empty accumulation — on_fail.", model_name, req_id)
			if type(on_fail) == "function" then pcall(on_fail) end
			return
		end

		local raw    = Parser.strip_thinking(accumulated)
		local ms_req = math.floor((hs.timer.secondsSinceEpoch() - t0_req) * 1000)
		Logger.debug(LOG, "[%s] #%d STREAM_DONE (%dms) -> %s", model_name, req_id, ms_req, raw:sub(1, 250))

		local results = {}
		if not is_batch then
			local pred = Parser.process_prediction(full_text, tail_text, raw)
			if pred then ApiCommon.insert_prediction(results, pred, dedup_stats, DEDUPLICATION_ENABLED, Logger, LOG) end
		else
			for _, block in ipairs(Parser.split_blocks(raw)) do
				if #results >= num_predictions then break end
				local pred = Parser.process_prediction(full_text, tail_text, block)
				if pred then ApiCommon.insert_prediction(results, pred, dedup_stats, DEDUPLICATION_ENABLED, Logger, LOG) end
			end
		end

		if #results == 0 then
			Logger.debug(LOG, "[%s] #%d STREAM: parse yielded 0 result(s).", model_name, req_id)
			if type(on_fail) == "function" then pcall(on_fail) end
			return
		end
		Logger.debug(LOG, "[%s] #%d STREAM: %d result(s).", model_name, req_id, #results)
		if keylogger and type(keylogger.log_llm) == "function" then pcall(keylogger.log_llm, full_text, results) end
		if type(on_success) == "function" then pcall(on_success, results) end
	end

	-- Write payload to a temp file so curl reads it directly — avoids the
	-- stdin-pipe/streaming-callback conflict in hs.task
	local tmp_path = os.tmpname() .. "_mlx_stream.json"
	local fh = io.open(tmp_path, "w")
	if not fh then
		Logger.error(LOG, "Failed to open temp file '%s' for MLX streaming payload.", tmp_path)
		if type(on_fail) == "function" then pcall(on_fail) end
		return
	end
	fh:write(encoded)
	fh:close()

	if _active_stream_timeout then
		pcall(function() _active_stream_timeout:stop() end)
		_active_stream_timeout = nil
	end

	local task = hs.task.new("/usr/bin/curl", on_done, on_chunk, {
		"-s", "-N", "-X", "POST",
		"-H", "Content-Type: application/json",
		"--connect-timeout", tostring(STREAM_CONNECT_TIMEOUT_SEC),
		"--data-binary", "@" .. tmp_path,
		endpoint,
	})
	task:start()
	_active_stream_task    = task
	_active_stream_has_chunks = false
	Logger.debug(LOG, "[%s] #%d STREAM task started (payload: %s).", model_name, req_id, tmp_path)

	-- Hard-timeout: if no token has arrived within STREAM_HARD_TIMEOUT_SEC, the server
	-- accepted the connection but is hung — terminate the task and fire on_fail so the
	-- UI does not freeze indefinitely showing the loading spinner.
	_active_stream_timeout = hs.timer.doAfter(STREAM_HARD_TIMEOUT_SEC, function()
		_active_stream_timeout = nil
		-- Only fire if this stream is still the current one
		if my_generation ~= _stream_generation then return end
		if _active_stream_task then
			Logger.warn(LOG, "[%s] #%d STREAM hard timeout (%gs) — terminating hung task.",
				model_name, req_id, STREAM_HARD_TIMEOUT_SEC)
			pcall(function() _active_stream_task:terminate() end)
			_active_stream_task    = nil
			_active_stream_has_chunks = false
			if type(on_fail) == "function" then pcall(on_fail) end
		end
	end)

	-- Clean up the temp file once the task has had time to read it
	hs.timer.doAfter(10, function()
		os.remove(tmp_path)
	end)
end




-- ===================================
-- ===================================
-- ======= 3/ Fetch Strategies =======
-- ===================================
-- ===================================

--- Dispatches a single API request asking for N clustered predictions.
--- @param full_text string The complete tracked context string.
--- @param tail_text string The most recent segment of the context.
--- @param model_name string Name of the targeted local model.
--- @param temperature number Base sampling temperature.
--- @param max_predict number Maximum allowed output tokens.
--- @param num_predictions number Request quantity for prediction arrays.
--- @param profile table Active profile mapping.
--- @param on_success function Function to execute on success.
--- @param on_fail function Function to execute on failure.
--- @param request_id_provider function Callback returning the current request identifier.
--- @param streaming boolean Whether to use token-by-token streaming (controlled by init.lua).
--- @param on_partial function|nil Optional token-by-token streaming callback.
function M.fetch_batch(full_text, tail_text, model_name, temperature,
                       max_predict, num_predictions, profile,
                       on_success, on_fail, request_id_provider, streaming, on_partial)

	local effective_temp = tonumber(temperature) or 0.1
	local system_prompt  = Profiles.resolve_system_prompt(profile, num_predictions)
	local tokens         = tonumber(max_predict) * num_predictions + (num_predictions * 5)
	local is_batch       = profile.batch
	local dedup_stats    = ApiCommon.new_dedup_stats()
	local post_fn        = streaming and post_and_parse_streaming or post_and_parse

	local t0 = hs.timer.secondsSinceEpoch()
	post_fn(model_name, system_prompt, full_text, tail_text,
		effective_temp, tokens, num_predictions, is_batch,
		function(results)
			local ms = math.floor((hs.timer.secondsSinceEpoch() - t0) * 1000)
			ApiCommon.log_prediction_summary(Logger, LOG, "batch", num_predictions, dedup_stats, #results)
			-- With streaming OFF: reveal each prediction one by one (complete, no animation) so
			-- the user sees slot 1 fill, then slot 2, etc. rather than all appearing at once.
			-- Each doAfter(0) yields to the event loop so the tooltip renders between reveals.
			-- With streaming ON: on_partial_cb already showed each pred token by token;
			-- emit the final call directly to replace stream placeholders with diff colors.
			if not streaming and #results > 1 then
				local function reveal_next(idx)
					if idx > #results then return end
					local subset = {}
					for j = 1, idx do subset[j] = results[j] end
					local is_final = (idx == #results)
					-- Pass is_batch_progressive=true so prediction_engine bypasses the
					-- streaming_multi early-return for these intermediate calls
					if type(on_success) == "function" then pcall(on_success, subset, ms, is_final, not is_final) end
					if not is_final then hs.timer.doAfter(0, function() reveal_next(idx + 1) end) end
				end
				reveal_next(1)
			else
				if type(on_success) == "function" then pcall(on_success, results, ms, true) end
			end
		end,
		on_fail,
		dedup_stats,
		streaming and on_partial or nil)
end

--- Dispatches multiple parallel API requests incrementing the temperature to aggregate predictions.
--- @param full_text string The complete tracked context string.
--- @param tail_text string The most recent segment of the context.
--- @param model_name string Name of the targeted local model.
--- @param temperature number Base sampling temperature.
--- @param max_predict number Maximum allowed output tokens.
--- @param num_predictions number Request quantity for prediction arrays.
--- @param profile table Active profile mapping.
--- @param on_success function Function to execute on success.
--- @param on_fail function Function to execute on failure.
--- @param request_id_provider function Callback returning the current request identifier.
--- @param streaming boolean Whether to use token-by-token streaming.
--- @param on_partial function|nil Optional token-by-token streaming callback.
function M.fetch_parallel(full_text, tail_text, model_name, temperature,
                          max_predict, num_predictions, profile,
                          on_success, on_fail, request_id_provider, streaming, on_partial)
	-- MLX can produce unstable outputs under parallel fan-out with some models
	-- Force sequential dispatch for reliability while keeping the same public API
	return M.fetch_sequential(full_text, tail_text, model_name, temperature,
		max_predict, num_predictions, profile,
		on_success, on_fail, request_id_provider, streaming, on_partial)
end

--- Dispatches multiple sequential API requests to avoid parallel connection dropping.
--- @param full_text string The complete tracked context string.
--- @param tail_text string The most recent segment of the context.
--- @param model_name string Name of the targeted local model.
--- @param temperature number Base sampling temperature.
--- @param max_predict number Maximum allowed output tokens.
--- @param num_predictions number Request quantity for prediction arrays.
--- @param profile table Active profile mapping.
--- @param on_success function Function to execute on success.
--- @param on_fail function Function to execute on failure.
--- @param request_id_provider function Callback returning the current request identifier.
--- @param streaming boolean Whether to use token-by-token streaming.
--- @param on_partial function|nil Optional token-by-token streaming callback.
function M.fetch_sequential(full_text, tail_text, model_name, temperature,
                             max_predict, num_predictions, profile,
                             on_success, on_fail, request_id_provider, streaming, on_partial)

	local system_prompt = Profiles.resolve_system_prompt(profile, 1)
	local t0            = hs.timer.secondsSinceEpoch()
	local results       = {}
	local base_temp     = tonumber(temperature) or 0.1
	local requested_predictions = math.max(1, math.floor(tonumber(num_predictions) or 1))
	local max_attempts = requested_predictions
	if RETRY_FAILED_PREDICTION_ENABLED == true then
		max_attempts = math.max(requested_predictions, requested_predictions * math.max(1, math.floor(tonumber(RETRY_FAILED_PREDICTION_MAX_MULTIPLIER) or 2)))
	end
	local attempt_index = 1
	local dedup_stats   = ApiCommon.new_dedup_stats()
	local initial_request_id = type(request_id_provider) == "function" and request_id_provider() or nil

	local function do_next()
		-- Check if this request batch was cancelled dynamically
		if type(request_id_provider) == "function" then
			local current_request_id = request_id_provider()
			if initial_request_id ~= nil and current_request_id ~= initial_request_id then
				Logger.debug(LOG, "Request batch cancelled: ID changed from %s to %s at step %d/%d",
					tostring(initial_request_id), tostring(current_request_id), attempt_index, max_attempts)
				return
			end
		end

		if #results >= requested_predictions or attempt_index > max_attempts then
			if #results == 0 then if type(on_fail) == "function" then pcall(on_fail) end return end
			ApiCommon.log_prediction_summary(Logger, LOG, "sequential", requested_predictions, dedup_stats, #results)
			local ms = math.floor((hs.timer.secondsSinceEpoch() - t0) * 1000)
			if type(on_success) == "function" then pcall(on_success, results, ms, true) end
			return
		end

		local variant_index  = attempt_index
		attempt_index        = attempt_index + 1
		local variant_temp   = ApiCommon.get_diversity_temperature(base_temp, variant_index, 0.30)
		local primary_tokens = tonumber(max_predict)
		-- Each variant streams its tokens via on_partial so the tooltip shows each
		-- prediction building in its own slot; prediction_engine.lua keeps the cursor
		-- at slot 1 (or wherever the user navigated) regardless of which slot streams
		local variant_partial = on_partial

		local function request_variant(attempt, tokens, temp)
			local post_fn = streaming and post_and_parse_streaming or post_and_parse
			post_fn(model_name, system_prompt, full_text, tail_text,
				temp, tokens, 1, false,
				function(preds)
					if type(preds) == "table" and type(preds[1]) == "table" then
						if #results < requested_predictions then
							ApiCommon.insert_prediction(results, preds[1], dedup_stats, DEDUPLICATION_ENABLED, Logger, LOG)
							local ms = math.floor((hs.timer.secondsSinceEpoch() - t0) * 1000)
							if type(on_success) == "function" then pcall(on_success, results, ms, false) end
						end
					end
					do_next()
				end,
				function()
					if attempt < 2 then
						local retry_tokens = tokens + 5
						local retry_temp   = math.min(0.60, (tonumber(temp) or 0.1) + 0.10)
						Logger.debug(LOG, "[%s] Variant %d/%d quick chat retry: tokens=%d temp=%.2f",
							model_name, variant_index, max_attempts, retry_tokens, retry_temp)
						-- Retry does not stream partial updates (would overwrite the growing preview)
						request_variant(attempt + 1, retry_tokens, retry_temp)
						return
					end
					do_next()
				end,
				dedup_stats,
				streaming and variant_partial or nil)
		end

		request_variant(1, primary_tokens, variant_temp)
	end

	do_next()
end

return M
