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


helpers.describe("FocusGuard: live daemon word-boundary premise", function()
	local previous_logger = package.loaded["logger.shim"]
	local previous_engine = package.loaded["hotstring_engine"]
	local previous_guard = package.loaded["modules.keylogger.focus_guard"]
	package.loaded["logger.shim"] = helpers.make_logger_stub()
	local Engine = helpers.load_module("hotstring_engine")
	local FocusGuard = helpers.load_module("modules.keylogger.focus_guard")

	local function observe(keys)
		local engine = Engine.new()
		helpers.assert_eq(engine:load_mappings({
			{ trigger = "adn", replacement = "ADN", is_word = true, auto_expand = false, is_case_sensitive = true },
		}), true)
		local guard = FocusGuard.new({
			detector = { invalidateFocus = function() return 1 end, refresh = function() return true end,
				isSecureField = function() return false end },
			keylogger = { set_secure_field = function() end }, now_ms = function() return 0 end,
			reset_text = function() engine:reset(false) end,
		})
		helpers.assert_eq(guard.prime(), true)
		helpers.assert_eq(guard.blocks_text(), false)
		helpers.assert_eq(engine:buffer_starts_at_word_boundary(), false,
			"a conclusive non-password verdict does not locate the caret at a word start")
		local text, matches = "", 0
		for char in keys:gmatch(".") do
			text = text .. char
			local result = engine:on_char(char, { is_terminator = char == " ", typed_at_ms = 1000 })
			if result then
				matches = matches + 1
				text = text:sub(1, #text - result.backspace_count) .. result.replacement
					.. (result.end_char and not result.consume_terminator and result.terminator or "")
			end
		end
		return text, matches
	end

	helpers.it("daemon word boundary: real probe types an observed separator", function()
		local input = assert(io.open(helpers.driver_root() .. "/tests/hardware/run_daemon_live.lua", "r"))
		local source = input:read("*a")
		input:close()
		local keys = assert(source:match('type_text%("([^"\n]+)"%)%s*local got, trail = read_output%(3%)'))
		local expected = assert(source:match('if got == "([^"\n]+)" then'))
		local text, matches = observe(keys)
		helpers.assert_eq(text, expected, "the real matcher must produce the probe's independent desktop expectation")
		helpers.assert_eq(matches, 1)
		helpers.assert_eq(keys, " adn ", "the live probe must observe the separator on its real keyboard")
		helpers.assert_eq(expected, " ADN ", "the expected desktop result keeps the independent separator literal")
	end)
	helpers.it("daemon word boundary: unknown initial suffix remains refused", function()
		local text, matches = observe("adn ")
		helpers.assert_eq(matches, 0)
		helpers.assert_eq(text, "adn ")
	end)
	helpers.it("daemon word boundary: larger word remains refused", function()
		local text, matches = observe("xadn ")
		helpers.assert_eq(matches, 0)
		helpers.assert_eq(text, "xadn ")
	end)
	package.loaded["hotstring_engine"] = previous_engine
	package.loaded["modules.keylogger.focus_guard"] = previous_guard
	package.loaded["logger.shim"] = previous_logger
end)
