--- modules/llm/api_common.lua

--- ==============================================================================
--- MODULE: LLM API Common Helpers
--- DESCRIPTION:
--- Centralizes shared helpers used by MLX and Ollama API controllers.
---
--- FEATURES & RATIONALE:
--- 1. Dedup Strategy: Keeps exact dedup behavior consistent across engines.
--- 2. Diversity Step: Applies the same per-request temperature increment.
--- 3. Unified Logging: Emits the same prediction summary format everywhere.
--- ==============================================================================

local M = {}

M.DEFAULT_DEDUPLICATION_ENABLED = true

--- Computes request temperature for a prediction variant.
--- @param base_temp number Base temperature configured by the user.
--- @param variant_index number Index of the generated variant (1-based).
--- @param step number|nil Optional diversity increment per variant.
--- @return number The computed temperature.
function M.get_diversity_temperature(base_temp, variant_index, step)
	local idx = math.max(1, tonumber(variant_index) or 1)
	local base = tonumber(base_temp) or 0.1
	local delta = tonumber(step)
	if delta == nil then
		if base <= 0.15 then
			delta = 0.24
		elseif base <= 0.35 then
			delta = 0.18
		else
			delta = 0.12
		end
	end

	local effective_base = base
	if idx > 1 and effective_base < 0.20 then
		effective_base = 0.20
	end

	return math.min(1.30, effective_base + (idx - 1) * delta)
end

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

return M
