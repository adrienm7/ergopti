--- modules/llm/api_common.lua

--- ==============================================================================
--- MODULE: LLM API Common Helpers
--- DESCRIPTION:
--- Centralizes shared helpers used by every LLM backend (MLX, Ollama, remote API)
--- — diversity temperature stepping, exact-text deduplication, retry policy.
--- The tunable numbers live in ``static/ergopti_plus/_shared/modules/llm/inference.json``
--- next to defaults.json so the AHK twin (modules/llm/api_common.ahk) reads
--- the SAME values: change a knob there and both drivers track it in lockstep.
---
--- FEATURES & RATIONALE:
--- 1. Single source of truth: tunables (diversity step, retry multiplier, dedup
---    default, rate-limit floor) live in JSON next to the rest of the LLM
---    shared config — no constant ever ships in two languages by accident.
--- 2. Dedup Strategy: Keeps exact dedup behaviour consistent across engines.
--- 3. Diversity Step: Applies the same per-request temperature increment.
--- 4. Unified Logging: Emits the same prediction summary format everywhere.
--- ==============================================================================

local M = {}
local hs     = hs
local Logger = require("infra.logger")
local Paths  = require("infra.paths")
local FileSystem = require("adapters.file_system")   -- OS-pure file read (port FileSystem)
local JsonCodec  = require("adapters.json_codec")    -- OS-pure JSON decode (port JsonCodec)
local LOG    = "llm.api_common"




-- =====================================
-- =====================================
-- ======= 1/ Shared Constants =========
-- =====================================
-- =====================================

--- Hardcoded fallback used when inference.json can't be read. Values match
--- the JSON committed alongside this file — keeping them here too means a
--- corrupted / missing JSON never leaves the engine in an undefined state.
local FALLBACK = {
	diversity_temperature = {
		step_when_base_le_0_15  = 0.24,
		step_when_base_le_0_35  = 0.18,
		step_default            = 0.12,
		effective_base_floor    = 0.20,
		max_temperature         = 1.30,
	},
	dedup = {
		enabled_by_default = true,
	},
	retry = {
		max_multiplier         = 2,
		retry_temperature_step = 0.18,
		retry_extra_tokens     = 5,
	},
	rate_limit_min_interval_ms = {
		ollama = 300,
		mlx    = 300,
		api    = 500,
	},
	stop_sequences = {
		batch = { "<|eot_id|>", "<|im_end|>", "[/INST]", "PREFIX:", "TAIL:" },
		line  = { "<|eot_id|>", "<|im_end|>", "[/INST]", "PREFIX:", "TAIL:", "\n\n", "===", "\n", "\r", "</", "Suite finale", "SUITE", "NEXT_WORDS:" },
	},
}

--- Loads the inference.json sitting next to defaults.json. The path is resolved
--- through the single shared-tree resolver (Paths.shared), which performs the
--- dual-root upward walk — robust to packaged .app builds and symlinked
--- ~/.hammerspoon setups alike. Falls back to FALLBACK on any read/parse failure.
--- @return table The constants table (always non-nil — falls back to FALLBACK).
local function load_inference_constants()
	local p = Paths.shared("modules/llm/inference.json")
	if type(p) == "string" and p ~= "" then
		local fh = io.open(p, "r")
		if fh then
			local raw = fh:read("*a")
			fh:close()
			local ok, parsed = pcall(hs.json.decode, raw)
			if ok and type(parsed) == "table" then
				Logger.debug(LOG, "Loaded inference constants from %s.", p)
				return parsed
			end
		end
	end
	Logger.warn(LOG, "inference.json not found — using hardcoded fallback.")
	return FALLBACK
end

local INFERENCE = load_inference_constants()

--- Loads the default generation temperature from the shared defaults.json — the
--- same single source DEFAULT_STATE is built from — so every backend's defensive
--- temperature fallback resolves to one value instead of a literal duplicated
--- across the backend adapters. Mirrors 0.1 only when the JSON is unreadable,
--- matching the FALLBACK convention above (a corrupt JSON never leaves the
--- temperature nil).
--- @return number The default generation temperature.
local function load_default_temperature()
	local p = Paths.shared("modules/llm/defaults.json")
	if type(p) == "string" and p ~= "" then
		local raw = FileSystem.read(p)
		if raw then
			local ok, parsed = pcall(JsonCodec.decode, raw)
			if ok and type(parsed) == "table" and tonumber(parsed.llm_temperature) then
				return tonumber(parsed.llm_temperature)
			end
		end
	end
	Logger.warn(LOG, "defaults.json llm_temperature unreadable — using mirrored fallback.")
	return 0.1
end

--- Default generation temperature, single-sourced from defaults.json. Backends
--- read it as ``ApiCommon.DEFAULT_TEMPERATURE`` for their defensive fallback so
--- the value is never hardcoded at the call site.
local DEFAULT_TEMPERATURE = load_default_temperature()
M.DEFAULT_TEMPERATURE = DEFAULT_TEMPERATURE

