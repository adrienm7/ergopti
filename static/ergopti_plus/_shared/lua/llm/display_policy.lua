--- _shared/lua/llm/display_policy.lua

--- ==============================================================================
--- MODULE: Prediction Display Polarity
--- DESCRIPTION:
--- Keeps the canonical progressive preference opposite to the native show-all
--- checkbox. Drivers retain persistence, readiness and presentation ownership.
--- ==============================================================================

local M = {}





-- =================================
-- =================================
-- =================================
-- =================================
-- =================================

--- Converts the canonical progressive preference to the show-all checkbox.
--- @param progressive boolean
--- @return boolean
function M.show_all(progressive)
	assert(type(progressive) == "boolean", "progressive display must be boolean")
	return not progressive
end

--- Converts a native show-all preference back to canonical progressive display.
--- @param show_all boolean
--- @return boolean
function M.progressive(show_all)
	return M.show_all(show_all)
end

--- Whether a current native owner may change the multi-prediction display mode.
--- @param count number
--- @param blocked boolean
--- @return boolean
function M.ready(count, blocked)
	return blocked == false and type(count) == "number"
		and count == math.floor(count) and count >= 2
end

--- Whether the current driver has an actual token streaming transport.
--- Buffered API answers do not qualify as native partial frames.
--- @param platform string Canonical driver id.
--- @param backend string Current native backend id.
--- @return boolean
function M.streaming_capable(platform, backend)
	return (platform == "hs" and (backend == "ollama" or backend == "mlx"))
		or (platform == "linux" and backend == "ollama")
end

--- Whether a fresh native snapshot admits changing token streaming.
--- @param snapshot table Runtime gates and exact owner revision.
--- @return boolean
function M.streaming_ready(snapshot)
	return type(snapshot) == "table"
		and (type(snapshot.owner) == "table" or (type(snapshot.owner) == "string" and snapshot.owner ~= ""))
		and type(snapshot.generation) == "number" and snapshot.generation >= 0
		and snapshot.generation == math.floor(snapshot.generation)
		and type(snapshot.streaming) == "boolean"
		and snapshot.enabled == true and snapshot.paused == false
		and snapshot.blocked == false and snapshot.progressive == true
		and M.streaming_capable(snapshot.platform, snapshot.backend)
end

--- Resolves a retained checkbox only against the same current native source.
--- @param expected table Snapshot captured when this checkbox was rendered.
--- @param current table Fresh native snapshot collected before publication.
--- @return table decision { admitted, value? }.
function M.streaming_intent(expected, current)
	if not M.streaming_ready(expected) or not M.streaming_ready(current) then
		return { admitted = false }
	end
	for _, field in ipairs({ "owner", "generation", "platform", "backend", "streaming", "progressive" }) do
		if expected[field] ~= current[field] then return { admitted = false } end
	end
	return { admitted = true, value = not current.streaming }
end

return M
