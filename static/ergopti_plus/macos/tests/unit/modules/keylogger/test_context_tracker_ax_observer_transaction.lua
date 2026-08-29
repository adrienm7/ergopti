--- tests/unit/modules/keylogger/test_context_tracker_ax_observer_transaction.lua

--- ==============================================================================
--- MODULE: Context Tracker AX Observer Transaction Tests
--- DESCRIPTION:
--- Proves that observer replacement and acquisition retain exact native cleanup
--- debt, never overlap generations, and fence callbacks until start commits.
--- ==============================================================================

local helpers = require("tests.helpers")

local function load_tracker(core_state, axuielement)
	package.loaded["modules.keylogger.context_tracker"] = nil
	local tracker = helpers.load_with_stubs("modules.keylogger.context_tracker", {
		axuielement = axuielement,
	})
	helpers.assert_true(tracker.init(core_state, {
		flush_buffer = function() return true end,
		append_log = function() return true end,
	}, function() return false end))
	return tracker
end

helpers.describe("context tracker AX observer ownership", function()
	helpers.it("retains a previous observer when replacement teardown raises", function()
		local old_observer = {
			stop = function() error("previous observer stop failed") end,
		}
		local new_calls = 0
		local core_state = {
			is_enabled = true,
			ax_observer = old_observer,
		}
		local tracker = load_tracker(core_state, {
			observer = {
				new = function()
					new_calls = new_calls + 1
					return {}
				end,
			},
			applicationElement = function() return {} end,
		})

		helpers.assert_eq(tracker.update_ax_observer(4242), false)
		helpers.assert_eq(core_state.ax_observer, old_observer,
			"a refused stop must retain the exact previous observer")
		helpers.assert_eq(new_calls, 0,
			"replacement must not create a successor while exact cleanup is pending")
	end)

	helpers.it("retains and fences an observer activated before start raises", function()
		local callback = nil
		local stop_calls = 0
		local candidate = {
			addWatcher = function(self) return self end,
			callback = function(self, fn) callback = fn; return self end,
			start = function(self)
				self.running = true
				error("observer start failed after activation")
			end,
			stop = function(self)
				stop_calls = stop_calls + 1
				if stop_calls == 1 then error("observer rollback failed") end
				self.running = false
				return self
			end,
		}
		local core_state = {
			is_enabled = true,
			is_secure_field = true,
			active_app_name = "Editor",
			ax_observer = nil,
		}
		local tracker = load_tracker(core_state, {
			observer = { new = function() return candidate end },
			applicationElement = function()
				return { attributeValue = function() return nil end }
			end,
		})

		helpers.assert_eq(tracker.update_ax_observer(4242), false)
		helpers.assert_eq(core_state.ax_observer, candidate,
			"failed rollback must retain the exact activated observer")
		helpers.assert_eq(stop_calls, 1,
			"failed acquisition must immediately attempt exact-candidate rollback")
		callback(nil, "AXFocusedUIElementChanged", candidate, nil)
		helpers.assert_true(core_state.is_secure_field,
			"an activated but uncommitted observer callback must remain inert")

		candidate:stop()
		helpers.assert_eq(stop_calls, 2)
		helpers.assert_true(candidate.running == false)
	end)
end)
