--- modules/llm/init.lua

--- ==============================================================================
--- MODULE: LLM Prediction Engine Core
--- DESCRIPTION:
--- Coordinates communication with the local Ollama/MLX API through decoupled API, 
--- Profiles, and Parsing engines.
--- ==============================================================================

local M = {}

local hs        = hs
local Profiles  = require("modules.llm.profiles")
local ApiOllama = require("modules.llm.api_ollama")
local ApiMlx    = require("modules.llm.api_mlx")
local ApiRemote = require("modules.llm.api_remote")
local Logger    = require("infra.logger")
local Paths     = require("infra.paths")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "llm.core"

M.BUILTIN_PROFILES = Profiles.BUILTIN_PROFILES





-- =======================================
-- =======================================
-- ======= 1/ Constants & Defaults =======
-- =======================================
-- =======================================

--- Shared scalar/boolean defaults: keys that live in _shared/modules/llm/defaults.json
--- under the same name on every driver. Sourced EXCLUSIVELY from the JSON — the
--- values are never re-declared here (rule 5.2 single source of truth).
local _SHARED_SCALAR_KEYS = {
	"llm_enabled", "llm_active_profile", "llm_temperature",
	"llm_num_predictions", "llm_context_length", "llm_min_words",
	"llm_max_words", "llm_pred_indent", "llm_show_info_bar",
	"llm_streaming", "llm_streaming_multi", "llm_instant_on_word_end",
	"llm_after_hotstring", "llm_reset_on_nav", "llm_auto_raise_temp",
	"llm_ollama_port",
	-- Privacy gates for the prediction path. These were absent from this list AND
	-- hardcoded to true in prediction_engine.lua, so the shared value was
	-- unreachable and the two drivers shipped opposite defaults for the same
	-- setting. The canonical posture now lives in defaults.json: password/secure
	-- fields blocked, URL bars allowed.
	"llm_disable_password_fields", "llm_disable_url_bars",
}

--- HS-only defaults: keys intentionally NOT in the cross-platform defaults.json
--- (the chosen backend, the per-backend model names, the macOS sequential/arrow
--- toggles). These are the single source for macOS — not duplicated in the
--- shared JSON, so there is no cross-driver drift to eliminate here.
local _HS_ONLY_DEFAULTS = {
	llm_backend           = "ollama",
	llm_model_ollama      = "gemma-4-E2B-it",
	llm_model_mlx         = "Qwen3.5-2B",
	llm_sequential_mode   = false,
	llm_arrow_nav_enabled = false,
}

