--- tests/support/active_layout_registry_fixture.lua

--- ==============================================================================
--- MODULE: Declared Active Layout Registry Fixture
--- DESCRIPTION:
--- Supplies the registry snapshot seam to consumer fixtures whose unrelated
--- native filesystem ports intentionally cover only their private output.
--- Reads the real shipped index and pins the requested convention explicitly;
--- neither missing metadata nor an unknown identifier acquires a fallback.
--- This models metadata publication, not a native input-source observation.
--- ==============================================================================

local M = {}
local SourceFile = require("tests.support.source_file")
local Json = require("json")

--- Creates a detached registry owner for one explicitly selected real entry.
--- @param active_id string Shipped registered layout identity.
--- @param expected_form string Independently expected ansi | iso declaration.
--- @return table owner Registry snapshot collaborator.
function M.new(active_id, expected_form)
	assert(type(active_id) == "string" and active_id ~= "", "fixture requires a registered source identity")
	assert(expected_form == "ansi" or expected_form == "iso", "fixture requires an explicit convention")
	local source = SourceFile.read(require("tests.helpers").shared("../../layouts/registry/index.json"))
	local index = assert(Json.decode(source), "the shipped registry index must decode")
	local entry = require("layouts.registry").find_entry(index, active_id)
	assert(entry and entry.keycode_convention == expected_form, "the fixture must follow the actual declared source")
	return { snapshot = function()
		return { active = active_id, installed = {}, index = assert(Json.decode(source)), source = "bundled" }
	end }
end

return M
