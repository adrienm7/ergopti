--- _shared/lua/shortcuts/magic_editor.lua

--- ==============================================================================
--- MODULE: Physical Magic Editor Shortcut Policy
--- DESCRIPTION:
--- Resolves one ordinary action slot against acknowledged plain physical-source
--- evidence. Drivers own native probing and acquisition; the action, source
--- eligibility, conflict priority and deferred-delivery rules live here.
--- ==============================================================================

local M = {}

M.SLOT_ID = "magic_editor"
M.PATH = "shortcuts.keyboard.magic_editor"
M.BINDING_ID = "keyboard__magic_editor"





-- ====================================
-- ====================================
-- ======= 1/ Physical evidence =======
-- ====================================
-- ====================================

--- Requires a non-negative integer owner generation.
--- @param value any Owner generation.
--- @return boolean valid
local function generation(value)
	return type(value) == "number" and value >= 0 and value % 1 == 0
end

--- Copies a physical candidate without sharing mutable source-owner records.
--- @param candidate table Native owner's validated physical candidate.
--- @return table copy
local function copy_candidate(candidate)
	return {
		code = candidate.code,
		native_code = candidate.native_code,
		identity = candidate.identity,
		text = candidate.text,
		direct = candidate.direct,
		dead = candidate.dead,
	}
end

--- Selects a unique plain source without changing native layout or lock state.
--- The caller supplies every candidate from the actual native owner. A source
--- using Shift, AltGr or a dead state never becomes a conditional shortcut.
--- @param source table Receipt { generation, status, candidates }.
--- @param trigger string Current magic trigger, compared exactly.
--- @param known_codes table Registry KeyboardEvent.code to true or record.
--- @return table|nil candidate Detached unique physical source.
--- @return string|nil reason Stable inactive reason.
function M.select_source(source, trigger, known_codes)
	assert(type(source) == "table" and generation(source.generation),
		"magic editor: source evidence requires an owner generation")
	assert(type(trigger) == "string" and trigger ~= "", "magic editor: the trigger is missing")
	assert(type(known_codes) == "table", "magic editor: the physical catalogue is missing")
	assert(source.status == "ready" or source.status == "unavailable", "magic editor: invalid source status")
	if source.status == "unavailable" then return nil, "source_unavailable" end
	assert(type(source.candidates) == "table", "magic editor: source evidence lacks its candidates")
	local candidates, dead, modified = {}, false, false
	local count = 0
	for key in pairs(source.candidates) do
		assert(generation(key) and key >= 1 and key <= #source.candidates,
			"magic editor: source candidates must be a dense array")
		count = count + 1
	end
	assert(count == #source.candidates, "magic editor: source candidates contain a hole")
	for _, candidate in ipairs(source.candidates) do
		assert(type(candidate) == "table" and type(candidate.code) == "string"
			and known_codes[candidate.code] ~= nil, "magic editor: source is outside the physical catalogue")
		assert(generation(candidate.native_code), "magic editor: source lacks its native code")
		assert(type(candidate.identity) == "string" and candidate.identity ~= "",
			"magic editor: source lacks its physical identity")
		assert(type(candidate.text) == "string" and type(candidate.direct) == "boolean"
			and type(candidate.dead) == "boolean", "magic editor: source lacks direct-tap evidence")
		if candidate.text == trigger then
			if candidate.dead then
				dead = true
			elseif not candidate.direct then
				modified = true
			else
				candidates[candidate.identity] = copy_candidate(candidate)
			end
		end
	end
	local selected
	for _, candidate in pairs(candidates) do
		if selected then return nil, "source_ambiguous" end
		selected = candidate
	end
	if selected then return selected end
	if dead then return nil, "source_dead" end
	if modified then return nil, "source_requires_modifiers" end
	return nil, "source_missing"
end





-- =======================================
-- =======================================
-- ======= 2/ Ordinary slot policy =======
-- =======================================
-- =======================================

--- Resolves a configured action without enabling its category or taking input.
--- Explicit claims contain only present ordinary settings, including "none";
--- seeded neutral defaults must never masquerade as user-owned conflicts.
--- @param opts table Action, source, catalogue, claims and admission snapshots.
--- @return table decision Detached action and native-acquisition decision.
function M.resolve(opts)
	assert(type(opts) == "table" and type(opts.is_action) == "function",
		"magic editor: resolution requires the ordinary action catalogue")
	assert(type(opts.default_action) == "string" and opts.is_action(opts.default_action),
		"magic editor: the manifest default is not a runnable action")
	local action = opts.stored_action
	if action == nil then action = opts.default_action end
	assert(type(action) == "string" and (action == "none" or opts.is_action(action)),
		"magic editor: the configured action is not owned")
	assert(generation(opts.configuration_generation), "magic editor: configuration lacks its generation")
	assert(type(opts.explicit_claims) == "table", "magic editor: explicit claim provenance is missing")
	local admission = opts.admission
	assert(type(admission) == "table" and type(admission.master) == "boolean"
		and type(admission.paused) == "boolean" and type(admission.inhibited) == "boolean",
		"magic editor: admission requires live category, pause and inhibition gates")
	local source, source_reason = M.select_source(opts.source, opts.trigger, opts.known_codes)
	local decision = {
		slot_id = M.SLOT_ID,
		path = M.PATH,
		binding_id = M.BINDING_ID,
		action = action,
		active = false,
		source = source,
		source_reason = source_reason,
		source_generation = opts.source.generation,
		configuration_generation = opts.configuration_generation,
	}
	if action == "none" then decision.reason = "shortcut_disabled"
	elseif not admission.master then decision.reason = "shortcuts_disabled"
	elseif admission.paused then decision.reason = "paused"
	elseif admission.inhibited then decision.reason = "inhibited"
	elseif source_reason then decision.reason = source_reason
	elseif opts.explicit_claims[source.identity] ~= nil then decision.reason = "explicit_assignment"
	else decision.active = true end
	return decision
end

--- Rechecks the live owner state before a queued native delivery can run.
--- @param decision table Captured result of resolve().
--- @param state table Live generations, action, category and admission gates.
--- @return boolean admitted
function M.can_deliver(decision, state)
	return type(decision) == "table" and decision.active == true and type(state) == "table"
		and state.master == true and state.paused == false and state.inhibited == false
		and state.action == decision.action
		and state.source_generation == decision.source_generation
		and state.configuration_generation == decision.configuration_generation
end

return M
