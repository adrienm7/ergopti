--- tests/unit/modules/gestures/test_native_app_switcher_action.lua

--- Actual product registry source admission and per-parent native lifecycle.
local h = require("tests.helpers")
local Fixture = require("tests.support.gesture_actions_fixture")
local eq = h.assert_eq
local function action_scope(fresh, body)
	return h.with_stub_scope({ "infra.preferences", "modules.gestures.native_app_switcher_action" }, function()
		local actions, calls = fresh()
		local state = { ga = { tap_3 = "system_app_switcher" } }
		actions.init(state)
		local source_current, content, publication = true, "canonical source", nil
		package.loaded["infra.preferences"] = {
			source_snapshot = function() return { status = "ok", content = "canonical source" } end,
			capture_source_delivery_guard = function() return function() return source_current end end,
		}
		package.loaded["adapters.file_system"].read_with_status = function() return content, "ok" end
		local native = { requests = 0, paused = {}, pending = {} }
		function native.request(parent, input)
			native.requests, publication = native.requests + 1, input
			eq(parent, "gestures"); eq(input.current(), true); eq(input.cached(), true)
			return true
		end
		function native.pause(parent) native.paused[parent] = true; return not native.pending[parent] end
		function native.resume(parent)
			if native.pending[parent] then return false end
			native.paused[parent] = false; return true
		end
		function native.is_paused(parent) return native.paused[parent] == true end
		function native.has_pending(parent) return native.pending[parent] == true end
		package.loaded["modules.gestures.native_app_switcher_action"] = native
		body({ actions = actions, state = state, calls = calls, native = native,
			publication = function() return publication end,
			revoke = function() source_current = false end,
			change_file = function() content = "foreign source" end })
	end)
end

h.describe("native switcher product action source", function()
	Fixture.it("offers a distinct native action while preserving direct previous-screen actions", function(fresh)
		action_scope(fresh, function(f)
			local catalogue = require("_generated.action_catalogue")
			eq(catalogue.actions.system_app_switcher ~= nil, true)
			eq(f.actions.is_assignable("system_app_switcher"), true)
			eq(catalogue.actions.app_switcher, nil)
			eq(f.actions.is_assignable("app_switcher"), false)
			f.actions.execute_single("app_switcher", "tap_3")
			eq(f.native.requests, 0); eq(#f.calls.keys, 0)
			eq(catalogue.actions.system_app_switcher.label_key, "sg_actions.system_app_switcher")
			eq(f.actions.is_assignable("app_previous_screen"), true)
			eq(f.actions.execute_single("system_app_switcher", "tap_3"), true)
			eq(f.native.requests, 1); eq(#f.calls.keys, 0)
		end)
	end)
	Fixture.it("keeps full source IO separate from pure runtime and terminal seals", function(fresh)
		action_scope(fresh, function(f)
			eq(f.actions.execute_single("system_app_switcher", "tap_3"), true)
			local p = f.publication(); eq(p.current(), true); eq(p.cached(), true)
			f.change_file(); eq(p.current(), false); eq(p.cached(), true)
			f.revoke(); eq(p.cached(), false)
		end)
	end)
	Fixture.it("withdraws an admitted operation when its exact gesture assignment changes", function(fresh)
		action_scope(fresh, function(f)
			eq(f.actions.execute_single("system_app_switcher", "tap_3"), true)
			f.state.ga.tap_3 = "app_previous"
			eq(f.publication().cached(), false); eq(f.publication().current(), false)
		end)
	end)
	Fixture.it("refuses a missing or foreign binding before native acquisition", function(fresh)
		action_scope(fresh, function(f)
			f.actions.execute_single("system_app_switcher", "foreign_slot")
			f.actions.execute_single("system_app_switcher")
			eq(f.native.requests, 0); eq(#f.calls.keys, 0)
		end)
	end)
	Fixture.it("joins exact cleanup and resume barriers for the native action parent", function(fresh)
		action_scope(fresh, function(f)
			eq(f.actions.execute_single("system_app_switcher", "tap_3"), true)
			f.native.pending.gestures = true
			eq(f.actions.force_cleanup("gestures"), false)
			eq(f.publication().cached(), false); eq(f.actions.resume_after_cleanup("gestures"), false)
			f.native.pending.gestures = false
			eq(f.actions.force_cleanup("gestures"), true); eq(f.actions.resume_after_cleanup("gestures"), true)
			eq(f.publication().cached(), false)
		end)
	end)
end)

h.describe("native switcher retired binding admission", function()
	Fixture.it("refuses an old persisted identifier before native acquisition", function(fresh)
		action_scope(fresh, function(f)
			f.state.ga.tap_3 = "app_switcher"
			f.actions.execute_single("system_app_switcher", "tap_3")
			f.actions.execute_single("app_switcher", "tap_3")
			eq(f.native.requests, 0); eq(#f.calls.keys, 0)
			eq(f.publication(), nil)
		end)
	end)
end)
