--- tests/unit/modules/keystats/privacy/test_focus_guard_text_owner.lua

--- ==============================================================================
--- MODULE: Ordinary Injection Destination Ownership
--- DESCRIPTION:
--- A retained destination survives no field, epoch, policy or resident API
--- replacement. Per-DOWN currency reads only RAM and never calls the barrier.
--- ==============================================================================
local helpers = require("tests.helpers")
local fixture = require("tests.support.text_owner_fixture")

helpers.describe("ordinary text destination ownership", function()
	helpers.it("keeps one current owner without probing for each DOWN", function()
		fixture.with(function(guard, state)
			local owner = assert(guard.capture_text_owner())
			helpers.assert_true(owner.current())
			local before, pumps = state.barriers, state.pumps
			for _ = 1, 20 do helpers.assert_true(owner.cached()) end
			helpers.assert_eq(state.barriers, before)
			helpers.assert_eq(state.pumps, pumps)
		end)
	end)
	for _, change in ipairs({ "field", "password", "unknown", "epoch", "ABA", "policy", "watch-port" }) do
		helpers.it("refuses " .. change .. " without granting the successor an old owner", function()
			fixture.with(function(guard, state, detector, policy, watch)
				local owner = assert(guard.capture_text_owner())
				if change == "field" then state.path = "/field/second"
				elseif change == "password" then state.role = 40
				elseif change == "unknown" then state.unknown = true
				elseif change == "epoch" then detector.invalidateFocus()
				elseif change == "ABA" then guard.invalidate(); assert(guard.refresh(true))
				elseif change == "policy" then
					local configuration = assert(policy.configuration_snapshot())
					configuration.private_filter_enabled = true
					assert(policy.apply_configuration(configuration))
				else watch.snapshot = function() return { bus = state.bus, path = state.path, role = state.role } end end
				helpers.assert_eq(owner.current(), false)
				helpers.assert_eq(owner.cached(), false)
			end)
		end)
	end
	for _, port in ipairs({ "focus", "watch", "policy" }) do
		helpers.it("refuses a " .. port .. " API replaced before initial capture", function()
			fixture.with(function(guard, _, _, policy, watch)
				if port == "focus" then guard.focused_text_identity = function() return "forged" end
				elseif port == "watch" then watch.barrier = function() return watch.snapshot() end
				else policy.is_context_protected = function() return false end end
				helpers.assert_eq(guard.capture_text_owner(), nil)
			end)
		end)
	end
	helpers.it("does not capture a replacement owner during the initial barrier", function()
		fixture.with(function(guard, state)
			state.on_barrier = function() state.on_barrier = nil; guard.invalidate() end
			helpers.assert_eq(guard.capture_text_owner(), nil)
		end)
	end)
end)
