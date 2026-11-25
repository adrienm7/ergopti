--- tests/unit/modules/shortcuts/auto_click/test_auto_click_mode.lua

--- ==============================================================================
--- MODULE: Anti-Sleep Mode Tests (macOS)
--- DESCRIPTION:
--- Drives modules/shortcuts/actions/auto_click.lua with a private configuration
--- folder, a stubbed keep-awake session and fake auto-click ports: Ctrl+M runs
--- the active preset's parts and a second Ctrl+M stops both, a preset that does
--- nothing is refused, and the auto-clicker ends with the keep-awake session.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_mode(fn)
	local dir = os.tmpname()
	os.remove(dir)
	local ConfigPaths = require("settings.engine.paths")
	local original_dir = ConfigPaths.get_config_dir
	ConfigPaths.get_config_dir = function() return dir .. "/" end
	local Sys = require("modules.shortcuts.actions.system")
	local saved = { toggle = Sys.toggle_awake, active = Sys.is_awake_active }
	local awake = { on = false, toggles = 0 }
	Sys.toggle_awake = function() awake.on = not awake.on; awake.toggles = awake.toggles + 1; return true end
	Sys.is_awake_active = function() return awake.on end
	package.loaded["modules.shortcuts.actions.auto_click"] = nil
	local Mode = require("modules.shortcuts.actions.auto_click")
	Mode._set_ports({
		foreground = function() return nil end,
		state = function() return {} end,
		scan = function() end,
		click = function() return true end,
		now_ms = function() return 0 end,
		log = function() end,
	})
	local ok, err = pcall(fn, Mode, awake)
	Mode._reset()
	Sys.toggle_awake, Sys.is_awake_active = saved.toggle, saved.active
	ConfigPaths.get_config_dir = original_dir
	os.execute("rm -rf '" .. dir .. "'")
	if not ok then error(err, 0) end
end

helpers.describe("anti-sleep mode (macOS)", function()
	helpers.it("anti-sleep mode: the plain preset toggles keep-awake only", function()
		with_mode(function(Mode, awake)
			helpers.assert_eq(Mode.toggle_mode(), true, "Ctrl+M starts the mode")
			helpers.assert_eq(awake.on, true, "keep-awake runs")
			helpers.assert_eq(Mode.running(), false, "no automatic click with the plain preset")
			helpers.assert_eq(Mode.toggle_mode(), true, "Ctrl+M stops the mode")
			helpers.assert_eq(awake.on, false, "keep-awake stopped")
		end)
	end)

	helpers.it("anti-sleep mode: the VS Code preset clicks too, and stops with Ctrl+M", function()
		with_mode(function(Mode, awake)
			helpers.assert_eq(Mode.edit("set_active", "vscode"), true, "choose VS Code")
			Mode.toggle_mode()
			helpers.assert_eq(awake.on, true, "keep-awake runs")
			helpers.assert_eq(Mode.running(), true, "the auto-clicker runs")
			Mode.toggle_mode()
			helpers.assert_eq(Mode.running(), false, "both stop")
			helpers.assert_eq(awake.on, false, "keep-awake stopped")
		end)
	end)

	helpers.it("anti-sleep mode: a preset that does nothing is refused", function()
		with_mode(function(Mode, awake)
			Mode.edit("set_switch", "simple", "keep_awake", false)
			helpers.assert_eq(Mode.toggle_mode(), false, "refused")
			helpers.assert_eq(awake.toggles, 0, "nothing started")
		end)
	end)
end)
