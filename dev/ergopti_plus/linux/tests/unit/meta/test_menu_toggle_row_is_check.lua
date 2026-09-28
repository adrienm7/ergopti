--- tests/unit/meta/test_menu_toggle_row_is_check.lua

--- ==============================================================================
--- MODULE: A Category Toggle Is A Checkbox With One Label
--- DESCRIPTION:
--- Renders every `toggle` row the shared manifest declares for Linux through the
--- shared renderer and requires a check row: `checked` answers the category
--- state, the title is the row's one `i18n` key, and the click is the command
--- the driver registered.
---
--- WHY IT EXISTS: the category switch rendered as a plain row whose text
--- alternated between « ✅ … enabled (click to disable) » and « ❌ … disabled
--- (click to enable) ». Every other on/off row of the tray is a native
--- checkbox, so the one row that governs a whole submenu read as a status line
--- rather than as a control, and each row carried two keys to keep in step in
--- twenty-one locales.
---
--- WHY IT LIVES IN THE LINUX SUITE: the renderer is shared by macOS and Linux,
--- and this suite loads it directly under the LuaJIT CI runs.
--- ==============================================================================

local helpers = require("tests.helpers")

local PLATFORM      = "linux"
local MANIFEST_PATH = "../_shared/modules/menu/menu_manifest.json"

-- The feature menus whose first row must be the category switch on Linux. The
-- Linux tap-holds live under kanata and the layout has no emulation to switch,
-- so neither declares a toggle for this platform.
local EXPECTED_MENUS = { "hotstrings_menu", "llm_menu", "metrics_menu", "shortcuts_menu", "gestures_menu" }

--- Reads the real shared manifest.
--- @return table
local function manifest_root()
	local fh = assert(io.open(MANIFEST_PATH, "r"))
	local root = require("json").decode(fh:read("*a"))
	fh:close()
	return root
end

--- True when the row is visible on Linux.
--- @param row table
--- @return boolean
local function for_linux(row)
	if type(row.platforms) ~= "table" then return true end
	for _, name in ipairs(row.platforms) do
		if name == PLATFORM then return true end
	end
	return false
end

--- Every toggle row visible on Linux, keyed by its menu.
--- @param root table
--- @return table menu_key -> toggle row
local function linux_toggles(root)
	local found = {}
	for key, rows in pairs(root) do
		if type(rows) == "table" and type(rows[1]) == "table" then
			for _, row in ipairs(rows) do
				if type(row) == "table" and row.type == "toggle" and for_linux(row) then found[key] = row end
			end
		end
	end
	return found
end

--- Renders one menu with the toggle's command and every getter answering `state`.
--- @param key string Menu key.
--- @param toggle table The toggle row.
--- @param state boolean What every checked_when getter answers.
--- @return table rendered, function command
local function render(key, toggle, state)
	package.loaded["menu.renderer"] = nil
	local R = require("menu.renderer").new({
		platform      = PLATFORM,
		manifest_path = function() return MANIFEST_PATH end,
		json_decode   = require("json").decode,
		i18n          = { get = function(k) return k end, section = function(k) return k end },
		logger        = helpers.make_logger_stub(),
	})
	local command = function() end
	local answer = setmetatable({}, { __index = function() return function() return state end end })
	local rows = R.build(key, key,
		setmetatable({}, { __index = function() return function() end end }),
		setmetatable({}, { __index = function() return function() return { items = {} } end end }),
		{ commands = { [toggle.command or toggle.id] = command }, state_getters = answer },
		setmetatable({}, { __index = function() return function() return {} end end }))
	return rows, command
end


helpers.describe("menu: a category toggle is a checkbox with one label (linux)", function()

	helpers.it("the real manifest declares the category switch of every Linux feature menu", function()
		local toggles = linux_toggles(manifest_root())
		for _, key in ipairs(EXPECTED_MENUS) do
			helpers.assert_true(toggles[key] ~= nil, key .. " must declare its category toggle for Linux")
		end
	end)

	helpers.it("declares one label key per toggle, not an alternating on/off pair", function()
		local toggles = linux_toggles(manifest_root())
		local count = 0
		for key, toggle in pairs(toggles) do
			count = count + 1
			helpers.assert_eq(type(toggle.i18n), "string", key .. " toggle must name its label with `i18n`")
			helpers.assert_nil(toggle.i18n_on, key .. " toggle must not carry an « enabled (click to disable) » label")
			helpers.assert_nil(toggle.i18n_off, key .. " toggle must not carry a « disabled (click to enable) » label")
		end
		helpers.assert_true(count >= #EXPECTED_MENUS, "the check must see every Linux toggle, saw " .. count)
	end)

	helpers.it("renders each toggle as the first row, ticked from its state and wired to its command", function()
		local toggles = linux_toggles(manifest_root())
		local count = 0
		for key, toggle in pairs(toggles) do
			for _, state in ipairs({ true, false }) do
				local rows, command = render(key, toggle, state)
				local first = rows[1]
				helpers.assert_true(type(first) == "table", key .. " must render its toggle row")
				helpers.assert_eq(first.title, toggle.i18n, key .. " toggle row is titled by its one key")
				helpers.assert_eq(first.checked, state, key .. " toggle row must be a checkbox showing the state")
				helpers.assert_true(first.fn == command, key .. " toggle row must run the registered command")
			end
			count = count + 1
		end
		helpers.assert_true(count >= #EXPECTED_MENUS, "the check must render every Linux toggle, rendered " .. count)
	end)

end)
