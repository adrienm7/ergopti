-- _shared/lua/layout/number_row_policy.lua
-- ============================================================================
-- MODULE: Number Row Policy
-- DESCRIPTION:
-- Validates number-row intent and source-scoped capability. Native adapters
-- retain physical descriptors, emission, persistence and lifecycle ownership.
-- ============================================================================

local M = {}

function M.mode(value)
	if value == "native" or value == "digits" or value == "symbols" then return value end
	return nil
end

local function descriptor(value)
	return type(value) == "table" and (
		(value.Kind == "text" and type(value.Text) == "string" and value.Text ~= "")
		or (value.Kind == "dead" and type(value.Action) == "string" and value.Action ~= ""
			and type(value.State) == "string" and value.State ~= ""
			and type(value.Text) == "string" and value.Text ~= "")
	)
end

--- Resolves the source level; a dead-key action retains its native machine.
function M.symbols_shift(digit, plain, shifted)
	if type(digit) ~= "string" or not digit:match("^%d$")
		or not descriptor(plain) or not descriptor(shifted) then return nil end
	local plain_digit = plain.Kind == "text" and plain.Text == digit
	local shifted_digit = shifted.Kind == "text" and shifted.Text == digit
	if plain_digit == shifted_digit then return nil end
	return plain_digit
end

function M.capable(platform, mode, symbols)
	if not M.mode(mode) then return false end
	if mode == "native" then return platform == "ahk" or platform == "hs" or platform == "linux" end
	return platform == "ahk" and (mode == "digits" or symbols == true)
end

local function integer(value)
	return type(value) == "number" and value >= 0 and value <= 9007199254740991 and value % 1 == 0
end

function M.ready(snapshot, value)
	if type(snapshot) ~= "table" or not M.mode(snapshot.mode) or not M.mode(value)
		or type(snapshot.owner) ~= "table" or type(snapshot.native_owner) ~= "table" then return false end
	local source = snapshot.source
	if type(source) ~= "table" and not (type(source) == "string" and source ~= "")
		and not (type(source) == "number" and source ~= 0 and source % 1 == 0 and math.abs(source) <= 9007199254740991) then return false end
	for _, field in ipairs({ "generation", "lifecycle" }) do
		if not integer(snapshot[field]) then return false end
	end
	if type(snapshot.hkl) ~= "number" or snapshot.hkl == 0 or snapshot.hkl % 1 ~= 0
		or math.abs(snapshot.hkl) > 9007199254740991 then return false end
	for _, field in ipairs({ "master", "paused", "symbols", "blocked", "caps" }) do
		if type(snapshot[field]) ~= "boolean" then return false end
	end
	return snapshot.master and not snapshot.paused and not snapshot.blocked and M.capable(snapshot.platform, value, snapshot.symbols)
end

function M.intent(expected, current, value)
	if not M.ready(expected, value) or not M.ready(current, value) then return false end
	for _, field in ipairs({ "owner", "source", "native_owner", "generation", "lifecycle", "hkl", "platform", "mode", "symbols", "caps" }) do
		if expected[field] ~= current[field] then return false end
	end
	return true
end

--- Reports actual native posture without claiming or saving a Lua preference.
--- Unknown personal fields remain entirely outside this read-only provider.
function M.native_rows(renderer, commands)
	if type(renderer) ~= "table" or type(renderer.choice_row) ~= "function"
		or type(renderer.get_array) ~= "function" or type(commands) ~= "table"
		or type(commands["number_row_mode"]) ~= "function" then return {} end
	local definitions = renderer.get_array("number_row_policy_rows")
	local declaration = type(definitions) == "table" and #definitions == 1 and definitions[1]
	local choices = type(declaration) == "table" and declaration.choices
	if type(choices) ~= "table" or #choices ~= 3
		then return {} end
	for index, value in ipairs({ "native", "digits", "symbols" }) do
		if type(choices[index]) ~= "table" or choices[index].value ~= value then return {} end
	end
	local row = renderer.choice_row("number_row_policy_rows", "number_row_mode",
		commands,
		{ ["layout.direct_access_digits"] = function() return "native" end })
	if type(row) ~= "table" or type(row.items) ~= "table" or #row.items ~= #choices then return {} end
	for _, item in ipairs(row.items) do
		if type(item) ~= "table" then return {} end
	end
	for index, item in ipairs(row.items) do
		item.action = nil
		item.disabled = true
		if choices[index].value ~= "native" then
			item.disabled_reason_key = "platform_reason.number_row_override_unsupported"
		end
	end
	return { row }
end

return M
