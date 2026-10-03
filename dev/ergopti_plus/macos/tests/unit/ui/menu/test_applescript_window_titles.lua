--- tests/unit/ui/menu/test_applescript_window_titles.lua

--- ==============================================================================
--- MODULE: AppleScript Native Window Caption Policy
--- DESCRIPTION:
--- Runs real choice builders and real numeric-menu callbacks with every shipped
--- translation. Native title literals compose through the shared policy before
--- escaping; prompts, focus, cancellation and persistence remain independent.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local LOCALES = {
	"ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja",
	"ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh",
}
local NUMERIC_DIALOGS = {
	{ row = "menu.tapholds.tap_hold_title", key = "menu.tapholds.tap_hold_dialog_title", default = 200 },
	{ row = "menu.tapholds.sticky_title", key = "menu.tapholds.sticky_dialog_title", default = 1000 },
	{ row = "menu.tapholds.simultaneous_title", key = "menu.tapholds.simultaneous_dialog_title", default = 50 },
	{ row = "menu.tapholds.key_tap_delay_set", key = "menu.tapholds.key_tap_delay_dialog_title", default = 200 },
}
local TITLE_KEYS = { ["llm.unreachable.title"] = true }
for _, spec in ipairs(NUMERIC_DIALOGS) do TITLE_KEYS[spec.key] = true end

--- Reads the independent, already-translated brandless titles.
--- @param code string Locale code.
--- @return table strings
local function locale_strings(code)
	local file = assert(io.open(helpers.shared("data/locales/" .. code .. ".json"), "r"))
	local strings = Json.decode(file:read("*a"))
	file:close()
	return strings
end

--- Finds a real rendered row anywhere in its lazy menu tree.
--- @param rows table Native menu rows.
--- @param title string Exact fixture label.
--- @return table|nil row
local function find_row(rows, title)
	for _, row in ipairs(rows or {}) do
		if row.title == title then return row end
		local children = type(row.menu) == "function" and row.menu() or row.menu
		local found = find_row(children, title)
		if found then return found end
	end
	return nil
end

--- A minimal remap owner whose writes remain observable after canceled dialogs.
--- @param world table Native observations.
--- @return table owner
local function remap_owner(world)
	local function write()
		world.writes = world.writes + 1
		return true
	end
	return {
		DEFAULT_TAP_HOLD_TIMEOUT_MS = 200,
		DEFAULT_STICKY_TIMEOUT_MS = 1000,
		DEFAULT_SIMULTANEOUS_THRESHOLD_MS = 50,
		AVAILABLE_ACTIONS = { { id = "none", label = "None", category = "Special", tappable = true, holdable = true } },
		TAP_HOLD_KEYS = { { id = "return_or_enter", label = "Enter" } },
		MOD_COMBOS = {}, NON_CANONICAL_COMBOS = {},
		get_enabled = function() return true end,
		get_tap_holds_enabled = function() return true end,
		get_mod_combos_enabled = function() return true end,
		get_combo_symmetric = function() return false end,
		get_tap_action = function() return "none" end,
		get_hold_action = function() return "none" end,
		get_tap_timeout = function() return nil end,
		get_tap_hold_timeout = function() return 200 end,
		get_sticky_timeout = function() return 1000 end,
		get_simultaneous_threshold = function() return 50 end,
		set_tap_hold_timeout = write, set_sticky_timeout = write,
		set_simultaneous_threshold = write, set_tap_timeout = write,
	}
end

