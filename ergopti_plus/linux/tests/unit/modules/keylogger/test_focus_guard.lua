--- tests/unit/modules/keylogger/test_focus_guard.lua

--- ==============================================================================
--- MODULE: Accessible Focus Privacy Guard Tests (Linux)
--- DESCRIPTION:
--- Reproduces same-window TEXT → PASSWORD_TEXT navigation without changing the
--- application or title. The test observes actual guard outputs: metric admission,
--- text-automation admission, LLM cancellation, and settle/epoch publication.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =========================================
-- =========================================
-- ======= 1/ Same-window Navigation =======
-- =========================================
-- =========================================

helpers.describe("FocusGuard: same-window secure-field navigation", function()
	local previous_logger = package.loaded["logger.shim"]
	package.loaded["logger.shim"] = helpers.make_logger_stub()
	local FocusGuard = helpers.load_module("modules.keylogger.focus_guard")

	local function fixture()
		local now = 1000
		local verdict = "unknown"
		local epoch = 0
		local probe_role = 42
		local probe_epoch = nil
		local metric_secure = true
		local pending_text = {}
		local llm_requests = 0
		local cancellations = 0
		local resets = 0

		local detector = {
			invalidateFocus = function()
				epoch = epoch + 1
				verdict = "unknown"
				return epoch
			end,
			refresh = function(requested_epoch)
				probe_epoch = requested_epoch
				if requested_epoch ~= epoch then return false, verdict end
				verdict = probe_role == 57 and "secure" or "insecure"
				return true, verdict
			end,
			isSecureField = function() return verdict ~= "insecure" end,
		}
		local keylogger = {
			set_secure_field = function(secure) metric_secure = secure == true end,
		}
		local prediction = {
			cancel = function() cancellations = cancellations + 1 end,
		}
		local guard = FocusGuard.new({
			detector   = detector,
			keylogger  = keylogger,
			prediction = prediction,
			now_ms     = function() return now end,
			settle_ms  = 250,
			reset_text = function() resets = resets + 1 end,
		})

		local state = {}
		function state.set_role(role) probe_role = role end
		function state.advance(ms) now = now + ms end
		function state.metric_secure() return metric_secure end
		function state.probe_epoch() return probe_epoch end
		function state.cancellations() return cancellations end
		function state.resets() return resets end
		function state.type_text(text)
			if not metric_secure then pending_text[#pending_text + 1] = text end
			if not guard.blocks_text() then llm_requests = llm_requests + 1 end
		end
		function state.pending_text() return table.concat(pending_text) end
		function state.llm_requests() return llm_requests end
		return guard, state
	end

	helpers.it("blocks Tab-to-password immediately and probes only after settle", function()
		local guard, state = fixture()
		helpers.assert_eq(guard.prime(), true, "the initial TEXT role must publish")
		helpers.assert_eq(guard.blocks_text(), false, "fresh TEXT permits automation")

		state.set_role(57)
		local tab_epoch = guard.invalidate()
		helpers.assert_eq(state.metric_secure(), true,
			"Tab must close metric admission before the password field receives text")
		helpers.assert_eq(guard.blocks_text(), true,
			"Tab must close hotstring and LLM admission immediately")
		helpers.assert_eq(state.cancellations(), 2,
			"the initial prime and Tab invalidation each cancel in-flight model work")
		helpers.assert_eq(state.resets(), 2,
			"the text buffer must cross each focus epoch with the detector")

		state.type_text("secret-before-probe")
		helpers.assert_eq(guard.refresh(false), false,
			"the password probe must not race raw focus delivery")
		helpers.assert_eq(state.probe_epoch(), 1,
			"only the initial prime should have probed before settle")
		state.advance(250)
		helpers.assert_eq(guard.refresh(false), true,
			"the settled current password epoch must publish")
		helpers.assert_eq(state.probe_epoch(), tab_epoch,
			"the probe must answer the epoch created by Tab")
		state.type_text("secret-after-probe")

		helpers.assert_eq(state.pending_text(), "",
			"no password text may enter the pending metric/log/SQLite path")
		helpers.assert_eq(state.llm_requests(), 0,
			"no password-field attempt may reach the model request path")
	end)

	helpers.it("clicks stay closed until a fresh insecure verdict re-enables text", function()
		local guard, state = fixture()
		guard.prime()
		state.set_role(57)
		guard.invalidate()
		state.advance(250)
		guard.refresh(false)
		helpers.assert_eq(guard.blocks_text(), true, "PASSWORD_TEXT must stay blocked")

		-- Same app and title, now click back to an ordinary TEXT control.
		state.set_role(42)
		guard.invalidate()
		helpers.assert_eq(guard.blocks_text(), true,
			"the previous secure verdict cannot authorize the new unknown control")
		state.type_text("too-early")
		state.advance(249)
		helpers.assert_eq(guard.refresh(false), false,
			"one millisecond before settle must still be blocked")
		state.advance(1)
		helpers.assert_eq(guard.refresh(false), true,
			"a fresh current TEXT verdict may re-enable consumers")
		helpers.assert_eq(guard.blocks_text(), false,
			"ordinary text is available only after that fresh verdict")
		state.type_text("safe")
		helpers.assert_eq(state.pending_text(), "safe",
			"only post-verdict ordinary text may enter pending metrics")
	end)

	helpers.it("fails closed when the detector is unavailable", function()
		local secure = false
		local guard = FocusGuard.new({
			detector  = nil,
			keylogger = { set_secure_field = function(value) secure = value end },
			now_ms    = function() return 0 end,
		})
		helpers.assert_eq(guard.prime(), false, "no detector cannot produce a verdict")
		helpers.assert_eq(secure, true, "metrics must remain fail-closed")
		helpers.assert_eq(guard.blocks_text(), true, "automation must remain fail-closed")
	end)

	package.loaded["logger.shim"] = previous_logger
end)
