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

--- Asserts fn(...) raises an error whose message names needle.
--- @param needle string Text the refusal must contain.
--- @param fn function
local function assert_refused(needle, fn, ...)
	local ok, err = pcall(fn, ...)
	helpers.assert_eq(ok, false, "expected a refusal naming " .. needle)
	helpers.assert_true(tostring(err):find(needle, 1, true) ~= nil, tostring(err))
end

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

	helpers.it("applies the resume layout at a running start and the pause layout at a paused start", function()
		local Running, running = fresh({ enabled = true, on_pause = "xkb:fr", on_resume = "xkb:fr+ergopti" })
		helpers.assert_eq(Running.on_start(false), "pending")
		helpers.assert_eq(table.concat(running, ","), "xkb:fr+ergopti")
		local Paused, paused = fresh({ enabled = true, on_pause = "xkb:fr", on_resume = "xkb:fr+ergopti" })
		helpers.assert_eq(Paused.on_start(true), "pending")
		helpers.assert_eq(table.concat(paused, ","), "xkb:fr")
		local Off, off = fresh({ enabled = false, on_pause = "xkb:fr", on_resume = "xkb:us" })
		helpers.assert_eq(Off.on_start(false), "none")
		helpers.assert_eq(#off, 0, "a switch turned off leaves the start layout")
	end)

	helpers.it("lets a restored pause that already switched decide the start layout", function()
		local Switch, selected = fresh({ enabled = true, on_pause = "xkb:fr", on_resume = "xkb:us" })
		helpers.assert_eq(Switch.on_pause_change(true), "pending")
		helpers.assert_eq(Switch.on_start(true), "superseded")
		helpers.assert_eq(table.concat(selected, ","), "xkb:fr", "the start selects nothing twice")
		assert_refused("must be a boolean", Switch.on_start, "paused")
		helpers.assert_eq(Switch.start_safely("paused"), "failed", "a refused start never stops the daemon")
	end)

	helpers.it("is started by the daemon once the live pause state is restored", function()
		local source = daemon_source()
		local restored = source:find('require("infra.restart_pause").restore(script_actions)', 1, true)
		local started = source:find('require("modules.keymap.pause_layout_switch").start_safely(script_actions.is_paused())', 1, true)
		helpers.assert_true(restored ~= nil and started ~= nil and restored < started,
			"the start switch reads the pause state the restore settled")
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
		assert_refused("native refusal", Switch.on_quit)
		Switch._reset_for_test()
		helpers.assert_eq(Switch.quit_safely(), "failed", "an uninitialised owner never blocks a quit")
	end)

	helpers.it("refuses a second initialisation and use before the first", function()
		package.loaded["modules.keymap.pause_layout_switch"] = nil
		local Switch = require("modules.keymap.pause_layout_switch")
		helpers.assert_eq(Switch.is_initialised(), false)
		assert_refused("is not initialised", Switch.on_pause_change, true)
		assert_refused("needs a switcher and a preferences reader", Switch.init, { switcher = {} })
		local Owned = fresh({ enabled = false })
		assert_refused("already initialised", Owned.init, { switcher = {}, preferences = {} })
		assert_refused("must be a boolean", Owned.on_pause_change, "yes")
		Owned._reset_for_test()
	end)

	helpers.it("is wired to the pause listener, both user quits and the shutdown owners", function()
		local source = daemon_source()
		local listener = source:match("on_pause_change = function%(paused%)(.-)\n\t\tend,\n\t}%)")
		helpers.assert_true(listener ~= nil, "the pause listener is found")
		helpers.assert_true(listener:find('require("modules.keymap.pause_layout_switch").on_pause_change(paused)', 1, true) ~= nil,
			"a pause transition reaches the layout switch")
		-- (pause-drops-dead-key) a dead key pending in the emulation must not
		-- compose with the first key typed after the resume.
		helpers.assert_true(listener:find('if paused then require("modules.keymap.layout_emulation").drop_pending_dead_key() end',
			1, true) ~= nil, "a pause drops the emulation's pending dead key")
		local _, quits = source:gsub('require%("modules%.keymap%.pause_layout_switch"%)%.quit_safely%(%)', "")
		-- The tray row, the shortcut and the gesture Quit share one owner (LCY-003).
		helpers.assert_eq(quits, 1, "the user Quit owner switches first")
		helpers.assert_true(source:find("quit = function(reason) return privacy_owners.user_quit(reason) end", 1, true) ~= nil,
			"the shortcut quit reaches the user Quit owner")
		-- The tray quit runs through infra/quit_request.lua, which applies the pause
		-- layout only once the shared admission accepted the quit.
		helpers.assert_true(source:find("on_quit       = privacy_owners.tray_quit,", 1, true) ~= nil)
		helpers.assert_true(source:find("apply_pause_layout = function() require", 1, true) ~= nil,
			"the tray quit switches the layout")
		-- infra/quit_request, selected by a declaration unique to it.
		local handler = helpers.read_driver_unit('local LOG = "infra.quit_request"')
		helpers.assert_true(handler ~= nil, "the tray quit handler is found")
		local switched = handler:find("pcall(ports.apply_pause_layout)", 1, true)
		local requested = handler:find("ports.shutdown.request(reason)", 1, true)
		helpers.assert_true(switched ~= nil and requested ~= nil and switched < requested,
			"the layout switches before the shutdown starts, and only after the admission")
		local owner = source:match('name = "pause layout switch",(.-)\n\t\t},')
		helpers.assert_true(owner ~= nil, "the shutdown waits for the quit switch")
		helpers.assert_true(owner:find("switch.is_settled()", 1, true) ~= nil)
		helpers.assert_true(owner:find("switch.when_settled(callback)", 1, true) ~= nil)
		-- The shortcut reload stays the bare reload owner: only quits switch.
		local actions = source:match("local script_actions = ScriptActions%.new%(%{(.-)\n\t%}%)")
		helpers.assert_true(actions ~= nil, "the script actions are found")
		helpers.assert_true(actions:find("\n\t\treload = perform_reload,\n", 1, true) ~= nil, "a reload does not switch")
		helpers.assert_true(actions:find("\n\t\tquit = function(reason) return privacy_owners.user_quit(reason) end,\n", 1, true) ~= nil,
			"the shortcut quit switches through the user Quit owner")
	end)
end)

return true
