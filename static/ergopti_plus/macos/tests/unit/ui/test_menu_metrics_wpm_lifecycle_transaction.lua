--- tests/unit/ui/test_menu_metrics_wpm_lifecycle_transaction.lua

--- ==============================================================================
--- MODULE: Metrics Menu WPM Lifecycle Transaction
--- DESCRIPTION:
--- Drives the real WPM menu callbacks through false, nil, throw, and stop-debt
--- outcomes. The visible/persisted checkmark must never claim ON after a runtime
--- producer refused activation, while an OFF transition remains truthful after
--- callbacks were fenced even when native cleanup still needs a retry.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the real metrics menu over controlled WPM lifecycle modules.
--- @param options table Lifecycle outcomes and initial state overrides.
--- @return table context Captured menu callbacks and state.
local function load_menu(options)
	options = options or {}
	local context = { saves = 0, updates = 0, menubar_starts = 0, widget_starts = 0 }
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	package.loaded["hs.fs"] = hs_stub.fs

	local defaults = {
		keylogger_enabled = options.keylogger_enabled ~= false,
		keylogger_disabled_apps = {}, keylogger_encrypt = false,
		keylogger_menubar_wpm = options.keylogger_menubar_wpm == true,
		keylogger_menubar_colors = false,
		keylogger_float_wpm = options.keylogger_float_wpm == true,
		keylogger_float_graph = false, keylogger_float_colors = false,
		keylogger_private_filter_enabled = true, keylogger_secure_filter_enabled = true,
		keylogger_system_auth_filter_enabled = true,
	}
	local keylogger_module = setmetatable({
		DEFAULT_STATE = defaults,
		start = function() return true end,
		stop = function() return true end,
	}, { __index = function() return function() return true end end })
	if options.keylogger_module ~= nil then
		keylogger_module = options.keylogger_module
		keylogger_module.DEFAULT_STATE = keylogger_module.DEFAULT_STATE or defaults
	end
	package.loaded["modules.keylogger"] = keylogger_module
	package.loaded["infra.app_picker"] = { build_menu = function() return {} end }
	package.loaded["infra.dialog_util"] = {
		block_alert = function() return "button.activate" end,
	}
	package.loaded["infra.i18n"] = nil
	local renderer_i18n = require("infra.i18n")
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	local renderer = assert(require("menu.renderer").new({
		platform = "hs",
		manifest_path = function()
			return helpers.driver_root() .. "../_shared/modules/menu/menu_manifest.json"
		end,
		json_decode = require("adapters.json_codec").decode,
		i18n = renderer_i18n,
		logger = helpers.make_logger_stub(),
	}))
	local capture = function(_id, _label, _dynamic_handlers, _unused, render_context)
			context.commands = render_context.commands
			return {}
		end
	renderer.build = capture
	context.parent_getters, context.parent_projections = 0, 0
	local original_group = renderer.group_row
	renderer.group_row = function(key, id, rows, getters)
		context.parent_projections = context.parent_projections + 1
		return original_group(key, id, rows, { keylogger_enabled = function()
			context.parent_getters = context.parent_getters + 1
			return getters.keylogger_enabled()
		end })
	end
	if options.mutate_source then options.mutate_source(renderer.get_root()) end
	if options.source_throw then renderer.get_root = function() error("actual source read refused") end end
	package.loaded["infra.manifest_menu"] = renderer
	package.loaded["infra.logger"] = helpers.make_logger_stub()

	local menubar_start = options.menubar_start or function() return true end
	local menubar_stop = options.menubar_stop or function() return true end
	local widget_start = options.widget_start or function() return true end
	local widget_stop = options.widget_stop or function() return true end
	package.loaded["ui.wpm.wpm_menubar"] = {
		start = function()
			context.menubar_starts = context.menubar_starts + 1
			return menubar_start()
		end,
		stop = function()
			context.menubar_stops = (context.menubar_stops or 0) + 1
			return menubar_stop()
		end,
		set_use_source_colors = function() end,
	}
	package.loaded["ui.wpm.wpm_widget"] = {
		start = function(graph)
			context.widget_starts = context.widget_starts + 1
			return widget_start(graph)
		end,
		stop = function()
			context.widget_stops = (context.widget_stops or 0) + 1
			return widget_stop()
		end,
		set_use_source_colors = function() end,
	}

	if options.native_menubar then package.loaded["ui.wpm.wpm_menubar"] = options.native_menubar end

	context.state = {}
	for key, value in pairs(defaults) do context.state[key] = value end
	package.loaded["ui.menu.menu_metrics"] = nil
	local MenuMetrics = require("ui.menu.menu_metrics")
	context.menu = MenuMetrics.build({
		state = context.state,
		save_prefs = function()
			context.saves = context.saves + 1
			return true
		end,
		updateMenu = function() context.updates = context.updates + 1 end,
		script_control = { is_paused = function() return options.paused == true end },
	})
	return context
end

