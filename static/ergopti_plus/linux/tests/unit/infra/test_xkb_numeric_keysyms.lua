--- tests/unit/infra/test_xkb_numeric_keysyms.lua

--- ==============================================================================
--- MODULE: Keymaps Serialized By libxkbcommon 1.13
--- DESCRIPTION:
--- libxkbcommon 1.13 (Ubuntu 26.04) serializes a keymap with numeric keysyms
--- (`[ 0x61, 0x41 ]`) and bare group indexes (`name[1]=`), the form a
--- compositor sends. The layout readers compare keysym names, and the source
--- probe blanks group names, so both forms must read as the named ones did
--- (Linux E2E input-display, run 43457007087).
--- ==============================================================================

local helpers = require("tests.helpers")

local NAMES = { [0x61] = "a", [0x41] = "A", [0xfe51] = "dead_acute", [0x10020ac] = "U20AC" }

--- Loads the parser over a libxkbcommon stand-in that names the keysyms above.
--- @param bound boolean Whether libxkbcommon is present.
--- @return table parser
local function parser(bound)
	package.loaded["infra.xkb_keymap"] = nil
	local Keysym = require("infra.keysym")
	Keysym._set_xkb_for_test(bound and {
		from_name = function() return nil end,
		to_utf8 = function() return nil end,
		name = function(sym) return NAMES[sym] end,
	} or false)
	return require("infra.xkb_keymap")
end

local DUMP = table.concat({
	'xkb_keymap {',
	'xkb_symbols "pc_us" {',
	'\tname[1]="English (US)";',
	'\tkey <AC01> {',
	'\t\ttype= "ALPHABETIC",',
	'\t\tsymbols[1]= [ 0x61, 0x41 ]',
	'\t};',
	'\tkey <AC11> {\t[ 0xfe51, 0x10020ac, 0x0 ] };',
	'};',
	'};',
}, "\n")

helpers.describe("xkb keymap: libxkbcommon 1.13 serialization", function()
	helpers.it("reads numeric keysyms by their canonical names", function()
		local symbols = parser(true).parse_symbols(DUMP)
		helpers.assert_eq(symbols.AC01[1], "a")
		helpers.assert_eq(symbols.AC01[2], "A")
		helpers.assert_eq(symbols.AC11[1], "dead_acute")
		helpers.assert_eq(symbols.AC11[2], "U20AC")
		helpers.assert_true(symbols.AC11[3] == false, "keysym 0 is NoSymbol")
	end)

	helpers.it("keeps a numeric keysym it cannot name instead of guessing", function()
		local symbols = parser(false).parse_symbols(DUMP)
		helpers.assert_eq(symbols.AC01[1], "0x61")
		helpers.assert_true(symbols.AC11[3] == false, "keysym 0 is NoSymbol without libxkbcommon too")
	end)

	helpers.it("blanks a bare-index group name as it blanks name[Group1]", function()
		local Probe = helpers.load_module("adapters.xkb_source_probe")
		local text = 'xkb_keycodes "k" {\n\t<AC01> = 38;\n};\nxkb_symbols "s" {\n\tname[1]="Français — bépo";\n'
			.. '\tname[Group2]="Other";\n\tkey <AC01> { type= "X", [ a ] };\n};\n'
		local ordered = Probe._ordered_aliases(text)
		helpers.assert_true(ordered:find('name[1]="";', 1, true) ~= nil, ordered)
		helpers.assert_true(ordered:find('name[Group2]="";', 1, true) ~= nil, ordered)
	end)
end)

require("infra.keysym")._set_xkb_for_test(nil)
package.loaded["infra.xkb_keymap"] = nil
