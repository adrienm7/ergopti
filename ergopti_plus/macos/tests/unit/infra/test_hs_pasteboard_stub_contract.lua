--- tests/unit/infra/test_hs_pasteboard_stub_contract.lua

--- ==============================================================================
--- MODULE: Hammerspoon Pasteboard Stub Contract
--- DESCRIPTION:
--- Pins the healthy Hammerspoon 1.1.1 pasteboard contract for UTF-8 text and
--- UTI-keyed raw bytes. Successful writes must publish observable state, and
--- snapshots must survive independent mutations before a later restoration.
--- ==============================================================================

local helpers = require("tests.helpers")

local TEXT_UTI = "public.utf8-plain-text"

helpers.describe("hs.pasteboard stub: observable native data", function()
	helpers.it("publishes UTF-8 text and replaces the previous clipboard types", function()
		local pasteboard = dofile("tests/stubs/hs.lua").pasteboard
		helpers.assert_nil(pasteboard.getContents(), "an empty native clipboard has no text")
		helpers.assert_eq(pasteboard.writeAllData({ ["public.rtf"] = "{\\rtf1 original}" }), true)
		helpers.assert_eq(pasteboard.setContents("Érgopti ✓"), true)
		helpers.assert_eq(pasteboard.getContents(), "Érgopti ✓")
		helpers.assert_eq(pasteboard.readAllData(), { [TEXT_UTI] = "Érgopti ✓" })
	end)

	helpers.it("snapshots all raw bytes independently on write and every read", function()
		local pasteboard = dofile("tests/stubs/hs.lua").pasteboard
		local original = {
			[TEXT_UTI] = "Original text",
			["public.rtf"] = "{\\rtf1 original}",
			["public.png"] = "\137PNG\0\255\r\n",
		}
		helpers.assert_eq(pasteboard.writeAllData(original), true)
		original[TEXT_UTI] = "unpublished mutation"
		original["public.png"] = nil
		local first = pasteboard.readAllData()
		local second = pasteboard.readAllData()
		helpers.assert_eq(first[TEXT_UTI], "Original text")
		helpers.assert_eq(first["public.png"], "\137PNG\0\255\r\n")
		helpers.assert_true(first ~= second, "native readAllData allocates a fresh table")
		first[TEXT_UTI] = "snapshot mutation"
		first["public.rtf"] = nil
		helpers.assert_eq(pasteboard.readAllData(), second)
		helpers.assert_eq(pasteboard.getContents(), "Original text")
	end)

	helpers.it("clears all types with the native void result", function()
		local pasteboard = dofile("tests/stubs/hs.lua").pasteboard
		helpers.assert_eq(pasteboard.writeAllData({ ["public.png"] = "\0image" }), true)
		helpers.assert_nil(pasteboard.getContents(), "an image clipboard has no plain text")
		helpers.assert_eq(table.pack(pasteboard.clearContents()).n, 0,
			"native clearContents returns no values")
		helpers.assert_eq(pasteboard.readAllData(), {})
		helpers.assert_nil(pasteboard.getContents())
	end)

	helpers.it("isolates the next fixture through the canonical reset hook", function()
		local hs_stub = dofile("tests/stubs/hs.lua")
		hs_stub.pasteboard.setContents("previous fixture")
		hs_stub.pasteboard.writeAllData("test.pasteboard", { [TEXT_UTI] = "named fixture" })
		helpers.assert_eq(hs_stub.pasteboard.getContents(), "previous fixture")
		helpers.assert_eq(hs_stub.pasteboard.getContents("test.pasteboard"), "named fixture")
		hs_stub.__reset()
		helpers.assert_nil(hs_stub.pasteboard.getContents())
		helpers.assert_eq(hs_stub.pasteboard.readAllData(), {})
		helpers.assert_nil(hs_stub.pasteboard.getContents("test.pasteboard"))
		helpers.assert_eq(hs_stub.pasteboard.readAllData("test.pasteboard"), {})
	end)
end)
