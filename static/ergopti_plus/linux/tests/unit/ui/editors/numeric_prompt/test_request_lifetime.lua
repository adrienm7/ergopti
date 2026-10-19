--- tests/unit/ui/editors/numeric_prompt/test_request_lifetime.lua

--- ==============================================================================
--- MODULE: Numeric Prompt Request Lifetime
--- DESCRIPTION:
--- Old Save, Cancel and native completion frames cannot hide, clear or confirm a
--- successor request. Explicit native page receipts remain separate from callback
--- admission, and a save callback may be entered only once at a time.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local MODULE = "ui.numeric_prompt.bridge"

--- Runs an isolated real bridge over explicit native page acknowledgements.
--- @param body function Receives bridge and native controls.
local function scenario(body)
	local previous = package.loaded[MODULE]
	local Prompt = helpers.load_module(MODULE)
	local state = { visible = false, epoch = 0, hides = 0, saves = 0, pushed = {} }
	local manager = {
		show = function()
			if not state.visible then state.epoch = state.epoch + 1 end
			state.visible, state.owned = true, true
			if state.on_show then state.on_show() end
			return true
		end,
		eval_js = function(_, code)
			state.pushed[#state.pushed + 1] = assert(Json.decode(assert(code:match("receive_prompt%((.*)%)$"))))
			if state.on_push then return state.on_push() end
			return true
		end,
		hide = function(_, epoch)
			if epoch ~= nil and epoch ~= state.epoch then return false end
			if state.refuse_hide then state.debt = true; return false end
			if state.partial_hide then state.visible, state.debt = false, true; return false end
			state.visible, state.owned, state.debt = false, false, false; state.hides = state.hides + 1
			if state.on_hide then state.on_hide() end
			return true
		end,
		is_visible = function() return state.visible end,
		current_epoch = function()
			if state.on_epoch then state.on_epoch() end
			return state.owned and state.epoch or nil
		end,
		page_current = function(_, epoch)
			if state.native_refusal == "throw" then error("controlled native page refusal") end
			if state.native_refusal == "false" then return false end
			return state.visible and not state.debt and state.epoch == epoch
		end,
	}
	state.manager = manager
	state.ask = function(title, callback)
		return Prompt.ask({ title = title, value = 2, min = 0, max = 10,
			on_save = callback or function() state.saves = state.saves + 1; return true end }, manager)
	end
	state.latest_epoch = function() return state.pushed[#state.pushed].request_epoch end
	local ok, why = pcall(body, Prompt, state)
	package.loaded[MODULE] = previous
	if not ok then error(why, 0) end
end

--- Saves the requested value through the actual handler.
--- @param prompt table Actual bridge.
--- @param epoch number Exact request identity.
--- @return table
local function save(prompt, epoch)
	return prompt.on_message({ action = "save", value = 3, request_epoch = epoch }, {})
end

helpers.describe("Numeric prompt exact request lifetime", function()
	helpers.it("(numeric-request-owner) keeps an ordinary successful callback exactly once", function()
		scenario(function(prompt, state)
			helpers.assert_true(state.ask("First"))
			local epoch = state.latest_epoch()
			local result = save(prompt, epoch)
			helpers.assert_eq(result.saved, true); helpers.assert_eq(result.closed, true)
			helpers.assert_eq(state.saves, 1); helpers.assert_eq(state.hides, 1)
			helpers.assert_eq(prompt.is_pending(), false)
			helpers.assert_eq(save(prompt, epoch).saved, false)
			helpers.assert_eq(state.saves, 1)
		end)
	end)

	helpers.it("(numeric-request-owner) does not close a successor opened by the save callback", function()
		scenario(function(prompt, state)
			helpers.assert_true(state.ask("First", function()
				helpers.assert_true(state.ask("Second")); return true
			end))
			local first = state.latest_epoch()
			local result = save(prompt, first)
			helpers.assert_eq(state.visible, true); helpers.assert_eq(state.hides, 0)
			helpers.assert_eq(prompt.is_pending(), true)
			helpers.assert_eq(result.saved, false); helpers.assert_eq(result.stale, true)
			helpers.assert_eq(save(prompt, first).saved, false)
			local second = state.latest_epoch()
			helpers.assert_true(second > first)
			helpers.assert_eq(save(prompt, second).saved, true)
			helpers.assert_eq(state.saves, 1); helpers.assert_eq(state.hides, 1)
		end)
	end)

	helpers.it("(numeric-request-owner) refuses duplicate Save while the callback is running", function()
		scenario(function(prompt, state)
			local epoch, nested, calls = nil, nil, 0
			helpers.assert_true(state.ask("First", function()
				calls = calls + 1
				if calls == 1 then nested = save(prompt, epoch) end
				return true
			end))
			epoch = state.latest_epoch()
			local result = save(prompt, epoch)
			helpers.assert_eq(calls, 1); helpers.assert_eq(nested.saved, false)
			helpers.assert_eq(result.saved, true); helpers.assert_eq(state.hides, 1)
		end)
	end)

	for _, returned in ipairs({ true, false }) do
		helpers.it("(numeric-request-owner) keeps a successor during request push returning " .. tostring(returned), function()
			scenario(function(prompt, state)
				state.on_push = function()
					state.on_push = nil
					helpers.assert_true(state.ask("Second"))
					return returned
				end
				helpers.assert_eq(state.ask("First"), false)
				helpers.assert_eq(state.visible, true); helpers.assert_eq(state.hides, 0)
				helpers.assert_eq(prompt.is_pending(), true)
				helpers.assert_eq(prompt.on_message("ready", {}).request.title, "Second")
				helpers.assert_eq(save(prompt, state.latest_epoch()).saved, true)
				helpers.assert_eq(state.saves, 1)
			end)
		end)
	end

	helpers.it("(numeric-request-owner) keeps a successor opened during native show", function()
		scenario(function(prompt, state)
			state.on_show = function()
				state.on_show = nil
				helpers.assert_true(state.ask("Second"))
			end
			helpers.assert_eq(state.ask("First"), false)
			helpers.assert_eq(state.pushed[1].title, "Second")
			helpers.assert_eq(#state.pushed, 1)
			helpers.assert_eq(save(prompt, state.latest_epoch()).saved, true)
		end)
	end)

	for _, action in ipairs({ "save", "cancel" }) do
		helpers.it("(numeric-request-owner) does not erase a successor during native " .. action .. " close", function()
			scenario(function(prompt, state)
				helpers.assert_true(state.ask("First"))
				local first = state.latest_epoch()
				state.on_hide = function()
					state.on_hide = nil
					helpers.assert_true(state.ask("Second"))
				end
				local result = prompt.on_message({ action = action, value = 3, request_epoch = first }, {})
				helpers.assert_eq(state.visible, true); helpers.assert_eq(prompt.is_pending(), true)
				helpers.assert_eq(result.closed, false); helpers.assert_eq(result.stale, true)
				helpers.assert_eq(prompt.on_message("ready", {}).request.title, "Second")
				helpers.assert_eq(save(prompt, first).saved, false)
				helpers.assert_eq(save(prompt, state.latest_epoch()).saved, true)
				helpers.assert_eq(state.saves, action == "save" and 2 or 1)
			end)
		end)
	end

	helpers.it("(numeric-request-owner) rejects an old native page before its setter runs", function()
		scenario(function(prompt, state)
			helpers.assert_true(state.ask("First")); local first = state.latest_epoch()
			state.visible, state.owned = false, false
			local result = save(prompt, first)
			helpers.assert_eq(result.saved, false); helpers.assert_eq(state.saves, 0)
			helpers.assert_eq(state.hides, 0)
		end)
	end)

	helpers.it("(numeric-request-owner) retries close without repeating a completed setter", function()
		scenario(function(prompt, state)
			helpers.assert_true(state.ask("First")); local epoch = state.latest_epoch()
			state.refuse_hide = true
			local result = save(prompt, epoch)
			helpers.assert_eq(result.saved, true); helpers.assert_eq(result.closed, false)
			helpers.assert_eq(state.saves, 1); helpers.assert_eq(prompt.is_pending(), true)
			state.refuse_hide = false
			helpers.assert_eq(save(prompt, epoch).closed, true)
			helpers.assert_eq(state.saves, 1); helpers.assert_eq(state.hides, 1)
		end)
	end)

	helpers.it("(numeric-request-owner) refuses Cancel during its exact save admission", function()
		scenario(function(prompt, state)
			local epoch, nested
			helpers.assert_true(state.ask("First", function()
				nested = prompt.on_message({ action = "cancel", request_epoch = epoch }, {})
				return true
			end))
			epoch = state.latest_epoch()
			helpers.assert_eq(save(prompt, epoch).saved, true)
			helpers.assert_eq(nested.closed, false); helpers.assert_eq(state.hides, 1)
		end)
	end)

	helpers.it("(numeric-request-owner) does not return a successor as the old ready response", function()
		scenario(function(prompt, state)
			helpers.assert_true(state.ask("First"))
			state.on_push = function()
				state.on_push = nil
				helpers.assert_true(state.ask("Second")); return true
			end
			helpers.assert_nil(prompt.on_message("ready", {}))
			helpers.assert_eq(prompt.on_message("ready", {}).request.title, "Second")
			helpers.assert_eq(save(prompt, state.latest_epoch()).saved, true)
		end)
	end)

	helpers.it("(numeric-request-owner) rejects a late Cancel after an ordinary replacement", function()
		scenario(function(prompt, state)
			helpers.assert_true(state.ask("First")); local first = state.latest_epoch()
			helpers.assert_true(state.ask("Second")); local second = state.latest_epoch()
			local result = prompt.on_message({ action = "cancel", request_epoch = first }, {})
			helpers.assert_eq(result.closed, false); helpers.assert_eq(result.stale, true)
			helpers.assert_eq(state.hides, 0); helpers.assert_eq(state.saves, 0)
			helpers.assert_eq(save(prompt, second).saved, true)
		end)
	end)

	helpers.it("(numeric-request-owner) retains cleanup after a partial native close without replaying the setter", function()
		scenario(function(prompt, state)
			helpers.assert_true(state.ask("First")); local epoch = state.latest_epoch()
			state.partial_hide = true
			local result = save(prompt, epoch)
			helpers.assert_eq(result.saved, true); helpers.assert_eq(result.closed, false)
			helpers.assert_eq(state.visible, false); helpers.assert_eq(prompt.is_pending(), true)
			state.partial_hide = false
			helpers.assert_eq(save(prompt, epoch).closed, true)
			helpers.assert_eq(state.saves, 1); helpers.assert_eq(state.hides, 1)
		end)
	end)

	for _, refusal in ipairs({ "false", "throw" }) do
		helpers.it("(numeric-request-owner) refuses native readiness " .. refusal .. " before its setter", function()
			scenario(function(prompt, state)
				helpers.assert_true(state.ask("First")); local epoch = state.latest_epoch()
				state.native_refusal = refusal
				helpers.assert_eq(save(prompt, epoch).saved, false)
				helpers.assert_eq(state.saves, 0); helpers.assert_eq(state.hides, 0)
				state.native_refusal = nil
				helpers.assert_eq(save(prompt, epoch).saved, true)
				helpers.assert_eq(state.saves, 1)
			end)
		end)
	end

	helpers.it("(numeric-request-owner) keeps a successor created while inspecting rollback ownership", function()
		scenario(function(prompt, state)
			helpers.assert_true(state.ask("First"))
			state.on_push = function() return false end
			state.on_hide = function()
				state.on_hide, state.on_push = nil, nil
				state.on_epoch = function()
					state.on_epoch = nil
					helpers.assert_true(state.ask("Successor"))
				end
			end
			helpers.assert_eq(state.ask("Refused"), false)
			helpers.assert_eq(state.visible, true)
			helpers.assert_eq(prompt.is_pending(), true)
			helpers.assert_eq(prompt.on_message("ready", {}).request.title, "Successor")
			helpers.assert_eq(save(prompt, state.latest_epoch()).saved, true)
		end)
	end)

	helpers.it("(numeric-request-owner) keeps a refused callback retryable", function()
		scenario(function(prompt, state)
			local refused = true
			helpers.assert_true(state.ask("First", function()
				state.saves = state.saves + 1
				if refused then error("controlled setter refusal") end
				return true
			end))
			local epoch = state.latest_epoch()
			helpers.assert_eq(save(prompt, epoch).saved, false)
			helpers.assert_eq(state.hides, 0); helpers.assert_eq(prompt.is_pending(), true)
			refused = false
			helpers.assert_eq(save(prompt, epoch).saved, true)
			helpers.assert_eq(state.saves, 2)
		end)
	end)
end)
