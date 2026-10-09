--- _shared/lua/llm/trigger_policy.lua

--- ==============================================================================
--- MODULE: Prediction Privacy Intent
--- DESCRIPTION:
--- Admits retained privacy checks only against the same live native owner.
--- Drivers prove exact source bytes and retain acknowledged publication owners.
--- ==============================================================================

local M = {}

--- Requires a complete native boolean snapshot and an available live master.
--- @param snapshot table Native owner, revision and privacy intent.
--- @return boolean ready
function M.ready(snapshot)
	return type(snapshot) == "table" and type(snapshot.owner) == "table"
		and type(snapshot.generation) == "number" and snapshot.generation >= 0
		and snapshot.generation < math.huge and snapshot.generation == math.floor(snapshot.generation)
		and type(snapshot.backend) == "string" and snapshot.backend ~= ""
		and type(snapshot.value) == "boolean" and snapshot.enabled == true
		and snapshot.paused == false and snapshot.blocked == false
end

--- Resolves a click without borrowing a newer owner's privacy intent.
--- @param expected table Snapshot captured when the row was rendered.
--- @param current table Fresh native snapshot before publication.
--- @return table decision Strict admission and optional next boolean.
function M.intent(expected, current)
	if not M.ready(expected) or not M.ready(current) then return { admitted = false } end
	for _, field in ipairs({ "owner", "generation", "backend", "value" }) do
		if expected[field] ~= current[field] then return { admitted = false } end
	end
	return { admitted = true, value = not current.value }
end

return M