helpers.describe("menu_metrics WPM lifecycle reaches persisted checkmarks", function()
	helpers.it("compensates false, nil, and thrown menubar activation", function()
		for _, case in ipairs({
			{ label = "false", start = function() return false end },
			{ label = "nil", start = function() return nil end },
			{ label = "throw", start = function() error("native start exploded") end },
		}) do
			local context = load_menu({ menubar_start = case.start })
			local ok, committed = pcall(context.commands.wpm_menubar)
			helpers.assert_true(ok, case.label .. " activation refusal must not escape the menu callback")
			helpers.assert_eq(committed, false)
			helpers.assert_eq(context.state.keylogger_menubar_wpm, false,
				case.label .. " activation refusal must repaint an unchecked row")
			helpers.assert_eq(context.saves, 2,
				case.label .. " activation refusal must persist the compensating OFF state")
			helpers.assert_eq(context.updates, 1)
		end
	end)

	helpers.it("compensates a rejected floating-widget activation", function()
		local context = load_menu({ widget_start = function() return false end })
		local committed = context.commands.wpm_widget()

		helpers.assert_eq(committed, false)
		helpers.assert_eq(context.state.keylogger_float_wpm, false)
		helpers.assert_eq(context.saves, 2)
		helpers.assert_eq(context.updates, 1)
	end)

	helpers.it("compensates a saved ON state during menu-build reconciliation", function()
		local context = load_menu({
			keylogger_menubar_wpm = true,
			menubar_start = function() return nil end,
		})

		helpers.assert_eq(context.state.keylogger_menubar_wpm, false,
			"a boot/menu rebuild must not render ON after its recurring producer refused")
		helpers.assert_eq(context.saves, 1,
			"build reconciliation must persist the compensating OFF preference")
	end)

	helpers.it("keeps OFF while reporting retained native stop debt", function()
		local stop_result = true
		local context = load_menu({ menubar_stop = function() return stop_result end })
		helpers.assert_eq(context.commands.wpm_menubar(), true)
		helpers.assert_eq(context.state.keylogger_menubar_wpm, true)
		stop_result = false

		local committed = context.commands.wpm_menubar()
		helpers.assert_eq(committed, false)
		helpers.assert_eq(context.state.keylogger_menubar_wpm, false,
			"the module fences callbacks before native stop, so OFF remains the truthful row")
		helpers.assert_eq(context.saves, 2)
	end)

	helpers.it("restores ON when the keylogger stop capability is unavailable", function()
		local context = load_menu({
			keylogger_module = { start = function() return true end },
		})
		helpers.assert_nil(context.menu.action, "the Metrics parent must carry no action")
		local committed = context.commands["metrics_toggle"]()

		helpers.assert_eq(committed, false)
		helpers.assert_eq(context.state.keylogger_enabled, true,
			"OFF must not be published while no runtime stop boundary exists")
		helpers.assert_eq(context.saves, 0,
			"the missing stop capability must be rejected before disk publication")
		helpers.assert_eq(context.updates, 1,
			"the menu must repaint the runtime-truthful state")
		helpers.assert_eq(context.menubar_stops or 0, 1,
			"menu-build reconciliation may stop a hidden WPM row once")
	end)
end)


helpers.describe("Metrics parent refusal preserves existing WPM lifecycle reconciliation", function()
	helpers.it("missing source still stops both paused producers without a parent getter", function()
		local context = load_menu({ paused=true, keylogger_menubar_wpm=true, keylogger_float_wpm=true,
			mutate_source=function(root)root.metrics_menu=nil end })
		helpers.assert_nil(context.menu)
		helpers.assert_eq(context.menubar_starts,0);helpers.assert_eq(context.widget_starts,0)
		helpers.assert_eq(context.menubar_stops,1);helpers.assert_eq(context.widget_stops,1)
		helpers.assert_eq(context.state.keylogger_menubar_wpm,true)
		helpers.assert_eq(context.state.keylogger_float_wpm,true)
		helpers.assert_eq(context.saves,0)
		helpers.assert_eq(context.parent_getters,0);helpers.assert_eq(context.parent_projections,0)
	end)
	helpers.it("source capture refusal still performs the existing paused cleanup", function()
		local context = load_menu({source_throw=true,paused=true,keylogger_menubar_wpm=true,keylogger_float_wpm=true})
		helpers.assert_nil(context.menu)
		helpers.assert_eq(context.menubar_starts,0);helpers.assert_eq(context.widget_starts,0)
		helpers.assert_eq(context.menubar_stops,1);helpers.assert_eq(context.widget_stops,1)
		helpers.assert_eq(context.saves,0)
		helpers.assert_eq(context.parent_getters,0);helpers.assert_eq(context.parent_projections,0)
	end)

	helpers.it("malformed source retains exact failed-start compensation before parent refusal", function()
		local context = load_menu({keylogger_menubar_wpm=true,menubar_start=function()return false end,
			mutate_source=function(root)root.metrics_menu=false end})
		helpers.assert_nil(context.menu)
		helpers.assert_eq(context.menubar_starts,1);helpers.assert_eq(context.widget_starts,0)
		helpers.assert_eq(context.widget_stops,1)
		helpers.assert_eq(context.state.keylogger_menubar_wpm,false)
		helpers.assert_eq(context.saves,1)
		helpers.assert_eq(context.parent_getters,0);helpers.assert_eq(context.parent_projections,0)
	end)
	helpers.it("parent refusal retains then cancels the genuine WPM owner's exact timer", function()
		require("tests.support.wpm_menubar_fixture")(function(native, observed)
			helpers.assert_eq(native.start(),true)
			local token = observed.timers[1]
			local active = load_menu({native_menubar=native,keylogger_menubar_wpm=true,
				mutate_source=function(root)root.metrics_menu=nil end})
			helpers.assert_nil(active.menu)
			helpers.assert_eq(#observed.timers,1,"reconciliation must retain the existing native timer")
			helpers.assert_true(rawequal(observed.timers[1],token))
			helpers.assert_true(token.timer ~= nil)
			local paused = load_menu({native_menubar=native,keylogger_menubar_wpm=true,paused=true,
				mutate_source=function(root)root.metrics_menu=nil end})
			helpers.assert_nil(paused.menu)
			helpers.assert_true(rawequal(observed.timers[1],token))
			helpers.assert_nil(token.timer,"existing pause cleanup must cancel the exact retained token")
			helpers.assert_eq(#observed.timers,1)
			helpers.assert_eq(paused.parent_getters,0);helpers.assert_eq(paused.parent_projections,0)
		end)
	end)
end)
