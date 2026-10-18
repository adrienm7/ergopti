--- _shared/lua/test/personal_metadata_type_contract.lua

--- ==============================================================================
--- MODULE: Personal Metadata Stored-Type Contract
--- DESCRIPTION:
--- Literal source values never acquire edit authority by disappearing from a view.
--- Independent vectors preserve foreign leaves while retaining safe controls.
--- ==============================================================================

local M = {}

--- Reads the exact canonical leaf independently of the hotstring projection.
--- @param content string Prepared source bytes.
--- @param section string|nil Literal section name.
--- @param field string Selected control.
--- @return any Stored value, or nil when explicitly cleared.
local function stored(content, section, field)
	local document = assert(require("toml_codec").decode(content))
	local meta = document._meta
	if section then meta = type(meta) == "table" and type(meta.sections) == "table" and meta.sections[section] end
	if type(meta) == "table" then return meta[field] end
	return nil
end

--- Replays raw metadata admission and source-preserving candidate preparation.
--- @param helpers table Existing driver assertions and case registration.
--- @param corpus table Independently authored source vectors.
function M.run(helpers, corpus)
	local Metadata = require("hotstrings.personal_metadata")
	local Codec = require("toml_codec")
	assert(corpus.version == 1 and #corpus.vectors == 24, "personal metadata type corpus must contain twenty-four vectors")
	helpers.describe("personal metadata stored types", function()
		for _, vector in ipairs(corpus.vectors) do
			helpers.it("(personal-metadata-source-type) " .. vector.name, function()
				helpers.assert_not_nil(Codec.decode(vector.source), "the source is genuine admitted TOML")
				local fields = Metadata.readonly_fields(vector.source, vector.section, vector.legacy)
				helpers.assert_eq(fields[vector.field], not vector.allowed)
				local plan = Metadata.prepare(vector.source, vector.section, vector.field, vector.value, vector.legacy)
				local cleared = Metadata.prepare(vector.source, vector.section, vector.field, nil, vector.legacy)
				if vector.allowed then
					helpers.assert_not_nil(plan); helpers.assert_not_nil(cleared)
					helpers.assert_eq(stored(plan.content, vector.section, vector.field), vector.value)
					helpers.assert_nil(stored(cleared.content, vector.section, vector.field))
					helpers.assert_contains(plan.content, vector.preserve)
					helpers.assert_contains(cleared.content, vector.preserve)
					helpers.assert_not_nil(Codec.decode(plan.content)); helpers.assert_not_nil(Codec.decode(cleared.content))
				else
					helpers.assert_nil(plan, "an ignored stored type is not an absent owned leaf")
					helpers.assert_nil(cleared, "clearing must also preserve the invalid source owner")
					if vector.safe_field or vector.safe_file_field then
						local safe_section = vector.section
						-- A file control is deliberately selected independently of section admission.
						if vector.safe_file_field then safe_section = nil end
						local safe_field = vector.safe_field or vector.safe_file_field
						helpers.assert_eq(Metadata.readonly_fields(vector.source, safe_section, vector.legacy)[safe_field], false)
						local safe = Metadata.prepare(vector.source, safe_section, safe_field, vector.safe_value, vector.legacy)
						helpers.assert_not_nil(safe, "unrelated valid controls remain editable")
						helpers.assert_eq(stored(safe.content, safe_section, safe_field), vector.safe_value)
						helpers.assert_contains(safe.content, vector.preserve)
						helpers.assert_not_nil(Codec.decode(safe.content))
					end
				end
			end)
		end
	end)
end

return M
