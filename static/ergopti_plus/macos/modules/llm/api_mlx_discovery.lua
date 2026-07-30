--- modules/llm/api_mlx_discovery.lua

--- ==============================================================================
--- MODULE: LLM API Endpoint Discovery & Route Cache (Apple MLX)
--- DESCRIPTION:
--- Owns the MLX server's connection-route state: which endpoint paths the live
--- mlx-lm install actually exposes (they have drifted across releases), the
--- cached working URLs, and the model identifiers a request payload must echo.
--- Extracted verbatim from api_mlx.lua so the controller stays focused on the
--- warmup / streaming / zombie-kill state machine; behaviour is unchanged.
---
--- FEATURES & RATIONALE:
--- 1. Single owner of routes: api_mlx (warmup), the inference engine (via the ctx
---    closures it is given), and set_port all read/refresh the live routes through
---    this module's getters, so there is one source of truth and a later
---    re-discovery or port change is always seen by every consumer.
--- 2. Probe robustness: discovery polls /v1/models with a repeating timer (immune
---    to dropped asyncGet callbacks when a killed server resets the connection)
---    using curl --no-keepalive (so a zombie socket lingering in CLOSE_WAIT cannot
---    pin a stale model ID), then POST-probes each candidate route, caching the
---    first that answers anything other than 404 / -1.
--- 3. One-way dependency: this module reaches nothing in api_mlx — it only uses
---    adapters and the base URL it is initialised with — so the controller depends
---    on discovery, never the reverse.
--- 4. Logs on the "llm.api_mlx" channel so every MLX line lands in ErgoptiPlus_mlx.log.
--- ==============================================================================

local M = {}

local Logger         = require("lib.logger")
local JsonCodec      = require("adapters.json_codec")
local TimerScheduler = require("adapters.timer_scheduler")
local ShellRunner    = require("adapters.shell_runner")
local Timings        = require("lib.timings")
local ApiCommon = require("modules.llm.api_common")
local _probe_client  = require("adapters.http_client").new()  -- Dedicated client for discover() POST probes; never shares state with warmup
-- MLX log channel; every MLX line lands in ErgoptiPlus_mlx.log.
local LOG            = "llm.api_mlx"





-- ===========================================
--- ===========================================
--- ======= 1/ Route & Identifier State =======
--- ===========================================
-- ===========================================

-- Discovered endpoint paths. Different mlx-lm releases have shipped completions
-- and chat-completions under different routes (with/without the `/v1/` prefix);
-- a silent route rename in a freshly-pulled wheel turns every request into a
-- 404 with no obvious cause. Rather than hard-coding one set of paths, we probe
-- the live server once per process to discover what it actually exposes, cache
-- the working URLs here, and let everything else resolve through these vars.
-- Initial values are the OpenAI-standard paths used by the long-stable
-- mlx-lm 0.18→0.21 series; discover() overrides them at runtime
-- whenever a probe finds a different working route.
-- The base URL is injected by api_mlx via M.init() (derived from MLX_HOST/MLX_PORT,
-- loaded from _shared/modules/llm/mlx_server.json) and refreshed via M.set_base_url()
-- when the user changes the port. discover() overrides the routes at runtime.
local _base_url             = nil
local _completions_endpoint = nil
local _chat_endpoint        = nil
local _endpoints_discovered = false
local _endpoint_probe_in_flight = false

