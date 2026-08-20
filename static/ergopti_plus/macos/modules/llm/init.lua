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
local Storage = require("adapters.storage")

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
	background_bootstrap_timer = nil,
	api_entries_load_timer = nil,
	api_entries_load_generation = 0,
	api_entries_load_started = false,
	api_persist_generation = 0,
	api_persist_pending = nil,
	api_persisted_state = nil,
	api_durable_combined_state = nil,
	api_cleanup_journal = {},
	api_cleanup_pending = nil,
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
	profile_generation     = 0,
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
local API_STATE_KEY      = "llm_api_state_v1"
local API_CLEANUP_JOURNAL_KEY = "llm_api_keychain_cleanup_v1"
local API_STATE_VERSION  = 1
local KEYCHAIN_REFERENCE_PREFIX = "keychain:"
local TokenCrypto = require("modules.llm.api_token_crypto")
local ApiCommon = require("modules.llm.api_common")

--- Copies acyclic settings data so later runtime mutations cannot mutate a test
--- stub's by-reference backing store or our last-known durable snapshot.
--- @param value any Value to copy.
--- @return any copy
local function copy_settings_value(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, child in pairs(value) do
		copy[copy_settings_value(key)] = copy_settings_value(child)
	end
	return copy
end

--- Structural equality for the exact settings readback contract.
--- @param left any First value.
--- @param right any Second value.
--- @return boolean equal
local function settings_equal(left, right)
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in pairs(left) do
		if not settings_equal(value, right[key]) then return false end
	end
	for key in pairs(right) do
		if left[key] == nil then return false end
	end
	return true
end

--- Returns the exact length of a dense one-based array, or nil for sparse,
--- map-shaped, fractional, or zero-based tables. ipairs() alone is unsafe for
--- persisted input because it silently stops at the first hole.
--- @param value any Candidate array.
--- @return number|nil length
local function dense_array_length(value)
	if type(value) ~= "table" then return nil end
	local count = 0
	local highest = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return nil end
		count = count + 1
		if key > highest then highest = key end
	end
	if highest ~= count then return nil end
	return count
end

--- Validates the canonical entry-array shape shared by legacy migration,
--- combined-state load, and runtime publication. The legacy path alone may
--- contain cleartext; every durable combined entry must carry an opaque ref.
--- @param entries any Candidate dense array.
--- @param allow_plaintext boolean Whether historical cleartext is accepted.
--- @param active_id string Candidate active identity.
--- @return boolean valid
local function validate_api_entries(entries, allow_plaintext, active_id)
	if dense_array_length(entries) == nil or type(active_id) ~= "string" then return false end
	local ids = {}
	for _, entry in ipairs(entries) do
		if type(entry) ~= "table"
			or type(entry.id) ~= "string" or entry.id == ""
			or type(entry.provider) ~= "string" or entry.provider == ""
			or type(entry.model) ~= "string" or entry.model == ""
			or type(entry.token) ~= "string" or entry.token == ""
			or (entry.base_url ~= nil and type(entry.base_url) ~= "string")
			or (entry.label ~= nil and type(entry.label) ~= "string")
			or ids[entry.id] == true then
			return false
		end
		ids[entry.id] = true
		local encrypted = TokenCrypto.is_encrypted(entry.token)
		if encrypted and entry.token ~= KEYCHAIN_REFERENCE_PREFIX .. entry.id then
			Logger.error(LOG, "API state entry '%s' points at a different Keychain account; refusing the snapshot.",
				tostring(entry.id))
			return false
		end
		if not allow_plaintext and not encrypted then
			Logger.error(LOG, "Persisted API state contains a plaintext token; refusing the snapshot.")
			return false
		end
	end
	return active_id == "" or ids[active_id] == true
end

--- Creates a validated combined state. Invalid fields fail the whole snapshot;
--- accepting a partial table would publish entries and active id from different
--- logical versions, recreating the torn two-key format this replaces.
--- @param raw any Settings value.
--- @return table|nil state
local function validate_api_state(raw)
	if type(raw) ~= "table" or raw.version ~= API_STATE_VERSION
		or type(raw.entries) ~= "table" or type(raw.active_id) ~= "string"
		or type(raw.pending_keychain_deletes) ~= "table" then
		return nil
	end
	if not validate_api_entries(raw.entries, false, raw.active_id)
		or dense_array_length(raw.pending_keychain_deletes) == nil then
		return nil
	end
	for _, entry_id in ipairs(raw.pending_keychain_deletes) do
		if type(entry_id) ~= "string" or entry_id == "" then return nil end
	end
	return copy_settings_value(raw)
end

local function empty_api_state()
	return {
		version = API_STATE_VERSION,
		entries = {},
		active_id = "",
		pending_keychain_deletes = {},
	}
end

local function invoke_persist_callback(callback, ...)
	if type(callback) ~= "function" then return end
	local args = table.pack(...)
	local ok, err = xpcall(function()
		callback(table.unpack(args, 1, args.n))
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "API persistence callback raised: %s", tostring(err))
	end
end

local function read_setting(key)
	local call_ok, read_ok, value_or_err = xpcall(function()
		return Storage.read_exact(key)
	end, debug.traceback)
	if not call_ok or read_ok ~= true then
		Logger.error(LOG, "API settings read failed for '%s': %s",
			tostring(key), tostring(call_ok and value_or_err or read_ok))
		return false, nil
	end
	return true, value_or_err
end

--- Restores one previous combined-key value after a rejected write.
--- @param previous table|nil Previously confirmed combined state.
--- @return boolean restored
local function restore_combined_state(previous)
	local ok, err = xpcall(function()
		if previous == nil then
			if Storage.delete_exact(API_STATE_KEY) ~= true then error("delete returned false") end
		else
			if Storage.set(API_STATE_KEY, copy_settings_value(previous)) ~= true then
				error("set returned false")
			end
		end
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "API settings rollback raised: %s", tostring(err))
		return false
	end
	local read_ok, readback = read_setting(API_STATE_KEY)
	if not read_ok or not settings_equal(readback, previous) then
		Logger.error(LOG, "API settings rollback could not be verified by readback.")
		return false
	end
	return true
end

--- Publishes one combined state and proves its exact durable readback. The
--- caller supplies the previously confirmed combined value so any mismatch is
--- rolled back to a non-torn snapshot before failure is reported.
--- @param candidate table State to persist.
--- @param rollback_combined table|nil Previously confirmed combined-key value.
--- @return boolean committed
local function write_combined_state(candidate, rollback_combined)
	local write_ok, write_err = xpcall(function()
		if Storage.set(API_STATE_KEY, copy_settings_value(candidate)) ~= true then
			error("set returned false")
		end
	end, debug.traceback)
	if not write_ok then
		Logger.error(LOG, "API settings write raised: %s", tostring(write_err))
		restore_combined_state(rollback_combined)
		return false
	end
	local read_ok, readback = read_setting(API_STATE_KEY)
	if not read_ok or not settings_equal(readback, candidate) then
		Logger.error(LOG, "API settings write was not confirmed by exact readback.")
		restore_combined_state(rollback_combined)
		return false
	end
	CoreState.api_durable_combined_state = copy_settings_value(candidate)
	CoreState.api_persisted_state = copy_settings_value(candidate)
	return true
end

--- Removes obsolete two-key storage after combined publication. This is also
--- retried on every combined-state load so a prior partial clear cannot leave a
--- legacy plaintext token indefinitely.
--- @return boolean cleared
local function clear_legacy_api_settings()
	local clear_ok, clear_err = xpcall(function()
		if Storage.delete_exact(API_ENTRIES_KEY) ~= true then error("entries clear returned false") end
		if Storage.delete_exact(API_ENTRY_ID_KEY) ~= true then error("active-id clear returned false") end
	end, debug.traceback)
	if not clear_ok then
		Logger.error(LOG, "Legacy API settings cleanup raised: %s", tostring(clear_err))
		return false
	end
	local entries_ok, old_entries = read_setting(API_ENTRIES_KEY)
	local active_ok, old_active = read_setting(API_ENTRY_ID_KEY)
	if not entries_ok or not active_ok or old_entries ~= nil or old_active ~= nil then
		Logger.error(LOG, "Legacy API settings cleanup was not confirmed by readback.")
		return false
	end
	return true
end

local function pending_id_set(state)
	local ids = {}
	for _, entry_id in ipairs((state and state.pending_keychain_deletes) or {}) do
		ids[entry_id] = true
	end
	return ids
end

local function sorted_ids(ids)
	local out = {}
	for entry_id in pairs(ids) do out[#out + 1] = entry_id end
	table.sort(out)
	return out
end

local function validate_id_list(raw)
	if raw == nil then return {} end
	if dense_array_length(raw) == nil then return nil end
	local ids = {}
	for _, entry_id in ipairs(raw) do
		if type(entry_id) ~= "string" or entry_id == "" then return nil end
		ids[entry_id] = true
	end
	return sorted_ids(ids)
end

--- Commits the plaintext-free cleanup journal used before the first combined
--- state exists (legacy migration and first Add). The legacy two-key snapshot
--- remains authoritative until final combined publication, so a crash can retry
--- without either exposing plaintext in the new key or hiding legacy entries.
--- @param candidate table Sorted entry-id array.
--- @return boolean committed
local function write_cleanup_journal(candidate)
	local previous = copy_settings_value(CoreState.api_cleanup_journal or {})
	local function write_value(value)
		if #value == 0 then
			if Storage.delete_exact(API_CLEANUP_JOURNAL_KEY) ~= true then
				error("journal clear returned false")
			end
		else
			if Storage.set(API_CLEANUP_JOURNAL_KEY, copy_settings_value(value)) ~= true then
				error("journal set returned false")
			end
		end
	end
	local write_ok, write_err = xpcall(function() write_value(candidate) end, debug.traceback)
	if write_ok then
		local read_ok, readback = read_setting(API_CLEANUP_JOURNAL_KEY)
		local expected = nil
		if #candidate > 0 then expected = candidate end
		if read_ok and settings_equal(readback, expected) then
			CoreState.api_cleanup_journal = copy_settings_value(candidate)
			return true
		end
		Logger.error(LOG, "API cleanup journal write was not confirmed by exact readback.")
	else
		Logger.error(LOG, "API cleanup journal write raised: %s", tostring(write_err))
	end

	local rollback_ok, rollback_err = xpcall(function() write_value(previous) end, debug.traceback)
	if not rollback_ok then
		Logger.error(LOG, "API cleanup journal rollback raised: %s", tostring(rollback_err))
		return false
	end
	local read_ok, readback = read_setting(API_CLEANUP_JOURNAL_KEY)
	local expected = nil
	if #previous > 0 then expected = previous end
	if not read_ok or not settings_equal(readback, expected) then
		Logger.error(LOG, "API cleanup journal rollback could not be verified.")
	end
	return false
end

local function remove_cleanup_journal_ids(ids_to_remove)
	local retained = {}
	for _, entry_id in ipairs(CoreState.api_cleanup_journal or {}) do
		if ids_to_remove[entry_id] ~= true then retained[#retained + 1] = entry_id end
	end
	return write_cleanup_journal(retained)
end

--- Retries durable Keychain-cleanup tombstones. Deletion is idempotent, and the
--- tombstone is removed only after both the subprocess and settings readback
--- commit. A crash at any point therefore retries rather than orphans a secret.
--- @param callback function|nil Receives (ok, reason).
function M.retry_pending_api_token_deletes(callback)
	local running = CoreState.api_cleanup_pending
	if running and running.done ~= true then
		running.waiters[#running.waiters + 1] = callback
		return
	end

	local record = { done = false, waiters = { callback } }
	CoreState.api_cleanup_pending = record

	local function finish(ok, reason)
		if record.done then return end
		record.done = true
		if CoreState.api_cleanup_pending == record then CoreState.api_cleanup_pending = nil end
		for _, waiter in ipairs(record.waiters) do
			invoke_persist_callback(waiter, ok, reason)
		end
	end

	local function run_cycle()
		if record.done then return end
		local current = CoreState.api_persisted_state or empty_api_state()
		local ids = pending_id_set(current)
		for _, entry_id in ipairs(CoreState.api_cleanup_journal or {}) do ids[entry_id] = true end
		local referenced = {}
		-- Never delete a credential still referenced by the durable entry list.
		for _, entry in ipairs(current.entries or {}) do
			if type(entry.id) == "string" and ids[entry.id] then
				referenced[entry.id] = true
				ids[entry.id] = nil
			end
		end
		local queue = sorted_ids(ids)
		if #queue == 0 then
			if next(referenced) ~= nil then
				local latest = copy_settings_value(CoreState.api_persisted_state or empty_api_state())
				local retained = pending_id_set(latest)
				for entry_id in pairs(referenced) do retained[entry_id] = nil end
				latest.pending_keychain_deletes = sorted_ids(retained)
				if CoreState.api_durable_combined_state ~= nil then
					local rollback = CoreState.api_durable_combined_state
					if not write_combined_state(latest, rollback) then
						finish(false, "settings_readback_failed")
						return
					end
				else
					CoreState.api_persisted_state = latest
				end
				if not remove_cleanup_journal_ids(referenced) then
					finish(false, "cleanup_journal_failed")
					return
				end
				run_cycle()
				return
			end
			finish(true, nil)
			return
		end

		local index = 1
		local function delete_next()
			if record.done then return end
			local entry_id = queue[index]
			if not entry_id then
				local latest = copy_settings_value(CoreState.api_persisted_state or empty_api_state())
				local cleared = pending_id_set(latest)
				for _, deleted_id in ipairs(queue) do cleared[deleted_id] = nil end
				latest.pending_keychain_deletes = sorted_ids(cleared)
				if CoreState.api_durable_combined_state ~= nil then
					local rollback = CoreState.api_durable_combined_state
					if not write_combined_state(latest, rollback) then
						finish(false, "settings_readback_failed")
						return
					end
				else
					CoreState.api_persisted_state = latest
				end
				local deleted_set = {}
				for _, deleted_id in ipairs(queue) do deleted_set[deleted_id] = true end
				if not remove_cleanup_journal_ids(deleted_set) then
					finish(false, "cleanup_journal_failed")
					return
				end
				run_cycle()
				return
			end
			index = index + 1
			local delete_callback_done = false
			local launch_ok, launch_err = xpcall(function()
				TokenCrypto.delete_async(entry_id, function(ok, reason)
					if delete_callback_done then return end
					delete_callback_done = true
					if ok ~= true then
						finish(false, reason or "keychain_delete_failed")
						return
					end
					delete_next()
				end)
			end, debug.traceback)
			if not launch_ok then
				Logger.error(LOG, "Keychain cleanup launch raised for '%s': %s",
					tostring(entry_id), tostring(launch_err))
				finish(false, "keychain_delete_launch_failed")
			end
		end
		delete_next()
	end

	run_cycle()
end

--- Loads one combined API state, falling back to the historical two keys only
--- for migration. Combined metadata loads without Keychain work; legacy
--- plaintext schedules the same asynchronous crash-safe persistence transaction
--- used by the menu before this function returns.
--- @return boolean loaded
function M.load_api_entries()
	local combined_ok, combined_raw = read_setting(API_STATE_KEY)
	if not combined_ok then return false end
	local journal_ok, journal_raw = read_setting(API_CLEANUP_JOURNAL_KEY)
	if not journal_ok then return false end
	local journal = validate_id_list(journal_raw)
	if not journal then
		Logger.error(LOG, "API cleanup journal is malformed; refusing persisted API state.")
		return false
	end
	CoreState.api_cleanup_journal = copy_settings_value(journal)

	local state = nil
	local needs_legacy_migration = false
	if combined_raw ~= nil then
		state = validate_api_state(combined_raw)
		if not state then
			Logger.error(LOG, "Combined API state is malformed; refusing stale legacy fallback.")
			return false
		end
		CoreState.api_durable_combined_state = copy_settings_value(state)
		clear_legacy_api_settings()
	else
		local entries_ok, legacy_entries = read_setting(API_ENTRIES_KEY)
		local active_ok, legacy_active = read_setting(API_ENTRY_ID_KEY)
		if not entries_ok or not active_ok then return false end
		needs_legacy_migration = legacy_entries ~= nil or legacy_active ~= nil
		state = empty_api_state()
		if legacy_entries ~= nil then
			if dense_array_length(legacy_entries) == nil then
				Logger.error(LOG, "Legacy API entry state is not a dense array; refusing migration.")
				return false
			end
			state.entries = copy_settings_value(legacy_entries)
		end
		if legacy_active ~= nil and type(legacy_active) ~= "string" then return false end
		if type(legacy_active) == "string" then state.active_id = legacy_active end
		if not validate_api_entries(state.entries, true, state.active_id) then
			Logger.error(LOG, "Legacy API entry schema is malformed; refusing migration.")
			return false
		end
		CoreState.api_durable_combined_state = nil
	end
	local pending = pending_id_set(state)
	for _, entry_id in ipairs(journal) do pending[entry_id] = true end
	state.pending_keychain_deletes = sorted_ids(pending)
	CoreState.api_persisted_state = copy_settings_value(state)
	ApiRemote.set_entries(copy_settings_value(state.entries))
	ApiRemote.set_active_entry_id(state.active_id)

	local prewarm_ok, prewarm_err = xpcall(ApiRemote.prewarm_active_entry_decrypt, debug.traceback)
	if not prewarm_ok then Logger.error(LOG, "API token prewarm raised: %s", tostring(prewarm_err)) end
	M.retry_pending_api_token_deletes()
	if needs_legacy_migration then
		M.persist_api_entries(function(ok, reason, durable)
			if ok == true then
				Logger.info(LOG, "Legacy API token migration committed to Keychain.")
			elseif durable == true then
				Logger.error(LOG, "Legacy API token migration committed with cleanup debt: %s",
					tostring(reason))
			else
				Logger.error(LOG, "Legacy API token migration failed and will retry on next load: %s",
					tostring(reason))
			end
		end)
	end
	return true
end

local function runtime_snapshot_matches(entries, active_id)
	return settings_equal(ApiRemote.get_entries() or {}, entries)
		and ApiRemote.get_active_entry_id() == active_id
end

--- Persists the current runtime API identity asynchronously. Plaintext tokens
--- first get a durable cleanup tombstone, then enter Keychain, then publish as
--- references in one combined settings value. A caller sees success only after
--- exact readback and any requested delete cleanup complete.
--- @param callback function|nil Receives (ok, reason, durable).
--- @param options table|nil Optional { delete_entry_ids = { ... } }.
function M.persist_api_entries(callback, options)
	CoreState.api_persist_generation = CoreState.api_persist_generation + 1
	local generation = CoreState.api_persist_generation
	local entries = copy_settings_value(ApiRemote.get_entries() or {})
	local active_id = ApiRemote.get_active_entry_id()
	if not validate_api_entries(entries, true, active_id) then
		Logger.error(LOG, "Runtime API entry schema is malformed; refusing persistence.")
		invoke_persist_callback(callback, false, "invalid_api_state", false)
		return
	end

	local prior = CoreState.api_persist_pending
	if prior and prior.done ~= true then
		if type(prior.when_settled) ~= "function"
			or type(prior.cancel_owned) ~= "function"
			or type(prior.finish) ~= "function" then
			Logger.error(LOG, "Prior API persistence has no exact settlement capability.")
			invoke_persist_callback(callback, false, "prior_settlement_unavailable", false)
			return
		end

		local waiter_active = true
		local wait_ok, wait_committed = xpcall(function()
			return prior.when_settled(function()
				if not waiter_active then return end
				waiter_active = false
				if generation ~= CoreState.api_persist_generation
					or not runtime_snapshot_matches(entries, active_id) then
					invoke_persist_callback(callback, false, "stale_runtime_state", false)
					return
				end
				-- Re-enter only after native completion has released the exact task.
				-- The new generation re-snapshots the still-leased runtime state and
				-- joins any cleanup the predecessor armed before settling.
				M.persist_api_entries(callback, options)
			end)
		end, debug.traceback)
		if not wait_ok or wait_committed ~= true then
			waiter_active = false
			Logger.error(LOG, "Prior API persistence settlement wait could not commit: %s",
				tostring(wait_ok and wait_committed or wait_committed))
			invoke_persist_callback(callback, false, "prior_settlement_unavailable", false)
			return
		end

		local cancel_ok, settled, cancel_state = xpcall(prior.cancel_owned, debug.traceback)
		if not cancel_ok then
			waiter_active = false
			Logger.error(LOG, "Prior API persistence cancellation raised: %s", tostring(settled))
			invoke_persist_callback(callback, false, "prior_cancellation_refused", false)
			return
		end
		if settled == true then
			if prior.done ~= true then prior.finish(false, "superseded", false) end
			return
		end
		if cancel_state == "pending" then return end

		waiter_active = false
		Logger.error(LOG, "Prior API persistence cancellation was refused: %s", tostring(cancel_state))
		invoke_persist_callback(callback, false, "prior_cancellation_refused", false)
		return
	end

	local function begin_transaction()
		if generation ~= CoreState.api_persist_generation
			or not runtime_snapshot_matches(entries, active_id) then
			invoke_persist_callback(callback, false, "stale_runtime_state", false)
			return
		end
	local operation = { done = false, settlement_waiters = {} }
	CoreState.api_persist_pending = operation

	local function invoke_settlement_waiter(waiter)
		local ok, err = xpcall(waiter, debug.traceback)
		if not ok then Logger.error(LOG, "API persistence settlement callback raised: %s", tostring(err)) end
		return ok
	end
	operation.when_settled = function(waiter)
		if type(waiter) ~= "function" then return false end
		if operation.done then return invoke_settlement_waiter(waiter) end
		operation.settlement_waiters[#operation.settlement_waiters + 1] = waiter
		return true
	end

	local function finish(ok, reason, durable)
		if operation.done then return end
		operation.done = true
		if CoreState.api_persist_pending == operation then CoreState.api_persist_pending = nil end
		invoke_persist_callback(callback, ok, reason, durable == true)
		local waiters = operation.settlement_waiters
		operation.settlement_waiters = {}
		for _, waiter in ipairs(waiters) do invoke_settlement_waiter(waiter) end
	end
	operation.finish = finish
	operation.cancel_owned = function()
		local owned = operation.crypto_operation
		if type(owned) ~= "table" or type(owned.cancel) ~= "function" then return true end
		local ok, settled, state = xpcall(function() return owned.cancel() end, debug.traceback)
		if ok and settled == true then
			operation.crypto_operation = nil
			return true, "settled"
		end
		if ok and state == "pending" then return false, "pending" end
		if not ok or state ~= "pending" then
			Logger.error(LOG, "Superseded Keychain encryption could not be terminated: %s",
				tostring(ok and (state or settled) or settled))
		end
		return false, "refused"
	end

	local serialised = copy_settings_value(entries)
	local encrypt_jobs = {}
	for index, entry in ipairs(serialised) do
		local token = entry.token
		if type(token) == "string" and token ~= "" and not TokenCrypto.is_encrypted(token) then
			if type(entry.id) ~= "string" or entry.id == "" then
				finish(false, "invalid_entry_id", false)
				return
			end
			encrypt_jobs[#encrypt_jobs + 1] = { index = index, id = entry.id, token = token }
			entry.token = nil
		end
	end

	local desired_pending = pending_id_set(CoreState.api_persisted_state or empty_api_state())
	local delete_ids = type(options) == "table" and options.delete_entry_ids or nil
	if type(delete_ids) == "table" then
		for _, entry_id in ipairs(delete_ids) do
			if type(entry_id) == "string" and entry_id ~= "" then desired_pending[entry_id] = true end
		end
	end

	local function publish_final()
		if operation.done then return end
		if generation ~= CoreState.api_persist_generation
			or not runtime_snapshot_matches(entries, active_id) then
			finish(false, "stale_runtime_state", false)
			M.retry_pending_api_token_deletes()
			return
		end
		for _, job in ipairs(encrypt_jobs) do desired_pending[job.id] = nil end
		local candidate = {
			version = API_STATE_VERSION,
			entries = serialised,
			active_id = active_id,
			pending_keychain_deletes = sorted_ids(desired_pending),
		}
		local rollback = CoreState.api_durable_combined_state
		if not write_combined_state(candidate, rollback) then
			finish(false, "settings_readback_failed", false)
			M.retry_pending_api_token_deletes()
			return
		end
		local legacy_cleared = clear_legacy_api_settings()
		if #encrypt_jobs > 0 or (type(delete_ids) == "table" and #delete_ids > 0) then
			M.retry_pending_api_token_deletes(function(cleaned, reason)
				if not legacy_cleared then
					finish(false, "legacy_cleanup_failed", true)
				else
					finish(cleaned == true, reason, true)
				end
			end)
		else
			if legacy_cleared then
				finish(true, nil, true)
			else
				finish(false, "legacy_cleanup_failed", true)
			end
		end
	end

	local function encrypt_next(index)
		if operation.done then return end
		local job = encrypt_jobs[index]
		if not job then
			publish_final()
			return
		end
		operation.crypto_owner_epoch = (operation.crypto_owner_epoch or 0) + 1
		local owner_epoch = operation.crypto_owner_epoch
		local encrypt_callback_done = false
		local launch_ok, operation_or_err = xpcall(function()
			return TokenCrypto.encrypt_async(job.id, job.token, function(ok, reference, reason)
				if encrypt_callback_done then return end
				encrypt_callback_done = true
				if operation.crypto_owner_epoch == owner_epoch then
					operation.crypto_operation = nil
				end
				if operation.done then return end
				if ok ~= true or reference ~= KEYCHAIN_REFERENCE_PREFIX .. job.id then
					-- Publish cleanup ownership before settlement waiters may resume a
					-- successor. The native helper has exited at this point, so the
					-- idempotent delete cannot race its Security.framework mutation.
					M.retry_pending_api_token_deletes()
					finish(false, reason or "keychain_encrypt_failed", false)
					return
				end
				serialised[job.index].token = reference
				encrypt_next(index + 1)
			end)
		end, debug.traceback)
		if launch_ok and not encrypt_callback_done and not operation.done
			and operation.crypto_owner_epoch == owner_epoch then
			operation.crypto_operation = operation_or_err
		end
		if not launch_ok then
			Logger.error(LOG, "Keychain encryption launch raised for '%s': %s",
				tostring(job.id), tostring(operation_or_err))
			if not encrypt_callback_done and not operation.done
				and operation.crypto_owner_epoch == owner_epoch then
				M.retry_pending_api_token_deletes()
				finish(false, "keychain_encrypt_launch_failed", false)
			end
		end
	end

	if #encrypt_jobs > 0 then
		if CoreState.api_durable_combined_state == nil then
			local journal_ids = {}
			for _, entry_id in ipairs(CoreState.api_cleanup_journal or {}) do journal_ids[entry_id] = true end
			for _, job in ipairs(encrypt_jobs) do journal_ids[job.id] = true end
			if not write_cleanup_journal(sorted_ids(journal_ids)) then
				finish(false, "cleanup_tombstone_failed", false)
				return
			end
			local logical = copy_settings_value(CoreState.api_persisted_state or empty_api_state())
			local logical_pending = pending_id_set(logical)
			for _, job in ipairs(encrypt_jobs) do logical_pending[job.id] = true end
			logical.pending_keychain_deletes = sorted_ids(logical_pending)
			CoreState.api_persisted_state = logical
		else
			local stage = copy_settings_value(CoreState.api_persisted_state or empty_api_state())
			local stage_pending = pending_id_set(stage)
			for _, job in ipairs(encrypt_jobs) do stage_pending[job.id] = true end
			stage.pending_keychain_deletes = sorted_ids(stage_pending)
			local rollback = CoreState.api_durable_combined_state
			if not write_combined_state(stage, rollback) then
				finish(false, "cleanup_tombstone_failed", false)
				return
			end
		end
	end
	encrypt_next(1)
	end

	-- Cleanup from a cancelled/timed-out predecessor must settle before a new
	-- write can reuse an account. Joining the single-flight cleanup also fences
	-- user actions that arrive while a durable delete tombstone is in flight.
	if CoreState.api_cleanup_pending and CoreState.api_cleanup_pending.done ~= true then
		M.retry_pending_api_token_deletes(function(ok, reason)
			if generation ~= CoreState.api_persist_generation
				or not runtime_snapshot_matches(entries, active_id) then
				invoke_persist_callback(callback, false, "stale_runtime_state", false)
				return
			end
			if ok ~= true then
				invoke_persist_callback(callback, false, reason or "keychain_cleanup_pending", false)
				return
			end
			begin_transaction()
		end)
		return
	end
	begin_transaction()
end

-- Restore persisted metadata after boot-critical input ownership commits. Token
-- resolution is fully asynchronous now, but settings migration and cleanup
-- readbacks still belong outside the require path. TimerScheduler also gives the
-- deferred load an exact owned handle for reload teardown.
local function schedule_api_entries_load()
	local prior = CoreState.api_entries_load_timer
	if type(prior) == "table" then
		if prior.committed == true then return true end
		if prior.timer ~= nil and TimerScheduler.cancel(prior) ~= true then
			Logger.error(LOG, "Persisted API-entry load cleanup remains pending.")
			return false
		end
		if CoreState.api_entries_load_timer == prior then CoreState.api_entries_load_timer = nil end
	end
	if CoreState.api_entries_load_started then return true end

	CoreState.api_entries_load_generation = CoreState.api_entries_load_generation + 1
	local generation = CoreState.api_entries_load_generation
	local handle
	local committed
	local schedule_ok, schedule_err = xpcall(function()
		handle, committed = TimerScheduler.after(0, function()
			if CoreState.api_entries_load_timer == handle and handle.timer == nil then
				CoreState.api_entries_load_timer = nil
			end
			if committed ~= true or generation ~= CoreState.api_entries_load_generation then return end
			local call_ok, loaded = Logger.pcall(LOG, M.load_api_entries)
			if call_ok == true and loaded == true then
				CoreState.api_entries_load_started = true
			else
				Logger.error(LOG, "Persisted API-entry load did not complete.")
			end
		end)
	end, debug.traceback)
	if type(handle) == "table" and handle.timer ~= nil then CoreState.api_entries_load_timer = handle end
	if not schedule_ok or committed ~= true then
		Logger.error(LOG, "Persisted API-entry load timer did not commit: %s.",
			tostring(schedule_ok and handle or schedule_err))
		return false
	end
	CoreState.api_entries_load_timer = handle
	return true
end

schedule_api_entries_load()

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
	CoreState.profile_generation = CoreState.profile_generation + 1
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
		local my_profile_generation = CoreState.profile_generation
		hs.timer.doAfter(0, function()
			local ok, err = xpcall(function()
				if CoreState.backend_generation ~= my_backend_generation
					or CoreState.profile_generation ~= my_profile_generation then
					Logger.debug(LOG, "set_active_profile: backend/profile changed before deferred warmup fired — discarding stale dispatch for '%s'.",
						tostring(model))
					return
				end
				if not CoreState.runtime_llm_enabled then
					Logger.debug(LOG, "set_active_profile: runtime LLM disabled before deferred warmup — discarding dispatch for '%s'.",
						tostring(model))
					return
				end
				M.warmup_model(model, new_profile)
			end, debug.traceback)
			if not ok then
				Logger.error(LOG, "Deferred profile warmup callback raised: %s", tostring(err))
			end
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
	if schedule_api_entries_load() ~= true then
		Logger.error(LOG, "Background LLM bootstrap refused — persisted API entries are not owned.")
		return false
	end
	if CoreState.background_bootstrap_started then
		Logger.debug(LOG, "start_background_network_bootstrap: already started — skipping duplicate call.")
		return true
	end

	local prior = CoreState.background_bootstrap_timer
	if prior then
		if prior.committed == true then
			Logger.debug(LOG, "start_background_network_bootstrap: already scheduled — skipping duplicate call.")
			return true
		end
		-- A prior activation may have raised after making its native timer live.
		-- Never publish a sibling until that exact cleanup capability settles.
		if TimerScheduler.cancel(prior) ~= true then
			Logger.error(LOG, "Background LLM bootstrap cleanup remains pending.")
			return false
		end
		if CoreState.background_bootstrap_timer == prior then
			CoreState.background_bootstrap_timer = nil
		end
	end

	-- Forward-declare before the closure so Lua captures this local rather than
	-- resolving a later declaration as the nil global `bootstrap_timer`.
	local bootstrap_timer
	local committed
	bootstrap_timer, committed = TimerScheduler.after(0, function()
		if CoreState.background_bootstrap_timer == bootstrap_timer
			and bootstrap_timer.timer == nil then
			CoreState.background_bootstrap_timer = nil
		end
		if CoreState.background_bootstrap_started then return end
		CoreState.background_bootstrap_started = true
		Logger.pcall(LOG, M.auto_detect_backend)
		Logger.pcall(LOG, M.warm_up_connections)
	end)

	if bootstrap_timer and bootstrap_timer.timer ~= nil then
		CoreState.background_bootstrap_timer = bootstrap_timer
	end
	if committed ~= true then
		if not bootstrap_timer or bootstrap_timer.timer == nil then
			CoreState.background_bootstrap_timer = nil
		end
		Logger.error(LOG, "Background LLM network bootstrap scheduling was refused.")
		return false
	end
	CoreState.background_bootstrap_timer = bootstrap_timer
	Logger.debug(LOG, "Background LLM network bootstrap scheduled.")
	return true
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
