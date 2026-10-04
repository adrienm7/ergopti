--- modules/llm/api_remote.lua

--- ==============================================================================
--- MODULE: LLM API Controller (Remote)
--- DESCRIPTION:
--- Async HTTP client for remote LLM APIs (OpenAI, Anthropic, Google Gemini,
--- and any OpenAI-Chat-Completions-compatible endpoint such as Groq, OpenRouter,
--- LM Studio, vLLM, Together, Fireworks…). Mirrors the AHK twin
--- (modules/llm/api_remote.ahk) so both drivers expose the same provider
--- catalogue and surface, but adapted to the HS engine's fetch_batch /
--- fetch_sequential / fetch_parallel surface so the prediction engine can
--- dispatch to it transparently.
---
--- FEATURES & RATIONALE:
--- 1. Provider catalogue — each entry declares Label, BaseUrl, DefaultModel
---    and Format (openai / anthropic / gemini / backboard / decisions). Adding
---    a provider of a known format is a single catalogue entry; the engine and
---    menus list it wherever its format serves (modules/llm/provider_uses.lua).
---    Backboard (a message on a new thread, naming the key's assistant, which
---    is created once per key and session) and decisions (TypeSafe's Jev, the
---    agent's System 1 only) take the shapes of _shared/lua/llm/remote_formats.lua.
--- 2. Async non-streaming — every call goes through ``hs.http.asyncPost`` so
---    the main thread never blocks. Remote streaming is intentionally OFF:
---    the three popular streaming flavours (OpenAI SSE / Anthropic event
---    stream / Gemini chunked JSONL) all parse differently, and for the
---    short completions this engine targets (3–15 words) the latency gain
---    is ~200–500 ms — not enough to justify three brittle codecs. The
---    rate-limit floor in inference.json plus the user's debounce already
---    pace requests, so the synchronous shape keeps error paths trivial.
--- 3. Multi-entry state — the user can configure several API entries (one per
---    provider/account) and switch between them via the tray menu. Each
---    fetch picks up the active entry at dispatch time so a switch takes
---    effect on the very next prediction.
--- ==============================================================================

local M = {}

local Logger         = require("infra.logger")
local text_utils = require("infra.text_utils")
local Timings        = require("infra.timings")
local Paths          = require("infra.paths")
local Profiles       = require("modules.llm.profiles")
local Parser         = require("modules.llm.parser")
local ApiCommon      = require("modules.llm.api_common")
local SharedPromptBuilder = require("llm.prompt_builder")   -- single source for DEFAULT_MAX_TOKENS
local TokenCrypto    = require("modules.llm.api_token_crypto")
local _http_adapter  = require("adapters.http_client")
local REQUEST_TIMEOUT_MS = Timings.ms("llm", "request_timeout_ms")
local _http_options = { timeout_ms = REQUEST_TIMEOUT_MS }
local _infer_client  = _http_adapter.new(_http_options)   -- used for inference POST requests
local _check_client  = _http_adapter.new(_http_options)   -- used for explicit availability checks
local _warmup_client = _http_adapter.new(_http_options)   -- warmup has independent cancellation ownership
-- Screen reading (modules/llm/screen_answer.lua) names its own provider, which
-- need not be the active entry: its requests never share the prediction owner
local _vision_client = _http_adapter.new(_http_options)
-- The Test-API probe of an entry that is not the prediction backend (a
-- decisions provider): it must cancel neither a prediction nor an agent request
local _probe_client = _http_adapter.new(_http_options)
local JsonCodec      = require("adapters.json_codec")
local TimerScheduler = require("adapters.timer_scheduler")
local ProgressiveReveal = require("modules.llm.progressive_reveal")
local ResponseClassifier = require("modules.llm.remote_response_classifier")
local Formats        = require("llm.remote_formats")
local ProviderUses   = require("modules.llm.provider_uses")
local LocalServers   = require("modules.llm.local_servers")
local AuthPolicy     = require("llm.local_server_auth")
local LOG            = "llm.api_remote"
-- One probe client per local server, created at its first sweep with the
-- registry's local_server_probe_timeout_ms and pinned for the life of the
-- module, so a sweep probes every server at once and a newer sweep supersedes
-- each probe
local _local_probe_clients = {}

local ok_kl, keylogger = pcall(require, "modules.keylogger")
if not ok_kl then keylogger = nil end




-- =======================================
-- =======================================
-- ======= 1/ Provider Catalogue =========
-- =======================================
-- =======================================

--- Loaded from _shared/modules/llm/api_providers.json at require time (AHK twin loads the
--- same file). Adding a provider = one entry in the JSON plus (optionally) a
--- new format branch in build_payload / parse_response below.
--- Returns (providers_table, order_array, prices_table) on success, or three
--- empty-catalogue equivalents on any failure so that a corrupted JSON file
--- never aborts the full keymap-engine require chain.
-- The request formats a provider may declare
local CATALOG_FORMATS = { openai = true, anthropic = true, gemini = true, backboard = true, decisions = true }

local function catalog_descriptor_is_valid(provider_id, desc)
	if type(desc) ~= "table" then return false end
	for _, key in ipairs({ "label", "base_url", "default_model", "format" }) do
		if type(desc[key]) ~= "string" then return false end
	end
	if desc.label:match("^%s*$") then return false end
	if not CATALOG_FORMATS[desc.format] then return false end
	if provider_id ~= "openai_compat"
		and (desc.base_url:match("^%s*$") or desc.default_model:match("^%s*$"))
	then
		return false
	end
	if desc.base_url ~= "" and not desc.base_url:match("^https?://%S+$") then return false end
	return true
end

local function catalog_price_is_valid(value)
	return type(value) == "number" and value == value and value >= 0
		and value ~= math.huge and value ~= -math.huge
end

--- Normalizes the optional per-provider model_extras section (table model id
--- -> table field -> value) into publishable tables. Fail-closed per piece:
--- doc keys, non-table models, non-scalar values and field names that would
--- break JSON are dropped with the provider still loading. Values are
--- strings or numbers, mirroring the AHK twin.
--- @param raw any providers.<id>.model_extras value.
--- @return table model id -> table field -> value (possibly empty).
local function normalize_model_extras(raw)
	local norm = {}
	if type(raw) ~= "table" then return norm end
	for model, fields in pairs(raw) do
		local usable_model = type(model) == "string" and model ~= ""
			and model:sub(1, 1) ~= "_" and type(fields) == "table"
		if usable_model then
			local kept = {}
			for field, value in pairs(fields) do
				local usable_field = type(field) == "string"
					and field:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
				local vtype = type(value)
				if usable_field and (vtype == "string" or vtype == "number") then
					kept[field] = value
				end
			end
			if next(kept) ~= nil then norm[model] = kept end
		end
	end
	return norm
end
M.__normalize_model_extras_for_test = normalize_model_extras

--- Validates the shared Test-API probe section (api_providers.json
--- test_request): the exact minimal completion both drivers send verbatim.
--- Fail-soft like the rest of the catalogue: a malformed section degrades to
--- nil and the panel refuses loudly, instead of aborting the require chain.
--- @param node any root.test_request value.
--- @return table|nil { system_prompt, user_text, temperature, max_tokens } or nil.
local function parse_test_request(node)
	if type(node) ~= "table" then
		Logger.error("llm.api_remote", "api_providers.json: test_request must be an object with system_prompt/user_text/temperature/max_tokens.")
		return nil
	end
	local sys, user, temp, toks = node.system_prompt, node.user_text, node.temperature, node.max_tokens
	if type(sys) ~= "string" or sys == "" or type(user) ~= "string" or user == "" then
		Logger.error("llm.api_remote", "api_providers.json: test_request needs non-empty system_prompt and user_text.")
		return nil
	end
	if type(temp) ~= "number" or temp ~= temp or temp < 0 or temp > 2 then
		Logger.error("llm.api_remote", "api_providers.json: test_request temperature must be a number in 0..2.")
		return nil
	end
	if type(toks) ~= "number" or toks % 1 ~= 0 or toks < 1 or toks > 64 then
		Logger.error("llm.api_remote", "api_providers.json: test_request max_tokens must be an integer in 1..64.")
		return nil
	end
	return { system_prompt = sys, user_text = user, temperature = temp, max_tokens = toks }
end

--- Validates the shared Test-API probe of a decisions provider (api_providers.json
--- decisions_test): the state and the questions both drivers send verbatim.
--- @param node any root.decisions_test value.
--- @return table|nil { state, questions } or nil.
local function parse_decisions_test(node)
	local valid = type(node) == "table" and type(node.state) == "string" and node.state ~= ""
		and type(node.questions) == "table" and next(node.questions) ~= nil
	if not valid then
		Logger.error("llm.api_remote", "api_providers.json: decisions_test must hold a non-empty state and questions.")
		return nil
	end
	return { state = node.state, questions = node.questions }
end

local function load_api_providers()
	local path = Paths.shared_llm_path("api_providers.json")
	if not path then
		-- Defensive for test/CI envs where the shared path resolution may differ or the file
		-- is not on disk in the lua cwd. Profile substitution tests often pass profile objects
		-- directly and don't need the full catalogue.
		if Logger and Logger.warn then Logger.warn("llm.api_remote", "api_providers.json not found via Paths — using empty catalogue (test/CI graceful)") end
		return {}, {}, {}
	end

	-- Wrap the entire parse/validate phase in pcall so a corrupted or schema-
	-- mismatched file degrades to an empty catalogue instead of raising at require
	-- time, which would abort the full keymap → llm → api_remote require chain.
	local ok, providers, order, prices, test_request, decisions_test = pcall(function()
		local fh = io.open(path, "r")
		if not fh then
			Logger.error("llm.api_remote", "api_providers.json unreadable at %s — empty catalogue.", tostring(path))
			return {}, {}, {}
		end
		local raw = fh:read("*a")
		fh:close()
		local parse_ok, root = pcall(JsonCodec.decode, raw)
		if not parse_ok or type(root) ~= "table" then
			Logger.error("llm.api_remote", "api_providers.json parse failed at %s — empty catalogue.", tostring(path))
			return {}, {}, {}
		end
		local p_order    = root.provider_order
		local p_providers = root.providers
		local p_prices   = root.model_prices
		if type(p_order) ~= "table" or #p_order == 0
			or type(p_providers) ~= "table" or type(p_prices) ~= "table"
		then
			Logger.error("llm.api_remote", "api_providers.json: invalid top-level structure — empty catalogue.")
			return {}, {}, {}
		end
		local out_providers = {}
		local out_order = {}
		local seen_providers = {}
		for _, pid in ipairs(p_order) do
			if type(pid) ~= "string" or pid == "" then
				Logger.warn("llm.api_remote", "api_providers.json: skipping invalid provider_order entry.")
			elseif seen_providers[pid] then
				Logger.warn("llm.api_remote", "api_providers.json: duplicate provider_order entry '%s' skipped.", pid)
			else
				seen_providers[pid] = true
				local desc = p_providers[pid]
				if not catalog_descriptor_is_valid(pid, desc) then
					Logger.warn("llm.api_remote", "api_providers.json: providers.%s has an invalid descriptor — skipped.", tostring(pid))
				else
					out_providers[pid] = {
						label         = desc.label,
						base_url      = desc.base_url,
						default_model = desc.default_model,
						format        = desc.format,
						model_extras  = normalize_model_extras(desc.model_extras),
					}
					out_order[#out_order + 1] = pid
				end
			end
		end
		local out_prices = {}
		for model, row in pairs(p_prices) do
			if type(model) == "string" and model ~= ""
				and type(row) == "table"
				and catalog_price_is_valid(row["in"])
				and catalog_price_is_valid(row["out"])
			then
				out_prices[model] = { ["in"] = row["in"], ["out"] = row["out"] }
			else
				Logger.warn("llm.api_remote", "api_providers.json: model_prices.%s skipped (missing in/out).", tostring(model))
			end
		end
		local out_test = parse_test_request(root.test_request)
		local out_decisions_test = parse_decisions_test(root.decisions_test)
		Logger.info("llm.api_remote", "Loaded API provider catalogue (%d providers) from %s", #out_order, path)
		return out_providers, out_order, out_prices, out_test, out_decisions_test
	end)

	if not ok then
		-- pcall itself failed (should never happen given the guards above, but be safe)
		Logger.error("llm.api_remote", "api_providers.json: unexpected error during load — empty catalogue: %s", tostring(providers))
		return {}, {}, {}, nil, nil
	end
	return providers or {}, order or {}, prices or {}, test_request, decisions_test
end

local MODEL_PRICES
M.PROVIDERS, M.PROVIDER_ORDER, MODEL_PRICES, M.TEST_REQUEST, M.DECISIONS_TEST = load_api_providers()

--- Registers the local servers of local_servers.json as providers of the
--- openai format that need no key. They stay out of PROVIDER_ORDER: the menus
--- list a local server only while it answers (modules/llm/local_servers.lua).
local function register_local_servers()
	for _, id in ipairs(LocalServers.ORDER) do
		local server = LocalServers.SERVERS[id]
		if M.PROVIDERS[id] ~= nil then
			Logger.error(LOG, "local_servers.json: '%s' is already a provider of api_providers.json — the local server is skipped.", id)
		else
			M.PROVIDERS[id] = {
				label         = server.label,
				base_url      = server.base_url,
				default_model = "",
				format        = "openai",
				model_extras  = {},
				local_server  = true,
			}
		end
	end
end
register_local_servers()

--- Tells whether a provider id names a local server (local_servers.json).
--- @param provider_id any
--- @return boolean
function M.is_local_server(provider_id)
	local provider = type(provider_id) == "string" and M.PROVIDERS[provider_id] or nil
	return type(provider) == "table" and provider.local_server == true
		and AuthPolicy.token_allowed(provider_id, "", LocalServers.SERVERS)
end

--- Tells whether an entry cannot be sent without a key: every provider needs
--- one except a local server, which takes one only when the user gave it.
--- @param entry table API entry.
--- @return boolean missing
local function key_missing(entry)
	if type(entry) ~= "table" then return true end
	local servers = M.is_local_server(entry.provider) and LocalServers.SERVERS or {}
	return not AuthPolicy.token_allowed(entry.provider, entry.token, servers)
end

--- Lists the providers that serve one use (modules/llm/provider_uses.lua), in
--- the catalogue's order.
--- @param use string A use of provider_uses ("prediction", "system1", "system2", "vision").
--- @return table ids
function M.provider_ids(use)
	return ProviderUses.provider_ids(M.PROVIDER_ORDER, M.PROVIDERS, use)
end

--- Tells whether a provider serves one use.
--- @param provider_id string Provider id of api_providers.json.
--- @param use string A use of provider_uses.
--- @return boolean serves
function M.provider_serves(provider_id, use)
	return ProviderUses.provider_serves(M.PROVIDERS, provider_id, use)
end

local DEDUPLICATION_ENABLED      = ApiCommon.DEFAULT_DEDUPLICATION_ENABLED
-- Retry policy from _shared/modules/llm/inference.json (api_common.lua) so the
-- remote backend tracks the same retry budget as Ollama / MLX.
local _R_MAX_MULT, _R_TEMP_STEP, _R_EXTRA_TOKENS = ApiCommon.get_retry_policy()
local RETRY_FAILED_PREDICTION    = (_R_MAX_MULT or 0) > 1
local RETRY_FAILED_MAX_MULT      = _R_MAX_MULT




-- =======================================
-- =======================================
-- ======= 2/ Multi-Entry State ==========
-- =======================================
-- =======================================

-- Array of user-configured API entries. Each entry is a table:
--   { id, provider, base_url?, token, model, label? }
-- ``base_url`` overrides the provider default when present (empty string =
-- inherit). ``label`` is the name a user typed in builds before 2026-10: it is
-- kept as stored and never read, since every tray names an entry after its
-- provider and model (_shared/lua/llm/api_entry_names.lua).
local _entries = {}
local _active_id = ""
local _is_ready = false
local _identity_generation = 0
local _availability_generation = 0
local _availability_owner = nil
local _warmup_generation = 0
local _warmup_active = false
local _warmup_last_model = nil
local _warmup_last_profile = nil
local _warmup_resume_pending = false
local _warmup_explicitly_stopped = false
local _warmup_resume_timer = nil
local _warmup_resume_observers = {}
local _warmup_resume_activation_pending = false
local _warmup_token_lease = nil
local WARMUP_RESUME_COMMIT_DELAY_SEC = 0.05
local _token_cache = {}
local _token_inflight = {}
local _token_cleanup_debt = false
local _token_cleanup_in_progress = false
local _availability_pause_cleanup_pending = false
local _warmup_client_recovery_token = nil
-- Entries already named for a provider this build no longer has, so each is
-- warned once rather than at every warmup, check and prediction.
local _retired_provider_reported = {}

--- Names a stored API entry whose provider this build no longer has. It is
--- ignored, so warmup and predictions through it are off; the entries live in
--- the app's settings, not a file, so the user replaces or deletes it from the
--- AI menu. Only a DEBUG line said so before.
--- The entry is named as the AI menu names it, after its provider and model.
--- @param entry table The stored entry (its token is never logged).
local function report_retired_provider(entry)
	local key = tostring(entry.id) .. "\0" .. tostring(entry.provider)
	if _retired_provider_reported[key] then return end
	_retired_provider_reported[key] = true
	Logger.warn(LOG, "API entry '%s/%s' names provider '%s', which this build no longer has; it is ignored — "
		.. "replace or delete it in the AI menu.", tostring(entry.provider), tostring(entry.model),
		tostring(entry.provider))
end

--- Completes one availability owner exactly once without conflating
--- cancellation with a reachable-but-invalid endpoint.
--- @param owner table|nil Availability owner.
--- @param outcome string `available`, `missing`, or `cancelled`.
--- @param detail any Missing reachability flag or cancellation reason.
--- @return boolean delivered Whether this call owned the terminal.
local function finish_availability_owner(owner, outcome, detail)
	if type(owner) ~= "table" or owner.done == true then return false end
	owner.done = true
	if _availability_owner == owner then _availability_owner = nil end
	if outcome == "available" and type(owner.on_available) == "function" then
		ApiCommon.protected_call(owner.on_available, "on_available")
	elseif outcome == "missing" and type(owner.on_missing) == "function" then
		ApiCommon.protected_call(owner.on_missing, "on_missing", detail == true)
	elseif outcome == "cancelled" and type(owner.on_cancelled) == "function" then
		ApiCommon.protected_call(owner.on_cancelled, "on_cancelled", detail)
	end
	return true
end

--- Terminalizes the current availability caller before its native request is
--- cancelled or superseded. The native callback remains fenced by owner.done.
--- @param reason string Stable cancellation reason.
local function cancel_availability_owner(reason)
	finish_availability_owner(_availability_owner, "cancelled", reason)
end

local function read_script_pause_state()
	local control = package.loaded["modules.shortcuts.script_control"]
	if type(control) ~= "table" then return false, 0, true end
	local epoch = 0
	if type(control.get_pause_epoch) == "function" then
		local epoch_ok, value = xpcall(control.get_pause_epoch, debug.traceback)
		if not epoch_ok or type(value) ~= "number" then return true, -1, false end
		epoch = value
	end
	if type(control.is_paused) ~= "function" then return false, epoch, true end
	local paused_ok, paused = xpcall(control.is_paused, debug.traceback)
	if not paused_ok or type(paused) ~= "boolean" then return true, epoch, false end
	return paused, epoch, true
end

local stage_warmup_resume
local recover_warmup_resume
local recover_warmup_after_client
local begin_warmup_resume_activation

local function cancel_warmup_resume_timer()
	local handle = _warmup_resume_timer
	if type(handle) ~= "table" or handle.timer == nil then
		_warmup_resume_timer = nil
		return true
	end
	local ok, result = xpcall(function()
		return TimerScheduler.cancel(handle)
	end, debug.traceback)
	if not ok or result ~= true then return false end
	if _warmup_resume_timer == handle then _warmup_resume_timer = nil end
	return true
end

local function cancel_warmup_token_lease()
	local lease = _warmup_token_lease
	if lease == nil then return true end
	if type(lease) ~= "table" or type(lease.cancel) ~= "function" then return false end
	local ok, result = xpcall(lease.cancel, debug.traceback)
	if not ok or result ~= true then return false end
	if _warmup_token_lease == lease then _warmup_token_lease = nil end
	return true
end

--- Retains one continuation for a staging timer whose native cleanup settles
--- after the lifecycle call already returned.
local function observe_warmup_resume_settlement(handle, epoch, generation)
	if type(handle) ~= "table" or _warmup_resume_observers[handle] == true then return true end
	if type(TimerScheduler.onSettled) ~= "function" then return false end
	_warmup_resume_observers[handle] = true
	local ok, registered_or_err = xpcall(function()
		return TimerScheduler.onSettled(handle, function()
			_warmup_resume_observers[handle] = nil
			if _warmup_resume_timer == handle then _warmup_resume_timer = nil end
			if generation ~= _warmup_generation or _warmup_resume_pending ~= true then return end
			local paused, current_epoch, state_ok = read_script_pause_state()
			if state_ok == true and paused ~= true and current_epoch == epoch then
				recover_warmup_resume(epoch, true)
			end
		end)
	end, debug.traceback)
	if not ok or registered_or_err ~= true then
		_warmup_resume_observers[handle] = nil
		return false
	end
	return true
end

local function arm_warmup_resume(epoch)
	if type(_warmup_resume_timer) == "table"
		and _warmup_resume_timer.timer ~= nil
		and _warmup_resume_timer.committed == true then
		return true
	end
	if cancel_warmup_resume_timer() ~= true then return false end
	-- cancel() may synchronously deliver an old handle's settlement observer,
	-- which can already acquire the one valid successor before this outer frame
	-- resumes. Never overwrite that re-entrant publication with a sibling.
	if _warmup_resume_pending ~= true then return true end
	if type(_warmup_resume_timer) == "table"
		and _warmup_resume_timer.timer ~= nil
		and _warmup_resume_timer.committed == true then
		return true
	end
	local generation = _warmup_generation
	local handle
	local committed
	local arm_ok, arm_error = xpcall(function()
		handle, committed = TimerScheduler.after(WARMUP_RESUME_COMMIT_DELAY_SEC, function()
			if _warmup_resume_timer ~= handle then return end
			if handle.timer ~= nil then
				observe_warmup_resume_settlement(handle, epoch, generation)
				return
			end
			_warmup_resume_timer = nil
			if committed ~= true or generation ~= _warmup_generation
				or _warmup_resume_pending ~= true then return end
			local paused, current_epoch, state_ok = read_script_pause_state()
			if state_ok ~= true then
				recover_warmup_resume(epoch, false)
				return
			end
			if current_epoch ~= epoch then return end
			if paused == true then
				recover_warmup_resume(epoch, false)
				return
			end
			begin_warmup_resume_activation(epoch, true)
		end)
	end, debug.traceback)
	if type(handle) == "table" and handle.timer ~= nil then
		_warmup_resume_timer = handle
	end
	if not arm_ok or committed ~= true or type(handle) ~= "table" or handle.timer == nil then
		if type(handle) == "table" and handle.timer ~= nil then
			observe_warmup_resume_settlement(handle, epoch, generation)
		end
		Logger.error(LOG, "Remote warmup resume staging failed: %s.",
			tostring(arm_ok and committed or arm_error))
		return false
	end
	handle.committed = true
	_warmup_resume_timer = handle
	return true
end

stage_warmup_resume = arm_warmup_resume

--- Performs a bounded recovery after a post-commit retry acquisition refuses.
--- One clean scheduler refusal gets one immediate replacement attempt; if the
--- scheduler remains unavailable, a confirmed RESUMED runtime may perform the
--- warmup directly once. Pending intent remains observable through is_ready().
recover_warmup_resume = function(epoch, allow_direct)
	if _warmup_resume_activation_pending == true then return true end
	if _warmup_client_recovery_token ~= nil then return true end
	if stage_warmup_resume(epoch) == true then return true end
	if type(_warmup_resume_timer) == "table" and _warmup_resume_timer.timer ~= nil then
		return false
	end
	if stage_warmup_resume(epoch) == true then return true end
	if type(_warmup_resume_timer) == "table" and _warmup_resume_timer.timer ~= nil then
		return false
	end
	if allow_direct ~= true then return false end
	local paused, current_epoch, state_ok = read_script_pause_state()
	if state_ok ~= true or paused == true or current_epoch ~= epoch
		or _warmup_resume_pending ~= true then return false end
	return begin_warmup_resume_activation(epoch, false)
end

--- Waits for all private HttpClient capabilities before staging a successor.
--- `onSettled` invokes synchronously for a clean refusal and asynchronously for
--- a retained timeout/task debt, so the same path covers both without overlap.
recover_warmup_after_client = function(epoch, allow_direct)
	local recovery_generation = _warmup_generation
	if type(_warmup_client.onSettled) ~= "function" then
		return recover_warmup_resume(epoch, allow_direct)
	end
	local token = {}
	_warmup_client_recovery_token = token
	local ok, registered_or_err = xpcall(function()
		return _warmup_client.onSettled(function()
			if _warmup_client_recovery_token ~= token then return end
			_warmup_client_recovery_token = nil
			if recovery_generation ~= _warmup_generation
				or _warmup_resume_pending ~= true then return end
			local paused, current_epoch, state_ok = read_script_pause_state()
			if state_ok == true and paused ~= true and current_epoch == epoch then
				recover_warmup_resume(epoch, allow_direct)
			end
		end)
	end, debug.traceback)
	if not ok or registered_or_err ~= true then
		if _warmup_client_recovery_token == token then
			_warmup_client_recovery_token = nil
		end
		return recover_warmup_resume(epoch, allow_direct)
	end
	return true
end

--- Starts one resumed warmup but consumes restore intent only when the real GET
--- acquisition commits. Encrypted tokens may resolve long after M.warmup returns.
begin_warmup_resume_activation = function(epoch, allow_direct_recovery)
	if _warmup_resume_activation_pending == true then return true end
	local terminal = false
	local outcome = false
	_warmup_resume_activation_pending = true
	local call_ok, accepted_or_err = xpcall(function()
		return M.warmup(_warmup_last_model, _warmup_last_profile, function(committed)
			if terminal then return end
			terminal = true
			_warmup_resume_activation_pending = false
			if committed == true then
				_warmup_resume_pending = false
				outcome = true
				return
			end
			outcome = recover_warmup_after_client(epoch, allow_direct_recovery)
		end)
	end, debug.traceback)
	local accepted = call_ok == true and accepted_or_err or false
	if not call_ok then
		Logger.error(LOG, "Remote resumed warmup raised: %s.", tostring(accepted_or_err))
	end
	if accepted ~= true and terminal ~= true then
		terminal = true
		_warmup_resume_activation_pending = false
		return recover_warmup_after_client(epoch, allow_direct_recovery)
	end
	if terminal == true then return outcome == true end
	return accepted == true
end

--- Delivers one token-resolution result without exposing a callback throw to
--- the task-completion boundary that called it.
--- @param callback function|nil Resolver callback.
--- @param ... any Callback arguments.
local function invoke_token_callback(callback, ...)
	if type(callback) ~= "function" then return end
	local args = table.pack(...)
	local ok, err = xpcall(function()
		callback(table.unpack(args, 1, args.n))
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "Token resolver callback raised: %s", tostring(err))
	end
end

--- Returns an already-settled resolver lease for synchronous/no-op outcomes.
--- @return table lease
local function settled_token_lease()
	return { cancel = function() return true end }
end

--- Removes one waiter identity without disturbing siblings sharing the task.
local function remove_token_waiter(record, waiter)
	for index, candidate in ipairs(record.waiters or {}) do
		if candidate == waiter then
			table.remove(record.waiters, index)
			return
		end
	end
end

--- Fences every waiter and joins the shared Keychain operations exactly. Records
--- remain globally owned across false/nil/throw so neither a pause retry nor an
--- identity successor can overlap the native task/timeout.
--- @param reason string Stable invalidation reason.
--- @param notify_waiters boolean Whether superseded callers receive a terminal.
--- @return boolean settled
local function settle_token_resolutions(reason, notify_waiters)
	_token_cache = {}
	if _token_cleanup_in_progress == true then
		_token_cleanup_debt = true
		return false
	end
	_token_cleanup_in_progress = true
	_token_cleanup_debt = true

	-- Detach a stable waiter snapshot before any callback is delivered. A
	-- superseded callback is allowed to re-enter the resolver, but the cleanup
	-- fence above makes that attempt settle synchronously without coalescing onto
	-- either this record or a successor operation.
	local records = {}
	for cache_key, record in pairs(_token_inflight) do
		local waiters = record.waiters or {}
		record.waiters = {}
		records[#records + 1] = {
			cache_key = cache_key,
			record = record,
			waiters = waiters,
		}
	end

	local settled = true
	for _, owned in ipairs(records) do
		local cache_key = owned.cache_key
		local record = owned.record
		if record.done == true then
			if _token_inflight[cache_key] == record then
				_token_inflight[cache_key] = nil
			end
		else
			for _, waiter in ipairs(owned.waiters) do
				if waiter.active == true then
					waiter.active = false
					if notify_waiters == true then
						invoke_token_callback(waiter.callback, false, nil, reason)
					end
				end
			end
			local cancel_ok, cancel_result = xpcall(function()
				if type(record.operation) ~= "table"
					or type(record.operation.cancel) ~= "function" then
					return false
				end
				return record.operation.cancel()
			end, debug.traceback)
			if record.done == true or (cancel_ok == true and cancel_result == true) then
				if record.done ~= true then record.done = true end
				if _token_inflight[cache_key] == record then
					_token_inflight[cache_key] = nil
				end
			else
				settled = false
				Logger.error(LOG, "Keychain read cancellation retained exact debt: %s",
					tostring(cancel_result))
			end
		end
	end
	_token_cache = {}
	_token_cleanup_debt = settled ~= true
	_token_cleanup_in_progress = false
	return settled
end

local function invalidate_token_resolutions(reason)
	return settle_token_resolutions(reason, true)
end

--- Invalidates every asynchronous operation owned by the prior remote entry.
--- Entry identity is a request-generation boundary: a healthy response from A
--- must never make B ready, and A's completion must never publish after B was
--- selected. The adapter generation is the first fence; this module generation
--- remains authoritative even when a native completion was already queued.
local function invalidate_identity()
	cancel_availability_owner("identity_changed")
	_identity_generation = _identity_generation + 1
	_availability_generation = _availability_generation + 1
	_warmup_generation = _warmup_generation + 1
	_token_cleanup_debt = true
	invalidate_token_resolutions("identity_changed")
	_warmup_active = false
	_warmup_resume_pending = false
	_warmup_explicitly_stopped = true
	if cancel_warmup_resume_timer() ~= true then
		Logger.error(LOG, "Remote resume-stage cancellation failed during identity change.")
	end
	if cancel_warmup_token_lease() ~= true then
		Logger.error(LOG, "Remote token-waiter cancellation failed during identity change.")
	end
	_is_ready = false
	for label, client in pairs({
		availability = _check_client,
		inference = _infer_client,
		warmup = _warmup_client,
	}) do
		local ok, result = xpcall(function() return client.cancel() end, debug.traceback)
		if not ok or result ~= true then
			Logger.error(LOG, "Remote %s cancellation failed during identity change: %s.",
				tostring(label), tostring(result))
		end
	end
end

--- Replace the full list of configured API entries. Used at load time from
--- the persisted JSON sidecar and whenever the tray menu adds / removes one.
--- @param entries table Array of entry tables. Pass {} to clear.
function M.set_entries(entries)
	if type(entries) ~= "table" then return end
	invalidate_identity()
	_entries = {}
	for _, e in ipairs(entries) do
		if type(e) == "table" then table.insert(_entries, e) end
	end
	Logger.debug(LOG, "API entries set (%d entry/entries).", #_entries)
end

function M.get_entries()
	return _entries
end

--- The shared Test-API probe spec (api_providers.json test_request), or nil
--- when the catalogue carries none. The panel refuses loudly on nil instead
--- of probing with invented values.
--- @return table|nil { system_prompt, user_text, temperature, max_tokens }.
function M.get_test_request_spec()
	if type(M.TEST_REQUEST) ~= "table" then return nil end
	return M.TEST_REQUEST
end

--- Pick the active API entry by id. Empty and unknown ids deliberately select
--- no entry: the menu's "No Model" choice must disable runtime inference rather
--- than silently falling back to the first configured account.
--- @param id string Active entry identifier (matches entry.id field).
function M.set_active_entry_id(id)
	if type(id) ~= "string" then return end
	if id == _active_id then return end
	_active_id = id
	invalidate_identity()
	Logger.debug(LOG, "Active API entry id: '%s'.", id)
end

function M.get_active_entry_id()
	return _active_id
end

--- Returns the opaque generation for the complete remote-entry identity.
--- Consumers may compare tokens for freshness but must never infer or mutate it.
--- @return number generation
function M.get_identity_generation()
	return _identity_generation
end

--- Finds the currently active entry object by exact id without resolving its
--- token. An empty or unknown id intentionally means "No Model".
--- @return table|nil entry
local function find_active_entry()
	if #_entries == 0 or _active_id == "" then return nil end
	for _, entry in ipairs(_entries) do
		if entry.id == _active_id then return entry end
	end
	return nil
end

--- Returns active entry metadata without decrypting or mutating its token.
--- Menu construction calls this function, so it must remain deterministic and
--- free of subprocess work even when the login Keychain is locked.
--- @return table|nil entry
function M.get_active_entry()
	return find_active_entry()
end

--- Returns a shallow copy whose token is cleartext, leaving the persisted entry
--- object untouched. Concurrent callers for the same exact identity/reference
--- share one Keychain task. Identity changes complete all waiters as stale and
--- prevent the old task from publishing cache state.
--- @param callback function Receives (ok, resolved_entry, reason).
--- @return table lease Exact ownership of this one waiter.
function M.resolve_active_entry(callback)
	local paused, _, pause_state_ok = read_script_pause_state()
	if _token_cleanup_debt == true and _token_cleanup_in_progress ~= true then
		settle_token_resolutions("resolver_preflight", false)
	end
	if pause_state_ok ~= true or paused == true or _token_cleanup_debt == true then
		invoke_token_callback(callback, false, nil, "resolver_quiesced")
		return settled_token_lease()
	end
	local entry = find_active_entry()
	if not entry then
		invoke_token_callback(callback, false, nil, "no_active_entry")
		return settled_token_lease()
	end
	local stored = entry.token
	if key_missing(entry) then
		invoke_token_callback(callback, false, nil, "missing_token")
		return settled_token_lease()
	end

	local function resolved_copy(cleartext)
		local copy = {}
		for key, value in pairs(entry) do copy[key] = value end
		copy.token = cleartext
		return copy
	end

	-- A local server the user gave no key to is sent none
	if type(stored) ~= "string" or stored == "" then
		invoke_token_callback(callback, true, resolved_copy(""), nil)
		return settled_token_lease()
	end
	if not TokenCrypto.is_encrypted(stored) then
		invoke_token_callback(callback, true, resolved_copy(stored), nil)
		return settled_token_lease()
	end

	local cache_key = tostring(entry.id) .. "\0" .. stored
	local cached = _token_cache[cache_key]
	if type(cached) == "string" and cached ~= "" then
		invoke_token_callback(callback, true, resolved_copy(cached), nil)
		return settled_token_lease()
	end

	local waiter = { callback = callback, active = true, record = nil }
	local lease = {}
	lease.cancel = function()
		if waiter.active ~= true then return true end
		local record = waiter.record
		if type(record) ~= "table" or record.done == true then
			waiter.active = false
			return true
		end
		for _, sibling in ipairs(record.waiters or {}) do
			if sibling ~= waiter and sibling.active == true then
				waiter.active = false
				remove_token_waiter(record, waiter)
				return true
			end
		end
		if type(record.operation) ~= "table"
			or type(record.operation.cancel) ~= "function" then
			return false
		end

		-- Revoke callback delivery before crossing the fallible native boundary.
		-- Restore it only when the same operation remains genuinely unsettled.
		waiter.active = false
		local cancel_ok, cancel_result = xpcall(function()
			return record.operation.cancel()
		end, debug.traceback)
		if not cancel_ok or cancel_result ~= true then
			if record.done ~= true then waiter.active = true end
			return record.done == true
		end
		remove_token_waiter(record, waiter)
		if record.done ~= true then
			record.done = true
			for key, candidate in pairs(_token_inflight) do
				if candidate == record then _token_inflight[key] = nil end
			end
		end
		return true
	end

	local existing = _token_inflight[cache_key]
	if existing and existing.done ~= true then
		waiter.record = existing
		existing.waiters[#existing.waiters + 1] = waiter
		return lease
	end

	local record = {
		done = false,
		entry = entry,
		stored = stored,
		generation = _identity_generation,
		waiters = { waiter },
	}
	waiter.record = record
	_token_inflight[cache_key] = record

	local function finish(ok, cleartext, reason)
		if record.done == true then return end
		record.done = true
		if _token_inflight[cache_key] == record then _token_inflight[cache_key] = nil end
		local still_current = record.generation == _identity_generation
			and find_active_entry() == record.entry
			and record.entry.token == record.stored
		if not still_current then
			ok, cleartext, reason = false, nil, "stale_identity"
		elseif ok == true and type(cleartext) == "string" and cleartext ~= "" then
			_token_cache[cache_key] = cleartext
		else
			ok, cleartext, reason = false, nil, reason or "decrypt_failed"
		end
		for _, pending_waiter in ipairs(record.waiters) do
			if pending_waiter.active == true then
				pending_waiter.active = false
				invoke_token_callback(pending_waiter.callback,
					ok, ok and resolved_copy(cleartext) or nil, reason)
			end
		end
	end

	local launch_ok, operation_or_err = xpcall(function()
		return TokenCrypto.decrypt_async(stored, finish)
	end, debug.traceback)
	if not launch_ok then
		Logger.error(LOG, "Keychain resolver launch raised for entry '%s': %s",
			tostring(entry.id), tostring(operation_or_err))
		finish(false, nil, "launch_failed")
	else
		record.operation = operation_or_err
		if record.done == true and type(operation_or_err) == "table"
			and type(operation_or_err.cancel) == "function" then
			local cancel_ok, cancel_err = xpcall(function()
				return operation_or_err.cancel()
			end, debug.traceback)
			if not cancel_ok or cancel_err ~= true then
				Logger.error(LOG, "Completed Keychain read cleanup raised: %s", tostring(cancel_err))
			end
		end
	end
	return lease
end

--- Starts a best-effort asynchronous token resolution after persisted state
--- loads. Correctness never depends on this prewarm: every network path calls
--- resolve_active_entry itself.
function M.prewarm_active_entry_decrypt()
	M.resolve_active_entry(function(ok, entry, reason)
		if ok then
			Logger.debug(LOG, "Pre-warmed Keychain token for active API entry '%s'.",
				tostring(entry and entry.id))
		elseif reason ~= "no_active_entry" and reason ~= "missing_token" then
			Logger.warn(LOG, "Keychain token prewarm did not complete: %s.", tostring(reason))
		end
	end)
end




-- =======================================
-- =======================================
-- ======= 3/ URL + Auth Helpers =========
-- =======================================
-- =======================================

--- Trim a trailing slash if present. Lua's string.gsub returns the count too,
--- so we drop it with a parenthesised expression for cleanliness.
local function rtrim_slash(s)
	return (tostring(s or ""):gsub("/+$", ""))
end

--- Validates and normalizes one remote provider base URL without logging it.
--- Userinfo, query strings, fragments, and whitespace are refused because they
--- can smuggle credentials or alter every endpoint appended by this module.
--- @param raw any Candidate base URL.
--- @return string|nil normalized Valid HTTP(S) base without trailing slashes.
--- @return string reason Privacy-safe refusal reason.
local function normalize_base_url(raw)
	if type(raw) ~= "string" or raw == "" then
		return nil, "base URL is empty"
	end
	if raw:find("[%c%s]") then
		return nil, "base URL contains whitespace or control characters"
	end
	if raw:find("\\", 1, true) then
		return nil, "base URL contains a backslash"
	end

	local scheme, authority, suffix = raw:match("^([%a][%w+%.%-]*)://([^/?#]+)(.*)$")
	if not scheme or not authority then
		return nil, "base URL must include a scheme and host"
	end
	scheme = scheme:lower()
	if scheme ~= "http" and scheme ~= "https" then
		return nil, "base URL scheme must be http or https"
	end
	if authority:find("@", 1, true) then
		return nil, "base URL authority must not contain userinfo"
	end
	if suffix:find("?", 1, true) or suffix:find("#", 1, true) then
		return nil, "base URL must not contain a query or fragment"
	end

	local host = authority
	local port
	if authority:sub(1, 1) == "[" then
		local bracket_host, remainder = authority:match("^(%[[^%]]+%])(.*)$")
		local bracket_value = bracket_host and bracket_host:sub(2, -2) or ""
		if bracket_value == ""
			or not bracket_value:match("^[%w:%.%%%-]+$")
			or not bracket_value:find(":", 1, true)
			or not bracket_value:find("[%x]") then
			return nil, "base URL host is invalid"
		end
		host = bracket_host
		if remainder ~= "" then
			port = remainder:match("^:(%d+)$")
			if not port then return nil, "base URL port is invalid" end
		end
	else
		local host_with_port, port_text = authority:match("^([^:]+):(%d+)$")
		if host_with_port then
			host = host_with_port
			port = port_text
		elseif authority:find(":", 1, true) then
			return nil, "base URL port is invalid"
		end
		if not host:match("^[%w%._%-]+$") or not host:find("[%w]") then
			return nil, "base URL host is invalid"
		end
	end
	if port then
		local numeric_port = tonumber(port)
		if not numeric_port or numeric_port < 1 or numeric_port > 65535 then
			return nil, "base URL port is outside 1..65535"
		end
	end

	return rtrim_slash(scheme .. "://" .. authority .. suffix), "ok"
end

--- Resolves and validates the effective base URL for one entry/provider pair.
--- @param entry table Active remote entry.
--- @param provider table Provider descriptor.
--- @return string|nil normalized
--- @return string reason
local function resolve_base_url(entry, provider)
	local raw = entry.base_url
	if raw == nil or raw == "" then raw = provider.base_url end
	return normalize_base_url(raw)
end

--- Reports an endpoint refusal without persisting the rejected URL itself.
--- @param operation string Semantic operation.
--- @param entry table Active remote entry.
--- @param reason string Privacy-safe validation detail.
local function log_endpoint_refusal(operation, entry, reason)
	Logger.error(LOG,
		"Remote %s refused invalid endpoint configuration for provider '%s' (entry '%s'): %s.",
		tostring(operation), tostring(entry and entry.provider),
		tostring(entry and entry.id), tostring(reason))
end

--- Query parameters that carry a credential. Gemini authenticates by URL
--- (`?key=<token>`) rather than by header, so the finished request URL contains
--- the decrypted API key verbatim.
local CREDENTIAL_QUERY_PARAMS = {
	key = true,
	api_key = true,
	apikey = true,
	access_token = true,
	token = true,
}

--- Redact credentials from a URL so it can be written to a log file.
---
--- The whole point of api_token_crypto is that the cleartext token never lands
--- on disk. Logging the finished Gemini URL defeated that in one line: the
--- default log level is DEBUG, retention is fourteen days, and this is a file
--- users are actively told to consult and attach to support requests — so the
--- key was written on EVERY prediction, to a file designed to be shared.
---
--- Redacting rather than dropping the URL keeps the diagnostic that matters
--- (which endpoint and model were hit) while removing the part that must never
--- be persisted.
--- @param url string The URL about to be logged.
--- @return string The URL with userinfo and credential parameter values replaced.
local function redact_url(url)
	local out = tostring(url or "")

	-- Userinfo is credential-bearing regardless of its spelling. Keep the
	-- scheme and authority visible for diagnostics, but never persist either
	-- the username or password. The greedy userinfo capture deliberately ends
	-- at the last '@' in the authority so an embedded '@' cannot expose a tail.
	out = out:gsub("^([%a][%w+%.%-]*://)([^/%?#]*@)([^/%?#]+)",
		function(scheme, _userinfo, authority)
			return scheme .. "REDACTED@" .. authority
		end, 1)

	-- Preserve the original query-name spelling and every non-credential
	-- parameter. Only the comparison is case-folded; values stop at the next
	-- query separator or fragment boundary.
	out = out:gsub("([%?&])([^=&#]*)(=)([^&#]*)",
		function(delimiter, name, equals, value)
			if CREDENTIAL_QUERY_PARAMS[name:lower()] then
				return delimiter .. name .. equals .. "REDACTED"
			end
			return delimiter .. name .. equals .. value
		end)
	return out
end

--- Builds the per-provider inference URL from validated components. Gemini
--- places one encoded model segment in the path; the OpenAI, Anthropic, and
--- compatible shapes use fixed endpoints with the model in the JSON payload.
--- @param base string Validated base URL.
--- @param format string Provider wire format.
--- @param model string Candidate model resource name.
--- @param token string Decrypted API token.
--- @return string|nil url
--- @return string|nil reason
local function build_url(base, format, model, token)
	if format == "anthropic" then
		return base .. "/messages", nil
	end
	if format == "gemini" then
		-- Gemini: /models/<model>:generateContent?key=<token>
		if type(model) ~= "string" then return nil, "model name must be a string" end
		if model:sub(1, 7) == "models/" then model = model:sub(8) end
		if model == "" then return nil, "Gemini model name is empty" end
		local segment = _http_adapter.encodePathSegment(model)
		local enc = _http_adapter.encodeForQuery(token)
		return base .. "/models/" .. segment .. ":generateContent?key=" .. enc, nil
	end
	-- OpenAI / OpenAI-compatible
	return base .. "/chat/completions", nil
end

--- Builds the provider's authenticated models endpoint from a validated base.
--- @param base string Validated base URL.
--- @param format string Provider wire format.
--- @param token string Decrypted API token.
--- @return string url
local function build_models_url(base, format, token)
	if format == "gemini" then
		return base .. "/models?key=" .. _http_adapter.encodeForQuery(token)
	end
	return base .. "/models"
end

--- Compute the per-provider auth headers. Gemini carries auth via the URL
--- query string and has nothing to add here; OpenAI uses Bearer; Anthropic
--- uses x-api-key + a fixed version pin; Backboard its own key header, with no
--- Bearer; a decisions provider a Bearer header (llm/remote_formats.lua).
local function build_headers(format, token)
	local headers = { ["Content-Type"] = "application/json" }
	if format == "backboard" then
		if token and token ~= "" then headers[Formats.BACKBOARD_KEY_HEADER] = token end
		return headers
	end
	if format == "decisions" then
		if token and token ~= "" then headers[Formats.DECISIONS_KEY_HEADER] = Formats.decisions_key_value(token) end
		return headers
	end
	if format == "anthropic" then
		if token and token ~= "" then headers["x-api-key"] = token end
		headers["anthropic-version"] = "2023-06-01"
		return headers
	end
	if format == "gemini" then
		-- Token already in the URL.
		return headers
	end
	if token and token ~= "" then
		headers["Authorization"] = "Bearer " .. token
	end
	return headers
end


--- Verifies that a successful models response belongs to the configured API.
--- A generic HTTP 2xx only proves that something answered at the URL; captive
--- portals and reverse-proxy error pages must not publish backend readiness.
--- @param format string Provider wire format.
--- @param response table HTTP response.
--- @return boolean valid True only for a provider-shaped models catalogue.
--- @return string reason Privacy-safe refusal reason.
local function models_response_is_valid(format, response)
	if type(response) ~= "table" or response.ok ~= true then
		return false, "HTTP request failed"
	end
	-- Backboard lists no models: its probe is the creation of the assistant
	if format == "backboard" then
		if type(response.assistant_id) ~= "string" then return false, "assistant id is missing" end
		return true, "ok"
	end
	if type(response.body) ~= "string" or response.body == "" then
		return false, "response body is empty"
	end
	local decode_ok, decoded, decode_error = pcall(JsonCodec.decode, response.body)
	if not decode_ok or decode_error ~= nil or type(decoded) ~= "table" then
		return false, "response body is not valid JSON"
	end
	local catalogue_key = format == "gemini" and "models" or "data"
	if type(decoded[catalogue_key]) ~= "table" then
		return false, "models catalogue is missing"
	end
	return true, "ok"
end


--- Logs a provider-identity refusal without exposing response bytes or tokens.
--- @param operation string Health operation label.
--- @param entry table Active API entry.
--- @param response table HTTP response.
--- @param reason string Privacy-safe refusal reason.
local function log_models_response_refusal(operation, entry, response, reason)
	Logger.warn(LOG,
		"Remote %s received an invalid models response (provider=%s, status=%s, reason=%s).",
		operation,
		tostring(entry and entry.provider),
		tostring(type(response) == "table" and response.status or nil),
		tostring(reason))
end

--- Build the JSON payload for the chosen provider format. We keep the body
--- minimal but correct: one system message + one user message + temperature.
--- Streaming is OFF — the engine-level pacing already protects paid quotas,
--- and the single-shot path keeps error handling trivial.
--- @param extras table|nil Per-model body fields from the catalogue
--- (model_extras), merged into OpenAI-shape payloads only. Anthropic and
--- Gemini branches never receive them. No per-model literal may ever be
--- restated here (single-sourced in api_providers.json).
local function build_payload(format, model, system_prompt, user_prompt, temperature, max_tokens, extras)
	temperature = tonumber(temperature) or ApiCommon.DEFAULT_TEMPERATURE
	-- No literal: an unset cap resolves to the one shared default
	-- (DEFAULT_MAX_TOKENS), the same constant the engine threads from the budget.
	max_tokens  = tonumber(max_tokens) or SharedPromptBuilder.DEFAULT_MAX_TOKENS

	if format == "anthropic" then
		return {
			model      = model,
			system     = system_prompt or "",
			messages   = { { role = "user", content = user_prompt or "" } },
			max_tokens = max_tokens,
			temperature = temperature,
		}
	end
	if format == "gemini" then
		return {
			systemInstruction = { parts = { { text = system_prompt or "" } } },
			contents          = { { role = "user", parts = { { text = user_prompt or "" } } } },
			generationConfig  = { temperature = temperature, maxOutputTokens = max_tokens },
		}
	end
	-- OpenAI Chat Completions
	local payload = {
		model       = model,
		messages    = {
			{ role = "system", content = system_prompt or "" },
			{ role = "user",   content = user_prompt   or "" },
		},
		temperature = temperature,
		max_tokens  = max_tokens,
		stream      = false,
	}
	if type(extras) == "table" then
		for field, value in pairs(extras) do
			local vtype = type(value)
			if type(field) == "string"
				and field:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
				and (vtype == "string" or vtype == "number")
			then
				payload[field] = value
			end
		end
	end
	return payload
end
M.__build_payload_for_test = build_payload

--- Extracts the provider's own error text (error.message, else a top-level
--- message as in the Cerebras error shape) without promoting content
--- decoys. Trimmed for notifications; nil when there is nothing to show.
--- @param body any Response body.
--- @return string|nil Message or nil.
local function extract_server_message(body)
	if type(body) ~= "string" or body == "" then return nil end
	local ok, root = pcall(JsonCodec.decode, body)
	if not ok or type(root) ~= "table" then return nil end
	local err = root.error
	if type(err) == "table" and type(err.message) == "string" and err.message ~= "" then
		return err.message:sub(1, 200)
	end
	if type(root.message) == "string" and root.message ~= "" then
		return root.message:sub(1, 200)
	end
	return nil
end
M.__extract_server_message_for_test = extract_server_message

--- Builds the failure detail a caller shows: the status and the provider's own message.
--- @param reason string Short reason.
--- @param response table|nil The HTTP response, when one came back.
--- @return table detail { reason, status, message }
local function failure_detail(reason, response)
	local status = type(response) == "table" and tonumber(response.status) or 0
	local body = type(response) == "table" and response.body or nil
	return { reason = reason, status = status or 0, message = extract_server_message(body) or "" }
end

--- Decodes a JSON response body.
--- @param body any Response body.
--- @return table|nil decoded Nil when the body is not a JSON object or array.
local function decode_body(body)
	if type(body) ~= "string" or body == "" then return nil end
	local ok, decoded = pcall(JsonCodec.decode, body)
	if not ok or type(decoded) ~= "table" then return nil end
	return decoded
end

--- Names the top-level keys of a decoded answer, never its values: what a log
--- may say about an answer whose shape was not the expected one.
--- @param value any Decoded answer.
--- @return string keys Sorted, comma-separated, or the value's type.
local function top_level_keys(value)
	if type(value) ~= "table" then return type(value) end
	local keys = {}
	for key in pairs(value) do keys[#keys + 1] = tostring(key) end
	table.sort(keys)
	return table.concat(keys, ", ")
end
M.__top_level_keys_for_test = top_level_keys

-- The Backboard assistant of each base URL and key, for this session: it is
-- created at the first request of the key, then every message names it
local _backboard_assistants = {}

--- Calls back with the Backboard assistant of a key, creating it first when
--- this session has none. A failed creation caches nothing: the next request
--- tries again.
--- @param client table HTTP client that sends the creation.
--- @param base string Validated base URL.
--- @param token string Decrypted key.
--- @param on_id function Receives the assistant id.
--- @param on_fail function Receives (reason, response|nil).
--- @return boolean dispatched True when the id was known or its creation was sent.
local function ensure_backboard_assistant(client, base, token, on_id, on_fail)
	local cache_key = base .. "\0" .. token
	local cached = _backboard_assistants[cache_key]
	if cached then
		on_id(cached)
		return true
	end
	local request = Formats.backboard_assistant_request(base)
	local encoded, encode_error = JsonCodec.encode(request.body)
	if not encoded then
		Logger.error(LOG, "Backboard assistant request encode failed: %s.", tostring(encode_error))
		on_fail("encode_failed", nil)
		return false
	end
	Logger.info(LOG, "Backboard assistant requested for this key -> %s.", redact_url(request.url))
	return client.post(request.url, build_headers("backboard", token), encoded, function(r)
		Logger.pcall(LOG, function()
			if type(r) ~= "table" or r.ok ~= true then
				local status = type(r) == "table" and r.status or nil
				Logger.error(LOG, "Backboard assistant creation failed: HTTP %s (%s).", tostring(status),
					tostring(type(r) == "table" and (extract_server_message(r.body) or r.error) or ""))
				on_fail("assistant_http_" .. tostring(status or "unknown"), r)
				return
			end
			local decoded = decode_body(r.body)
			local id = Formats.backboard_assistant_id(decoded)
			if not id then
				Logger.error(LOG, "Backboard assistant creation answered no assistant_id (keys: %s).",
					top_level_keys(decoded))
				on_fail("assistant_missing", r)
				return
			end
			_backboard_assistants[cache_key] = id
			Logger.info(LOG, "Backboard assistant created; every request of this key names it.")
			on_id(id)
		end)
	end) == true
end

--- Sends one Backboard message on a new thread, creating the key's assistant
--- first when needed. Backboard's message shape has no temperature or token
--- budget: none is sent.
--- @param client table HTTP client.
--- @param base string Validated base URL.
--- @param token string Decrypted key.
--- @param spec table { model = "<llm_provider>/<model_name>", system, text, questions? }
--- @param on_response function Receives the HTTP response of the message.
--- @param on_fail function Receives (reason, detail) when no message could be sent.
--- @return boolean dispatched
local function post_backboard_message(client, base, token, spec, on_response, on_fail)
	if not Formats.backboard_split_model(spec.model) then
		Logger.error(LOG, "Backboard request refused: model '%s' names no provider (<llm_provider>/<model_name>).",
			tostring(spec.model))
		on_fail("invalid_model", failure_detail("invalid_model", nil))
		return false
	end
	return ensure_backboard_assistant(client, base, token, function(assistant_id)
		local request = Formats.backboard_message_request(base, {
			assistant_id = assistant_id, model = spec.model, system = spec.system or "",
			text = spec.text or "", questions = spec.questions,
		})
		local encoded, encode_error = JsonCodec.encode(request.body)
		if not encoded then
			Logger.error(LOG, "Backboard message encode failed: %s.", tostring(encode_error))
			on_fail("encode_failed", failure_detail("encode_failed", nil))
			return
		end
		client.post(request.url, build_headers("backboard", token), encoded, on_response)
	end, function(reason, r)
		on_fail(reason, failure_detail(reason, r))
	end)
end

--- Sends a provider's readiness probe: its models list, or for Backboard the
--- creation of the key's assistant, answered as { ok, status, assistant_id }.
--- @param client table HTTP client.
--- @param base string Validated base URL.
--- @param format string Provider wire format.
--- @param token string Decrypted key.
--- @param callback function Receives the response.
--- @return boolean dispatched
local function dispatch_probe(client, base, format, token, callback)
	if format == "backboard" then
		return ensure_backboard_assistant(client, base, token, function(id)
			callback({ ok = true, status = 200, assistant_id = id })
		end, function(_, r)
			if type(r) == "table" and r.ok == true then
				callback({ ok = true, status = r.status })
				return
			end
			callback(type(r) == "table" and r or { ok = false, status = 0 })
		end)
	end
	return client.get(build_models_url(base, format, token), build_headers(format, token), callback)
end

local function estimate_cost(model, in_tokens, out_tokens)
	if not model or model == "" or not MODEL_PRICES[model] then return 0.0 end
	local p = MODEL_PRICES[model]
	return (in_tokens * p["in"] + out_tokens * p["out"]) / 1000000.0
end
M.__estimate_cost_for_test = estimate_cost

-- =======================================
-- =======================================
-- ======= 4/ Backend Surface ============
-- =======================================
-- =======================================

--- Returns true once at least one configured entry has been ping-confirmed
--- ready. The prediction engine uses this to gate its loading-tooltip /
--- dispatch path — same contract as api_ollama.is_ready.
function M.is_ready()
	if _warmup_resume_pending == true
		and _warmup_resume_activation_pending ~= true
		and _warmup_client_recovery_token == nil then
		local paused, epoch, state_ok = read_script_pause_state()
		if state_ok == true and paused ~= true then
			recover_warmup_after_client(epoch, true)
		end
	end
	return _is_ready
end

--- API "warmup" maps to a cheap availability check rather than a model load —
--- remote providers don't have a GPU-cache cold-start the way Ollama/MLX do.
--- A successful ping flips ``_is_ready`` so the prediction engine starts
--- dispatching real requests immediately.
function M.warmup(_model_name, _profile, on_acquired)
	local acquisition_reported = false
	local function report_acquisition(committed)
		if acquisition_reported then return end
		acquisition_reported = true
		if type(on_acquired) ~= "function" then return end
		local ok, err = xpcall(function() on_acquired(committed == true) end, debug.traceback)
		if not ok then
			Logger.error(LOG, "Remote warmup acquisition callback raised: %s.", tostring(err))
		end
	end
	_warmup_last_model = _model_name
	_warmup_last_profile = _profile
	_warmup_explicitly_stopped = false
	_warmup_generation = _warmup_generation + 1
	_warmup_active = false
	if _token_cleanup_debt == true
		and settle_token_resolutions("warmup_predecessor", false) ~= true then
		Logger.error(LOG, "Remote warmup refused over shared Keychain cleanup debt.")
		report_acquisition(false)
		return false
	end
	if cancel_warmup_token_lease() ~= true then
		Logger.error(LOG, "Remote warmup refused over unsettled token-resolution ownership.")
		report_acquisition(false)
		return false
	end
	local my_warmup = _warmup_generation
	local my_identity = _identity_generation
	_is_ready = false
	_warmup_active = true
	local accepted = true
	local resolver_terminal = false
	local resolver_lease
	local launch_ok, launch_error = xpcall(function()
		resolver_lease = M.resolve_active_entry(function(resolved, entry, reason)
		resolver_terminal = true
		if _warmup_token_lease == resolver_lease then _warmup_token_lease = nil end
		if my_warmup ~= _warmup_generation or my_identity ~= _identity_generation then return end
		if resolved ~= true or not entry then
			_warmup_active = false
			accepted = false
			Logger.debug(LOG, "warmup: active API token unavailable (%s).", tostring(reason))
			report_acquisition(false)
			return
		end
		local provider = M.PROVIDERS[entry.provider]
		if not provider then
			_warmup_active = false
			accepted = false
			report_retired_provider(entry)
			report_acquisition(false)
			return
		end
		local base, base_error = resolve_base_url(entry, provider)
		if not base then
			_warmup_active = false
			accepted = false
			log_endpoint_refusal("warmup", entry, base_error)
			report_acquisition(false)
			return
		end
		local token = entry.token or ""
		if key_missing(entry) then
			_warmup_active = false
			accepted = false
			Logger.debug(LOG, "warmup: no token configured for entry '%s'.", tostring(entry.id))
			report_acquisition(false)
			return
		end

		local identity_entry = find_active_entry()
		local format = provider.format
		if not ProviderUses.format_serves(format, ProviderUses.PREDICTION) then
			_warmup_active = false
			accepted = false
			Logger.warn(LOG, "warmup: provider '%s' serves the agent's System 1 only, not predictions.",
				tostring(entry.provider))
			report_acquisition(false)
			return
		end

		local dispatch_committed = false
		local pending_response = nil
		local function apply_response(r)
			if my_warmup ~= _warmup_generation
				or my_identity ~= _identity_generation
				or find_active_entry() ~= identity_entry then
				return
			end
			_warmup_active = false
			local was_ready = _is_ready
			local response_valid, refusal_reason = models_response_is_valid(format, r)
			_is_ready = response_valid
			if _is_ready and not was_ready then
				Logger.info(LOG, "Remote API ready (provider=%s, model=%s).",
					tostring(entry.provider), tostring(entry.model))
			elseif type(r) == "table" and r.ok == true then
				log_models_response_refusal("warmup", entry, r, refusal_reason)
			elseif not _is_ready then
				Logger.warn(LOG, "Remote API ping failed (status=%s) for provider=%s.",
					tostring(type(r) == "table" and r.status or nil),
					tostring(entry.provider))
			end
			if M.is_local_server(entry.provider) then
				local status = type(r) == "table" and tonumber(r.status) or 0
				if _is_ready then
					LocalServers.report_success(entry.provider)
				elseif status == 0 or status == 401 or status == 403 then
					-- A models probe answering 404 means a wrong address, not a
					-- missing model: only an absent server or a wanted key is reported
					LocalServers.report_failure(entry.provider, status, nil, entry.model)
				end
			end
		end
		local dispatch_ok, dispatched_or_err = xpcall(function()
			return dispatch_probe(_warmup_client, base, format, token, function(r)
				if dispatch_committed ~= true then
					pending_response = r
					return
				end
				apply_response(r)
			end)
		end, debug.traceback)
		if not dispatch_ok or dispatched_or_err ~= true then
			pending_response = nil
			_warmup_active = false
			accepted = false
			Logger.error(LOG, "Remote warmup GET acquisition failed: %s.",
				tostring(dispatched_or_err))
			report_acquisition(false)
		else
			dispatch_committed = true
			if pending_response ~= nil then
				local response = pending_response
				pending_response = nil
				apply_response(response)
			end
			report_acquisition(true)
		end
		end)
	end, debug.traceback)
	if not launch_ok then
		_warmup_active = false
		Logger.error(LOG, "Remote warmup dispatch raised: %s.", tostring(launch_error))
		report_acquisition(false)
		return false
	end
	if type(resolver_lease) ~= "table" or type(resolver_lease.cancel) ~= "function" then
		_warmup_active = false
		Logger.error(LOG, "Remote warmup token resolver returned no exact waiter lease.")
		report_acquisition(false)
		return false
	end
	if resolver_terminal ~= true then _warmup_token_lease = resolver_lease end
	return accepted
end

local function settle_paused_availability()
	if _availability_pause_cleanup_pending ~= true then return true end
	local ok, result = xpcall(function() return _check_client.cancel() end, debug.traceback)
	if not ok or result ~= true then
		Logger.error(LOG, "Remote availability cancellation failed: %s.", tostring(result))
		return false
	end
	_availability_pause_cleanup_pending = false
	return true
end

local function quiesce_warmup(include_availability)
	_warmup_generation = _warmup_generation + 1
	_warmup_active = false
	_warmup_resume_activation_pending = false
	local timer_settled = cancel_warmup_resume_timer() == true
	local resolver_settled = settle_token_resolutions("warmup_quiesced", false) == true
	local token_settled = cancel_warmup_token_lease() == true
	local ok, result = xpcall(function() return _warmup_client.cancel() end, debug.traceback)
	local client_settled = ok == true and result == true
	if client_settled then _warmup_client_recovery_token = nil end
	if not client_settled then
		Logger.error(LOG, "Remote warmup cancellation failed: %s.", tostring(result))
	end
	local check_settled = true
	if include_availability == true then
		cancel_availability_owner("paused")
		_availability_generation = _availability_generation + 1
		_availability_pause_cleanup_pending = true
		check_settled = settle_paused_availability()
	end
	if not timer_settled or not resolver_settled or not token_settled
		or not client_settled or not check_settled then return false end
	Logger.debug(LOG, "Remote warmup stopped (generation %d).", _warmup_generation)
	return true
end

function M.stop_warmup()
	_warmup_resume_pending = false
	_warmup_explicitly_stopped = true
	return quiesce_warmup(false)
end

--- Quiesces one in-flight warmup while retaining its exact pre-pause intent.
--- @return boolean settled
function M.pause_warmup()
	if _warmup_explicitly_stopped == true then
		_warmup_resume_pending = false
	elseif _warmup_resume_pending ~= true then
		local active = _warmup_active == true or _warmup_token_lease ~= nil
		if not active and type(_warmup_client.isActive) == "function" then
			local ok, value = xpcall(_warmup_client.isActive, debug.traceback)
			active = ok == true and value == true
		end
		_warmup_resume_pending = active
	end
	return quiesce_warmup(true)
end

--- Restarts only the exact warmup that pause_warmup() invalidated.
--- @return boolean committed
function M.resume_warmup()
	-- A failed pause leaves the exact HTTP handle owned by HttpClient. Settle
	-- that debt before starting the asynchronous token-resolution path; warmup()
	-- can otherwise report acceptance before its later GET discovers the same
	-- uncancellable predecessor.
	local timer_settled = cancel_warmup_resume_timer() == true
	local resolver_settled = settle_token_resolutions("warmup_resume", false) == true
	local token_settled = cancel_warmup_token_lease() == true
	local availability_settled = settle_paused_availability() == true
	local ok_cancel, cancel_result = xpcall(function()
		return _warmup_client.cancel()
	end, debug.traceback)
	if not timer_settled or not resolver_settled or not token_settled
		or not availability_settled
		or not ok_cancel or cancel_result ~= true then
		Logger.error(LOG, "Remote warmup resume is waiting for prior cancellation: %s.",
			tostring(cancel_result))
		return false
	end
	if _warmup_resume_pending ~= true or _warmup_explicitly_stopped == true then
		_warmup_resume_pending = false
		return true
	end
	local paused, epoch, state_ok = read_script_pause_state()
	if state_ok ~= true then return false end
	if paused == true then return stage_warmup_resume(epoch) end
	return begin_warmup_resume_activation(epoch, true)
end

--- Cancels the active request/response inference, if any.
function M.cancel_streaming()
	local ok, result = xpcall(function() return _infer_client.cancel() end, debug.traceback)
	if not ok or result ~= true then
		Logger.error(LOG, "Remote inference cancellation failed: %s", tostring(result))
		return false
	end
	return true
end

--- Async availability check used by the menu / status indicator. Calls
--- ``on_available()`` on HTTP 2xx, ``on_missing(unreachable_bool)`` on any
--- other status, and optional ``on_cancelled(reason)`` when ownership is lost
--- before an endpoint verdict. ``model_name`` is accepted for surface parity but ignored:
--- remote providers list models, not a single configured one — exhaustive
--- model verification belongs in the picker, not the hot path.
function M.check_availability(_model_name, on_available, on_missing, on_cancelled)
	local paused, _, pause_state_ok = read_script_pause_state()
	if pause_state_ok ~= true or paused == true then return false end
	if settle_paused_availability() ~= true then return false end
	cancel_availability_owner("superseded")
	_availability_generation = _availability_generation + 1
	local my_availability = _availability_generation
	local owner = {
		done = false,
		on_available = on_available,
		on_missing = on_missing,
		on_cancelled = on_cancelled,
	}
	_availability_owner = owner
	local accepted = true
	local lease = M.resolve_active_entry(function(resolved, entry)
		if owner.done == true then return end
		if my_availability ~= _availability_generation then
			accepted = false
			finish_availability_owner(owner, "cancelled", "superseded")
			return
		end
		if resolved ~= true or not entry then
			accepted = false
			finish_availability_owner(owner, "missing", true)
			return
		end
		local provider = M.PROVIDERS[entry.provider]
		if not provider then
			accepted = false
			report_retired_provider(entry)
			finish_availability_owner(owner, "missing", true)
			return
		end
		local base, base_error = resolve_base_url(entry, provider)
		if not base then
			log_endpoint_refusal("availability check", entry, base_error)
			accepted = false
			finish_availability_owner(owner, "missing", true)
			return
		end
		if key_missing(entry) then
			accepted = false
			finish_availability_owner(owner, "missing", true)
			return
		end

		local identity_entry = find_active_entry()
		local format = provider.format
		local my_identity = _identity_generation
		if not ProviderUses.format_serves(format, ProviderUses.PREDICTION) then
			Logger.warn(LOG, "Availability check refused: provider '%s' serves the agent's System 1 only.",
				tostring(entry.provider))
			accepted = false
			finish_availability_owner(owner, "missing", false)
			return
		end

		local dispatch_ok, dispatched_or_err = xpcall(function()
			return dispatch_probe(_check_client, base, format, entry.token, function(r)
				if owner.done == true then return end
				local callback_paused, _, callback_state_ok = read_script_pause_state()
				if my_availability ~= _availability_generation
					or my_identity ~= _identity_generation
					or find_active_entry() ~= identity_entry
					or callback_state_ok ~= true or callback_paused == true then
					finish_availability_owner(owner, "cancelled", "stale_identity")
					return
				end
				local response_valid, refusal_reason = models_response_is_valid(format, r)
				if response_valid then
					finish_availability_owner(owner, "available")
				else
					if type(r) == "table" and r.ok == true then
						log_models_response_refusal("availability check", entry, r, refusal_reason)
					end
					finish_availability_owner(owner, "missing",
						type(r) == "table" and r.status == 0)
				end
			end)
		end, debug.traceback)
		if not dispatch_ok or dispatched_or_err ~= true then
			accepted = false
			Logger.error(LOG, "Remote availability GET acquisition failed: %s.",
				tostring(dispatched_or_err))
			finish_availability_owner(owner, "cancelled", "dispatch_refused")
		end
	end)
	if type(lease) ~= "table" or type(lease.cancel) ~= "function" then
		accepted = false
		finish_availability_owner(owner, "cancelled", "resolver_lease_missing")
		return false
	end
	return accepted
end




-- =======================================
-- =======================================
-- ======= 5/ Request + Parse ============
-- =======================================
-- =======================================

local _req_counter = 0


--- Fire a single non-streaming remote request and turn the response into one
--- or more prediction objects via ``Parser.process_prediction`` /
--- ``Parser.split_blocks``. The signature mirrors api_ollama's
--- ``post_and_parse`` so the higher-level fetch_* strategies can keep their
--- structure unchanged.
local function post_and_parse_resolved(entry, model_name, system_prompt, full_text, tail_text,
                                        temperature, max_tokens, num_predictions, is_batch,
                                        on_success, on_fail, dedup_stats, on_raw)
	local provider = M.PROVIDERS[entry.provider]
	local my_identity = _identity_generation
	local identity_entry = find_active_entry()
	if not provider then
		report_retired_provider(entry)
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
		return
	end
	local base, base_error = resolve_base_url(entry, provider)
	local model = (model_name and model_name ~= "") and model_name or (entry.model and entry.model ~= "" and entry.model) or provider.default_model
	if not base then
		log_endpoint_refusal("inference", entry, base_error)
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
		return
	end
	if type(model) ~= "string" or model == "" then
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
		return
	end

	_req_counter = _req_counter + 1
	local req_id = _req_counter

	-- Compose user prompt: the engine's profile already injects PREFIX/TAIL
	-- markers or {context} substitution upstream, but for remote providers we
	-- still need to fall back gracefully when the active profile expects a
	-- different shape. Mirror api_ollama.build_request_context's intent: if
	-- the system prompt asks for PREFIX/TAIL, format the user turn as such;
	-- otherwise pass the full context as-is.
	local final_sys = system_prompt
	if type(final_sys) == "string" then
		final_sys = final_sys:gsub("%{n%}", text_utils.escape_gsub_replacement(tostring(num_predictions)))
	end
	local user_prompt = ""
	if type(final_sys) == "string" and final_sys:find("PREFIX") and final_sys:find("TAIL") then
		user_prompt = string.format("PREFIX: \"%s\"\nTAIL: \"%s\"", full_text or "", tail_text or "")
	else
		local ctx = type(full_text) == "string" and full_text or ""
		if type(final_sys) == "string" and final_sys:find("{context}", 1, true) then
			final_sys  = final_sys:gsub("%{context%}", function() return ctx end)
			user_prompt = ""
			-- Some providers (Gemini) handle systemInstruction; keep ctx empty so
			-- the user turn doesn't duplicate the system prompt content.
		else
			user_prompt = ctx
		end
	end

	if not ProviderUses.format_serves(provider.format, ProviderUses.PREDICTION) then
		Logger.error(LOG, "[%s] #%d refused: provider '%s' serves the agent's System 1 only, not text requests.",
			tostring(model), req_id, tostring(entry.provider))
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
		return
	end

	local t0 = TimerScheduler.now()

	--- Handles the provider's answer: the chat completion, or the Backboard message.
	--- @param r table HTTP response.
	local function on_response(r)
		if my_identity ~= _identity_generation or find_active_entry() ~= identity_entry then
			Logger.debug(LOG, "[%s] #%d response discarded after remote identity changed.",
				tostring(model), req_id)
			return
		end
		local status, body = r.status, r.body
		-- Logger.pcall, not a bare pcall. This closure IS the entire response
		-- handler: parsing, dedup, telemetry and the on_success dispatch all live
		-- inside it. A throw anywhere aborts the rest silently — the caller's
		-- callback simply never fires and no line appears anywhere — which is the
		-- documented "green but no prediction" failure mode. api_remote was the
		-- one backend never migrated off that anti-pattern.
		Logger.pcall(LOG, function()
			local ms = math.floor((TimerScheduler.now() - t0) * 1000)
			if not r.ok then
				Logger.error(LOG, "[%s] #%d HTTP_ERROR status=%s body=%s",
					model, req_id, tostring(status), (body or ""):sub(1, 200))
				-- Log the failure so the audit trail shows it instead of
				-- silently dropping. Same envelope as keylogger.log_llm
				-- but routed to log_llm_failed; the engine doesn't need
				-- to know about the distinction.
				if keylogger and type(keylogger.log_llm_failed) == "function" then
					pcall(keylogger.log_llm_failed, full_text, nil, {
						backend        = "api",
						model          = tostring(model),
						system_prompt  = system_prompt,
						user_prompt    = user_prompt,
						failure_reason = "http_" .. tostring(status or "unknown"),
						elapsed_ms     = ms,
					})
				end
				-- The provider's own verdict travels as an optional second
				-- argument: engine callbacks ignore extra args, while the
				-- Test-API action surfaces status + message to the user.
				local detail = {
					reason = "http_" .. tostring(status or "unknown"),
					status = tonumber(status) or 0,
					message = extract_server_message(body) or "",
				}
				if provider.local_server == true then
					LocalServers.report_failure(entry.provider, detail.status, detail.message, model)
				end
				if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail", detail) end
				return
			end
			if provider.local_server == true then LocalServers.report_success(entry.provider) end

			local classified = ResponseClassifier.classify(provider.format, body)
			classified.usage.est_cost_usd = estimate_cost(tostring(model),
				classified.usage.prompt_tokens, classified.usage.completion_tokens)
			local raw_text = classified.text
			if raw_text == "" then
				Logger.warn(LOG, "[%s] #%d empty completion (could not parse).", model, req_id)
				if keylogger and type(keylogger.log_llm_failed) == "function" then
					pcall(keylogger.log_llm_failed, full_text, nil, {
						backend        = "api",
						model          = tostring(model),
						system_prompt  = system_prompt,
						user_prompt    = user_prompt,
						failure_reason = "parse_empty",
						elapsed_ms     = ms,
					})
				end
				if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
				return
			end

			local raw     = Parser.strip_thinking(raw_text)
			if type(on_raw) == "function" then
				Logger.debug(LOG, "[%s] #%d RAW answer in %dms (%d chars).", model, req_id, ms, #raw)
				ApiCommon.protected_call(on_raw, "on_raw", raw)
				return
			end
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
				Logger.debug(LOG, "[%s] #%d PARSED -> 0 result (parser failure)", model, req_id)
				if keylogger and type(keylogger.log_llm_failed) == "function" then
					pcall(keylogger.log_llm_failed, full_text, nil, {
						backend        = "api",
						model          = tostring(model),
						system_prompt  = system_prompt,
						user_prompt    = user_prompt,
						failure_reason = "parser_no_blocks",
						elapsed_ms     = ms,
					})
				end
				if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
				return
			end

			-- Token usage + cost extraction. Each provider exposes the same
			-- numeric fields under a top-level ``usage`` block (OpenAI shape)
			-- or under ``usageMetadata`` (Gemini). Cost is computed from the
			-- per-model price table in pricing.lua.
			local usage = classified.usage

			Logger.debug(LOG, "[%s] #%d PARSED -> %d result(s) in %dms", model, req_id, #results, ms)
			if keylogger and type(keylogger.log_llm) == "function" then
				pcall(keylogger.log_llm, full_text, results, nil, {
					backend           = "api",
					model             = tostring(model),
					system_prompt     = system_prompt,
					user_prompt       = user_prompt,
					prompt_tokens     = usage.prompt_tokens,
					completion_tokens = usage.completion_tokens,
					total_tokens      = usage.total_tokens,
					est_cost_usd      = usage.est_cost_usd,
					elapsed_ms        = ms,
				})
			end
			if type(on_success) == "function" then ApiCommon.protected_call(on_success, "on_success", results) end
		end)
	end

	if provider.format == "backboard" then
		Logger.debug(LOG, "[%s] #%d Backboard message (%d chars prompt)", model, req_id, #(user_prompt or ""))
		post_backboard_message(_infer_client, base, entry.token or "",
			{ model = model, system = final_sys or "", text = user_prompt },
			on_response,
			function(_, detail)
				if my_identity ~= _identity_generation or find_active_entry() ~= identity_entry then return end
				if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail", detail) end
			end)
		return
	end

	local url, url_error = build_url(base, provider.format, model, entry.token or "")
	if not url then
		log_endpoint_refusal("inference", entry, url_error)
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
		return
	end

	local provider_extras = type(provider.model_extras) == "table" and provider.model_extras[model] or nil
	local payload = build_payload(provider.format, model, final_sys or "", user_prompt, temperature, max_tokens,
		provider_extras)
	local encoded, enc_err = JsonCodec.encode(payload)
	if not encoded then
		Logger.error(LOG, "[%s] #%d Payload encode failed — %s", model, req_id, tostring(enc_err))
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
		return
	end

	local headers = build_headers(provider.format, entry.token or "")

	Logger.debug(LOG, "[%s] #%d POST -> %s (provider=%s, %d chars prompt)",
		model, req_id, redact_url(url), provider.format, #(user_prompt or ""))

	_infer_client.post(url, headers, encoded, on_response)
end

--- Resolves the credential asynchronously before constructing any request.
--- Every fetch strategy enters through this wrapper, so a cold or locked
--- Keychain can delay/fail one request without freezing keyboard processing.
local function post_and_parse(model_name, system_prompt, full_text, tail_text,
                               temperature, max_tokens, num_predictions, is_batch,
                               on_success, on_fail, dedup_stats, on_raw)
	M.resolve_active_entry(function(resolved, entry)
		if resolved ~= true or not entry then
			if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
			return
		end
		post_and_parse_resolved(entry, model_name, system_prompt, full_text, tail_text,
			temperature, max_tokens, num_predictions, is_batch,
			on_success, on_fail, dedup_stats, on_raw)
	end)
end

--- Sends one request and hands back the model's answer unparsed. For callers
--- that read their own answer format (the tone actions rewrite a selection, not
--- the typed buffer the prediction parser aligns against).
--- @param model_name string|nil Model id; nil uses the active entry's.
--- @param system_prompt string The resolved system prompt.
--- @param full_text string PREFIX (or the context of a non PREFIX/TAIL prompt).
--- @param tail_text string TAIL.
--- @param temperature number Sampling temperature.
--- @param max_tokens number Output token budget.
--- @param on_raw function Receives the answer text, thinking blocks stripped.
--- @param on_fail function Called on a credential, transport, HTTP or empty-answer failure.
--- @param _options table|nil { chat = true } as for api_ollama.request_raw: a remote
---        request is always a chat turn, so there is nothing to change.
function M.request_raw(model_name, system_prompt, full_text, tail_text, temperature, max_tokens, on_raw, on_fail,
                       _options)
	if type(on_raw) ~= "function" then error("api_remote.request_raw: on_raw must be a function") end
	post_and_parse(model_name, system_prompt, full_text, tail_text,
		temperature, max_tokens, 1, false, nil, on_fail, ApiCommon.new_dedup_stats(), on_raw)
end

--- Finds the API entry a vision request to a provider runs with: the active
--- entry when it belongs to that provider, else the first one configured for it.
--- A local server needs no entry: without one, its requests go to the address
--- and with the key typed for it this session, else to its default address
--- with no key.
--- @param provider_id string Provider id of api_providers.json.
--- @return table|nil entry
local function find_provider_entry(provider_id)
	local active = find_active_entry()
	if active and active.provider == provider_id then return active end
	for _, entry in ipairs(_entries) do
		if entry.provider == provider_id then return entry end
	end
	if M.is_local_server(provider_id) then
		local pending = LocalServers.pending(provider_id)
		return {
			id = "local:" .. provider_id, provider = provider_id,
			base_url = pending.base_url or "", token = pending.token or "", model = "",
		}
	end
	return nil
end

--- The API entry that holds a local server's address, key and model, if the
--- user chose one of its models.
--- @param provider_id string Server id of local_servers.json.
--- @return table|nil entry
function M.local_server_entry(provider_id)
	if not M.is_local_server(provider_id) then return nil end
	local active = find_active_entry()
	if active and active.provider == provider_id then return active end
	for _, entry in ipairs(_entries) do
		if entry.provider == provider_id then return entry end
	end
	return nil
end

--- Tells whether a request of one use can be sent to a provider, before
--- anything is captured: the provider exists, serves that use
--- (modules/llm/provider_uses.lua) and an API entry with a key is configured.
--- @param provider_id string Provider id of api_providers.json.
--- @param use string A use of provider_uses ("vision", "system1", "system2").
--- @return boolean ready
--- @return string|nil reason "unknown_provider", "unsupported", "no_entry" or "missing_token".
function M.provider_status(provider_id, use)
	if type(provider_id) ~= "string" or M.PROVIDERS[provider_id] == nil then
		return false, "unknown_provider"
	end
	if not M.provider_serves(provider_id, use) then return false, "unsupported" end
	local entry = find_provider_entry(provider_id)
	if not entry then return false, "no_entry" end
	if key_missing(entry) then return false, "missing_token" end
	return true, nil
end

--- Tells whether a vision request can be sent to a provider (provider_status
--- for the vision use).
--- @param provider_id string Provider id of api_providers.json.
--- @return boolean ready
--- @return string|nil reason As provider_status.
function M.vision_provider_status(provider_id)
	return M.provider_status(provider_id, ProviderUses.VISION)
end

--- The request format of a provider ("openai", "anthropic", "gemini",
--- "backboard" or "decisions").
--- @param provider_id string Provider id of api_providers.json.
--- @return string|nil format Nil for an unknown provider.
function M.provider_format(provider_id)
	local provider = M.PROVIDERS[provider_id]
	return provider and provider.format or nil
end

--- Resolves the key and the address of a provider's request, then hands them
--- over. The request carries private text or a screenshot: neither it nor the
--- answer is ever logged.
--- @param label string What is requested, for the log ("Vision", "Agent").
--- @param provider_id string Provider id of api_providers.json.
--- @param use string The use it serves (provider_status).
--- @param fail function Receives a short reason when nothing can be sent.
--- @param on_ready function Receives (provider, entry, token, base).
--- @return boolean started True when the key resolution started.
local function with_provider_key(label, provider_id, use, fail, on_ready)
	local ready, reason = M.provider_status(provider_id, use)
	if not ready then
		Logger.error(LOG, "%s request refused for provider '%s': %s.", label, tostring(provider_id), tostring(reason))
		fail(reason)
		return false
	end
	local provider = M.PROVIDERS[provider_id]
	local entry = find_provider_entry(provider_id)
	--- Hands over the request once its key is known.
	--- @param token string The cleartext key, "" for a local server given none.
	local function with_token(token)
		local base, base_error = resolve_base_url(entry, provider)
		if not base then
			log_endpoint_refusal(label:lower(), entry, base_error)
			fail("invalid_endpoint")
			return
		end
		on_ready(provider, entry, token, base)
	end
	if type(entry.token) ~= "string" or entry.token == "" then
		-- key_missing() let it through: a local server given no key
		with_token("")
		return true
	end
	TokenCrypto.decrypt_async(entry.token, function(decrypted, token, token_reason)
		if decrypted ~= true or type(token) ~= "string" or token == "" then
			Logger.error(LOG, "%s request for provider '%s' has no usable key (entry '%s'): %s.",
				label, provider_id, tostring(entry.id), tostring(token_reason))
			fail("missing_token")
			return
		end
		with_token(token)
	end)
	return true
end

--- Wraps a caller's failure callback so it is called once, protected.
--- @param on_fail function Receives a short reason.
--- @return function fail Returns false, for the refusals.
local function failure_callback(on_fail)
	return function(reason)
		ApiCommon.protected_call(on_fail, "on_fail", reason)
		return false
	end
end

--- Posts one prebuilt request body to a provider with its stored API key,
--- through the same URL, header and answer rules as a prediction.
--- @param client table The HTTP client that posts it.
--- @param label string What is requested, for the log ("Vision", "Agent").
--- @param use string The use it serves (provider_status).
--- @param provider_id string Provider id of api_providers.json.
--- @param model string The model (Gemini puts it in the URL).
--- @param body table The request body (llm/vision.lua build_request).
--- @param on_text function Receives the answer text, thinking blocks stripped.
--- @param on_fail function Receives a short reason when no answer came back.
--- @param with_extras boolean|nil Merge the model's model_extras of
---        api_providers.json into an OpenAI-shape body, as a prediction does.
--- @return boolean sent True when the key resolution started.
local function request_prebuilt(client, label, use, provider_id, model, body, on_text, on_fail, with_extras)
	if type(on_text) ~= "function" or type(on_fail) ~= "function" then
		error("api_remote." .. label .. " request: on_text and on_fail must be functions")
	end
	local fail = failure_callback(on_fail)
	local ready, reason = M.provider_status(provider_id, use)
	if not ready then
		Logger.error(LOG, "%s request refused for provider '%s': %s.", label, tostring(provider_id), tostring(reason))
		return fail(reason)
	end
	if type(model) ~= "string" or model == "" or type(body) ~= "table" then
		error("api_remote." .. label .. " request: a model and a body are required")
	end
	local format = M.provider_format(provider_id)
	if format == "backboard" or format == "decisions" then
		-- Their requests are not chat bodies: request_backboard / request_decisions
		Logger.error(LOG, "%s request refused for provider '%s': a %s provider takes no prebuilt body.",
			label, tostring(provider_id), format)
		return fail("unsupported")
	end
	return with_provider_key(label, provider_id, use, fail, function(provider, entry, token, base)
		local extras = with_extras and provider.format == "openai" and provider.model_extras
			and provider.model_extras[model] or nil
		if extras then
			-- A reasoning model left at its default effort spends a small budget
			-- thinking and answers nothing; the body's own fields win
			for field, value in pairs(extras) do
				if body[field] == nil then body[field] = value end
			end
		end
		local url, url_error = build_url(base, provider.format, model, token)
		if not url then
			log_endpoint_refusal(label:lower(), entry, url_error)
			fail("invalid_endpoint")
			return
		end
		local encoded, encode_error = JsonCodec.encode(body)
		if not encoded then
			Logger.error(LOG, "%s request body encode failed: %s.", label, tostring(encode_error))
			fail("encode_failed")
			return
		end
		local t0 = TimerScheduler.now()
		Logger.info(LOG, "%s request to provider '%s' (model %s, %d byte(s)) -> %s.",
			label, provider_id, model, #encoded, redact_url(url))
		client.post(url, build_headers(provider.format, token), encoded, function(r)
			Logger.pcall(LOG, function()
				local ms = math.floor((TimerScheduler.now() - t0) * 1000)
				if not r.ok then
					local message = extract_server_message(r.body)
					Logger.error(LOG, "%s request to provider '%s' failed in %dms: HTTP %s (%s).",
						label, provider_id, ms, tostring(r.status), tostring(message or r.error or ""))
					if provider.local_server == true then
						LocalServers.report_failure(provider_id, r.status, message, model)
					end
					fail("http_" .. tostring(r.status or "unknown"))
					return
				end
				if provider.local_server == true then LocalServers.report_success(provider_id) end
				local text = Parser.strip_thinking(ResponseClassifier.classify(provider.format, r.body).text)
				if type(text) ~= "string" or text == "" then
					Logger.warn(LOG, "%s answer of provider '%s' holds no text (%dms).", label, provider_id, ms)
					fail("empty_answer")
					return
				end
				Logger.info(LOG, "%s answer of provider '%s' received in %dms (%d char(s)).",
					label, provider_id, ms, #text)
				ApiCommon.protected_call(on_text, "on_text", text)
			end)
		end)
	end)
end

--- Posts one prebuilt vision request body (a screenshot and its prompt) to a
--- provider with its stored API key.
--- @param provider_id string Provider id of api_providers.json.
--- @param model string The vision model.
--- @param body table The request body (llm/vision.lua build_request).
--- @param on_text function Receives the answer text, thinking blocks stripped.
--- @param on_fail function Receives a short reason when no answer came back.
--- @return boolean sent True when the key resolution started.
function M.request_vision(provider_id, model, body, on_text, on_fail)
	return request_prebuilt(_vision_client, "Vision", ProviderUses.VISION, provider_id, model, body, on_text, on_fail)
end

--- Posts one prebuilt text chat body (llm/vision.lua build_request without an
--- image) to a provider with its stored API key: the AI agent's System 1 and
--- System 2 requests, which name their own backend whatever the AI menu uses.
--- The model's model_extras apply, as they do to a prediction.
--- @param provider_id string Provider id of api_providers.json.
--- @param model string The model.
--- @param body table The request body.
--- @param on_text function Receives the answer text, thinking blocks stripped.
--- @param on_fail function Receives a short reason when no answer came back.
--- @param use string|nil The use it serves (default: System 2).
--- @return boolean sent True when the key resolution started.
function M.request_chat(provider_id, model, body, on_text, on_fail, use)
	return request_prebuilt(_vision_client, "Agent", use or ProviderUses.SYSTEM2, provider_id, model, body,
		on_text, on_fail, true)
end

--- Sends one Backboard message to a provider with its stored API key, for the
--- AI agent: a chat turn, or Jev's questions (spec.questions) through
--- Backboard. The key's assistant is created at its first request.
--- @param provider_id string A "backboard" provider of api_providers.json.
--- @param spec table { model = "<llm_provider>/<model_name>", system, text, questions? }
--- @param on_answer function Receives the decoded answer.
--- @param on_fail function Receives a short reason when no answer came back.
--- @param use string|nil The use it serves (default: System 2).
--- @return boolean sent True when the key resolution started.
function M.request_backboard(provider_id, spec, on_answer, on_fail, use)
	if type(on_answer) ~= "function" or type(on_fail) ~= "function" or type(spec) ~= "table" then
		error("api_remote.request_backboard: a spec, on_answer and on_fail are required")
	end
	local fail = failure_callback(on_fail)
	if M.provider_format(provider_id) ~= "backboard" then
		Logger.error(LOG, "Backboard request refused: provider '%s' is not a Backboard provider.", tostring(provider_id))
		return fail("unsupported")
	end
	return with_provider_key("Agent", provider_id, use or ProviderUses.SYSTEM2, fail, function(_, _, token, base)
		local t0 = TimerScheduler.now()
		Logger.info(LOG, "Agent request to provider '%s' (model %s, %d byte(s)).",
			provider_id, tostring(spec.model), #tostring(spec.text or ""))
		post_backboard_message(_vision_client, base, token, spec, function(r)
			Logger.pcall(LOG, function()
				local ms = math.floor((TimerScheduler.now() - t0) * 1000)
				if not r.ok then
					Logger.error(LOG, "Agent request to provider '%s' failed in %dms: HTTP %s (%s).",
						provider_id, ms, tostring(r.status), tostring(extract_server_message(r.body) or r.error or ""))
					fail("http_" .. tostring(r.status or "unknown"))
					return
				end
				local decoded = decode_body(r.body)
				if not decoded then
					Logger.warn(LOG, "Agent answer of provider '%s' is not JSON (%dms).", provider_id, ms)
					fail("empty_answer")
					return
				end
				Logger.info(LOG, "Agent answer of provider '%s' received in %dms.", provider_id, ms)
				ApiCommon.protected_call(on_answer, "on_answer", decoded)
			end)
		end, function(reason) fail(reason) end)
	end)
end

--- Posts one decisions request to a provider (TypeSafe's System One protocol:
--- its base_url is the full endpoint) and hands back the answers.
--- @param client table HTTP client.
--- @param provider_id string A "decisions" provider, for the log.
--- @param base string Validated endpoint.
--- @param token string Decrypted key.
--- @param body table decisions_body().
--- @param on_answers function Receives the `answers` object.
--- @param fail function Receives (reason, detail).
local function post_decisions(client, provider_id, base, token, body, on_answers, fail)
	local encoded, encode_error = JsonCodec.encode(body)
	if not encoded then
		Logger.error(LOG, "Decisions request body encode failed: %s.", tostring(encode_error))
		fail("encode_failed", failure_detail("encode_failed", nil))
		return
	end
	local t0 = TimerScheduler.now()
	Logger.info(LOG, "Decisions request to provider '%s' (model %s, %d byte(s)) -> %s.",
		provider_id, tostring(body.model), #encoded, redact_url(base))
	client.post(base, build_headers("decisions", token), encoded, function(r)
		Logger.pcall(LOG, function()
			local ms = math.floor((TimerScheduler.now() - t0) * 1000)
			if not r.ok then
				Logger.error(LOG, "Decisions request to provider '%s' failed in %dms: HTTP %s (%s).",
					provider_id, ms, tostring(r.status), tostring(extract_server_message(r.body) or r.error or ""))
				fail("http_" .. tostring(r.status or "unknown"), failure_detail("http_" .. tostring(r.status), r))
				return
			end
			local decoded = decode_body(r.body)
			local answers = Formats.decisions_answers(decoded)
			if not answers then
				Logger.warn(LOG, "Decisions answer of provider '%s' holds no answers (keys: %s).",
					provider_id, top_level_keys(decoded))
				fail("no_answers", failure_detail("no_answers", nil))
				return
			end
			Logger.info(LOG, "Decisions answer of provider '%s' received in %dms.", provider_id, ms)
			on_answers(answers, ms)
		end)
	end)
end

--- Asks a decisions provider (Jev) its questions about a state, for the AI
--- agent's System 1.
--- @param provider_id string A "decisions" provider of api_providers.json.
--- @param model string e.g. "jev-latest".
--- @param state string|table What the questions are about.
--- @param questions table { [id] = { type, instructions, criteria } }
--- @param on_answers function Receives the `answers` object.
--- @param on_fail function Receives a short reason when no answer came back.
--- @return boolean sent True when the key resolution started.
function M.request_decisions(provider_id, model, state, questions, on_answers, on_fail)
	if type(on_answers) ~= "function" or type(on_fail) ~= "function" then
		error("api_remote.request_decisions: on_answers and on_fail must be functions")
	end
	local fail = failure_callback(on_fail)
	if M.provider_format(provider_id) ~= "decisions" then
		Logger.error(LOG, "Decisions request refused: provider '%s' is not a decisions provider.", tostring(provider_id))
		return fail("unsupported")
	end
	return with_provider_key("Agent", provider_id, ProviderUses.SYSTEM1, fail, function(_, _, token, base)
		post_decisions(_vision_client, provider_id, base, token, Formats.decisions_body(model, state, questions),
			function(answers) ApiCommon.protected_call(on_answers, "on_answers", answers) end,
			function(reason) fail(reason) end)
	end)
end

--- Sends the shared decisions probe (api_providers.json decisions_test,
--- verbatim) to one explicit decisions entry: it succeeds when the answer
--- holds answers. Such an entry is never the prediction backend, so the probe
--- runs on its own client whatever entry is active.
--- @param entry table API entry record.
--- @param provider table Its provider descriptor.
--- @param on_ok function Called with (answers_json, elapsed_ms).
--- @param on_fail function Called with (reason_string, detail_table_or_nil).
--- @return boolean True when a probe was dispatched.
local function test_decisions(entry, provider, on_ok, on_fail)
	local function fail(reason, detail)
		Logger.error(LOG, "API test probe failed: %s", tostring(reason))
		if type(on_fail) == "function" then
			ApiCommon.protected_call(on_fail, "test_request_fail", tostring(reason), detail)
		end
		return false
	end
	local probe = M.DECISIONS_TEST
	if type(probe) ~= "table" then return fail("no shared decisions probe") end
	local base, base_error = resolve_base_url(entry, provider)
	if not base then
		log_endpoint_refusal("test", entry, base_error)
		return fail("invalid_endpoint")
	end
	local model = (type(entry.model) == "string" and entry.model ~= "") and entry.model or provider.default_model
	local body = Formats.decisions_body(model, probe.state, probe.questions)
	local function send(token)
		post_decisions(_probe_client, tostring(entry.provider), base, token, body, function(answers, ms)
			local encoded = JsonCodec.encode(answers)
			if type(on_ok) == "function" then
				ApiCommon.protected_call(on_ok, "test_request_ok", encoded or "answers", ms)
			end
		end, fail)
	end
	local stored = entry.token
	if type(stored) ~= "string" or stored == "" then return fail("missing_token") end
	TokenCrypto.decrypt_async(stored, function(decrypted, token, reason)
		if decrypted ~= true or type(token) ~= "string" or token == "" then
			fail("missing_token: " .. tostring(reason))
			return
		end
		send(token)
	end)
	return true
end

--- Sends the shared minimal probe (api_providers.json test_request, verbatim)
--- to one explicit entry and reports the verdict. Unlike check_availability
--- (credential reachability via /models), this proves the full inference path:
--- credentials, model id and body format. An empty reply counts as failure on
--- both drivers — a 200 with no text proves nothing about the model.
--- The entry travels explicitly (never "active at callback time"); identity
--- drift mid-flight is still enforced downstream and reported as no verdict,
--- exactly like a superseded availability probe.
--- @param entry table API entry record with decrypted token.
--- @param spec table { system_prompt, user_text, temperature, max_tokens }.
--- @param on_ok function Called with (reply_text, elapsed_ms).
--- @param on_fail function Called with (reason_string, detail_table_or_nil).
---   detail carries status + the provider's own message when the server
---   answered with an error body.
--- @return boolean True when a probe was dispatched.
function M.test_request(entry, spec, on_ok, on_fail)
	local function fail(reason)
		Logger.error(LOG, "API test probe refused: %s", tostring(reason))
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "test_request_fail", tostring(reason)) end
		return false
	end
	if type(entry) ~= "table" then return fail("no entry") end
	local provider = M.PROVIDERS[entry.provider]
	if provider and provider.format == "decisions" then return test_decisions(entry, provider, on_ok, on_fail) end
	if type(spec) ~= "table" then return fail("no shared probe spec") end
	for _, key in ipairs({ "system_prompt", "user_text" }) do
		if type(spec[key]) ~= "string" or spec[key] == "" then return fail("invalid probe text") end
	end
	if type(spec.temperature) ~= "number" or type(spec.max_tokens) ~= "number" then
		return fail("invalid probe sampling")
	end
	local t0 = TimerScheduler.now()
	local ok_send, send_err = xpcall(function()
		post_and_parse_resolved(entry,
			(type(entry.model) == "string" and entry.model ~= "") and entry.model or nil,
			spec.system_prompt, spec.user_text, "",
			spec.temperature, spec.max_tokens, 1, false,
			-- The probe judges the raw reply: the prediction parser applies the
			-- menu's minimum word count, which refused the one-word "OK" the probe
			-- asks for, so every real key failed its test.
			nil,
			function(detail)
				if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "test_request_fail", "request_failed", detail) end
			end,
			ApiCommon.new_dedup_stats(),
			function(raw)
				local text = type(raw) == "string" and raw:match("^%s*(.-)%s*$") or ""
				if text == "" then
					if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "test_request_fail", "empty_reply") end
					return
				end
				local ms = math.max(0, math.floor((TimerScheduler.now() - t0) * 1000))
				if type(on_ok) == "function" then ApiCommon.protected_call(on_ok, "test_request_ok", text, ms) end
			end)
	end, debug.traceback)
	if not ok_send then return fail("dispatch_raised: " .. tostring(send_err)) end
	return true
end




-- =======================================
-- =======================================
-- ======= 6/ Fetch Strategies ===========
-- =======================================
-- =======================================

--- Batch strategy: one request, the model returns N completions in a single
--- response. Mirrors api_ollama.fetch_batch but with the remote post_and_parse
--- helper. Most remote providers don't natively expose a "n completions" knob
--- — instead we ask once and let the parser split blocks (which is what the
--- profile prompt sets up).
function M.fetch_batch(full_text, tail_text, model_name, temperature,
                       max_predict, num_predictions, profile,
                       on_success, on_fail, request_id_provider, _streaming, _on_partial)
	local effective_temp     = tonumber(temperature) or ApiCommon.DEFAULT_TEMPERATURE
	local system_prompt      = Profiles.resolve_system_prompt(profile, num_predictions)
	local tokens             = (tonumber(max_predict) or 32) * num_predictions + (num_predictions * 5)
	local is_batch           = profile.batch
	local dedup_stats        = ApiCommon.new_dedup_stats()
	local t0                 = TimerScheduler.now()
	-- Snapshot the request id so the callback can detect if the user typed more text
	-- while the single HTTP round-trip was in flight and discard the stale response
	local initial_request_id = type(request_id_provider) == "function" and request_id_provider() or nil
	local initial_identity = _identity_generation

	post_and_parse(model_name, system_prompt, full_text, tail_text,
		effective_temp, tokens, num_predictions, is_batch,
		function(results)
			if initial_identity ~= _identity_generation then return end
			-- Discard if the user typed new text between dispatch and callback
			if initial_request_id
				and type(request_id_provider) == "function"
				and request_id_provider() ~= initial_request_id then
				Logger.debug(LOG, "Batch response discarded (request id changed).")
				return
			end
			local ms = math.floor((TimerScheduler.now() - t0) * 1000)
			ApiCommon.log_prediction_summary(Logger, LOG, "batch", num_predictions, dedup_stats, #results)
			-- `is_batch` is true on every path that reaches here, so `not is_batch`
			-- made this branch dead and the remote backend revealed all predictions at
			-- once instead of one slot at a time. The sibling dispatchers guard on
			-- `not streaming`, which is a tautology for a backend that never streams —
			-- the equivalent condition here is simply "more than one result".
			if #results > 1 then
				ProgressiveReveal.deliver(results, on_success, ms, function()
					if initial_identity ~= _identity_generation then return false end
					return not initial_request_id
						or type(request_id_provider) ~= "function"
						or request_id_provider() == initial_request_id
				end)
			else
				if type(on_success) == "function" then ApiCommon.protected_call(on_success, "on_success", results, ms, true) end
			end
		end,
		on_fail, dedup_stats)
end

--- Sequential strategy: N requests fired in sequence with a temperature
--- diversity step. Useful for variants from a single-prediction profile.
function M.fetch_sequential(full_text, tail_text, model_name, temperature,
                             max_predict, num_predictions, profile,
                             on_success, on_fail, request_id_provider, _streaming, _on_partial)
	local system_prompt          = Profiles.resolve_system_prompt(profile, 1)
	local t0                     = TimerScheduler.now()
	local results                = {}
	local base_temp              = tonumber(temperature) or ApiCommon.DEFAULT_TEMPERATURE
	local requested_predictions  = math.max(1, math.floor(tonumber(num_predictions) or 1))
	local max_attempts           = requested_predictions
	if RETRY_FAILED_PREDICTION then
		max_attempts = math.max(requested_predictions, requested_predictions * math.max(1, math.floor(tonumber(RETRY_FAILED_MAX_MULT))))
	end
	local attempt_index          = 1
	local dedup_stats            = ApiCommon.new_dedup_stats()
	local initial_request_id     = type(request_id_provider) == "function" and request_id_provider() or nil
	local initial_identity       = _identity_generation

	local function request_is_current()
		if initial_identity ~= _identity_generation then return false end
		if type(request_id_provider) == "function" then
			local cur = request_id_provider()
			if initial_request_id ~= nil and cur ~= initial_request_id then
				Logger.debug(LOG, "Sequential batch cancelled (id changed).")
				return false
			end
		end
		return true
	end

	local function do_next()
		if not request_is_current() then return end
		if #results >= requested_predictions or attempt_index > max_attempts then
			if #results == 0 then
				if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
				return
			end
			ApiCommon.log_prediction_summary(Logger, LOG, "sequential", requested_predictions, dedup_stats, #results)
			local ms = math.floor((TimerScheduler.now() - t0) * 1000)
			if type(on_success) == "function" then ApiCommon.protected_call(on_success, "on_success", results, ms, true) end
			return
		end
		local variant_index = attempt_index
		attempt_index       = attempt_index + 1
		local variant_temp  = ApiCommon.get_diversity_temperature(base_temp, variant_index, 0.30)
		local primary_tokens = tonumber(max_predict)

		local function request_variant(attempt, tokens, temp)
			if not request_is_current() then return end
			post_and_parse(model_name, system_prompt, full_text, tail_text,
				temp, tokens, 1, false,
				function(preds)
					if type(preds) == "table" and type(preds[1]) == "table" then
						if #results < requested_predictions then
							ApiCommon.insert_prediction(results, preds[1], dedup_stats, DEDUPLICATION_ENABLED, Logger, LOG)
							local ms = math.floor((TimerScheduler.now() - t0) * 1000)
							if type(on_success) == "function" then ApiCommon.protected_call(on_success, "on_success", results, ms, false) end
						end
					end
					do_next()
				end,
				function()
					if attempt < 2 then
						local retry_tokens = tokens + _R_EXTRA_TOKENS
						local retry_temp   = math.min(1.30, (tonumber(temp) or ApiCommon.DEFAULT_TEMPERATURE) + _R_TEMP_STEP)
						request_variant(attempt + 1, retry_tokens, retry_temp)
						return
					end
					do_next()
				end,
				dedup_stats)
		end

		request_variant(1, primary_tokens, variant_temp)
	end

	do_next()
end

--- Parallel strategy aliases to sequential — remote providers tend to throttle
--- per-key concurrency, and we cannot guarantee request ordering without an
--- extra coordinator. Sequential keeps the rate-limit floor honest without
--- having to reason about parallel races.
M.fetch_parallel = M.fetch_sequential

--- Thinking-model heuristic. Same heuristic as api_ollama so the menu's
--- thinking-model warning row triggers consistently on remote models that
--- expose a reasoning suffix (qwen3, deepseek, *-r1, *-think*).
function M.is_thinking_model(name)
	if type(name) ~= "string" then return false end
	name = name:lower()
	return name:find("qwen3") ~= nil
		or name:find("deepseek") ~= nil
		or name:find("%-r1") ~= nil
		or name:find(":r1") ~= nil
		or name:find("think") ~= nil
		or name:find("reasoning") ~= nil
end

--- Exposed for regression tests only. These invariants cannot be asserted
--- without running the exact helpers used by the production request path.
M.__redact_url_for_test = redact_url
M.__parse_response_for_test = parse_response





-- =======================================
-- =======================================
-- ======= 7/ Local Servers ==============
-- =======================================
-- =======================================

--- Validates a base URL the user typed for a local server, with the rules of
--- every remote base URL.
--- @param raw any Candidate base URL.
--- @return string|nil normalized Valid HTTP(S) base without trailing slashes.
--- @return string reason Privacy-safe refusal reason.
function M.normalize_base_url(raw)
	return normalize_base_url(raw)
end

--- Where a local server is probed and with which stored key: its API entry's
--- address and key, else those typed this session, else its default address.
--- @param provider_id string Server id of local_servers.json.
--- @return table target { id, base_url, token } (token "" or a stored reference).
function M.local_server_target(provider_id)
	local provider = M.PROVIDERS[provider_id]
	local entry = M.local_server_entry(provider_id)
	local pending = LocalServers.pending(provider_id)
	local base_url = entry and entry.base_url or ""
	if base_url == "" then base_url = pending.base_url or provider.base_url end
	local token = entry and entry.token or pending.token or ""
	return { id = provider_id, base_url = base_url, token = token }
end

--- Sweeps every local server's models endpoint at once, with the rules of the
--- remote availability check (dispatch_probe), and publishes which answer
--- (modules/llm/local_servers.lua). Never blocks: each probe is asynchronous
--- and bounded by local_server_probe_timeout_ms.
--- @param on_done function|nil Receives (changed) when every server settled.
--- @return boolean started
function M.detect_local_servers(on_done)
	local targets = {}
	for _, id in ipairs(LocalServers.ORDER) do
		if M.is_local_server(id) then targets[#targets + 1] = M.local_server_target(id) end
	end
	return LocalServers.sweep(targets, function(target, settle, ticket)
		local base, reason = normalize_base_url(target.base_url)
		if not base then
			Logger.warn(LOG, "Local server '%s' has an invalid address: %s.", target.id, reason)
			return false
		end
		local client = _local_probe_clients[target.id]
		if not client then
			-- A running server on loopback answers at once: the deadline is short
			client = _http_adapter.new({ timeout_ms = Timings.ms("llm", "local_server_probe_timeout_ms") })
			_local_probe_clients[target.id] = client
		end
		-- The ticket fences logical supersession, not native task retirement.
		-- Compare the live settings owner as well: these are its current in-memory
		-- entry/pending fields, not a fresh private-file read or a disk lease.
		local function target_is_current()
			if ticket.is_current() ~= true or not M.is_local_server(target.id) then return false end
			local current = M.local_server_target(target.id)
			return current.id == target.id and current.base_url == target.base_url and current.token == target.token
		end
		local function probe(token)
			if not target_is_current() then return false end
			return dispatch_probe(client, base, "openai", token, function(response)
				if target_is_current() then settle(response) else settle(nil) end
			end)
		end
		if target.token == "" then return probe("") end
		TokenCrypto.decrypt_async(target.token, function(decrypted, token, token_reason)
			-- Held credentials from an older generation must not acquire the
			-- same HTTP client and cancel a newer request. Changed live settings
			-- settle this current target as unavailable until its next search.
			if not target_is_current() then settle(nil); return end
			if decrypted ~= true or type(token) ~= "string" or token == "" then
				Logger.warn(LOG, "Local server '%s' key is unreadable: %s.", target.id, tostring(token_reason))
				-- Probed without its key, the server says whether it wants one
				token = ""
			end
			if probe(token) ~= true then settle(nil) end
		end)
		return true
	end, on_done)
end

return M
