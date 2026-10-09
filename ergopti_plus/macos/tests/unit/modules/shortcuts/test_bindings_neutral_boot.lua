--- tests/unit/modules/shortcuts/test_bindings_neutral_boot.lua

local helpers = require("tests.helpers")
local Fixture = require("tests.support.shortcut_bindings_fixture")

helpers.describe("neutral shortcut registration", function()
	helpers.it("enabling an empty master does not import fixed child preferences or native registrations", function()
		Fixture.with_bindings(function(bindings, ctx)
			local count = 0
			for id, entry in pairs(Fixture.index(bindings)) do
				count = count + 1
				helpers.assert_eq(entry.enabled, false, id .. " must require explicit desired intent")
			end
			helpers.assert_true(count > 10, "exercise the real registry")
			helpers.assert_eq(bindings.start(), true)
			helpers.assert_eq(ctx.created, 0, "no implicit child may acquire a native owner")
			helpers.assert_eq(Fixture.live_count(ctx), 0)
			helpers.assert_eq(bindings.enable("ctrl_a"), true)
			helpers.assert_eq(ctx.created, 1, "an explicit child still acquires its real native port")
			helpers.assert_eq(Fixture.live_count(ctx), 1)
			helpers.assert_eq(bindings.pause(), true)
			helpers.assert_eq(bindings.is_enabled("ctrl_a"), true, "pause must preserve desired intent")
			helpers.assert_eq(Fixture.live_count(ctx), 0)
		end)
	end)
end)

helpers.describe("tap-key dispatcher ownership", function()
	helpers.it("reconciles explicit assignments without acquiring behind pause or a stopped master", function()
		Fixture.with_bindings(function(bindings, ctx)
			local tap_keys = require("modules.shortcuts.tap_keys")
			tap_keys.set_action("number_row_left", "screen_capture")
			helpers.assert_eq(bindings.reconcile_tap_keys(), true)
			helpers.assert_eq(ctx.created, 0, "an edit behind the stopped master owns no input")
			helpers.assert_eq(bindings.start(), true)
			helpers.assert_eq(Fixture.live_count(ctx), 1)
			helpers.assert_eq(bindings.reconcile_tap_keys(), true)
			helpers.assert_eq(ctx.created, 1, "reconciliation retains the same native owner")
			helpers.assert_eq(bindings.pause(), true)
			tap_keys.set_action("number_row_left", "send_text")
			helpers.assert_eq(bindings.reconcile_tap_keys(), true)
			helpers.assert_eq(Fixture.live_count(ctx), 0)
			helpers.assert_eq(bindings.resume_after_pause(), true)
			helpers.assert_eq(Fixture.live_count(ctx), 1)
			tap_keys.set_action("number_row_left", "none")
			helpers.assert_eq(bindings.reconcile_tap_keys(), true)
			helpers.assert_eq(Fixture.live_count(ctx), 0, "clearing the last assignment releases its owner")
			helpers.assert_eq(bindings.enable("tap_keys"), true)
			helpers.assert_eq(Fixture.live_count(ctx), 0, "the dispatcher is not itself a preset")
		end)
	end)

	helpers.it("the real picker reconciles an assignment and its removal after persistence", function()
		Fixture.with_bindings(function(bindings, ctx)
			helpers.with_stub_scope({ "ui.menu.menu_tap_keys", "ui.action_picker", "infra.deferred_work",
				"adapters.input_source_broker", "ui.menu.shortcut_utils", "ui.menu.menu_keyboard_slots" }, function()
				local picked, updates
				updates = 0
				package.loaded["ui.action_picker"] = { open = function(_, callback) picked = callback end }
				package.loaded["infra.deferred_work"] = { after = function(_, fn) fn() end }
				package.loaded["adapters.input_source_broker"] = { subscribe = function() return true end }
				package.loaded["ui.menu.shortcut_utils"] = { picker_parameter_fields = function() return {} end }
				package.loaded["ui.menu.menu_keyboard_slots"] = { build_action_items = function() return {} end }
				package.loaded["ui.menu.menu_tap_keys"] = nil
				local menu = require("ui.menu.menu_tap_keys")
				local menu_ctx = { gestures = {
					is_assignable = function() return true end,
					get_action_label = function(id) return id end,
					get_action_parameter_spec = function() return nil end,
				}, updateMenu = function() updates = updates + 1 end }
				helpers.assert_eq(bindings.start(), true)
				menu.provide_rows(menu_ctx)[1].action()
				helpers.assert_eq(picked("screen_capture"), true)
				helpers.assert_eq(Fixture.live_count(ctx), 1)
				ctx.refuse_persist = true
				helpers.assert_eq(picked("none"), false)
				helpers.assert_eq(Fixture.live_count(ctx), 1, "failed persistence cannot release the owner")
				ctx.refuse_persist = false
				helpers.assert_eq(picked("none"), true)
				helpers.assert_eq(Fixture.live_count(ctx), 0)
				helpers.assert_eq(updates, 2)
			end)
		end)
	end)
end)

