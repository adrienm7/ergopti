--- tests/unit/adapters/synthetic_input/test_selected_output_range.lua

--- ==============================================================================
--- MODULE: Selected Output Range Boundaries
--- DESCRIPTION:
--- Exercises real selected output and clipboard preparation around explicit cold
--- native observations. Controlled ports do not claim compositor atomicity.
--- ==============================================================================
local helpers = require("tests.helpers")
local fixture = require("tests.support.adapters.synthetic_input.selection_write_fixture")

helpers.describe("staged selected output exact range", function()
	for _, text in ipairs({ "ok", "☃", "é", "👩‍💻" }) do
		helpers.it("writes and reselects the verified Unicode span " .. text, function()
			fixture.with(function(state, owner)
				local token = state.read()
				local committed, result = state.staged(token, text)
				helpers.assert_true(committed)
				helpers.assert_true(result.payload_written)
				helpers.assert_true(result.cleanup_ok)
				helpers.assert_true(owner.is_settled())
				helpers.assert_eq(state.starts, 3)
				helpers.assert_eq(state.requests[3].span, { first = 0, last = require("compat.utf8").len(text) })
				helpers.assert_eq(state.clipboard, "SAVED")
				helpers.assert_eq(next(state.held), nil)
			end)
		end)
	end
	for _, point in ipairs({ "write", "settle" }) do
		helpers.it("refuses a same-field selected range changed during " .. point, function()
			fixture.with(function(state, owner)
				local token = state.read()
				state.on_boundary = function(at)
					if at == point then state.selection = { first = 1, last = 2, text = "t" } end
				end
				local committed, result = state.staged(token)
				helpers.assert_eq(committed, false)
				helpers.assert_eq(result.payload_written, false)
				helpers.assert_eq(state.wire, {})
				helpers.assert_eq(state.clipboard, "SAVED")
				helpers.assert_true(owner.is_settled())
			end)
		end)
	end
	helpers.it("returns an honest partial result when the caret moves during the existing twenty milliseconds", function()
		fixture.with(function(state, owner)
			local token = state.read()
			state.on_boundary = function(at) if at == "reselect" then state.inserted = nil end end
			local committed, result = state.staged(token)
			helpers.assert_eq(committed, false)
			helpers.assert_true(result.payload_written)
			helpers.assert_true(result.cleanup_ok)
			for _, event in ipairs(state.wire) do helpers.assert_eq(event == "42:1" or event == "105:1", false) end
			helpers.assert_eq(state.clipboard, "SAVED")
			helpers.assert_true(owner.is_settled())
			local starts, wire = state.starts, #state.wire
			helpers.assert_eq(state.staged(token), false)
			helpers.assert_eq(state.starts, starts)
			helpers.assert_eq(#state.wire, wire)
		end)
	end)
	for _, point in ipairs({ "read", "write", "settle", "restore-wait", "reselect" }) do
		for _, action in ipairs({ "cancel", "stop" }) do
			helpers.it("retains the staging frame while " .. action .. " reenters " .. point, function()
				fixture.with(function(state, owner)
					local token = state.read()
					local retired = false
					state.on_boundary = function(at)
						if at ~= point or retired then return end
						retired = true
						helpers.assert_eq(owner[action](), false)
						helpers.assert_eq(owner.is_settled(), false)
						helpers.assert_eq(owner.read("foreign", function() return true end, function() end), false)
					end
					local committed, result = state.staged(token)
					helpers.assert_true(retired)
					helpers.assert_eq(committed, false)
					helpers.assert_true(result.cleanup_ok)
					helpers.assert_eq(state.clipboard, "SAVED", "a setter completing after revocation must not overwrite restoration")
					helpers.assert_eq(next(state.held), nil)
					helpers.assert_true(owner.is_settled())
				end)
			end)
		end
	end
	helpers.it("never starts a fresh clipboard preparation after native route retirement", function()
		fixture.with(function(state, owner)
			local token = state.read()
			local delivered = state.deliver
			state.on_boundary = function(at)
				if at == "capture-owner" then
					local layout = require("adapters.keyboard_layout")
					local plan = layout.plan
					layout.plan = function(...) local offered, why, receipt = plan(...); state.allowed = false; return offered, why, receipt end
				end
			end
			helpers.assert_eq(state.staged(token, "ok"), false)
			helpers.assert_eq(state.writes, {})
			helpers.assert_eq(state.wire, {})
			helpers.assert_true(owner.is_settled())
			helpers.assert_type(delivered, "function")
		end)
	end)
	helpers.it("passes a decreasing remainder from the single canonical admission deadline", function()
		fixture.with(function(state)
			local token = state.read()
			state.on_boundary = function(at)
				if at == "settle" then state.now = 200 end
				if at == "reselect" then state.now = 650 end
			end
			helpers.assert_true(state.staged(token))
			helpers.assert_eq(state.requests[2].timeout_ms, 800)
			helpers.assert_eq(state.requests[3].timeout_ms, 350)
		end)
	end)
	helpers.it("expires after payload without resetting its deadline or retrying the consumed read", function()
		fixture.with(function(state, owner)
			local token = state.read()
			state.on_boundary = function(at) if at == "reselect" then state.now = 1001 end end
			local committed, result = state.staged(token)
			helpers.assert_eq(committed, false)
			helpers.assert_true(result.payload_written)
			helpers.assert_eq(state.starts, 2)
			helpers.assert_true(owner.is_settled())
			helpers.assert_eq(state.staged(token), false)
			helpers.assert_eq(state.starts, 2)
		end)
	end)
	helpers.it("keeps clipboard restoration debt visible after a successful payload", function()
		fixture.with(function(state, owner)
			local token = state.read()
			state.restore_refused = true
			local committed, result = state.staged(token)
			helpers.assert_eq(committed, false)
			helpers.assert_true(result.payload_written)
			helpers.assert_eq(result.cleanup_ok, false)
			helpers.assert_eq(owner.is_settled(), false)
			helpers.assert_eq(owner.cancel(), false)
			helpers.assert_eq(state.staged(token), false)
		end)
	end)
	helpers.it("settles a retired writing frame only after a later actual clipboard restoration ACK", function()
		fixture.with(function(state, owner)
			local token = state.read()
			state.restore_refused = true
			local committed = state.staged(token)
			helpers.assert_eq(committed, false)
			helpers.assert_eq(owner.is_settled(), false)
			state.restore_refused = false
			helpers.assert_true(owner.cancel())
			helpers.assert_eq(state.clipboard, "SAVED")
			helpers.assert_true(owner.is_settled())
		end)
	end)
	helpers.it("reports a real native first-character mutation when authority retires before the remaining text", function()
		fixture.with(function(state, owner)
			local token = state.read()
			state.on_boundary = function(at) if at == "emit:24:1" then state.allowed = false end end
			local committed, result = state.staged(token, "ok")
			helpers.assert_eq(committed, false)
			helpers.assert_true(result.payload_written)
			helpers.assert_true(result.cleanup_ok)
			helpers.assert_eq(state.wire, { "24:1", "24:0" })
			helpers.assert_eq(state.stopped, 0)
			helpers.assert_true(owner.is_settled())
		end)
	end)
	helpers.it("does not mistake a Ctrl modifier-only refusal for a payload mutation", function()
		fixture.with(function(state, owner)
			local token = state.read()
			state.on_boundary = function(at) if at == "emit:29:1" then state.allowed = false end end
			local committed, result = state.staged(token)
			helpers.assert_eq(committed, false)
			helpers.assert_eq(result.payload_written, false)
			helpers.assert_eq(state.wire, { "29:1", "29:0" })
			helpers.assert_eq(state.clipboard, "SAVED")
			helpers.assert_true(owner.is_settled())
		end)
	end)
	helpers.it("keeps payload mutation visible after a throwing paste-consumption wait", function()
		fixture.with(function(state, owner)
			local token = state.read()
			state.on_boundary = function(at) if at == "restore-wait" then error("controlled wait failure") end end
			local committed, result = state.staged(token)
			helpers.assert_eq(committed, false)
			helpers.assert_true(result.payload_written)
			helpers.assert_eq(state.wire, { "29:1", "47:1", "47:0", "29:0" })
			helpers.assert_eq(state.clipboard, "SAVED")
			helpers.assert_eq(state.stopped, 1)
			helpers.assert_true(owner.is_settled())
		end)
	end)
end)
