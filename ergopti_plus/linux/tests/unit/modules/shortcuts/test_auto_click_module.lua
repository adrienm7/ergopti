--- tests/unit/modules/shortcuts/test_auto_click_module.lua

--- ==============================================================================
--- MODULE: Anti-Sleep Auto-Clicker Module Tests (Linux)
--- DESCRIPTION:
--- Drives modules/auto_click.lua with a private configuration folder and fake
--- session ports: a preset edit is written and survives a reload of the
--- document, a refused edit writes nothing, the menu rows follow the active
--- preset, and a session clicks through the ports and stops with Ctrl+M.
--- ==============================================================================

local helpers = require("tests.helpers")

local ConfigPaths = require("settings.engine.paths")

local function with_config_dir(fn)
	local dir = os.tmpname()
	os.remove(dir)
	os.execute("mkdir -p " .. dir)
	local original = ConfigPaths.get_config_dir
	ConfigPaths.get_config_dir = function() return dir end
	local AutoClick = require("modules.auto_click")
	AutoClick._reset()
	local ok, err = pcall(fn, AutoClick, dir)
	AutoClick._reset()
	ConfigPaths.get_config_dir = original
	os.execute("rm -rf " .. dir)
	if not ok then error(err, 0) end
end

helpers.describe("anti-sleep auto-clicker module (Linux)", function()
	helpers.it("auto-click module: a preset edit survives a reload of the document", function()
		with_config_dir(function(AutoClick, dir)
			helpers.assert_eq(AutoClick.document().active, "simple", "plain keep-awake first")
			helpers.assert_eq(AutoClick.edit("set_active", "vscode"), true, "choose VS Code")
			local file = io.open(dir .. "/auto_click/presets.json", "rb")
			helpers.assert_not_nil(file, "the document is written")
			file:close()
			local ok, reason = AutoClick.edit("set_active", "nope")
			helpers.assert_eq(ok, false, "an unknown preset is refused")
			helpers.assert_eq(reason, "preset_unknown", "its reason")
			AutoClick._reset()
			helpers.assert_eq(AutoClick.document().active, "vscode", "the choice was kept")
			helpers.assert_eq(AutoClick.active_plan().auto_click, true, "the VS Code preset clicks")
		end)
	end)

	helpers.it("auto-click module: the menu rows follow the active preset", function()
		with_config_dir(function(AutoClick)
			local rows = AutoClick.preset_rows()
			helpers.assert_eq(#rows, 3, "three starter presets")
			helpers.assert_eq(rows[1].checked, true, "the active one is ticked")
			helpers.assert_eq(rows[2].radio, true, "a single-choice group")
			rows[2].action()
			helpers.assert_eq(AutoClick.document().active, "vscode", "a click chooses the preset")
		end)
	end)

	helpers.it("auto-click module: the manifest's switch rows read and flip the active preset", function()
		with_config_dir(function(AutoClick)
			AutoClick.edit("set_active", "vscode")
			local before = AutoClick.switch_on("auto_click")
			helpers.assert_eq(AutoClick.toggle_switch("auto_click"), true, "the flip is saved")
			helpers.assert_eq(AutoClick.switch_on("auto_click"), not before, "the switch row reads the new state")
			local rows = AutoClick.status_rows()
			helpers.assert_true(rows[1].disabled == true and rows[1].label:find("0", 1, true) ~= nil,
				"the status list starts with the click counter")
		end)
	end)

	helpers.it("auto-click module: a session clicks through its ports and stops", function()
		with_config_dir(function(AutoClick)
			AutoClick.edit("set_active", "vscode")
			local clicked, scans = {}, 0
			AutoClick._set_ports({
				foreground = function() return { window = 7, app_id = "code" } end,
				state = function() return { locked = false, paused = false, secure_field = false } end,
				scan = function(_, _, callback)
					scans = scans + 1
					callback({ image = { width = 100, height = 50, scale = 1, frame = { x = 10, y = 20 } },
						hits = {}, text_hits = { { id = "copilot_allow_once", x = 40, y = 10, width = 20, height = 10 } } })
				end,
				click = function(x, y) clicked[#clicked + 1] = x .. "," .. y; return true end,
				now_ms = function() return 1000 end,
				log = function() end,
			})
			helpers.assert_eq(AutoClick.start(AutoClick.active_plan()), true, "the session starts")
			helpers.assert_eq(AutoClick.running(), true, "it runs")
			AutoClick.stop()
			helpers.assert_eq(AutoClick.running(), false, "it stops")
			helpers.assert_eq(scans, 0, "no tick ran before the timer")
		end)
	end)
end)
