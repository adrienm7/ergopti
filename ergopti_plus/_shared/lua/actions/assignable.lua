--- _shared/lua/actions/assignable.lua

--- ==============================================================================
--- MODULE: Assignable Actions
--- DESCRIPTION:
--- Builds the ordinary binding identity set from the generated action catalogue
--- and the actual shared modifier-key catalogue. Boot migrations and native
--- assignment validation use this same owner without loading native actions
--- before configuration migration. Picker order, labels and native dispatch
--- remain owned by their existing catalogues and registrars.
--- ==============================================================================

local M = {}

--- @param catalogue table Generated, platform-filtered action catalogue.
--- @param modifier_chords table Decoded canonical modifier_chords.json.
--- @param platform string Shared catalogue platform, e.g. "macos".
--- @return table Set of assignable action identities.
function M.build(catalogue, modifier_chords, platform)
	assert(type(catalogue) == "table" and type(catalogue.sg_items) == "table"
		and type(catalogue.ax_items) == "table", "assignable: invalid action catalogue")
	local native = modifier_chords and modifier_chords.platforms and modifier_chords.platforms[platform]
	local result = {}
	for _, item in ipairs(catalogue.sg_items) do
		if item.kind == "action" then result[item.id] = true end
	end
	for _, id in ipairs(catalogue.ax_items) do result[id] = true end
	-- Native registration historically keeps static actions when its optional
	-- modifier catalogue is unavailable; boot context validation is stricter.
	if type(native) ~= "table" or type(native.modifiers) ~= "table"
		or type(modifier_chords.keys) ~= "table" then return result end
	for mask = 1, (2 ^ #native.modifiers) - 1 do
		local ids = {}
		for index, modifier in ipairs(native.modifiers) do
			if math.floor(mask / (2 ^ (index - 1))) % 2 == 1 then ids[#ids + 1] = modifier.id end
		end
		local prefix = table.concat(ids, "_") .. "_"
		for _, key in ipairs(modifier_chords.keys) do result[prefix .. key.id] = true end
	end
	return result
end

return M
