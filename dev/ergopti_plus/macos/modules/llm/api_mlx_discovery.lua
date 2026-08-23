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

local Logger         = require("infra.logger")
local JsonCodec      = require("adapters.json_codec")
local TimerScheduler = require("adapters.timer_scheduler")
local ShellRunner    = require("adapters.shell_runner")
local Timings        = require("infra.timings")
local ApiCommon = require("modules.llm.api_common")
local _probe_client  = require("adapters.http_client").new()  -- Dedicated client for discover() POST probes; never shares state with warmup
-- MLX log channel; every MLX line lands in ErgoptiPlus_mlx.log.
local LOG            = "llm.api_mlx"





--- ===========================================
--- ===========================================
--- ======= 1/ Route & Identifier State =======
--- ===========================================
--- ===========================================

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

-- When the last probe cycle ENDED, for the inter-cycle cooldown. A failed cycle
-- fires its queued callbacks synchronously, each of which is a warmup that
-- re-tests is_discovered() — still false on the failure path — and calls
-- discover() again inline. The new cycle then resets BOTH pacing variables, so
-- the exponential backoff never applied across cycles and the retry landed on
-- the very next run-loop tick: a curl + HTTP storm on the main thread, happening
-- exactly when the server is not answering.
local _last_cycle_finished_at   = nil
-- The pending deferred re-entry, so a burst of callers arms ONE timer.
local _cooldown_timer           = nil
-- Exact async capabilities for the current poll. They remain owned until a
-- verified cancel/terminate or their identity-matched callback completes.
local _poll_timer               = nil
local _poll_task                = nil
-- Lifecycle fence owned by api_mlx.stop_warmup(). A stopped discovery keeps
-- every late native completion inert until the matching owner explicitly resumes
local _quiesced                 = false
-- One cycle token prevents a late duplicate callback from clearing a newer
-- cycle that happens to share the same model-switch generation.
local _active_cycle             = nil
-- A failed cycle invokes every waiter. A waiter may immediately call discover()
-- again; finish the whole fan-out before dispatching one coalesced retry.
local _discovery_callbacks_draining = false
-- One synchronous infrastructure retry is allowed after fan-out. If the
-- scheduler rejects that retry too, keep the waiter queued for the next external
-- signal rather than recursing until the Lua stack overflows.
local _infrastructure_retry_in_progress = false
-- Exact owner-level settlement waiters. TimerScheduler and HttpClient can
-- report their own terminal transition; the curl task is completed through the
-- identity-matched ShellRunner callback below. A waiter is released only after
-- the whole discovery aggregate joins, never after one child settles alone.
local _settlement_waiters = {}
local retry_settlement_waiter
local notify_settlement_waiters

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
-- Minimum gap between the END of one probe cycle and the START of the next.
-- Distinct from the backoff above, which paces probes WITHIN a cycle and is reset
-- every time a cycle begins.
local DISCOVERY_RETRY_COOLDOWN_SEC  = Timings.sec("llm", "discovery_retry_cooldown_ms")

-- Seeded once the initial value is known; reset to it on a successful discovery.
_poll_delay_sec = DISCOVERY_POLL_INITIAL_SEC





--- ===========================================
--- ===========================================
--- ======= 2/ Lifecycle & Route Access =======
--- ===========================================
--- ===========================================

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


--- Reports whether after() explicitly committed one native timer while keeping
--- its cancellation handle opaque.
--- @param handle any Scheduler result.
--- @param committed any Explicit second return from TimerScheduler.after().
--- @return boolean committed True only when one timer became live.
local function timer_committed(handle, committed)
	return type(handle) == "table" and committed == true
end


--- Cancels one scheduler handle without discarding an unrevoked capability.
--- @param handle table TimerScheduler handle.
--- @param label string Stable diagnostic label.
--- @return boolean stopped True only when no live timer remains.
local function cancel_timer(handle, label)
	local ok, result = xpcall(function()
		return TimerScheduler.cancel(handle)
	end, debug.traceback)
	if not ok or result ~= true then
		Logger.error(LOG, "Cannot cancel %s timer; handle retained for retry (result: %s).",
			tostring(label), tostring(result))
		return false
	end
	return true
