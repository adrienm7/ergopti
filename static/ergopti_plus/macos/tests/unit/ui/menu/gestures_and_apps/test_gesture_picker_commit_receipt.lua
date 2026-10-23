--- tests/unit/ui/menu/gestures_and_apps/test_gesture_picker_commit_receipt.lua

--- ==============================================================================
--- MODULE: Gesture Picker Commit Receipt Composition
--- DESCRIPTION:
--- Keeps the real menu, preference transaction, picker and controller pool in one
--- path. The existing native reference fixture owns the WebView boundary; only
--- persistence and the gesture runtime facade are controlled, without file writes.
--- ==============================================================================

local helpers = require("tests.helpers")
local NativeFixture = require("tests.support.ui.usercontent_reference_fixture")

local OWNED_MODULES = {
	"ui.menu.menu_gestures", "modules.gestures", "ui.menu.menu_utils",
	"infra.dialog_util", "infra.manifest_menu", "ui.menu.shortcut_utils",
	"infra.deferred_work", "action_parameter_label", "ui.gesture_conflict_notice",
	"ui.menu.preferences_transaction", "diagnostics.operation_reporter",
	"menu.renderer", "logger.shim", "compat.utf8", "number_policy", "toml_codec.leaf_rows",
}

--- Opens the actual plain gesture picker over an acknowledged preference owner.
--- @param mode string First publication refusal, or "true" for a healthy save.
--- @param conflict table|nil Existing native conflict notice data.
--- @param scenario function Receives observations and an exact retained native callback.
local function with_gesture(mode, conflict, scenario)
	helpers.with_stub_scope(OWNED_MODULES, function()
		NativeFixture(function(picker, native)
			local result = table.pack(xpcall(function()
				local controls = { mode = mode, assigned = "none", disk = "none", saves = 0,
					commits = 0, rollbacks = 0, updates = 0, conflicts = 0, notices = {}, queue = {} }
				local state = { gestures = true, action = "none" }
				local logger = package.loaded["infra.logger"]
				package.loaded["logger.shim"] = logger
				package.loaded["infra.dialog_util"] = {}
				package.loaded["ui.menu.menu_utils"] = {}
				package.loaded["ui.menu.shortcut_utils"] = {
					picker_parameter_fields = function() return {} end,
				}
				package.loaded["infra.deferred_work"] = { after = function(_, work)
					controls.queue[#controls.queue + 1] = work
					return true
				end }
				package.loaded["ui.gesture_conflict_notice"] = { show = function(value)
					controls.notices[#controls.notices + 1] = value
					return true
				end }
				local runtime = {
					DEFAULT_STATE = { gestures = true },
					get_action = function() return controls.assigned end,
					set_action = function(_, value) controls.assigned, state.action = value, value; return true end,
					get_sg_names = function() return { "none", "lookup" } end,
					get_action_label = function(value) return value end,
					get_action_parameter_spec = function() return nil end,
					on_action_changed = function()
						controls.conflicts = controls.conflicts + 1
						return conflict
					end,
				}
				package.loaded["modules.gestures"] = runtime
				local Transaction = require("ui.menu.preferences_transaction")
				local save = Transaction.bind({ save = function(_, candidate)
					controls.saves = controls.saves + 1
					if controls.mode == "throw" then error("controlled preference publication error") end
					if controls.mode == "nil" then return nil end
					if controls.mode == "false" then return false end
					controls.disk, controls.commits = candidate.action, controls.commits + 1
					return true, { gestures = candidate.gestures, action = candidate.action }
				end }, {
					path = "/virtual/config.toml", state = state,
					initial_state = state, initial_preferences = state,
					read_only_reason = function() return controls.mode == "read-only" and "unreadable config.toml" or nil end,
					restore_runtime = function(previous)
						controls.rollbacks = controls.rollbacks + 1
						controls.assigned = previous.action
						return true
					end,
				})
				local renderer = assert(require("menu.renderer").new({
					platform = "hs", manifest_path = function() return helpers.shared("modules/menu/menu_manifest.json") end,
					json_decode = require("json").decode,
					i18n = { get = package.loaded["infra.i18n"].get,
						section = package.loaded["infra.i18n"].get }, logger = logger,
				}))
				local provider
				package.loaded["infra.manifest_menu"] = {
					group_receiver = renderer.group_receiver, template_rows = renderer.template_rows,
					get_root = function() return { gesture_slots = { ["3"] = { "tap_3" } } } end,
					build = function(_, _, _, _, _, providers) provider = providers.gesture_slots_3; return {} end,
				}
				require("ui.menu.menu_gestures").build({ state = state, gestures = runtime, paused = false,
					save_prefs = save, updateMenu = function() controls.updates = controls.updates + 1 end })
				helpers.assert_type(provider, "function")
				local rows = provider()
				helpers.assert_eq(#rows, 1)
				rows[1].items[1].action()
				helpers.assert_eq(#native.views, 0, "the menu defers native presentation")
				helpers.assert_eq(#controls.queue, 1)
				table.remove(controls.queue, 1)()
				helpers.assert_eq(#native.views, 1, "the real menu must open the real shared picker")
				local view, controller = native.views[1], native.controllers[1]
				local dispatch = native.callback_refs[controller]
				helpers.assert_type(dispatch, "function")
				local function confirm(id)
					dispatch({ name = controller.name, webView = view, body = { action = "confirm", id = id or "lookup" } })
				end
				scenario(controls, native, view, controller, dispatch, confirm)
			end, debug.traceback))
			helpers.assert_true(picker.close(), "cleanup must settle the exact picker session")
			helpers.assert_eq(next(native.callback_refs), nil, "cleanup releases the native callback reference")
			for _, view in ipairs(native.views) do helpers.assert_true(view.deleted) end
			if not result[1] then error(result[2], 0) end
		end)
	end)
end

helpers.describe("plain gesture picker commit receipt (gesture-picker-commit-receipt)", function()
	for _, refusal in ipairs({ "read-only", "false", "nil", "throw" }) do
		helpers.it("keeps a " .. refusal .. " preference refusal retryable in the same gesture picker", function()
			with_gesture(refusal, nil, function(controls, native, view, controller, dispatch, confirm)
				confirm()
				helpers.assert_eq(controls.assigned, "none", "the rejected assignment must roll back")
				helpers.assert_eq(controls.disk, "none")
				helpers.assert_eq(controls.rollbacks, 1)
				helpers.assert_eq(controls.commits, 0)
				helpers.assert_eq(controls.updates, 0)
				helpers.assert_eq(controls.conflicts, 0)
				helpers.assert_eq(view.deleted, false, "a refused publication must keep the real picker open")
				helpers.assert_eq(native.callback_refs[controller], dispatch, "the exact bridge remains available for retry")
				local refused_saves = refusal == "read-only" and 0 or 1
				helpers.assert_eq(controls.saves, refused_saves)
				controls.mode = "true"
				confirm()
				helpers.assert_eq(controls.assigned, "lookup")
				helpers.assert_eq(controls.disk, "lookup")
				helpers.assert_eq(controls.saves, refused_saves + 1)
				helpers.assert_eq(controls.commits, 1)
				helpers.assert_eq(controls.conflicts, 1)
				helpers.assert_true(view.deleted)
				helpers.assert_eq(#native.views, 1)
				helpers.assert_eq(next(native.callback_refs), nil)
				confirm("none")
				helpers.assert_eq(controls.assigned, "lookup", "the retained retired bridge cannot change another action")
				helpers.assert_eq(controls.saves, refused_saves + 1)
				helpers.assert_eq(controls.commits, 1)
			end)
		end)
	end

	for _, has_conflict in ipairs({ false, true }) do
		helpers.it("closes a committed gesture picker " .. (has_conflict and "with its original conflict" or "without a conflict"), function()
			local conflict = has_conflict and { key = "tap_3", msg = "existing system gesture conflict", url = "settings" } or nil
			with_gesture("true", conflict, function(controls, native, view, _, _, confirm)
				confirm()
				helpers.assert_eq(controls.assigned, "lookup")
				helpers.assert_eq(controls.disk, "lookup")
				helpers.assert_eq(controls.commits, 1)
				helpers.assert_eq(controls.conflicts, 1)
				helpers.assert_eq(#controls.notices, has_conflict and 1 or 0)
				if has_conflict then helpers.assert_true(rawequal(controls.notices[1], conflict)) end
				helpers.assert_true(view.deleted)
				helpers.assert_eq(next(native.callback_refs), nil)
			end)
		end)
	end
end)
