--- tests/unit/modules/keymap/test_pause_layout_switch.lua

--- ==============================================================================
--- MODULE: Pause Layout Switch Tests
--- DESCRIPTION:
--- A pause, a resume and a user quit switch the desktop layout through the
--- shared policy; the daemon wires the pause listener, both user quit paths
--- and a shutdown owner that waits for the quit switch, and a reload never
--- switches.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A fresh orchestrator over a recording switcher and fixed settings.
--- @param settings table { enabled, on_pause, on_resume }
--- @return table Switch, table selected
local function fresh(settings)
	package.loaded["modules.keymap.pause_layout_switch"] = nil
	local Switch = require("modules.keymap.pause_layout_switch")
	local selected, pending = {}, {}
	local listeners = {}
	Switch.init({
		switcher = {
			select = function(id, on_done) selected[#selected + 1] = id; pending[#pending + 1] = on_done end,
			is_settled = function() return #pending == 0 end,
			when_settled = function(listener) listeners[#listeners + 1] = listener end,
			choices = function() return {} end,
		},
		preferences = { settings = function() return settings end },
	})
	local function answer()
		for _, on_done in ipairs(pending) do on_done(true) end
		pending = {}
		for _, listener in ipairs(listeners) do listener() end
	end
	return Switch, selected, answer
end

local function daemon_source()
	local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
	local source = file:read("*a")
	assert(file:close())
	return source
end

helpers.describe("pause layout switch", function()
	helpers.it("selects the pause layout on a pause and the resume layout on a resume", function()
		local Switch, selected = fresh({ enabled = true, on_pause = "xkb:fr", on_resume = "xkb:fr+ergopti" })
		helpers.assert_eq(Switch.on_pause_change(true), "pending")
		helpers.assert_eq(Switch.on_pause_change(false), "pending")
		helpers.assert_eq(table.concat(selected, ","), "xkb:fr,xkb:fr+ergopti")
	end)

	helpers.it("switches nothing while the switch is off or the event's layout is no change", function()
		local Switch, selected = fresh({ enabled = false, on_pause = "xkb:fr", on_resume = "xkb:us" })
		helpers.assert_eq(Switch.on_pause_change(true), "none")
		helpers.assert_eq(Switch.on_quit(), "none")
		local On, on_selected = fresh({ enabled = true, on_pause = "", on_resume = "xkb:us" })
		helpers.assert_eq(On.on_pause_change(true), "none")
		helpers.assert_eq(On.on_quit(), "none")
		helpers.assert_eq(#selected + #on_selected, 0)
	end)

	helpers.it("selects the pause layout on a quit and reports when it settled", function()
		local Switch, selected, answer = fresh({ enabled = true, on_pause = "xkb:fr", on_resume = "xkb:us" })
		helpers.assert_eq(Switch.on_quit(), "pending")
		helpers.assert_eq(selected[1], "xkb:fr")
		helpers.assert_eq(Switch.is_settled(), false)
		local settled = false
		Switch.when_settled(function() settled = true end)
		answer()
		helpers.assert_true(settled)
		helpers.assert_true(Switch.is_settled())
	end)

	helpers.it("never lets a failed quit switch stop the quit", function()
		package.loaded["modules.keymap.pause_layout_switch"] = nil
		local Switch = require("modules.keymap.pause_layout_switch")
		Switch.init({
			switcher = { select = function() error("native refusal") end, is_settled = function() return true end,
				when_settled = function() end },
			preferences = { settings = function() return { enabled = true, on_pause = "xkb:fr", on_resume = "" } end },
		})
		helpers.assert_eq(Switch.quit_safely(), "failed")
		helpers.assert_eq(pcall(Switch.on_quit), false, "on_quit itself still fails fast")
		Switch._reset_for_test()
		helpers.assert_eq(Switch.quit_safely(), "failed", "an uninitialised owner never blocks a quit")
	end)

	helpers.it("refuses a second initialisation and use before the first", function()
		package.loaded["modules.keymap.pause_layout_switch"] = nil
		local Switch = require("modules.keymap.pause_layout_switch")
		helpers.assert_eq(Switch.is_initialised(), false)
		helpers.assert_eq(pcall(Switch.on_pause_change, true), false, "an uninitialised owner fails fast")
		helpers.assert_eq(pcall(Switch.init, { switcher = {} }), false)
		local Owned = fresh({ enabled = false })
		helpers.assert_eq(pcall(Owned.init, { switcher = {}, preferences = {} }), false, "duplicate init")
		helpers.assert_eq(pcall(Owned.on_pause_change, "yes"), false, "the pause state is a boolean")
		Owned._reset_for_test()
	end)

	helpers.it("is wired to the pause listener, both user quits and the shutdown owners", function()
		local source = daemon_source()
		local listener = source:match("on_pause_change = function%(paused%)(.-)\n\t\tend,\n\t}%)")
		helpers.assert_true(listener ~= nil, "the pause listener is found")
		helpers.assert_true(listener:find('require("modules.keymap.pause_layout_switch").on_pause_change(paused)', 1, true) ~= nil,
			"a pause transition reaches the layout switch")
		local _, quits = source:gsub('require%("modules%.keymap%.pause_layout_switch"%)%.quit_safely%(%)', "")
		helpers.assert_eq(quits, 2, "the shortcut quit and the tray quit switch first")
		helpers.assert_true(source:find('shutdown.request("tray quit")', 1, true) ~= nil)
		local owner = source:match('name = "pause layout switch",(.-)\n\t\t},')
		helpers.assert_true(owner ~= nil, "the shutdown waits for the quit switch")
		helpers.assert_true(owner:find("switch.is_settled()", 1, true) ~= nil)
		helpers.assert_true(owner:find("switch.when_settled(callback)", 1, true) ~= nil)
		-- The shortcut reload stays the bare reload owner: only quits switch.
		local actions = source:match("local script_actions = ScriptActions%.new%(%{(.-)\n\t%}%)")
		helpers.assert_true(actions ~= nil, "the script actions are found")
		helpers.assert_true(actions:find("\n\t\treload = perform_reload,\n", 1, true) ~= nil, "a reload does not switch")
		local quit = actions:match("\n\t\tquit = function%(reason%)(.-)\n\t\tend,")
		helpers.assert_true(quit ~= nil and quit:find(".quit_safely()", 1, true) ~= nil, "the shortcut quit switches")
	end)
end)

return true