end


--- Terminates one poll task without losing the exact retry capability.
--- @param task table ShellRunner handle.
--- @param label string Stable diagnostic label.
--- @return boolean stopped True only when task termination committed.
local function terminate_task(task, label)
	if type(task) ~= "table" or type(task.terminate) ~= "function" then
		Logger.error(LOG, "Cannot terminate %s task; terminate() is unavailable.", tostring(label))
		return false
	end
	local ok, result, settlement = xpcall(function()
		return task.terminate()
	end, debug.traceback)
	if not ok or result ~= true then
		Logger.error(LOG, "Cannot terminate %s task; handle retained for retry (result: %s).",
			tostring(label), tostring(result))
		return false
	end
	-- ShellRunner distinguishes a delivered SIGTERM from the completion callback
	-- that proves native exit. Retain the exact task across that pending interval
	if settlement == "pending" then
		Logger.debug(LOG, "%s task termination is pending native completion.", tostring(label))
		return false
	end
	return true
end

--- Cancels every exact asynchronous capability owned by discovery.
--- @param label string Stable diagnostic operation.
--- @return boolean settled True only when no timer, task, or HTTP owner remains.
local function settle_async_owners(label)
	local poll_timer_settled = true
	local cooldown_settled = true
	local poll_task_settled = true
	local probe_settled = true

	if _poll_timer then
		poll_timer_settled = cancel_timer(_poll_timer, label .. " poll") == true
		if poll_timer_settled then _poll_timer = nil end
	end
	if _cooldown_timer then
		cooldown_settled = cancel_timer(_cooldown_timer, label .. " cooldown") == true
		if cooldown_settled then _cooldown_timer = nil end
	end
	if _poll_task then
		poll_task_settled = terminate_task(_poll_task, label .. " poll") == true
		if poll_task_settled then _poll_task = nil end
	end

	local cancel_ok, cancel_result = xpcall(function()
		if type(_probe_client.cancel) ~= "function" then return false end
		return _probe_client.cancel()
	end, debug.traceback)
	probe_settled = cancel_ok == true and cancel_result == true
	if not probe_settled then
		Logger.error(LOG, "%s POST-probe cancellation retained exact HTTP debt: %s.",
			tostring(label), tostring(cancel_result))
	end

	return poll_timer_settled and cooldown_settled
		and poll_task_settled and probe_settled
end

--- Attaches one discovery waiter to an exact timer debt.
--- @param waiter table Composite settlement token.
--- @param handle table|nil TimerScheduler handle.
--- @return boolean observed
local function observe_settlement_timer(waiter, handle)
	if type(handle) ~= "table" or handle.timer == nil then return false end
	if waiter.timers[handle] == true then return true end
	if type(TimerScheduler.onSettled) ~= "function" then return false end
	waiter.timers[handle] = true
	local observe_ok, observed = xpcall(function()
		return TimerScheduler.onSettled(handle, function()
			waiter.timers[handle] = nil
			retry_settlement_waiter(waiter)
		end)
	end, debug.traceback)
	if not observe_ok or observed ~= true then
		waiter.timers[handle] = nil
		Logger.error(LOG, "Discovery could not observe exact timer settlement: %s.",
			tostring(observed))
		return false
	end
	return true
end

--- Attaches one discovery waiter to the exact POST-probe client aggregate.
--- @param waiter table Composite settlement token.
--- @return boolean observed
local function observe_probe_settlement(waiter)
	if waiter.probe_settled == true then return false end
	if waiter.probe_observed == true then return true end
	if type(_probe_client.onSettled) ~= "function" then return false end
	waiter.probe_observed = true
	local observe_ok, observed = xpcall(function()
		return _probe_client.onSettled(function()
			waiter.probe_observed = false
			waiter.probe_settled = true
			retry_settlement_waiter(waiter)
		end)
	end, debug.traceback)
	if not observe_ok or observed ~= true then
		waiter.probe_observed = false
		Logger.error(LOG, "Discovery could not observe exact POST-probe settlement: %s.",
			tostring(observed))
		return false
	end
	return true