--- Loads the default Ollama keep-alive window from the shared defaults.json — the
--- single source every payload builder reads so "30m" is never hardcoded at the
--- call site. Mirrors "30m" only when the JSON is unreadable, matching the
--- FALLBACK convention above (a corrupt JSON never leaves keep_alive nil).
--- @return string The default keep-alive window.
local function load_default_keep_alive()
	local p = Paths.shared("modules/llm/defaults.json")
	if type(p) == "string" and p ~= "" then
		local raw = FileSystem.read(p)
		if raw then
			local ok, parsed = pcall(JsonCodec.decode, raw)
			if ok and type(parsed) == "table" and type(parsed.llm_ollama_keep_alive) == "string" then
				return parsed.llm_ollama_keep_alive
			end
		end
	end
	Logger.warn(LOG, "defaults.json llm_ollama_keep_alive unreadable — using mirrored fallback.")
	return "30m"
end

--- Default Ollama keep-alive window, single-sourced from defaults.json. Backends
--- read it as ``ApiCommon.OLLAMA_KEEP_ALIVE`` so the value is never hardcoded at
--- the payload call site (the AHK twin seeds LLM_OLLAMA_KEEP_ALIVE the same way).
M.OLLAMA_KEEP_ALIVE = load_default_keep_alive()

--- Picks a field from the JSON config, falling back to FALLBACK on miss.
--- Keeps the call sites readable: ``cfg("diversity_temperature", "step_default")``.
local function cfg(section, key)
	local sub = INFERENCE[section]
	if type(sub) == "table" and sub[key] ~= nil then return sub[key] end
	return FALLBACK[section][key]
end

M.DEFAULT_DEDUPLICATION_ENABLED = cfg("dedup", "enabled_by_default") == true

--- Returns the minimum interval (seconds) between two prediction requests
--- for the given backend id. Mirrors the AHK twin's
--- LLM_BACKEND_MIN_REQUEST_INTERVAL_MS so the floor is identical across
--- drivers. Falls back to 0.3 s for unknown backends.
function M.get_rate_limit_min_interval_s(backend_id)
	local map = INFERENCE.rate_limit_min_interval_ms or FALLBACK.rate_limit_min_interval_ms
	local ms  = tonumber(map[backend_id])
	if ms == nil then ms = 300 end
	return ms / 1000.0
end

--- Returns the full retry policy, intended for the sequential fetch loop.
--- @return number max_multiplier, number retry_temperature_step, number retry_extra_tokens
function M.get_retry_policy()
	return cfg("retry", "max_multiplier"),
		cfg("retry", "retry_temperature_step"),
		cfg("retry", "retry_extra_tokens")
end

--- Returns the stop-sequence array for the given backend variant.
--- Reads directly from the INFERENCE table (arrays survive hs.json.decode natively).
--- Falls back to FALLBACK on a missing key so a corrupt inference.json never
--- leaves the engine with a nil stop list.
--- @param variant string One of "batch", "line".
--- @return table Array of stop-token strings.
function M.get_stop_sequences(variant)
	local seqs = INFERENCE.stop_sequences
	if type(seqs) == "table" and type(seqs[variant]) == "table" then
		return seqs[variant]
	end
	local fb = FALLBACK.stop_sequences and FALLBACK.stop_sequences[variant]
	if type(fb) == "table" then
		Logger.warn(LOG, "inference.json missing stop_sequences.%s — using hardcoded fallback.", variant)
		return fb
	end
	error("ergopti_plus: inference.json missing stop_sequences." .. tostring(variant) .. " and no fallback available")
end




-- =========================================
-- =========================================
-- ======= 2/ Diversity Temperature ========
-- =========================================
-- =========================================

--- Computes request temperature for a prediction variant.
--- Algorithm (must stay in lockstep with the AHK twin):
---   1. Resolve the diversity step:
---        - explicit ``step`` parameter wins when provided,
---        - else: base ≤ 0.15 → step_when_base_le_0_15
---                base ≤ 0.35 → step_when_base_le_0_35
---                base  > 0.35 → step_default
---   2. Raise the effective base to effective_base_floor when variant_index > 1
---      AND base < effective_base_floor — the first variant stays faithful to
---      the user's setting, the next ones get headroom for diversity.
---   3. Clamp the final value at max_temperature.
--- @param base_temp number Base temperature configured by the user.
--- @param variant_index number Index of the generated variant (1-based).
--- @param step number|nil Optional diversity increment per variant.
--- @return number The computed temperature.
function M.get_diversity_temperature(base_temp, variant_index, step)
	local idx = math.max(1, tonumber(variant_index) or 1)
	local base = tonumber(base_temp) or DEFAULT_TEMPERATURE
	local delta = tonumber(step)
	if delta == nil then
		if base <= 0.15 then
			delta = cfg("diversity_temperature", "step_when_base_le_0_15")
		elseif base <= 0.35 then
			delta = cfg("diversity_temperature", "step_when_base_le_0_35")
		else
			delta = cfg("diversity_temperature", "step_default")
		end
	end

	local floor_val = cfg("diversity_temperature", "effective_base_floor")
	local max_val   = cfg("diversity_temperature", "max_temperature")
	local effective_base = base
	if idx > 1 and effective_base < floor_val then
		effective_base = floor_val
	end

	return math.min(max_val, effective_base + (idx - 1) * delta)
