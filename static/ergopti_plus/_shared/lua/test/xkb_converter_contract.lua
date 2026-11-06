--- _shared/lua/test/xkb_converter_contract.lua

--- ==============================================================================
--- MODULE: Keylayout to XKB Converter Contract
--- DESCRIPTION:
--- Replays the shared conversion vector against `layouts.xkb_converter`: the XKB
--- symbols and XCompose text it writes for a hand-written layout (dead keys, a
--- chained dead key, a multi-character output, XKB hints) must equal the Python
--- converter's, and a layout that cannot be converted is refused with a reason.
--- tools/test/test-keylayout-canonical-parity.cjs compares both converters on
--- every shipped layout; this contract keeps the pure module honest in the Lua
--- suites of both drivers.
--- ==============================================================================

local M = {}

--- Reads a whole file.
local function read_all(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

--- Registers the contract on a driver's test helpers.
--- @param helpers table The driver's test helpers (describe/it/assert_*).
--- @param paths table { vectors, keycodes, data_dir }.
function M.register(helpers, paths)
	local Json = require("json")
	local Keylayout = require("layouts.keylayout")
	local Converter = require("layouts.xkb_converter")

	local function options_of(vector)
		local keycodes = assert(Converter.keycodes(assert(Json.decode(read_all(paths.keycodes))), vector.convention))
		local keysym_table = assert(Json.decode(read_all(paths.data_dir .. "/key_sym.json")))
		return {
			keycodes = keycodes,
			keysyms = keysym_table.keysyms,
			locale_extended_prefixes = keysym_table.locale_extended_prefixes,
			template = read_all(paths.data_dir .. "/xkb_symbols.txt"),
			layout_id = vector.layout_id,
			display_name = vector.display_name,
			hints = vector.hints,
		}
	end

	helpers.describe("keylayout to XKB converter (shared contract)", function()
		helpers.it("writes the files the Python converter writes for every vector", function()
			local corpus = assert(Json.decode(read_all(paths.vectors)))
			helpers.assert_true(#corpus.vectors > 0, "the corpus holds vectors")
			for _, vector in ipairs(corpus.vectors) do
				local canonical = assert(Keylayout.parse(vector.keylayout))
				local result, err = Converter.convert(canonical, options_of(vector))
				helpers.assert_true(result ~= nil, vector.name .. " converts: " .. tostring(err))
				helpers.assert_eq(result.symbols_text, vector.symbols, vector.name .. " symbols")
				helpers.assert_eq(result.compose_text, vector.compose, vector.name .. " compose")
				helpers.assert_eq(#result.unplaced, 0, vector.name .. " places every key")
			end
		end)

		helpers.it("reports the keys the keycode table cannot place, keypad and controls aside", function()
			local vector = assert(Json.decode(read_all(paths.vectors))).vectors[1]
			local extra = '<key code="93" output="&#x00A5;"/><key code="94" action="a"/>'
				.. '<key code="82" output="0"/><key code="95" output="&#x0001;"/>'
			local text = vector.keylayout:gsub('(<keyMap index="0">)', function(open) return open .. extra end, 1)
			local result = assert(Converter.convert(assert(Keylayout.parse(text)), options_of(vector)))
			helpers.assert_eq(table.concat(result.unplaced, ","), "93,94")
		end)

		helpers.it("refuses a layout id the XKB section cannot carry", function()
			local vector = assert(Json.decode(read_all(paths.vectors))).vectors[1]
			local options = options_of(vector)
			options.layout_id = "bad id"
			local result, err = Converter.convert(assert(Keylayout.parse(vector.keylayout)), options)
			helpers.assert_true(result == nil and type(err) == "string", "refused")
		end)

		helpers.it("refuses a key that uses an action the layout does not define", function()
			local vector = assert(Json.decode(read_all(paths.vectors))).vectors[1]
			local text = vector.keylayout:gsub('action="acute"', 'action="missing"', 1)
			local result, err = Converter.convert(assert(Keylayout.parse(text)), options_of(vector))
			helpers.assert_true(result == nil and tostring(err):find("undefined action", 1, true) ~= nil, "refused: " .. tostring(err))
		end)

		-- DKS-001: the table includes the locale's, whose longer sequences make Compose
		-- skip a shorter rule; the dead key starting it must not keep a standard keysym.
		helpers.it("borrows the trigger of a dead key whose sequence the locale extends (dks-001)", function()
			local vector = assert(Json.decode(read_all(paths.vectors))).vectors[1]
			local canonical = assert(Keylayout.parse(vector.keylayout))
			local options = options_of(vector)
			options.locale_extended_prefixes = {}
			local plain = assert(Converter.convert(canonical, options))
			helpers.assert_true(plain.compose_text:find("\n<dead_circumflex> <dead_acute>\t", 1, true) ~= nil,
				"control: without the locale list the standard trigger ends a written sequence")
			options.locale_extended_prefixes = { "dead_circumflex dead_acute" }
			local result = assert(Converter.convert(canonical, options))
			helpers.assert_true(result.compose_text:find("<dead_circumflex> <dead_acute>", 1, true) == nil,
				"no written sequence is one the locale extends")
			helpers.assert_true(result.compose_text:find("<dead_acute>\t", 1, true) ~= nil,
				"the other dead key keeps its standard keysym")
			helpers.assert_true(result.symbols_text:find("dead_circumflex", 1, true) == nil,
				"the shadowed dead key sends its borrowed trigger")
		end)

		helpers.it("refuses a conversion without the locale-extended prefixes", function()
			local vector = assert(Json.decode(read_all(paths.vectors))).vectors[1]
			local options = options_of(vector)
			options.locale_extended_prefixes = nil
			local result, err = Converter.convert(assert(Keylayout.parse(vector.keylayout)), options)
			helpers.assert_true(result == nil and tostring(err):find("locale-extended", 1, true) ~= nil, "refused: " .. tostring(err))
		end)

		helpers.it("refuses an unknown keycode convention", function()
			local keycodes, err = Converter.keycodes(assert(Json.decode(read_all(paths.keycodes))), "dvorak")
			helpers.assert_true(keycodes == nil and type(err) == "string", "refused")
		end)
	end)
end

return M