end

--- Observes every retained child without acquiring any successor work.
--- @param waiter table Composite settlement token.
--- @return boolean observed True when at least one debt has a terminal trigger.
local function observe_settlement_children(waiter)
	local observed = observe_settlement_timer(waiter, _poll_timer)
	if observe_settlement_timer(waiter, _cooldown_timer) then observed = true end
	-- ShellRunner has no standalone settlement port. Keeping the waiter in the
	-- module ledger lets the exact task completion callback below trigger it.
	if _poll_task ~= nil then observed = true end
	if observe_probe_settlement(waiter) then observed = true end
	return observed
end

--- Rejoins the whole discovery owner after one child becomes terminal.
--- @param waiter table Composite settlement token.
retry_settlement_waiter = function(waiter)
	if _settlement_waiters[waiter] ~= true or waiter.joining == true then return end
	waiter.joining = true
	local settled = settle_async_owners("Discovery settlement observer") == true
	waiter.joining = false
	if not settled then
		if observe_settlement_children(waiter) ~= true then
			Logger.error(LOG, "Discovery retained non-observable cleanup debt.")
		end
		return
	end

	_settlement_waiters[waiter] = nil
	ApiCommon.protected_call(waiter.callback, "discovery settlement observer")
end

--- Retries every waiter after the identity-matched curl task becomes terminal.
notify_settlement_waiters = function()
	local snapshot = {}
	for waiter in pairs(_settlement_waiters) do snapshot[#snapshot + 1] = waiter end
	for _, waiter in ipairs(snapshot) do retry_settlement_waiter(waiter) end
end

--- Registers a continuation for exact settlement of the whole discovery owner.
--- The callback runs synchronously when no timer/task/HTTP child remains, or
--- exactly once after the last retained child later reaches its terminal path.
--- @param observer function Zero-arity settlement callback.
--- @return boolean registered
function M.onSettled(observer)
	if type(observer) ~= "function" then return false end
	local waiter = {
		callback = observer,
		timers = {},
		probe_observed = false,
		probe_settled = false,
		joining = false,
	}
	_settlement_waiters[waiter] = true
	retry_settlement_waiter(waiter)
	return true
end

--- Reports whether discovery currently owns deferred or native work.
--- @return boolean active True while any discovery continuation remains owned.
function M.is_active()
	if _endpoint_probe_in_flight or _poll_timer or _poll_task or _cooldown_timer
		or #_discovery_pending_callbacks > 0 then
		return true
	end
	if type(_probe_client.isActive) ~= "function" then return false end
	local ok, active = xpcall(_probe_client.isActive, debug.traceback)
	return not ok or active == true
end

--- Fences every callback and joins all exact discovery capabilities.
--- @return boolean settled True only after every owned capability settled.
function M.stop()
	_quiesced = true
	_discovery_gen = _discovery_gen + 1
	_endpoint_probe_in_flight = false
	_active_cycle = nil
	_discovery_pending_callbacks = {}
	_last_cycle_finished_at = nil
	return settle_async_owners("Discovery stop")
end

--- Reopens discovery only after prior cleanup debt has settled.
--- @return boolean settled True when future discovery is admitted.
function M.resume()
	if settle_async_owners("Discovery resume") ~= true then return false end
	_quiesced = false
	return true
end

--- Resets the discovery state (flags, pending callbacks, model identifiers) so the
--- next warmup re-probes the live server. The cached route URLs are deliberately
--- NOT reset here — only set_base_url() rewrites them — so a server relaunch on the
--- same port keeps the last-known routes until a fresh probe overrides them.
function M.reset()
	_endpoints_discovered        = false
	_endpoint_probe_in_flight    = false
	_active_cycle                = nil
	_discovery_pending_callbacks = {}
	_server_model_id             = nil
	_expected_model_id           = nil
	_model_hf_path               = nil
	-- Invalidate any in-flight discover() cycle (including its opportunistic
	-- background chat-route probe) so a stale response cannot overwrite the
	-- routes the NEXT discovery cycle caches (F-MED-8).
	_discovery_gen = _discovery_gen + 1
	-- The inter-cycle cooldown goes with it. reset() means the server changed —
	-- a relaunch, a model switch — so the next probe is about a DIFFERENT server
	-- and must not be held back by how the previous one failed. Keeping the
	-- timestamp here would make a model switch wait out a cooldown earned by the
	-- model the user just left.
	_last_cycle_finished_at = nil
	return settle_async_owners("Discovery reset")
end





--- =====================================
--- =====================================
--- ======= 3/ Endpoint Discovery =======
--- =====================================
--- =====================================

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
	if _quiesced then
		Logger.debug(LOG, "Discovery skipped — lifecycle owner is quiesced.")
		return false
	end
	if _is_paused() then
		Logger.debug(LOG, "Discovery skipped — script is paused.")
		return false
	end
	if _endpoints_discovered then
		if type(on_done) == "function" then ApiCommon.protected_call(on_done, "on_done") end
		return true
	end
	-- Enqueue the callback so it fires when the in-flight probe completes —
	-- previously we returned silently here, dropping the caller's on_done and
	-- causing every warmup issued during the server boot window to be lost.
	local callback_index
	if type(on_done) == "function" then
		_discovery_pending_callbacks[#_discovery_pending_callbacks + 1] = on_done
		callback_index = #_discovery_pending_callbacks
	end
	local function withdraw_unaccepted_callback()
		if callback_index
			and _discovery_pending_callbacks[callback_index] == on_done then
			table.remove(_discovery_pending_callbacks, callback_index)
		end
	end
	if _discovery_callbacks_draining then return true end
	if _endpoint_probe_in_flight then return true end
	-- A prior reset or failed launch can retain an exact native capability when
	-- cancellation itself refused. Retry that cleanup before starting a sibling
	-- poll; otherwise two curl tasks can race the same route cache.
	if _poll_timer then
		if cancel_timer(_poll_timer, "stale discovery poll") then
			_poll_timer = nil
		else
			withdraw_unaccepted_callback()
			return false
		end
	end
	if _poll_task then
		if terminate_task(_poll_task, "stale discovery poll") then
			_poll_task = nil
		else
			withdraw_unaccepted_callback()
			return false
		end
	end

	-- Inter-cycle cooldown. Owned here rather than at the one caller that
	-- re-enters, because every caller of discover() would otherwise have to
	-- remember it — and the queued-callback path that caused the storm is not the
	-- only way in.
	--
	-- The cycle is DEFERRED, never dropped: the caller's on_done is already queued
	-- above, so refusing outright would strand it. Re-entering through
	-- TimerScheduler keeps the contract and only moves it later.
	if _last_cycle_finished_at then
		local waited = TimerScheduler.now() - _last_cycle_finished_at
		if waited < DISCOVERY_RETRY_COOLDOWN_SEC then
			if not _cooldown_timer then
				local remaining = DISCOVERY_RETRY_COOLDOWN_SEC - waited
				Logger.debug(LOG, "Discovery retry deferred %.2fs by the inter-cycle cooldown.", remaining)
				local generation = _discovery_gen
				local candidate
				local arm_committed
				local ok, result = xpcall(function()
					candidate, arm_committed = TimerScheduler.after(remaining, function()
						if _cooldown_timer ~= candidate then return end
						if candidate.timer ~= nil then
							Logger.error(LOG, "Discovery cooldown fired with exact timer cleanup debt retained.")
							return
						end
						_cooldown_timer = nil
						if generation ~= _discovery_gen then return end
						-- nil so this re-entry cannot be deferred again by the same window.
						_last_cycle_finished_at = nil
						M.discover()
					end)
					return candidate
				end, debug.traceback)
				if ok and timer_committed(result, arm_committed) then
					_cooldown_timer = result
				else
					-- A table result is an opaque capability that may still own a
					-- timer. Revoke it through the port; retain it only when the
					-- adapter explicitly reports that cancellation failed.
					if type(result) == "table"
						and not cancel_timer(result, "invalid discovery cooldown") then
						_cooldown_timer = result
					end
					Logger.error(LOG,
						"Discovery cooldown timer did not commit (result: %s, committed: %s).",
						tostring(result), tostring(arm_committed))
				end
				if not _cooldown_timer then
					_last_cycle_finished_at = nil
				end
			end
			if _cooldown_timer then return true end
		end
	end

	_endpoint_probe_in_flight = true
	local cycle = {}
	_active_cycle = cycle
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

	local function finish_discovery(success, record_cooldown)
		if cycle ~= _active_cycle or my_discovery_gen ~= _discovery_gen then return false end
		-- Stop the poll timer before firing callbacks so a callback that calls
		-- reset() + discover() again does not find the timer
		-- still running and incorrectly skip starting a fresh one.
		_endpoint_probe_in_flight = false
		_active_cycle             = nil
		if record_cooldown == false then
			_last_cycle_finished_at = nil
		else
			_last_cycle_finished_at = TimerScheduler.now()
		end
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
		local was_draining = _discovery_callbacks_draining
		_discovery_callbacks_draining = true
		for _, cb in ipairs(cbs) do ApiCommon.protected_call(cb, "discovery on_done") end
		_discovery_callbacks_draining = was_draining

		-- api_mlx.warmup() is itself one of these callbacks. On failure it
		-- immediately calls discover() again, which was queued by the draining
		-- guard above. Dispatch that queue only AFTER every original waiter ran so
		-- one callback cannot overtake or strand its siblings.
		if #_discovery_pending_callbacks > 0 then
			local infrastructure_failure = record_cooldown == false
			if not infrastructure_failure or not _infrastructure_retry_in_progress then
				if infrastructure_failure then _infrastructure_retry_in_progress = true end
				local retry_ok, retry_err = xpcall(function() M.discover() end, debug.traceback)
				if infrastructure_failure then _infrastructure_retry_in_progress = false end
				if not retry_ok then
					Logger.error(LOG, "Discovery callback retry dispatch raised: %s.", tostring(retry_err))
				end
			end
		end
		return true
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
	-- Backoff read from module scope, not re-initialised here. As a local it
	-- restarted at the shortest interval on every discover() call, so a cycle
	-- that gave up followed by a retry on the next run-loop tick probed as
	-- eagerly as the first attempt — a curl spawn and an HTTP POST per tick
	-- against a server that is down, with the backoff resetting each time it was
	-- supposed to grow.
	local poll_delay_sec = _poll_delay_sec
	local do_poll

	--- Arms one identity-checked poll timer through the strict scheduler contract.
	--- @param delay number Seconds before the poll.
	--- @param stage string Stable diagnostic label.
	--- @return boolean committed True only when the timer is live and owned.
	local function schedule_poll(delay, stage)
		if _poll_timer then
			if cancel_timer(_poll_timer, stage .. " predecessor poll") ~= true then
				return false
			end
			_poll_timer = nil
		end
		local candidate
		local arm_committed
		local ok, result = xpcall(function()
			candidate, arm_committed = TimerScheduler.after(delay, function()
				if _poll_timer ~= candidate then return end
				if candidate.timer ~= nil then
					Logger.error(LOG, "Discovery poll fired with exact timer cleanup debt retained.")
					return
				end
				_poll_timer = nil
				if cycle ~= _active_cycle or my_discovery_gen ~= _discovery_gen then return end
				local callback_ok, callback_err = xpcall(do_poll, debug.traceback)
				if not callback_ok then
					Logger.error(LOG, "Discovery %s poll callback raised: %s.",
						tostring(stage), tostring(callback_err))
					finish_discovery(false, false)
				end
			end)
			return candidate
		end, debug.traceback)
		if not ok or not timer_committed(result, arm_committed) then
			-- A table result is an opaque capability that may still own a timer.
			-- Revoke it through the port; if the adapter explicitly refuses, publish
			-- that exact handle so reset()/the next discover() can retry cancellation.
			if type(result) == "table" and not cancel_timer(result, stage .. " invalid poll") then
				_poll_timer = result
			end
			Logger.error(LOG, "Discovery %s poll timer did not commit (result: %s, committed: %s).",
				tostring(stage), tostring(result), tostring(arm_committed))
			return false
		end
		_poll_timer = result
		return true
	end

	do_poll = function()
		-- Guard: a reset() since this cycle started makes this an ORPHANED chain.
		-- Relying on _endpoint_probe_in_flight alone is not enough — a newer
		-- discover() re-sets that flag to true, silently resurrecting this chain, and
		-- both chains then contend for the single module-level _probe_client whose
		-- adapter contract is one request at a time. Same generation guard this file
		-- already applies to its three probe callbacks (F-MED-8).
		if my_discovery_gen ~= _discovery_gen or cycle ~= _active_cycle then return end
		-- Guard: if discovery was reset externally (model switch) while the
		-- timer was in flight, stop quietly without firing callbacks.
		if not _endpoint_probe_in_flight then return end
		local elapsed = TimerScheduler.now() - started_at
		if elapsed >= DISCOVERY_MAX_WAIT_SEC then
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
		-- Forward-declare so the completion closure captures this local capability.
		local curl_task
		local spawn_ok, spawned_or_err = xpcall(function()
			curl_task = ShellRunner.spawn("/usr/bin/curl", {
				"--silent", "--max-time", "5", "--no-keepalive",
				"-H", "Connection: close",
				_base_url .. "/v1/models",
			}, function(exit_code, stdout, _stderr)
				-- Only the callback for the exact published task may release it.
				if _poll_task ~= curl_task then return end
				_poll_task = nil
				notify_settlement_waiters()
				if my_discovery_gen ~= _discovery_gen or cycle ~= _active_cycle then return end

				local callback_ok, callback_err = xpcall(function()
					local status = (exit_code == 0) and 200 or -1
					local body   = stdout or ""
					Logger.debug(LOG, "Endpoint discovery: /v1/models -> HTTP %s.", tostring(status))
					if not _endpoint_probe_in_flight then return end
					if status == 200 then
						-- /v1/models lists the cache, not the currently loaded model.
						-- Reachability is the only fact this response commits.
						_server_model_id = nil
						if type(body) == "string" and type(_expected_model_id) == "string"
							and _expected_model_id ~= "" then
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
						-- Server not ready yet — apply exponential backoff before the next tick.
						Logger.debug(LOG,
							"Endpoint discovery: server not ready — next probe in %.1fs.", poll_delay_sec)
						if not schedule_poll(poll_delay_sec, "rearm") then
							finish_discovery(false, false)
							return
						end
						poll_delay_sec = math.min(poll_delay_sec * 2, DISCOVERY_POLL_MAX_SEC)
						-- Persist growth only after the new timer owns the continuation.
						_poll_delay_sec = poll_delay_sec
					end
				end, debug.traceback)
				if not callback_ok then
					Logger.error(LOG, "Discovery poll completion callback raised: %s.", tostring(callback_err))
					finish_discovery(false, false)
				end
			end)
			return curl_task
		end, debug.traceback)

		if not spawn_ok or type(spawned_or_err) ~= "table"
			or type(spawned_or_err.start) ~= "function" then
			Logger.error(LOG, "Discovery poll task construction did not commit (result: %s).",
				tostring(spawned_or_err))
			finish_discovery(false, false)
			return
		end

		_poll_task = spawned_or_err
		local start_ok, start_result = xpcall(function()
			return spawned_or_err.start()
		end, debug.traceback)
		if not start_ok or start_result ~= true then
			if terminate_task(spawned_or_err, "uncommitted discovery poll")
				and _poll_task == spawned_or_err then
				_poll_task = nil
			end
			Logger.error(LOG, "Discovery poll task start did not commit (result: %s).",
				tostring(start_result))
			finish_discovery(false, false)
		end
	end

	if not schedule_poll(0, "initial") then
		finish_discovery(false, false)
		return false
	end
	return true
end

return M
