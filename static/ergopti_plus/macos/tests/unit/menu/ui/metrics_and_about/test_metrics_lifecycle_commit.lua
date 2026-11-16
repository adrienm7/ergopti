--- tests/unit/menu/ui/metrics_and_about/test_metrics_lifecycle_commit.lua

--- ==============================================================================
--- MODULE: Metrics menu lifecycle commitment
--- DESCRIPTION:
--- Drives the real top-level Metrics action with a keystats whose strict start
--- returns false. The click must compensate the already-persisted ON preference,
--- keep WPM producers stopped, and repaint an unchecked menu.
--- ==============================================================================

local helpers = require("tests.helpers")

local function load_menu(start_result)
	local ctx = { saves = 0, updates = 0, menubar_starts = 0, widget_starts = 0, alerts = {}, revocations = 0 }
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	package.loaded["hs.fs"] = hs_stub.fs

	local defaults = {
		keystats_enabled = false, keystats_disabled_apps = {}, keystats_encrypt = false,
		keystats_menubar_wpm = true, keystats_menubar_colors = false,
		keystats_float_wpm = true, keystats_float_graph = false,
		keystats_float_colors = false, keystats_private_filter_enabled = true,
		keystats_secure_filter_enabled = true, keystats_system_auth_filter_enabled = true,
	}
	package.loaded["modules.keystats"] = setmetatable({
		DEFAULT_STATE = defaults,
		start = function() return start_result end,
		set_options = function() return true end,
		revoke_roi_text = function() ctx.revocations = ctx.revocations + 1 end,
		set_disabled_apps = function() end,
	}, { __index = function() return function() end end })
	package.loaded["apps.engine.picker"] = { build_menu = function() return {} end }
	package.loaded["core.ui.engine.dialog_util"] = {
		block_alert = function(_, body) ctx.alerts[#ctx.alerts + 1] = body; return "button.activate" end,
	}
	package.loaded["core.i18n.engine.i18n"] = nil
	local renderer_i18n = require("core.i18n.engine.i18n")
	package.loaded["core.i18n.engine.i18n"] = { get = function(key) return key end }
	-- The switch is the command registered for the manifest's metrics_toggle
	-- row, captured where the menu hands it to the renderer.
	local renderer = assert(require("menu.engine.renderer").new({
		platform = "hs",
		manifest_path = function()
			return helpers.driver_root() .. "../_shared/menu/data/menu_manifest.json"
		end,
		json_decode = require("core.fs.adapters.json_codec").decode,
		i18n = renderer_i18n,
		logger = helpers.make_logger_stub(),
	}))
	local capture = function(_, _, _, _, render_ctx)
			ctx.commands = render_ctx.commands
			ctx.getters = render_ctx.state_getters
			return {}
		end
	renderer.build = capture
	package.loaded["menu.engine.manifest_menu"] = renderer
	package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
	package.loaded["ui.wpm.wpm_menubar"] = {
		start = function() ctx.menubar_starts = ctx.menubar_starts + 1 end,
		stop = function() end, set_use_source_colors = function() end,
	}
	package.loaded["ui.wpm.wpm_widget"] = {
		start = function() ctx.widget_starts = ctx.widget_starts + 1 end,
		stop = function() end, set_use_source_colors = function() end,
	}
	package.loaded["ui.menu.menu_metrics"] = nil
	local MenuMetrics = require("ui.menu.menu_metrics")

	ctx.state = {}
	for key, value in pairs(defaults) do ctx.state[key] = value end
	ctx.item = MenuMetrics.build({
		state = ctx.state,
		save_prefs = function() ctx.saves = ctx.saves + 1; return true end,
		updateMenu = function() ctx.updates = ctx.updates + 1 end,
		script_control = { is_paused = function() return false end },
	})
	helpers.assert_nil(ctx.item.action, "the Metrics parent opens a submenu and must carry no action")
	ctx.toggle = ctx.commands and ctx.commands["metrics_toggle"]
	helpers.assert_type(ctx.toggle, "function")
	return ctx
end

helpers.describe("menu_metrics: strict keystats lifecycle reaches the checkmark", function()
	helpers.it("compensates a rejected activation before reporting Metrics enabled", function()
		local ctx = load_menu(false)
		local result = ctx.toggle()

		helpers.assert_eq(false, result,
			"the click must report that runtime activation did not commit")
		helpers.assert_eq(false, ctx.state.keystats_enabled,
			"the rendered and persisted switch must roll back to disabled")
		helpers.assert_eq(2, ctx.saves,
			"the initial ON publication needs one compensating OFF publication")
		helpers.assert_eq(1, ctx.updates,
			"the menu must repaint the compensating unchecked state")
		helpers.assert_eq(0, ctx.menubar_starts,
			"WPM menubar cannot start when the keystats security watcher failed")
		helpers.assert_eq(0, ctx.widget_starts,
			"WPM widget cannot start when the keystats security watcher failed")
	end)
end)


helpers.describe("menu_metrics: encryption refuses pending ROI work", function()
	local function with_cipher_menu(body)
		helpers.with_stub_scope({ "modules.keystats.text_cipher", "modules.keystats.log_manager",
			"modules.keystats.init", "modules.keystats", "modules.keystats.text_migration" }, function()
			package.loaded["modules.keystats.text_cipher"] = nil
			package.loaded["modules.keystats.log_manager"] = nil
			package.loaded["modules.keystats.init"] = nil
			local ctx = load_menu(false)
			local path = os.tmpname()
			assert(os.remove(path))
			local _, source_status = require("settings.engine.preferences.preferences").load(path)
			helpers.assert_eq(source_status, "absent")
			local cipher = require("modules.keystats.text_cipher")
			helpers.assert_true(cipher.set_enabled(false))
			local ports = { settled = true, available = true, migrations = 0, retirements = 0 }
			cipher.is_available = function() return ports.available end
			package.loaded["modules.keystats.log_manager"] = { retire_roi_text = function()
				ports.retirements = ports.retirements + 1
				return ports.settled
			end }
			package.loaded["modules.keystats.text_migration"] = { start_for_posture = function()
				ports.migrations = ports.migrations + 1
			end }
			body(ctx, cipher, ports)
		end)
	end

	helpers.it("does not publish or tick ON while the earlier textual receipt remains pending", function()
		with_cipher_menu(function(ctx, cipher, ports)
			ports.settled = false
			helpers.assert_eq(ctx.commands.encryption(), false)
			helpers.assert_eq(ctx.state.keystats_encrypt, false)
			helpers.assert_eq(ctx.getters.metrics_encrypt_enabled(), false)
			helpers.assert_eq(ctx.saves, 0)
			helpers.assert_eq(ports.migrations, 0)
			helpers.assert_eq(cipher.roi_text_enabled(), false)
			helpers.assert_eq(ctx.alerts, { "dialog.metrics.encryption_pending_write" })
			helpers.assert_true(ctx.revocations > 0)
			ports.settled = true
			helpers.assert_true(ctx.commands.encryption())
			helpers.assert_true(ctx.getters.metrics_encrypt_enabled())
			helpers.assert_eq(ctx.saves, 1)
			helpers.assert_eq(ports.migrations, 1)
		end)
	end)

	helpers.it("abandons a clean provider refusal under OFF without restoring the retired text", function()
		with_cipher_menu(function(ctx, cipher, ports)
			ports.available = false
			helpers.assert_eq(ctx.commands.encryption(), false)
			helpers.assert_eq(ctx.state.keystats_encrypt, false)
			helpers.assert_eq(ctx.saves, 0)
			helpers.assert_eq(ports.migrations, 0)
			helpers.assert_eq(ctx.alerts, { "dialog.metrics.encryption_unavailable" })
			helpers.assert_true(ctx.revocations > 0)
			helpers.assert_true(cipher.roi_text_enabled(), "fresh OFF capture can resume after a clean refusal")
		end)
	end)

	helpers.it("does not claim an active cipher from an ON preference whose provider stayed off", function()
		with_cipher_menu(function(ctx, cipher)
			ctx.state.keystats_encrypt = true
			helpers.assert_true(cipher.set_enabled(false, true))
			helpers.assert_eq(ctx.getters.metrics_encrypt_enabled(), false)
			helpers.assert_eq(cipher.roi_text_enabled(), false)
		end)
	end)
end)
