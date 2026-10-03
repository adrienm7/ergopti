--- tests/unit/adapters/test_e2e_keyboard_source_receipt.lua

--- ==============================================================================
--- MODULE: Simulated Native Keyboard Source Receipts
--- DESCRIPTION:
--- Qualifies the E2E machine boundary independently from remapped script output:
--- exact selected IDs, ordered numeric keys, explicit dead proof and no display
--- alias can fabricate a contextual source. Real OS proof runs in Swift on macOS.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local World = require("tests.e2e.boot.world")
local ABC = "com.apple.keylayout.ABC"
local FRENCH = "com.apple.keylayout.French"
local ERGOPTI = "org.sil.ukelele.keyboardlayout.ergopti.ergopti_v2_2_2_plus"

helpers.describe("E2E machine: native source receipt", function()
	helpers.it("returns ordered physical output and explicit native dead proof for each selected source", function()
		local cases = {
			{source=ABC, expected={{code=8,text="c",dead=false,direct=true}, {code=38,text="j",dead=false,direct=true},
				{code=42,text="\\",dead=false,direct=true}, {code=127,text="",dead=false,direct=false}}},
			{source=FRENCH, expected={{code=8,text="c",dead=false,direct=true}, {code=38,text="j",dead=false,direct=true},
				{code=42,text="",dead=false,direct=false}, {code=127,text="",dead=false,direct=false}}},
			{source=ERGOPTI, expected={{code=8,text="★",dead=false,direct=true}, {code=38,text="s",dead=false,direct=true},
				{code=42,text="",dead=true,direct=false}, {code=127,text="",dead=false,direct=false}}},
		}
		for _, case in ipairs(cases) do
			local answer = World.keyboard_source_answer({"--keyboard-source-probe",case.source,"8","38","42","127"},
				{source_id=case.source})
			helpers.assert_eq(answer.code, 0)
			helpers.assert_eq(Json.decode(answer.stdout), {version=1, source_id=case.source,
				keyboard_type=40, levels=case.expected})
		end
	end)

	helpers.it("refuses stale IDs, display aliases, omitted codes and noncanonical or duplicate identities", function()
		for _, args in ipairs({
			{"--keyboard-source-probe",ERGOPTI,"8"}, {"--keyboard-source-probe","ABC","8"},
			{"--keyboard-source-probe",ABC}, {"--keyboard-source-probe",ABC,"8","8"},
			{"--keyboard-source-probe",ABC,"08"}, {"--keyboard-source-probe",ABC,"128"},
			{"--keyboard-source-probe",ABC,"-1"}, {"--keyboard-source-probe",ABC,"8.5"},
			{"--keyboard-source-probe",ABC,"8.0"}, {"--keyboard-source-probe",ABC,"8e0"},
		}) do
			local answer = World.keyboard_source_answer(args, {source_id=ABC})
			helpers.assert_eq(answer.code, 64)
			helpers.assert_nil(answer.stdout)
		end
	end)

	helpers.it("uses the newly selected source rather than a cached receipt from the previous one", function()
		for _, source in ipairs({ERGOPTI, ABC, ERGOPTI, FRENCH}) do
			local answer = World.keyboard_source_answer({"--keyboard-source-probe",source,"8"}, {source_id=source})
			local receipt = Json.decode(answer.stdout)
			helpers.assert_eq(receipt.source_id, source)
			helpers.assert_eq(receipt.levels[1].text, source == ERGOPTI and "★" or "c")
		end
	end)
end)

return true