helpers.describe("layer wheel ownership (layer-wheel-slots)", function()
	local VOLUME_UP = { code = "WheelUp", strokes = { { system = "SOUND_UP" } } }
	local MUTE = { code = "WheelUp", strokes = { { system = "MUTE" } } }

	helpers.it("holds a scroll tap only while layers.toml binds a wheel direction", function()
		Fixture.with_bindings(function(bindings, ctx)
			helpers.assert_eq(bindings.start(), true)
			helpers.assert_eq(bindings.is_bound("layer_wheel"), false, "a layer without a wheel binding owns no input")
			ctx.wheel.vertical[1] = VOLUME_UP
			helpers.assert_eq(bindings.reconcile_layer_wheel(), true)
			helpers.assert_eq(bindings.is_bound("layer_wheel"), true, "a saved wheel binding binds its owner")
			local slot = ctx.factory_args.layer_wheel[2]
			helpers.assert_eq(slot("vertical", 1), VOLUME_UP)
			helpers.assert_nil(slot("vertical", -1), "an unbound direction scrolls")

			ctx.wheel = { vertical = { [1] = MUTE }, horizontal = {} }
			helpers.assert_eq(bindings.reconcile_layer_wheel(), true)
			helpers.assert_eq(ctx.created, 1, "an edited binding keeps the same native owner")
			helpers.assert_eq(slot("vertical", 1), MUTE, "the bound owner runs the edited binding")

			ctx.wheel = { vertical = {}, horizontal = {} }
			helpers.assert_eq(bindings.reconcile_layer_wheel(), true)
			helpers.assert_eq(bindings.is_bound("layer_wheel"), false, "removing the last wheel binding releases the owner")
			helpers.assert_eq(bindings.enable("layer_wheel"), true)
			helpers.assert_eq(bindings.is_bound("layer_wheel"), false, "the wheel owner is no preference to switch on")
		end)
	end)

	helpers.it("derives the owner at start and retains an edit made behind pause", function()
		Fixture.with_bindings(function(bindings, ctx)
			ctx.wheel.vertical[1] = VOLUME_UP
			helpers.assert_eq(bindings.start(), true)
			helpers.assert_eq(bindings.is_bound("layer_wheel"), true, "the start reads layers.toml")
			helpers.assert_eq(bindings.pause(), true)
			ctx.wheel = { vertical = {}, horizontal = {} }
			helpers.assert_eq(bindings.reconcile_layer_wheel(), true)
			helpers.assert_eq(Fixture.live_count(ctx), 0, "an edit behind pause owns no input")
			helpers.assert_eq(bindings.resume_after_pause(), true)
			helpers.assert_eq(bindings.is_bound("layer_wheel"), false, "the resume reads the edited file")
		end)
	end)
end)