--- Loads the real owners with a native recorder; assertions run after callbacks.
--- @param strings table Actual locale values.
--- @param composer function|nil Private policy delegate, otherwise the real module.
--- @param callback function Receives (Dialogs, Menu, Context, world).
local function with_world(strings, composer, callback)
	helpers.with_stub_scope({ "infra.dialog_util", "ui.menu.menu_tap_holds", "infra.i18n", "window_titles" }, function()
		if composer then package.loaded["window_titles"] = { compose = composer } end
		local world = { scripts = {}, focuses = 0, writes = 0 }
		local native = {
			focus = function() world.focuses = world.focuses + 1; return true end,
			osascript = { applescript = function(script)
				world.scripts[#world.scripts + 1] = script
				if script:find("default answer", 1, true) then return false, {} end
				return true, "", ""
			end },
		}
		local Menu = helpers.load_with_stubs("ui.menu.menu_tap_holds", native)
		local Dialogs = require("infra.dialog_util")
		local i18n = package.loaded["infra.i18n"]
		i18n.get = function(key)
			if TITLE_KEYS[key] or key == "button.ok" or key == "button.cancel" then return strings[key] end
			return key
		end
		local context = { karabiner = remap_owner(world), updateMenu = function() end }
		callback(Dialogs, Menu, context, world)
	end)
end

--- Invokes all real numeric rows and returns their native script receipts.
--- @param Menu table Real native menu owner.
--- @param context table Its remap context.
--- @param world table Captured native observations.
--- @return table scripts
local function numeric_scripts(Menu, context, world)
	local tap_rows = Menu.build(context).submenu
	local combo_rows = Menu.build_key_combinations(context)
	local scripts = {}
	for _, spec in ipairs(NUMERIC_DIALOGS) do
		local row = find_row(tap_rows, spec.row) or find_row(combo_rows, spec.row)
		helpers.assert_not_nil(row, "the real numeric-dialog row must render: " .. spec.row)
		local before = #world.scripts
		row.fn()
		helpers.assert_eq(#world.scripts, before + 1, "one native dialog per menu activation")
		scripts[#scripts + 1] = world.scripts[#world.scripts]
	end
	return scripts
end

helpers.describe("AppleScript native window titles (shared-window-titles)", function()
	helpers.it("all native choice and numeric captions use every shipped brandless translation", function()
		for _, code in ipairs(LOCALES) do
			local strings = locale_strings(code)
			for key in pairs(TITLE_KEYS) do
				helpers.assert_true(type(strings[key]) == "string" and strings[key] ~= "", code .. ": " .. key)
				helpers.assert_nil(strings[key]:find("Ergopti", 1, true), "locale titles must stay brandless")
			end
			with_world(strings, nil, function(Dialogs, Menu, context, world)
				local title = strings["llm.unreachable.title"]:gsub("{1}", "Ollama")
				for _, choices in ipairs({ { "A", "B" }, { "A", "B", "C" } }) do
					helpers.assert_nil(Dialogs.choose(title, "Preserved prompt", choices, "Cancel", "Apply"))
					local script = world.scripts[#world.scripts]
					helpers.assert_true(script:find('with title "ErgoptiPlus — ' .. title .. '"', 1, true) ~= nil, script)
					helpers.assert_true(script:find('"Preserved prompt"', 1, true) ~= nil, "caption policy preserves the body")
				end
				for index, script in ipairs(numeric_scripts(Menu, context, world)) do
					local spec = NUMERIC_DIALOGS[index]
					helpers.assert_true(script:find('with title "ErgoptiPlus — ' .. strings[spec.key] .. '"', 1, true) ~= nil, script)
					helpers.assert_true(script:find('default answer "' .. spec.default .. '"', 1, true) ~= nil,
						"caption composition preserves the native numeric default")
				end
				helpers.assert_eq(world.writes, 0, "canceling never writes configuration")
				helpers.assert_eq(world.focuses, 8, "two focus requests per choice and one per numeric dialog")
			end)
		end
	end)

	helpers.it("composes through the policy before escaping quoted product captions", function()
		local labels = {}
		local function compose(label)
			labels[#labels + 1] = label
			return 'Other "C:\\Product" / ' .. label
		end
		with_world(locale_strings("en"), compose, function(Dialogs, Menu, context, world)
			for _, choices in ipairs({ { "A" }, { "A", "B", "C" } }) do
				helpers.assert_nil(Dialogs.choose("Backend unavailable", "Body", choices, "Cancel", "Apply"))
				helpers.assert_true(world.scripts[#world.scripts]:find(
				'with title "Other \\"C:\\\\Product\\" / Backend unavailable"', 1, true) ~= nil,
				world.scripts[#world.scripts])
			end
			for index, script in ipairs(numeric_scripts(Menu, context, world)) do
				local bare = locale_strings("en")[NUMERIC_DIALOGS[index].key]
				helpers.assert_true(script:find('with title "Other \\"C:\\\\Product\\" / ' .. bare .. '"', 1, true) ~= nil, script)
			end
			helpers.assert_eq(#labels, 6, "one policy invocation per true native caption")
			helpers.assert_eq(labels[1], "Backend unavailable", "the shared owner receives the bare title")
		end)
	end)

	helpers.it("removing the shared prefix removes it from both choice forms and all numeric dialogs", function()
		with_world(locale_strings("en"), function(label) return label end, function(Dialogs, Menu, context, world)
			for _, choices in ipairs({ { "A" }, { "A", "B", "C" } }) do
				helpers.assert_nil(Dialogs.choose("Backend unavailable", "Body", choices, "Cancel", "Apply"))
				helpers.assert_true(world.scripts[#world.scripts]:find('with title "Backend unavailable"', 1, true) ~= nil)
			end
			for index, script in ipairs(numeric_scripts(Menu, context, world)) do
				local bare = locale_strings("en")[NUMERIC_DIALOGS[index].key]
				helpers.assert_true(script:find('with title "' .. bare .. '"', 1, true) ~= nil, script)
			end
		end)
	end)
end)
