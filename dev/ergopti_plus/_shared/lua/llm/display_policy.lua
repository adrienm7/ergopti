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

--- Copies the numeric indentation catalogue without changing stored value types.
--- @param feature table Canonical generated number feature.
--- @return table values Ordered integer offsets.
function M.indentation_values(feature)
	assert(type(feature) == "table" and feature.type == "number"
		and type(feature.choice_values) == "table" and #feature.choice_values >= 2,
		"indentation requires its canonical numeric choice catalogue")
	local values = {}
	for index, value in ipairs(feature.choice_values) do
		assert(type(value) == "number" and value == math.floor(value)
			and value ~= math.huge and value ~= -math.huge
			and (index == 1 or value == values[index - 1] + 1),
			"indentation choices must be ordered contiguous integers")
		values[index] = value
	end
	return values
end

--- Admits an indentation choice only from a live multi-prediction owner.
--- @param snapshot table Current native owner and exact revision.
--- @return boolean
function M.indentation_ready(snapshot)
	return type(snapshot) == "table" and type(snapshot.owner) == "table"
		and type(snapshot.generation) == "number" and snapshot.generation >= 0
		and snapshot.generation == math.floor(snapshot.generation)
		and type(snapshot.indentation) == "number" and snapshot.indentation == math.floor(snapshot.indentation)
		and type(snapshot.progressive) == "boolean"
		and snapshot.enabled == true and snapshot.paused == false
		and M.ready(snapshot.count, snapshot.blocked)
end

--- Resolves a retained numeric choice against the same current native source.
--- @param expected table Rendering snapshot.
--- @param current table Fresh snapshot before the acknowledged setting owner.
--- @param value number Requested offset.
--- @param values table Canonical ordered integer catalogue.
--- @return table decision { admitted, value? }.
function M.indentation_intent(expected, current, value, values)
	if not M.indentation_ready(expected) or not M.indentation_ready(current) then
		return { admitted = false }
	end
	for _, field in ipairs({ "owner", "generation", "backend", "indentation", "progressive", "count" }) do
		if expected[field] ~= current[field] then return { admitted = false } end
	end
	for _, accepted in ipairs(values) do
		if type(value) == "number" and value == accepted then return { admitted = true, value = value } end
	end
	return { admitted = false }
end

--- Admits the presentation checkbox from a live current native owner.
--- Info Bar does not depend on prediction count or streaming capability.
--- @param snapshot table Current runtime gates and owner revision.
--- @return boolean
function M.info_bar_ready(snapshot)
	return type(snapshot) == "table" and type(snapshot.owner) == "table"
		and type(snapshot.generation) == "number" and snapshot.generation >= 0
		and snapshot.generation == math.floor(snapshot.generation)
		and type(snapshot.backend) == "string" and snapshot.backend ~= ""
		and type(snapshot.info_bar) == "boolean" and snapshot.enabled == true
		and snapshot.paused == false and snapshot.blocked == false
end

--- Resolves one held checkbox against the same acknowledged native source.
--- @param expected table Rendering snapshot.
--- @param current table Current snapshot before the canonical setting owner.
--- @return table decision { admitted, value? }.
function M.info_bar_intent(expected, current)
	if not M.info_bar_ready(expected) or not M.info_bar_ready(current) then
		return { admitted = false }
	end
	for _, field in ipairs({ "owner", "generation", "backend", "info_bar" }) do
		if expected[field] ~= current[field] then return { admitted = false } end
	end
	return { admitted = true, value = not current.info_bar }
end

return M