--- Loads the cross-platform defaults.json and layers its values onto the HS-only
--- defaults. The JSON is REQUIRED: a missing/unparseable file, or any missing
--- shared key, is a broken install and fails loudly (rule 5.3/5.4 — no silent
--- hardcoded fallback for the shared values).
--- @return table The fully-populated DEFAULT_STATE table.
local function load_shared_defaults()
	-- Resolved through the single shared-tree resolver (Paths.shared), which
	-- performs the dual-root upward walk so it is deterministic in production
	-- and in headless tests alike — independent of hs.configdir layout.
	local raw, used = nil, nil
	local p = Paths.shared("modules/llm/defaults.json")
	if type(p) == "string" and p ~= "" then
		local fh = io.open(p, "r")
		if fh then raw = fh:read("*a"); fh:close(); used = p end
	end

	if not raw or raw == "" then
		Logger.error(LOG, "_shared/modules/llm/defaults.json not found on any candidate path — LLM defaults cannot be initialised.")
		error("ergopti_plus: _shared/modules/llm/defaults.json is required but was not found")
	end

	local ok, parsed = pcall(hs.json.decode, raw)
	if not ok or type(parsed) ~= "table" then
		Logger.error(LOG, "_shared/modules/llm/defaults.json (%s) could not be parsed — LLM defaults cannot be initialised.", tostring(used))
		error("ergopti_plus: _shared/modules/llm/defaults.json failed to parse")
	end

	-- Start from the HS-only defaults, then layer every shared value on top.
	local merged = {}
	for k, v in pairs(_HS_ONLY_DEFAULTS) do merged[k] = v end

	local missing = {}
	for _, key in ipairs(_SHARED_SCALAR_KEYS) do
		if parsed[key] == nil then
			missing[#missing + 1] = key
		else
			merged[key] = parsed[key]
		end
	end

	-- Modifier arrays: shared stores ["alt"] / [] — copied verbatim.
	for _, key in ipairs({ "llm_val_modifiers", "llm_nav_modifiers" }) do
		if type(parsed[key]) ~= "table" then
			missing[#missing + 1] = key
		else
			merged[key] = parsed[key]
		end
	end

	-- llm_debounce: shared stores llm_debounce_ms (ms); macOS uses seconds.
	if type(parsed.llm_debounce_ms) ~= "number" then
		missing[#missing + 1] = "llm_debounce_ms"
	else
		merged.llm_debounce = parsed.llm_debounce_ms / 1000
	end

	if #missing > 0 then
		Logger.error(LOG, "_shared/modules/llm/defaults.json is missing required key(s): %s — LLM defaults incomplete.", table.concat(missing, ", "))
		error("ergopti_plus: _shared/modules/llm/defaults.json is missing required key(s): " .. table.concat(missing, ", "))
	end

	Logger.done(LOG, "Shared LLM defaults loaded from defaults.json (%s).", tostring(used))
	return merged
end

M.DEFAULT_STATE = load_shared_defaults()

-- Single source of truth for the streaming flag; backends receive it as a parameter
-- on each fetch call so they hold no state of their own for this flag
local _streaming_enabled = M.DEFAULT_STATE.llm_streaming

local CoreState = {
	active_profile_id      = M.DEFAULT_STATE.llm_active_profile,
	user_profiles          = {},
	backend                = M.DEFAULT_STATE.llm_backend,
	-- Seed per-backend model names from DEFAULT_STATE so get_current_model()
	-- returns a non-nil string before any setter is called (e.g. on a fresh
	-- install where no llm_model_* key is persisted yet).
	llm_model_ollama       = M.DEFAULT_STATE.llm_model_ollama,
	llm_model_mlx          = M.DEFAULT_STATE.llm_model_mlx,
	runtime_llm_enabled    = false,
	background_bootstrap_started = false,
	last_backend_check     = 0,
	backend_check_interval = 10,
	-- Monotonically-increasing counter that lets on_both_done() discard stale
	-- probe results when set_backend() is called while probes are in-flight
	detection_generation   = 0,
	-- Set to true when the user explicitly picks a backend; prevents any future
	-- auto_detect_backend() call from silently overwriting the manual choice
	user_override_backend  = false,
	-- Bumped by set_backend(); lets set_active_profile()'s deferred (0-delay
	-- timer) warmup discard itself if the backend was switched within the
	-- same tick — otherwise the deferred callback would dispatch a stale
	-- model name (captured against the OLD backend) to the NEW backend's
	-- warmup() (F-MED-6). Mirrors detection_generation's pattern.
	backend_generation     = 0,
}





-- =====================================
-- =====================================
-- ======= 2/ Core Orchestration =======
-- =====================================
-- =====================================

--- Auto-detect best available backend and set it as active.
--- Uses async HTTP checks — never blocks the main thread.
--- @param callback function|nil Optional callback(backend_name) called when detection completes.
function M.auto_detect_backend(callback)
	local now = hs.timer.secondsSinceEpoch()

	-- Return cached result immediately if checked recently (within 10s)
	if now - CoreState.last_backend_check < CoreState.backend_check_interval then
		local result = CoreState.backend
		if type(callback) == "function" then pcall(callback, result) end
		return result
	end

	CoreState.last_backend_check = now

	-- Capture the generation before launching probes so the closure can detect
	-- whether set_backend() was called while the probes were in-flight; if it
	-- was, the counter will have been bumped and our result is now stale
	local my_generation = CoreState.detection_generation + 1
	CoreState.detection_generation = my_generation

	-- Async parallel health checks — both fire at once, state resolved in callbacks
	local ollama_done, mlx_done = false, false
	local ollama_ok, mlx_ok = false, false

	local function on_both_done()
		if not (ollama_done and mlx_done) then return end
		-- Discard if an explicit set_backend() call superseded this probe run
		if CoreState.detection_generation ~= my_generation then
			Logger.debug(LOG, "auto_detect: stale detection result, ignoring.")
			return
		end
		if CoreState.user_override_backend then
			Logger.debug(LOG, "auto_detect: user has set a manual backend override — skipping automatic write.")
			return
		end
		-- Prefer Ollama if both available, otherwise use MLX if available
		if ollama_ok then
			CoreState.backend = "ollama"
			-- Ensure the Ollama daemon is running now that we know it is the active
			-- backend — doing this at api_ollama require-time would launch Ollama for
			-- MLX/API users who never selected it.
			pcall(function() ApiOllama.ensure_running() end)
		elseif mlx_ok then
			CoreState.backend = "mlx"
		else
			CoreState.backend = "inconnu"
		end

		if type(callback) == "function" then pcall(callback, CoreState.backend) end
	end

	-- pcall's boolean result must be checked: if hs.http.asyncGet throws
	-- SYNCHRONOUSLY (e.g. a malformed URL), its callback never fires and the
	-- discarded failure left ollama_done/mlx_done stuck at false forever —
	-- on_both_done() never completes and auto_detect_backend()'s callback is
	-- silently dropped. Mark the leg done+failed instead, mirroring the
	-- pattern already used in adapters/http_client.lua's post()/get() (F-MED-5).
	local ollama_probe_ok = pcall(hs.http.asyncGet, "http://127.0.0.1:11434/api/version", {}, function(status, body)
		ollama_ok = (status == 200) and type(body) == "string" and body:find('"version"') ~= nil
		ollama_done = true
		on_both_done()
	end)
	if not ollama_probe_ok then
		Logger.error(LOG, "auto_detect_backend: hs.http.asyncGet threw synchronously for the Ollama probe.")
		ollama_ok   = false
		ollama_done = true
		on_both_done()
	end

	-- The MLX probe follows the configured port via api_mlx.get_base_url() — the
	-- single source of truth. ApiMlx is required at the top of this file, so no
	-- local re-require and no hardcoded port literal here.
	local mlx_models_url = ApiMlx.get_base_url() .. "/v1/models"
	local mlx_probe_ok = pcall(hs.http.asyncGet, mlx_models_url, {}, function(status, body)
		mlx_ok = (status == 200) and type(body) == "string" and body:find('"object"') ~= nil
		mlx_done = true
		on_both_done()
	end)
	if not mlx_probe_ok then
		Logger.error(LOG, "auto_detect_backend: hs.http.asyncGet threw synchronously for the MLX probe.")
		mlx_ok   = false
		mlx_done = true
		on_both_done()
	end
end

--- Pre-warms TCP connections to both backends (async, non-blocking).
--- This establishes the loopback socket but does NOT load the model into GPU memory.
--- Call warmup_model() separately once the model name is known.
function M.warm_up_connections()
	pcall(function()
		-- Parallel async pings to both backends (fire-and-forget). The MLX URL
		-- follows the configured port via api_mlx.get_base_url() (required at the
		-- top of this file) — the single source of truth, no hardcoded port.
		hs.http.asyncGet("http://127.0.0.1:11434/api/version", {}, function() end)
		hs.http.asyncGet(ApiMlx.get_base_url() .. "/v1/models", {}, function() end)
	end)
end

--- Returns the active API engine based on the current backend state.
--- Defined here (early in the file) because warmup_model and cancel_streaming
--- need to reference it; Lua locals are only visible after their declaration,
--- so placing this later silently turns get_api into a nil global lookup that
--- fails the first time it is called.
--- @return table The specific backend module object.
local function get_api()
	if CoreState.backend == "mlx" then
		return ApiMlx
	end
	if CoreState.backend == "api" then
		return ApiRemote
	end
	return ApiOllama
end

-- Expose the remote backend module so the menu / settings layer can configure
-- entries (CRUD, active id) and call ``M.warmup_model`` immediately after,
-- without going through the engine dispatcher. Kept as a direct field so the
-- menu doesn't have to require the module separately and risk pulling a
-- stale copy of the entry list.
M.api_remote = ApiRemote

-- Persistence keys for the remote API multi-entry state. These mirror the
-- ``api_entries.json`` / ``api_entry_id`` slots on the AHK side; on HS we
-- piggyback on ``hs.settings`` (the same store the rest of the LLM module
-- uses for debounce / temperature / etc.) so there's a single durable
-- backing store across reloads. The token field is persisted as an
-- opaque ``keychain:<id>`` reference, not the cleartext — see
-- modules/llm/api_token_crypto.lua.
local API_ENTRIES_KEY    = "llm_api_entries"
local API_ENTRY_ID_KEY   = "llm_api_entry_id"
local TokenCrypto = require("modules.llm.api_token_crypto")
local ApiCommon = require("modules.llm.api_common")

--- Load persisted API entries from hs.settings and seed the remote backend.
--- Idempotent — calling it more than once just refreshes the in-memory state
--- from the durable store (useful right after the menu writes a new entry).
--- Tokens stored as ``keychain:<id>`` references are decrypted via the
--- macOS Keychain so callers always see cleartext.
function M.load_api_entries()
	local entries = hs.settings.get(API_ENTRIES_KEY)
	local active_id = hs.settings.get(API_ENTRY_ID_KEY)
	if type(entries) == "table" then
		-- Tokens stored as keychain:<id> references are resolved lazily on first
		-- use inside ApiRemote.get_active_entry() to avoid blocking Keychain
		-- subprocess calls on the boot or load tick.
		ApiRemote.set_entries(entries)
	end
	if type(active_id) == "string" then
		ApiRemote.set_active_entry_id(active_id)
	end
	-- Pre-warm the active entry's decrypted token cache asynchronously so a
	-- LATER call to ApiRemote.get_active_entry() from a warmup or
	-- first-prediction timer callback almost always hits the cached
	-- cleartext instead of shelling out to `security` synchronously — a
	-- locked Keychain there would otherwise freeze the whole run loop on a
	-- modal unlock prompt (F-MED-9). This call itself is already off the
	-- boot path (load_api_entries is deferred via TimerScheduler.after(0,…)
	-- below), so the extra async hop here costs nothing at boot.
	pcall(ApiRemote.prewarm_active_entry_decrypt)
end

--- Persist the current API entry list + active id to hs.settings. Called by
--- the menu's CRUD actions after each mutation; keeping the write here means
--- the menu doesn't have to know the storage scheme. Each token is
--- encrypted (Keychain reference) before being written to the plist so the
--- cleartext never lands on disk.
function M.persist_api_entries()
	local cleartext_entries = ApiRemote.get_entries() or {}
	local serialised = {}
	for _, e in ipairs(cleartext_entries) do
		local copy = {}
		for k, v in pairs(e) do copy[k] = v end
		if type(copy.token) == "string" and copy.token ~= "" and type(copy.id) == "string" then
			copy.token = TokenCrypto.encrypt(copy.id, copy.token)
		end
		table.insert(serialised, copy)
	end
	pcall(function() hs.settings.set(API_ENTRIES_KEY,  serialised) end)
	pcall(function() hs.settings.set(API_ENTRY_ID_KEY, ApiRemote.get_active_entry_id()) end)
end

-- Restore persisted state before the first prediction can fire. The hs.settings
-- READ is cheap, but load_api_entries also DECRYPTS each keychain-referenced
-- token via a BLOCKING `security find-generic-password` shell-out (and can raise
-- a modal Keychain-unlock prompt). Running that synchronously on the require path
-- blocked boot BEFORE the keyboard eventtap was even created — N stored entries =
-- N blocking subprocess spawns, and a locked Keychain froze the whole run loop on
-- a modal prompt. Defer it past tap creation with doAfter(0): it still runs on the
-- very next run-loop tick, long before any keystroke can trigger a prediction, but
-- no longer gates eventtap setup. Routed through the TimerScheduler adapter (not a
-- raw timer call) per the module OS-API purity convention.
TimerScheduler.after(0, function() pcall(M.load_api_entries) end)

--- Primes the backend model and its KV cache with the active profile's system prompt.
--- Must be called after both model and profile are configured; runs async so it does
--- not block the caller.
--- @param model_name string The backend-specific model identifier.
--- @param profile table|nil The active profile object; omit to use a minimal ping.
function M.warmup_model(model_name, profile)
	if type(model_name) ~= "string" or model_name == "" then
		Logger.debug(LOG, "warmup_model: skipped — model_name is empty.")
		return
	end
	-- « pause = tout éteint » applies to warmups the USER starts too. Switching
	-- profile or model from the menu during a pause funnels through here, and
	-- api_mlx's own _warmup_stopped flag only short-circuits its self-rescheduling
	-- retry chain — a freshly dispatched warmup sails past it, and Ollama has no
	-- such flag at all by design. Read through package.loaded rather than
	-- require() to avoid a circular dependency, exactly as the prediction engine
	-- does for the same question.
	local sc = package.loaded["modules.shortcuts.script_control"]
	if sc and type(sc.is_paused) == "function" and sc.is_paused() then
		Logger.debug(LOG, "warmup_model: paused — '%s' stays cold until resume.", tostring(model_name))
		return
	end

	local resolved_profile = profile or M.get_active_profile()
	Logger.debug(LOG, "warmup_model: dispatching to backend '%s' for model '%s'.",
		tostring(CoreState.backend), tostring(model_name))
	local ok, err = pcall(function() get_api().warmup(model_name, resolved_profile) end)
	if not ok then
		Logger.warn(LOG, "warmup_model: backend warmup raised: %s", tostring(err))
	end
end

--- Returns true when the active backend has confirmed it can answer inference
--- requests (model loaded, server responsive). The prediction engine uses this
--- to gate the loading tooltip and request dispatch — without it, the spinner
--- shows even while the MLX server is still loading model weights and would
--- never produce a prediction in time.
--- @return boolean
function M.is_backend_ready()
	local api = get_api()
	if type(api.is_ready) ~= "function" then return true end
	return api.is_ready() == true
end

--- Returns true when the active backend has GIVEN UP loading the current model
--- (warmup budget exhausted, or an incompatible architecture was reported). The
--- menu uses this to paint the status dot RED instead of leaving it on the orange
--- "still loading" colour forever. Backends without this concept (e.g. Ollama)
--- report false.
--- @return boolean
function M.is_backend_load_failed()
	local api = get_api()
	if type(api.is_load_failed) ~= "function" then return false end
	return api.is_load_failed() == true
end

--- Retrieves the currently active profile object.
--- @return table The active profile object.
function M.get_active_profile()
	return Profiles.get_active_profile(CoreState.active_profile_id, CoreState.user_profiles)
end

--- Updates the active profile ID and re-primes the KV cache for the new profile's
--- system prompt so the first request after a profile switch benefits from the cache.
--- @param id string The ID of the profile to activate.
function M.set_active_profile(id)
	if type(id) ~= "string" then return end
	CoreState.active_profile_id = id
	if not CoreState.runtime_llm_enabled then
		Logger.debug(LOG, "set_active_profile: runtime LLM disabled — skipping warmup for '%s'.", tostring(id))
		return
	end
	-- Re-prime the KV cache: the new profile may have a different static prompt prefix
	local model = M.get_current_model()
	if type(model) == "string" and model ~= "" then
		local new_profile = M.get_active_profile()
		-- Capture the backend generation now so the deferred warmup below can
		-- detect a set_backend() call that lands within the same tick and
		-- discard itself instead of dispatching `model` (resolved against the
		-- OLD backend) to the NEW backend's warmup() (F-MED-6).
		local my_backend_generation = CoreState.backend_generation
		hs.timer.doAfter(0, function()
			if CoreState.backend_generation ~= my_backend_generation then
				Logger.debug(LOG, "set_active_profile: backend switched before deferred warmup fired — discarding stale dispatch for '%s'.",
					tostring(model))
				return
			end
			pcall(M.warmup_model, model, new_profile)
		end)
	end
end

--- Enables or disables token-by-token streaming.
--- The flag is stored here and passed to backends at dispatch time — no backend state.
--- @param v boolean True to enable streaming, false to disable.
function M.set_llm_streaming(v)
	_streaming_enabled = (v == true)
	Logger.debug(LOG, "Streaming: %s.", _streaming_enabled and "on" or "off")
end

--- Cancels the in-flight streaming task on the active backend, if any.
--- Called when a new request supersedes the current stream.
function M.cancel_streaming()
	local ok, result = xpcall(function()
		return get_api().cancel_streaming()
	end, debug.traceback)
	if not ok or result ~= true then
		Logger.error(LOG, "Backend stream cancellation did not commit (result: %s).", tostring(result))
		return false
	end
	return true
end

--- Sets the active LLM backend identifier.
--- Bumps the detection generation so any in-flight auto_detect_backend() probe
--- that resolves after this call treats its result as stale and discards it.
--- @param backend string The backend identifier (e.g., "mlx", "ollama").
function M.set_backend(backend)
	if type(backend) == "string" and backend ~= "" then
		-- Invalidate in-flight auto-detect probes before writing the new value
		CoreState.detection_generation = CoreState.detection_generation + 1
		-- Invalidate any deferred set_active_profile() warmup scheduled against
		-- the OLD backend (F-MED-6) — see backend_generation's declaration comment.
		CoreState.backend_generation   = CoreState.backend_generation + 1
		CoreState.backend = backend
		-- Prevent any future auto-detection from overwriting this explicit choice
		CoreState.user_override_backend = true
		-- Any backend transition forces a fresh Ollama readiness verdict: leaving MLX
		-- kills `ollama serve`, and returning relaunches it async (not yet listening).
		-- Without this, a stale-true _is_ready would make the warmup chain self-terminate
		-- and predictions dispatch to a cold/dead server (F-M8). ensure_running launches
		-- the daemon but must NEVER imply readiness.
		pcall(function() ApiOllama.reset_ready() end)
		if backend == "ollama" then
			pcall(function() ApiOllama.ensure_running() end)
		end
		-- Convention 5.5: a public setter logs its new value, so the applied
		-- backend can be read back from the logs like every other setting.
		Logger.debug(LOG, "Backend: %s.", backend)
	else
		Logger.warn(LOG, "set_backend(): ignoring invalid backend %s.", tostring(backend))
	end
end

--- Returns the currently active LLM backend identifier.
--- @return string The backend identifier.
function M.get_backend()
	return CoreState.backend or "inconnu"
end

--- Tracks whether the runtime prediction engine currently allows LLM activity.
--- This is intentionally distinct from persisted/default config so startup can
--- restore profile/model state without triggering a backend warmup.
--- @param enabled boolean True when runtime LLM activity is enabled.
function M.set_runtime_llm_enabled(enabled)
	CoreState.runtime_llm_enabled = (enabled == true)
	-- This flag is the ONE gate that authorises a model load or a warmup, so its
	-- transitions are exactly what a "why did it warm up while disabled?" report
	-- needs from the log. It was the only writer of it that said nothing.
	Logger.debug(LOG, "Runtime LLM gate: %s.", CoreState.runtime_llm_enabled and "enabled" or "disabled")
end

--- Returns the current runtime LLM enabled state.
--- @return boolean
function M.get_runtime_llm_enabled()
	return CoreState.runtime_llm_enabled == true
end

--- Schedules the background backend probes explicitly once boot state has
--- confirmed that LLM is actually enabled for this session.
function M.start_background_network_bootstrap()
	if CoreState.background_bootstrap_started then
		Logger.debug(LOG, "start_background_network_bootstrap: already started — skipping duplicate call.")
		return
	end
	CoreState.background_bootstrap_started = true
	Logger.debug(LOG, "Scheduling background LLM network bootstrap.")
	hs.timer.doAfter(0, function()
		pcall(function() M.auto_detect_backend() end)
		pcall(function() M.warm_up_connections() end)
	end)
end

-- Flat index: { [label] = { ollama = "...", mlx = "..." } } — built once from JSON
local _model_index = nil

--- Builds and caches a flat O(1) lookup index from _shared/modules/llm/models.json.
--- @return table The index keyed by model label.
local function get_model_index()
	if _model_index then return _model_index end
	local Paths = require("infra.paths")
	local path = Paths.shared_llm_path("models.json")
	local presets = {}
	if path then
		local ok, fh = pcall(io.open, path, "r")
		if ok and fh then
			local raw = fh:read("*a")
			pcall(function() fh:close() end)
			local dec_ok, data = pcall(hs.json.decode, raw)
			if dec_ok and type(data) == "table" then presets = data end
		end
	end
	-- Flatten all models into a single index keyed by label
	local index = {}
	for _, provider in ipairs(presets) do
		for _, family in ipairs(provider.families or {}) do
			for _, m in ipairs(family.models or {}) do
				if type(m) == "table" and type(m.name) == "string" then
					local ollama_url = m.urls and m.urls.ollama or ""
					local mlx_url    = m.urls and m.urls.mlx    or ""
					index[m.name] = {
						ollama = (ollama_url ~= "" and ollama_url:match("/([^/]+)$")) or nil,
						mlx    = (mlx_url    ~= "" and mlx_url:match("/([^/]+)$"))    or nil,
					}
				end
			end
		end
	end
	_model_index = index
	return index
end

--- Translates a JSON model label to the backend-specific identifier in O(1).
--- e.g., "gemma-4-E2B-it" -> "gemma4:e2b" (Ollama) or "gemma-4-e2b-it-mxfp4" (MLX)
--- @param label string The model label ("name" field from _shared/modules/llm/models.json).
--- @param backend string The target backend identifier.
--- @return string The backend-specific identifier, or label unchanged if not found.
local function resolve_model_for_backend(label, backend)
	if type(label) ~= "string" or label == "" then return label end
	local entry = get_model_index()[label]
	if not entry then return label end
	return (entry[backend]) or label
end

--- Resolves the current model name based on the active backend.
--- @return string The model name for the active backend.
function M.get_current_model()
	if CoreState.backend == "api" then
		-- For remote backends, the model is whatever string the user typed
		-- when they configured the API entry — providers expose model names
		-- that don't appear in the llm_models.json catalogue, so no
		-- backend-specific resolution is meaningful.
		local entry = ApiRemote.get_active_entry()
		if entry and type(entry.model) == "string" and entry.model ~= "" then
			return entry.model
		end
		return ""
	end
	local label = (CoreState.backend == "mlx") and CoreState.llm_model_mlx or CoreState.llm_model_ollama
	return resolve_model_for_backend(label, CoreState.backend)
end

--- Sets the model for Ollama backend.
--- @param model_name string The model identifier for Ollama.
function M.set_llm_model_ollama(model_name)
	if type(model_name) == "string" then
		CoreState.llm_model_ollama = model_name
		-- A model switch is a fresh (server, model) identity: clear readiness so the
		-- scheduled warmup actually re-primes model B instead of self-terminating on
		-- model A's stale-true flag (F-M8).
		pcall(function() ApiOllama.reset_ready() end)
	end
end

--- Sets the model for MLX backend.
--- @param model_name string The model identifier for MLX.
function M.set_llm_model_mlx(model_name)
	if type(model_name) == "string" then
		CoreState.llm_model_mlx = model_name
	end
end

--- Exposes built-in profiles and user profiles.
--- @return table An array containing all available profiles.
function M.get_all_profiles()
	return Profiles.get_all_profiles(CoreState.user_profiles)
end

--- Overrides user profiles globally.
--- @param profiles_table table The new user profile map.
function M.set_user_profiles(profiles_table)
	if type(profiles_table) == "table" then
		CoreState.user_profiles = profiles_table
	end
end

--- Initiates a new LLM prediction request, selecting the optimal fetch strategy based on profile state.
--- @param full_text string The complete tracked context string.
--- @param tail_text string The most recent segment of the context.
--- @param model_name string Name of the targeted local model.
--- @param temperature number Base sampling temperature.
--- @param max_predict number Maximum allowed output tokens.
--- @param num_predictions number Request quantity for prediction arrays.
--- @param on_success function Function to execute when successfully parsed payload returns.
--- @param on_fail function Function to execute on timeout, error, or empty output.
--- @param sequential_mode boolean Flag to enforce sequential API requests instead of parallel.
--- @param force boolean If true, bypasses application exclusions.
--- @param request_id_provider function Callback returning the current request identifier.
--- @param on_partial function|nil Optional token-by-token streaming callback.
function M.fetch_llm_prediction(full_text, tail_text, model_name, temperature,
                                  max_predict, num_predictions, on_success, on_fail, sequential_mode, force, request_id_provider, on_partial)

	-- The app-exclusion filter lives in modules/llm/app_filter.lua and is applied
	-- by prediction_engine before it ever dispatches. A second copy lived here and
	-- read hs.settings.get("llm_disabled_apps") — a key nothing in the tree writes,
	-- because the real setter keeps the list in module state. So this copy could
	-- never block anything, and had drifted from the live one besides. Removed
	-- rather than repaired: two implementations of "may this app receive a
	-- prediction?" is the divergence, not the answer either gave.

	num_predictions = math.max(1, math.floor(tonumber(num_predictions) or 1))
	local profile = M.get_active_profile()
	local api = get_api()

	if type(profile) == "table" and (not profile.batch) then
		if num_predictions > 1 and not sequential_mode then
			api.fetch_parallel(full_text, tail_text, model_name, temperature, max_predict, num_predictions, profile, on_success, on_fail, request_id_provider, _streaming_enabled, on_partial)
		else
			api.fetch_sequential(full_text, tail_text, model_name, temperature, max_predict, num_predictions, profile, on_success, on_fail, request_id_provider, _streaming_enabled, on_partial)
		end
	else
		api.fetch_batch(full_text, tail_text, model_name, temperature, max_predict, num_predictions, profile, on_success, on_fail, request_id_provider, _streaming_enabled, on_partial)
	end
end

--- Validates keystroke event modifiers against an expected explicit modifier set.
--- @param eventFlags table The flags object emitted by the keystroke event.
--- @param targetMods table A list of expected modifier keys (e.g., {"cmd", "shift"}).
--- @return boolean True if the flags exactly match the target criteria, false otherwise.
function M.check_modifiers(eventFlags, targetMods)
	if type(targetMods) ~= "table" then return false end
	if #targetMods == 1 and targetMods[1] == "none" then return false end
	
	local target_map = { cmd = false, alt = false, shift = false, ctrl = false }
	for _, mod in ipairs(targetMods) do if target_map[mod] ~= nil then target_map[mod] = true end end
	
	if (eventFlags.cmd or false)   ~= target_map.cmd   then return false end
	if (eventFlags.alt or false)   ~= target_map.alt   then return false end
	if (eventFlags.shift or false) ~= target_map.shift then return false end
	if (eventFlags.ctrl or false)  ~= target_map.ctrl  then return false end
	
	return true
end

-- Proxy Model Heuristics Methods — dispatch to the active backend so the
-- menu's thinking-model warning row also fires correctly when the user is
-- pointed at a remote API serving qwen3 / deepseek / *-r1 / *-think* models.
M.is_thinking_model  = function(name) return get_api().is_thinking_model(name) end
M.check_availability = function(...) get_api().check_availability(...) end

return M