-- Inter-probe delay, carried ACROSS discovery cycles. Declared here rather than
-- inside discover() so a failed cycle's backoff is still in force when the next
-- caller retries.
local _poll_delay_sec = nil
-- Callbacks waiting for the current discovery probe to complete; each
-- discover() call during a probe enqueues its on_done here so no
-- caller is silently dropped when a second warmup fires mid-poll.
local _discovery_pending_callbacks = {}
-- Bumped on reset(); a discovery cycle whose captured gen has gone stale must
-- not let its opportunistic background chat-route probe overwrite whatever a
-- NEWER cycle has already cached. Unlike api_mlx.lua's _warmup_gen (which only
-- gates a single is_ready flip), this module has a background probe that keeps
-- running well after finish_discovery() returns (the "Only update the cached
-- URL" comment below) — without this guard, a stale probe from a superseded
-- model could silently clobber a freshly-discovered chat route (F-MED-8).
local _discovery_gen = 0
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
-- keyed by the payload’s "model" field; if the payload sends the HF repo id
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

-- Read from the shared registry rather than hardcoded. The key existed there with
-- NO reader while this file carried its own literal, so one concept had two values
-- and the registry's was the stale one.
local DISCOVERY_MAX_WAIT_SEC        = Timings.sec("llm", "discovery_max_wait_ms")
                                           -- Stop polling /v1/models after this much real time
                                           -- (a cold mlx_lm import + 2B model load can take 45-70 s+
                                           -- on a slow disk; 60 s gave up prematurely. Warmup keeps
                                           -- retrying regardless, but a longer window keeps the
                                           -- discovered routes fresh and silences the scary warning).
local DISCOVERY_POLL_INITIAL_SEC    = Timings.sec("llm", "discovery_poll_initial_ms")  -- First inter-probe delay (doubles each miss, capped below)
local DISCOVERY_POLL_MAX_SEC        = Timings.sec("llm", "discovery_poll_max_ms")       -- Cap for the exponential backoff interval

-- Seeded once the initial value is known; reset to it on a successful discovery.
_poll_delay_sec = DISCOVERY_POLL_INITIAL_SEC





-- ============================================
--- ===========================================
--- ======= 2/ Lifecycle & Route Access =======
--- ===========================================
-- ============================================

--- Initialises the route cache from the controller's base URL. Must be called
--- once at module wiring time before any discover()/warmup.
--- @param ctx table { base_url: string } — e.g. "http://127.0.0.1:3460".
function M.init(ctx)
	_base_url             = ctx.base_url
	_completions_endpoint = _base_url .. "/v1/completions"
	_chat_endpoint        = _base_url .. "/v1/chat/completions"
end

--- Refreshes the base URL and resets the cached routes to their defaults so the
--- next warmup re-probes on the new address. Called by api_mlx.set_port().
--- @param url string The new base URL, e.g. "http://127.0.0.1:3461".
function M.set_base_url(url)
	_base_url             = url
	_completions_endpoint = _base_url .. "/v1/completions"
	_chat_endpoint        = _base_url .. "/v1/chat/completions"
end

--- @return string The cached completions endpoint URL.
function M.get_completions_endpoint() return _completions_endpoint end

--- @return string The cached chat-completions endpoint URL.
function M.get_chat_endpoint() return _chat_endpoint end

--- @return string|nil The canonical model ID reported by /v1/models (currently always nil — see comment in discover()).
function M.get_server_model_id() return _server_model_id end

--- @return string|nil The full HF repo path used to launch the current server.
function M.get_model_hf_path() return _model_hf_path end

--- @return string|nil The exact --model argument the bash launcher wrote to disk.
function M.read_active_model_arg() return read_active_model_arg() end

--- Records the short model name warmup is waiting for, so the discovery poll can
--- reject a /v1/models 200 from a stale old server during a model switch.
--- @param name string|nil The expected (short) model identifier.
function M.set_expected_model_id(name) _expected_model_id = name end

--- Records the full HuggingFace repository path (e.g.
--- "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit") used to launch the server.
--- Called by models_manager_mlx (via api_mlx) immediately after reset so the
--- discovery bypass and warmup can fall back to this authoritative path when
--- /v1/models returns a stale model ID during weight loading.
--- @param hf_path string The full HF repo path passed to `mlx_lm server --model`.
function M.set_model_hf_path(hf_path)
	_model_hf_path = type(hf_path) == "string" and hf_path or nil
	Logger.debug(LOG, "Model HF path set to '%s'.", tostring(_model_hf_path))
end

--- @return boolean True once the live routes have been confirmed for this server.
function M.is_discovered() return _endpoints_discovered end

--- Clears the discovered flag so the next warmup re-probes the live routes.
--- Called by warmup when its own POST returns 404 (the routes it cached are dead).
function M.mark_undiscovered() _endpoints_discovered = false end

--- Resets the discovery state (flags, pending callbacks, model identifiers) so the
--- next warmup re-probes the live server. The cached route URLs are deliberately
--- NOT reset here — only set_base_url() rewrites them — so a server relaunch on the
--- same port keeps the last-known routes until a fresh probe overrides them.
function M.reset()
	_endpoints_discovered        = false
	_endpoint_probe_in_flight    = false
	_discovery_pending_callbacks = {}
	_server_model_id             = nil
	_expected_model_id           = nil
	_model_hf_path               = nil
	-- Invalidate any in-flight discover() cycle (including its opportunistic
	-- background chat-route probe) so a stale response cannot overwrite the
	-- routes the NEXT discovery cycle caches (F-MED-8).
	_discovery_gen = _discovery_gen + 1
end





-- =====================================
--- =====================================
--- ======= 3/ Endpoint Discovery =======
--- =====================================
-- =====================================

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
--- Reports whether the script is paused. Discovery spawns curl polls and POSTs
--- inference probes, which the "pause = everything off" invariant forbids: this
--- module had no reference to a pause predicate at all.
--- @return boolean
local function _is_paused()
	local sc = package.loaded["modules.shortcuts.script_control"]
	return type(sc) == "table" and type(sc.is_paused) == "function" and sc.is_paused() == true
end

function M.discover(on_done)
	if _is_paused() then
		Logger.debug(LOG, "Discovery skipped — script is paused.")
		-- The caller is answered rather than dropped: a warmup waiting on a
		-- callback that never fires is how the prediction lock got stuck.
		if type(on_done) == "function" then ApiCommon.protected_call(on_done, "on_done") end
		return
	end
	if _endpoints_discovered then
		if type(on_done) == "function" then ApiCommon.protected_call(on_done, "on_done") end
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
	-- Captured now so every async callback below (including the opportunistic
	-- background chat probe, which can outlive finish_discovery) can detect a
	-- reset() that started a newer cycle and discard its own stale write (F-MED-8).
	local my_discovery_gen = _discovery_gen

	local probe_completions = JsonCodec.encode({ prompt = " ", max_tokens = 1 })
	local probe_chat        = JsonCodec.encode({
		messages   = { { role = "user", content = " " } },
		max_tokens = 1,
	})
	local headers    = { ["Content-Type"] = "application/json" }
	local started_at = TimerScheduler.now()

	local function finish_discovery(success)
		-- Stop the poll timer before firing callbacks so a callback that calls
		-- reset() + discover() again does not find the timer
		-- still running and incorrectly skip starting a fresh one.
		_endpoint_probe_in_flight = false
		if success then
			_endpoints_discovered = true
			-- The server answered — that, and only that, justifies probing eagerly
			-- again on the next cycle.
			_poll_delay_sec = DISCOVERY_POLL_INITIAL_SEC
			Logger.warn(LOG, "MLX endpoints resolved: completions=%s, chat=%s.",
				_completions_endpoint, _chat_endpoint)
		end
		-- Fire all enqueued callbacks — each warmup caller that arrived during
		-- the discovery probe deserves to be notified so none are silently dropped
		-- (mlx-discovery-callbacks-loss). All callers requested the same model
		-- (model switches clear the queue via reset()), so firing all
		-- of them is correct and idempotent.
		local cbs = _discovery_pending_callbacks
		_discovery_pending_callbacks = {}
		for _, cb in ipairs(cbs) do pcall(cb) end
	end

	local function run_post_probes()
		-- payloads indexed by kind so each probe uses the correct API format;
		-- using the wrong format on some mlx-lm versions returns 404 (not 422)
		local probe_by_kind = { completions = probe_completions, chat = probe_chat }

		local function probe_one(candidates, idx, found_so_far, kind, on_resolved)
			if idx > #candidates then
				ApiCommon.protected_call(on_resolved, "on_resolved", found_so_far)
				return
			end
			local path = candidates[idx]
			local payload = probe_by_kind[kind] or probe_completions
			_probe_client.post(_base_url .. path, headers, payload, function(r)
				-- Accept only positive HTTP status codes — NSURLError codes are negative integers
				-- (e.g. -1 = connection refused/reset); the module comment at the top explicitly
				-- states we do NOT accept -1 as a hit, but the original guard only rejected 404 and 0.
				if type(r.status) == "number" and r.status >= 200 and r.status ~= 404 then
					Logger.info(LOG, "Endpoint discovery (%s): %s -> HTTP %s — accepted as live route.",
						kind, path, tostring(r.status))
					ApiCommon.protected_call(on_resolved, "on_resolved", _base_url .. path)
				else
					Logger.debug(LOG, "Endpoint discovery (%s): %s -> %s, trying next candidate.",
						kind, path, tostring(r.status))
					probe_one(candidates, idx + 1, found_so_far, kind, on_resolved)
				end
			end)
		end

		probe_one(COMPLETIONS_CANDIDATES, 1, nil, "completions", function(found)
			-- A reset() (model switch) since this cycle started means whatever
			-- routes a NEWER discover() call has already cached must not be
			-- clobbered by this superseded cycle's result (F-MED-8).
			if my_discovery_gen ~= _discovery_gen then
				Logger.debug(LOG, "Endpoint discovery: stale completions probe discarded (gen %d != %d).",
					my_discovery_gen, _discovery_gen)
				return
			end
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
					-- By the time this fires, reset() may have run for a new model;
					-- calling finish_discovery would corrupt the new server's state.
					-- Gen guard: this probe can outlive finish_discovery() by an
					-- arbitrary amount, so it must re-check for a newer cycle here
					-- too, not just at entry — a stale chat route must never
					-- overwrite a fresher one a newer discover() already cached.
					if found_chat and my_discovery_gen == _discovery_gen then
						_chat_endpoint = found_chat
					end
				end)
				return
			end
			-- Completions route not found — fall through to chat so the user still
			-- gets predictions on mlx-lm builds that only expose the chat route.
			probe_one(CHAT_CANDIDATES, 1, nil, "chat", function(found_chat)
				if my_discovery_gen ~= _discovery_gen then
					Logger.debug(LOG, "Endpoint discovery: stale chat-fallback probe discarded (gen %d != %d).",
						my_discovery_gen, _discovery_gen)
					return
				end
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
	-- The inter-probe delay uses exponential backoff (1 s → 2 s → 4 s → … → 10 s)
	-- so we react quickly on fast starts while not hammering the kernel during a
	-- slow model load (weights can take 30 s+ to map into GPU memory).
	local poll_timer       = nil
	-- Backoff read from module scope, not re-initialised here. As a local it
	-- restarted at the shortest interval on every discover() call, so a cycle
	-- that gave up followed by a retry on the next run-loop tick probed as
	-- eagerly as the first attempt — a curl spawn and an HTTP POST per tick
	-- against a server that is down, with the backoff resetting each time it was
	-- supposed to grow.
	local poll_delay_sec   = _poll_delay_sec
	local function do_poll()
		-- Guard: a reset() since this cycle started makes this an ORPHANED chain.
		-- Relying on _endpoint_probe_in_flight alone is not enough — a newer
		-- discover() re-sets that flag to true, silently resurrecting this chain, and
		-- both chains then contend for the single module-level _probe_client whose
		-- adapter contract is one request at a time. Same generation guard this file
		-- already applies to its three probe callbacks (F-MED-8).
		if my_discovery_gen ~= _discovery_gen then
			if poll_timer then TimerScheduler.cancel(poll_timer) end
			poll_timer = nil
			return
		end
		-- Guard: if discovery was reset externally (model switch) while the
		-- timer was in flight, stop quietly without firing callbacks.
		if not _endpoint_probe_in_flight then
			if poll_timer then TimerScheduler.cancel(poll_timer) end
			poll_timer = nil
			return
		end
		local elapsed = TimerScheduler.now() - started_at
		if elapsed >= DISCOVERY_MAX_WAIT_SEC then
			if poll_timer then TimerScheduler.cancel(poll_timer) end
			poll_timer = nil
			Logger.warn(LOG,
				"Endpoint discovery: gave up waiting for MLX server after %.1fs. " ..
				"Falling back to default routes; warmup will keep retrying.", elapsed)
			finish_discovery(false)
			return
		end
		Logger.debug(LOG, "Endpoint discovery: polling /v1/models (elapsed=%.1fs)…", elapsed)
		-- Use curl instead of hs.http.asyncGet so we can pass --no-keepalive.
		-- Hammerspoon's HTTP client pools TCP connections and will reuse a keep-alive
		-- socket to a zombie server (whose process was kill -9'd but whose socket
		-- lingers in CLOSE_WAIT), making the poll see the zombie's stale model ID
		-- indefinitely. curl --no-keepalive forces a fresh TCP handshake every call,
		-- so the moment the zombie's socket closes the next poll reaches the new server.
		local curl_task = ShellRunner.spawn("/usr/bin/curl", {
			"--silent", "--max-time", "5", "--no-keepalive",
			"-H", "Connection: close",
			_base_url .. "/v1/models",
		}, function(exit_code, stdout, _stderr)
			if poll_timer then TimerScheduler.cancel(poll_timer) end
			poll_timer = nil
			local status = (exit_code == 0) and 200 or -1
			local body   = stdout or ""
			Logger.debug(LOG, "Endpoint discovery: /v1/models -> HTTP %s.", tostring(status))
			-- A curl already in flight when reset() ran belongs to a superseded cycle.
			-- Letting it reach run_post_probes() would POST on the SHARED _probe_client
			-- and cancel the live cycle's in-flight probe, whose callback then never
			-- fires — and since finish_discovery() is the only writer that clears the
			-- mutex, discovery deadlocks until the user switches model again.
			if my_discovery_gen ~= _discovery_gen then
				Logger.debug(LOG, "Endpoint discovery: stale poll result discarded (gen %d != %d).",
					my_discovery_gen, _discovery_gen)
				return
			end
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
				-- For the warmup payload’s "model" field, prefer _model_hf_path
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
				Logger.info(LOG, "Endpoint discovery: server reachable on /v1/models — starting POST probes.")
				run_post_probes()
			else
				-- Server not ready yet — apply exponential backoff before the next tick
				-- so we back off gracefully during a slow model-weight load.
				Logger.debug(LOG,
					"Endpoint discovery: server not ready — next probe in %.1fs.", poll_delay_sec)
				poll_timer   = TimerScheduler.after(poll_delay_sec, do_poll)
				poll_delay_sec  = math.min(poll_delay_sec * 2, DISCOVERY_POLL_MAX_SEC)
				-- Persist it: the growth has to outlive the call that earned it.
				_poll_delay_sec = poll_delay_sec
			end
		end)
		curl_task.start()
	end

	poll_timer = TimerScheduler.after(0, do_poll)
end

return M
