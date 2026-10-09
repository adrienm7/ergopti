--- tests/unit/meta/test_menu_choice_row.lua

--- ==============================================================================
--- MODULE: A Choice Row Is One Row With Its Values Beneath It
--- DESCRIPTION:
--- A `choice` row is one setting with a fixed set of values (an enum feature):
--- the shared renderer draws ONE row titled by its key, and beneath it one row
--- per value, the current value ticked. Choosing a value runs the command the
--- driver registered for the row, with that value.
---
--- WHY IT EXISTS: the macOS menubar icon was two sibling rows, one per variant,
--- each an action of its own and stored outside config.toml — a choice between
--- values drawn as two unrelated buttons. The update channel and frequency rows
--- have the same shape.
---
--- WHY IT LIVES IN THE LINUX SUITE: the renderer is shared by macOS and Linux,
--- and this suite loads it directly under the LuaJIT CI runs.
--- ==============================================================================

local helpers = require("tests.helpers")

local FIXTURE = [[{"probe_menu":[{"type":"choice","id":"probe_choice","path":"ui.probe",
"i18n":"probe.title","choices":[{"value":"v1","i18n":"probe.title.v1"},
{"value":"v2","i18n":"probe.title.v2"}]}]}]]

--- Writes the fixture manifest and returns its path.
--- @return string
local function fixture_path()
	local path = os.tmpname()
	local fh = assert(io.open(path, "w"))
	fh:write(FIXTURE)
	fh:close()
	return path
end

--- Renders the probe menu with the given commands and getters.
--- @param commands table
--- @param getters table
--- @return table rows, table errors
local function render(commands, getters)
	local path = fixture_path()
	local errors = {}
	local logger = helpers.make_logger_stub()
	logger.error = function(_, message, ...) errors[#errors + 1] = string.format(message, ...) end
	package.loaded["menu.renderer"] = nil
	local R = require("menu.renderer").new({
		platform      = "linux",
		manifest_path = function() return path end,
		json_decode   = require("json").decode,
		i18n          = { get = function(k) return k end, section = function(k) return k end },
		logger        = logger,
	})
	local rows = R.build("probe_menu", "Probe", {}, {}, { commands = commands, state_getters = getters }, {})
	os.remove(path)
	return rows, errors
end


helpers.describe("menu: a choice row is one row with its values beneath it", function()

	helpers.it("draws one row whose submenu lists every value, the current one ticked", function()
		local rows = render({ probe_choice = function() end }, { ["ui.probe"] = function() return "v2" end })
		helpers.assert_eq(#rows, 1, "a choice is ONE row, not one row per value")
		helpers.assert_eq(rows[1].title, "probe.title")
		helpers.assert_type(rows[1].menu, "table", "the values hang under the row")
		helpers.assert_eq(#rows[1].menu, 2)
		helpers.assert_eq(rows[1].menu[1].title, "probe.title.v1")
		helpers.assert_eq(rows[1].menu[2].title, "probe.title.v2")
		helpers.assert_eq(rows[1].menu[1].checked, false)
		helpers.assert_eq(rows[1].menu[2].checked, true, "the current value is ticked")
		helpers.assert_nil(rows[1].fn, "the parent opens a submenu and is never clicked")
	end)

	helpers.it("runs the registered command with the value chosen", function()
		local chosen = {}
		local rows = render({ probe_choice = function(value) chosen[#chosen + 1] = value end },
			{ ["ui.probe"] = function() return "v1" end })
		rows[1].menu[2].fn()
		rows[1].menu[1].fn()
		helpers.assert_eq(chosen, { "v2", "v1" })
	end)

	helpers.it("reports a choice whose command no driver registered, and does not draw it", function()
		local rows, errors = render({}, { ["ui.probe"] = function() return "v1" end })
		helpers.assert_eq(#rows, 0)
		helpers.assert_eq(#errors, 1, "the missing command must be an ERROR, not a silent gap")
	end)

	helpers.it("ticks nothing and reports it when the current value has no getter", function()
		local rows, errors = render({ probe_choice = function() end }, {})
		helpers.assert_eq(#rows, 1)
		helpers.assert_eq(rows[1].menu[1].checked, false)
		helpers.assert_eq(rows[1].menu[2].checked, false)
		helpers.assert_eq(#errors, 1, "a missing getter must be an ERROR")
	end)

end)
