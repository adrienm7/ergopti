--- tests/unit/infra/test_hs_json_stub_contract.lua

--- ==============================================================================
--- MODULE: Hammerspoon JSON Stub Control Escape Contract
--- DESCRIPTION:
--- Keeps independently authored JSON control bytes distinct from literal escape
--- examples when the native stub reads unchanged golden corpora.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("hs.json stub: control escape bytes", function()
	helpers.it("decodes backspace and form feed as independent byte expectations", function()
		local codec = dofile("tests/stubs/hs.lua").json
		local actual = codec.decode([=["Back\bform\f"]=])
		helpers.assert_eq(actual, "Back" .. string.char(8) .. "form" .. string.char(12))
	end)

	helpers.it("preserves escaped backslashes in literal control escape examples", function()
		local codec = dofile("tests/stubs/hs.lua").json
		local actual = codec.decode([=["Back\\bform\\f"]=])
		helpers.assert_eq(actual, [=[Back\bform\f]=])
	end)
end)
