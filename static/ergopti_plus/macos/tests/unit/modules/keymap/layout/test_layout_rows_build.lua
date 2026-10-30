--- tests/unit/modules/keymap/layout/test_layout_rows_build.lua

--- ==============================================================================
--- MODULE: Layout Rows Build (macOS live replace)
--- DESCRIPTION:
--- Replays the live replacement of docs/design/layout-option-emulation.md,
--- section 3.1, against in-memory collaborators: each build is a new loose
--- layout, accepted only once a fresh process sees it selected and the keyboard
--- probe types its cells, after which the previous build is retired; a build
--- that fails is undone and the previous layout types again (layout-rows-build).
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Build = require("modules.keymap.layout_rows_build")
local Rows = require("layouts.keylayout_rows")

local REGISTRY_DIR = helpers.driver_root() .. "/../../layouts/registry/"

local function read(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

local KEYCODES = Json.decode(read(helpers.shared("modules/layouts/mac_keycodes.json")))
local ERGOL = read(REGISTRY_DIR .. "ergol/ergol.keylayout")
local SOURCE = { id = "ergol", keyboard_name = "Ergo-L", text = ERGOL, convention = "ansi" }

local fake_mac = require("tests.support.layout_rows_fake_mac").new

helpers.describe("layout rows build: a live replace with no logout (layout-rows-build)", function()
	helpers.it("installs, selects and reads back a build, then retires the previous one", function()
		Build._reset()
		local mac, deps = fake_mac()
		local first
		Build.replace(SOURCE, { order = "symbols", edges = false }, function(ok, result) first = { ok, result } end, deps)
		helpers.assert_eq(first[1], true, tostring(first[2]))
		helpers.assert_eq(first[2].build.name, "Ergo-L 1")
		helpers.assert_eq(mac.selected, "Ergo-L 1")
		helpers.assert_true(mac.files["/L/ErgoptiRows-1.keylayout"] ~= nil, "the build file is missing")
		local second
		Build.replace(SOURCE, { order = "symbols", edges = true }, function(ok, result) second = { ok, result } end, deps)
		helpers.assert_eq(second[1], true, tostring(second[2]))
		helpers.assert_eq(second[2].build.name, "Ergo-L 2")
		helpers.assert_eq(mac.selected, "Ergo-L 2")
		helpers.assert_nil(mac.files["/L/ErgoptiRows-1.keylayout"], "the previous build was not deleted")
		helpers.assert_nil(mac.enabled["Ergo-L 1"], "the previous build is still enabled")
		-- The previous build is retired only after the new one was selected.
		local selected_at, disabled_at
		for index, call in ipairs(mac.calls) do
			if call == "select Ergo-L 2" then selected_at = index end
			if call == "disable Ergo-L 1" then disabled_at = index end
		end
		helpers.assert_true(selected_at ~= nil and disabled_at ~= nil and selected_at < disabled_at,
			"the previous build was retired before the new one typed")
	end)

	helpers.it("undoes a build the probe does not see typing its cells", function()
		Build._reset()
		local mac, deps = fake_mac({ stale_cells = true })
		local answer
		Build.replace(SOURCE, { order = "symbols", edges = false }, function(...) answer = { ... } end, deps)
		helpers.assert_eq(answer[1], false)
		helpers.assert_eq(answer[2], Build.FAILURE_READBACK)
		helpers.assert_eq(mac.selected, "Ergo-L", "the source layout does not type again")
		helpers.assert_nil(mac.files["/L/ErgoptiRows-1.keylayout"], "the failed build was left on disk")
		helpers.assert_nil(mac.enabled["Ergo-L 1"], "the failed build is still enabled")
	end)

	helpers.it("goes back to the source layout when the choice moves no cell", function()
		Build._reset()
		local mac, deps = fake_mac()
		Build.replace(SOURCE, { order = "symbols", edges = false }, function() end, deps)
		local answer
		Build.replace(SOURCE, { order = "digits", edges = false }, function(...) answer = { ... } end, deps)
		helpers.assert_eq(answer[1], true)
		helpers.assert_nil(answer[2].build)
		helpers.assert_eq(answer[2].report.reason, "already_digits_first")
		helpers.assert_eq(mac.selected, "Ergo-L")
		helpers.assert_nil(mac.files["/L/ErgoptiRows-1.keylayout"])
	end)

	helpers.it("refuses a build while two retirements are outstanding", function()
		Build._reset()
		local mac, deps = fake_mac({ undeletable = true })
		local answers = {}
		for _ = 1, 4 do
			Build.replace(SOURCE, { order = "symbols", edges = false }, function(...) answers[#answers + 1] = { ... } end, deps)
		end
		helpers.assert_eq(answers[1][1], true)
		helpers.assert_eq(answers[2][1], true)
		-- Builds 1 and 2 could not be deleted: the fourth build is refused.
		helpers.assert_eq(answers[3][1], true)
		helpers.assert_eq(answers[4][1], false)
		helpers.assert_eq(answers[4][2], Build.FAILURE_STALE)
		helpers.assert_eq(mac.selected, "Ergo-L 3")
	end)

	helpers.it("compares the read-back with the build's base cells", function()
		local codes = assert(Rows.key_codes(KEYCODES, "ansi"))
		local cells = assert(Rows.cells(ERGOL, codes))
		local levels = {}
		local list = {}
		for _, cell in ipairs(cells.digits) do list[#list + 1] = cell.plain end
		for _, cell in ipairs(cells.edges) do list[#list + 1] = cell.plain end
		for index, cell in ipairs(list) do
			levels[index] = { code = index, text = cell and cell.Kind == "text" and cell.Text or "", dead = cell ~= nil and cell.Kind == "dead" }
		end
		helpers.assert_true(Build.compare_readback(cells, { levels = levels }))
		levels[3].text = "?"
		local matches, detail = Build.compare_readback(cells, { levels = levels })
		helpers.assert_eq(matches, false)
		helpers.assert_contains(detail, "key 3")
	end)
end)
