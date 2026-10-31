--- tests/unit/modules/keymap/layout/test_keylayout_rows.lua

--- ==============================================================================
--- MODULE: Shared Keylayout Number-Row Options
--- DESCRIPTION:
--- The macOS driver installs a .keylayout that already types the number-row
--- options (layouts/keylayout_rows.lua). tools/test/test-keylayout-row-options.cjs
--- proves the cells against the Linux converter; these cases pin what that
--- differential cannot see: a refusal changes nothing and says why, a versioned
--- build carries its name and id, and the read-back the driver compares with the
--- system sees the moved cells (keylayout-rows).
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Rows = require("layouts.keylayout_rows")

local REGISTRY_DIR = helpers.driver_root() .. "/../../layouts/registry/"

--- Reads a whole file.
--- @param path string
--- @return string
local function read(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

local function codes(convention)
	return assert(Rows.key_codes(Json.decode(read(helpers.shared("modules/layouts/mac_keycodes.json"))), convention))
end

-- A two-keyMap layout whose key 18 (the 1 key) holds its digit only with Shift.
local MINIMAL = [[<?xml version="1.1" encoding="UTF-8"?>
<keyboard group="126" id="-5" name="Minimal" maxout="1">
  <layouts><layout first="0" last="17" modifiers="m" mapSet="s"/></layouts>
  <modifierMap id="m" defaultIndex="0">
    <keyMapSelect mapIndex="0"><modifier keys=""/></keyMapSelect>
    <keyMapSelect mapIndex="1"><modifier keys="anyShift caps?"/></keyMapSelect>
  </modifierMap>
  <keyMapSet id="s">
    <keyMap index="0"><key code="18" output="&amp;"/><key code="19" output="é"/></keyMap>
    <keyMap index="1"><key code="18" output="1"/><key code="19" output="2"/></keyMap>
  </keyMapSet>
</keyboard>
]]

helpers.describe("keylayout rows: applying the number-row options to a .keylayout (keylayout-rows)", function()
	helpers.it("moves Ergo-L's cells and reads them back, Ctrl keeping the layout's digit", function()
		local text = read(REGISTRY_DIR .. "ergol/ergol.keylayout")
		local before = assert(Rows.cells(text, codes("ansi")))
		local result = assert(Rows.apply(text, { order = "symbols", edges = false }, codes("ansi")))
		helpers.assert_eq(result.changed, true)
		helpers.assert_eq(result.report.order, "symbols")
		local after = assert(Rows.cells(result.text, codes("ansi")))
		for index = 1, 10 do
			helpers.assert_eq(after.digits[index].plain.Text, before.digits[index].shift.Text, "key " .. index .. " plain")
			helpers.assert_eq(after.digits[index].shift.Text, before.digits[index].plain.Text, "key " .. index .. " shift")
		end
		-- Ctrl reached the plain keyMap through defaultIndex: it now has its own copy.
		helpers.assert_contains(result.text, '<modifier keys="anyControl"/>')
	end)

	helpers.it("leaves a row whose keys disagree unchanged, with the reason", function()
		local result = assert(Rows.apply(MINIMAL, { order = "symbols", edges = true }, codes("iso")))
		helpers.assert_eq(result.changed, false)
		helpers.assert_eq(result.text, MINIMAL)
		helpers.assert_eq(result.report.reason, "mixed")
	end)

	helpers.it("refuses an inline action on a moved key rather than dropping it", function()
		local text = read(REGISTRY_DIR .. "ergol/ergol.keylayout")
			:gsub('<key code="18"([^/>]*)/>', '<key code="18"%1><action id="inline"/></key>', 1)
		local result, err = Rows.apply(text, { order = "symbols", edges = false }, codes("ansi"))
		helpers.assert_nil(result)
		helpers.assert_contains(tostring(err), "inline action")
	end)

	helpers.it("renames a build with the id derived from its new name", function()
		local renamed = assert(Rows.rename(MINIMAL, "Minimal 2"))
		helpers.assert_contains(renamed, 'name="Minimal 2"')
		helpers.assert_contains(renamed, 'id="' .. Rows.keyboard_id("Minimal 2") .. '"')
		helpers.assert_true(Rows.keyboard_id("Minimal 2") ~= Rows.keyboard_id("Minimal 3"), "two builds share an id")
		local refused = Rows.rename("<keyboard/>", "x")
		helpers.assert_nil(refused)
	end)
end)