end




-- =====================================
-- =====================================
-- ======= 3/ Dedup Helpers ============
-- =====================================
-- =====================================

--- Builds an empty dedup statistics table.
--- @return table Stats with candidates, duplicates and kept counters.
function M.new_dedup_stats()
	return { candidates = 0, duplicates = 0, kept = 0 }
end

--- Inserts a prediction with optional exact-text deduplication.
--- @param results table Accumulator list.
--- @param pred table Candidate prediction object.
--- @param stats table|nil Dedup statistics accumulator.
--- @param dedup_enabled boolean Whether exact deduplication is enabled.
--- @param logger table Logger module.
--- @param log_name string Logger namespace.
--- @return boolean True when inserted, false when ignored.
function M.insert_prediction(results, pred, stats, dedup_enabled, logger, log_name)
	if type(results) ~= "table" or type(pred) ~= "table" then return false end
	if type(stats) == "table" then
		stats.candidates = (stats.candidates or 0) + 1
	end

	if dedup_enabled ~= true then
		table.insert(results, pred)
		if type(stats) == "table" then
			stats.kept = (stats.kept or 0) + 1
		end
		return true
	end

	local pred_text = tostring(pred.to_type or "")
	for _, existing in ipairs(results) do
		if tostring(existing.to_type or "") == pred_text then
			if logger and type(logger.debug) == "function" then
				logger.debug(log_name, "Déduplication: prédiction ignorée (doublon exact) → %s", pred_text:sub(1, 120))
			end
			if type(stats) == "table" then
				stats.duplicates = (stats.duplicates or 0) + 1
			end
			return false
		end
	end

	table.insert(results, pred)
	if type(stats) == "table" then
		stats.kept = (stats.kept or 0) + 1
	end
	return true
end




-- =====================================
-- =====================================
-- ======= 4/ Logging Helpers ==========
-- =====================================
-- =====================================

--- Logs prediction summary counters for one fetch strategy.
--- @param logger table Logger module.
--- @param log_name string Logger namespace.
--- @param mode string Strategy label (batch/parallel/sequential).
--- @param requested number Requested prediction count.
--- @param stats table|nil Dedup statistics.
--- @param kept_count number Final kept prediction count.
function M.log_prediction_summary(logger, log_name, mode, requested, stats, kept_count)
	if not logger or type(logger.info) ~= "function" then return end
	local s = type(stats) == "table" and stats or {}
	logger.info(
		log_name,
		"Résumé prédictions [%s]: demandées=%d, candidates=%d, doublons=%d, retenues=%d",
		tostring(mode or "unknown"),
		tonumber(requested) or 0,
		s.candidates or 0,
		s.duplicates or 0,
		type(kept_count) == "number" and kept_count or 0
	)
end


--- Invoke an LLM completion callback so a throw inside it cannot vanish.
---
--- Every backend hands its result to a caller-supplied callback, and those
--- hand-offs were written as bare `pcall(on_x, ...)`. pcall without inspecting
--- its result is not error handling, it is error deletion: an engine-side throw
--- — a parser choking on a malformed body, a renderer hitting a nil field —
--- became indistinguishable from a request that simply never completed. No
--- prediction, no error, nothing to search the log for. That is the exact shape
--- of the "green but no prediction" reports.
---
--- xpcall with a traceback rather than plain pcall: by the time the error
--- surfaces the stack is gone, and the traceback is the only thing that says
--- WHICH callback failed and where.
---
--- The error is contained rather than rethrown on purpose. These run from HTTP
--- completion handlers and timer callbacks, where an escaping exception reaches
--- Hammerspoon's own handler and is reported far from its cause; abandoning the
--- one request is the correct blast radius.
---
--- @param fn function|nil The callback. A non-function is a no-op, matching the
---        `type(x) == "function"` guards these call sites already carried.
--- @param name string Callback name, for the log line.
--- @param ... any Forwarded verbatim.
function M.protected_call(fn, name, ...)
	if type(fn) ~= "function" then return end
	local args = table.pack(...)
	local ok, err = xpcall(function()
		return fn(table.unpack(args, 1, args.n))
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "Callback '%s' raised: %s. This request is abandoned — nothing "
			.. "downstream retries it, so the user simply never sees a prediction.",
			tostring(name), tostring(err))
	end
end

return M
