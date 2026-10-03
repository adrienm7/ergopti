--- tests/unit/ui/menu/menu_llm/test_llm_enable_admission.lua

--- ==============================================================================
--- MODULE: LLM Enable Version Admission
--- DESCRIPTION:
--- Exercises the actual menu owner before persistence and backend publication.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_activation = require("tests.support.llm_activation_fixture")
local GOOD = { ok = true, status = 200, body = '{"version":"0.17.1"}' }
local BAD = { ok = false, status = 0, body = "" }

-- ===================================
-- ===================================
-- ======= 1/ Admission Regressions ===
-- ===================================
-- ===================================

--- Requires a refused or stale preflight to leave all publication owners inert.
--- @param state table Desired settings.
--- @param calls table Observed native fixture boundaries.
local function assert_off(state, calls)
	helpers.assert_eq(state.llm_enabled, false)
	helpers.assert_eq(calls.saves, 0)
	helpers.assert_eq(calls.keymap_states, {})
	helpers.assert_eq(calls.bootstrap, 0)
	helpers.assert_eq(calls.requirements, 0)
	helpers.assert_eq(calls.notifications, 0)
end

--- Selects one explicit repair without selecting again after a refusal.
--- @param suffix string Translated action suffix.
--- @return function picker
local function pick_once(suffix)
	local selected = false
	return function(dialog)
		if selected then return nil end
		selected = true
		for index, label in ipairs(dialog.choices) do
			if label:find("llm.unreachable." .. suffix, 1, true) == 1 then return index end
		end
	end
end

helpers.describe("LLM enable requires an owned fresh version receipt", function()
	helpers.it("keeps AI off during the exact origin request before any durable candidate", function()
		with_activation("ollama", { true }, { version_deferred = true }, function(action, state, calls)
			helpers.assert_eq(action(), true)
			assert_off(state, calls)
			helpers.assert_eq(calls.version_requests, { "http://127.0.0.1:11434/api/version" })
			calls.version_callback(GOOD)
			helpers.assert_eq(state.llm_enabled, true)
			helpers.assert_eq(calls.saves, 1)
			helpers.assert_eq(calls.requirements, 1)
			helpers.assert_eq(calls.bootstrap, 0)
		end)
	end)

	for index, receipt in ipairs({ BAD, { ok = true, status = 503, body = GOOD.body },
		{ ok = true, status = 302, body = GOOD.body, headers = { Location = "http://foreign.test/api/version" } },
		{ ok = true, status = 200, body = '[]' },
		{ ok = true, status = 200, body = '{"version":""}' },
		{ ok = true, status = 200, body = '{"version":1}' },
		{ ok = true, status = 200, body = GOOD.body .. ' garbage' },
		{ ok = true, status = 200, body = GOOD.body, body_truncated = true },
	}) do
		helpers.it("rejects complete HTTP receipt vector " .. index .. " without publication", function()
			with_activation("ollama", {}, { version_receipt = receipt }, function(action, state, calls)
				action()
				assert_off(state, calls)
				helpers.assert_eq(calls.service_repairs, 0)
				helpers.assert_eq(#calls.offer_dialogs, 1)
				helpers.assert_true(calls.offer_dialogs[1].message:find("llm.unreachable.body_unconfirmed", 1, true) ~= nil)
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("rejects synchronous good response before dispatch " .. mode .. " acknowledgement", function()
			with_activation("ollama", {}, { version_dispatch_mode = mode }, function(action, state, calls)
				action()
				assert_off(state, calls)
			end)
		end)
		helpers.it("never runs ordinary installer after a good receipt despite checker " .. mode, function()
			local options = { ollama_bootstrap_return = mode == "nil" and "nil" or false,
				ollama_bootstrap_throw = mode == "throw" }
			with_activation("ollama", { true }, options, function(action, state, calls)
				helpers.assert_eq(action(), true)
				helpers.assert_eq(state.llm_enabled, true)
				helpers.assert_eq(calls.bootstrap, 0)
				helpers.assert_eq(calls.ollama_installs, 0)
				helpers.assert_eq(calls.service_repairs, 0)
				helpers.assert_eq(calls.requirements, 1)
			end)
		end)
	end

	for _, changed in ipairs({ "backend", "model", "scope", "origin", "actual_backend", "actual_model" }) do
		helpers.it("refuses a late version reply after " .. changed .. " changes", function()
			local options = { version_deferred = true }
			with_activation("ollama", {}, options, function(action, state, calls)
				action()
				if changed == "backend" then state.llm_backend = "api"
				elseif changed == "model" then state.llm_model = "replacement"
				elseif changed == "scope" then options.scope_blocked = true
				elseif changed == "actual_backend" then require("modules.llm").set_backend("api")
				elseif changed == "actual_model" then require("modules.llm").set_llm_model_ollama("replacement-native-model")
				else require("modules.llm.ollama_endpoint").get_base_url = function() return "http://127.0.0.1:11435" end end
				calls.version_callback(GOOD)
				assert_off(state, calls)
				helpers.assert_eq(#calls.offer_dialogs, 0)
			end)
		end)
	end

	helpers.it("joins a paused version request then requires a fresh reply after resume", function()
		with_activation("ollama", { true }, { version_deferred = true }, function(action, state, calls)
			action()
			local stale = calls.version_callback
			local owner = calls.pause_owners.llm_activation
			helpers.assert_eq(owner.pause(), true)
			calls.set_paused(true)
			calls.set_pause_epoch(1)
			stale(GOOD)
			assert_off(state, calls)
			calls.set_pause_epoch(2)
			helpers.assert_eq(owner.resume(), true)
			calls.set_paused(false)
			local timer = calls.resume_timers[#calls.resume_timers]
			timer.callback()
			helpers.assert_eq(#calls.version_requests, 1, "resume cannot acquire while its native staging timer remains live")
			helpers.assert_eq(require("adapters.timer_scheduler").cancel(timer), true)
			helpers.assert_eq(#calls.version_requests, 2)
			assert_off(state, calls)
			calls.version_callback(GOOD)
			helpers.assert_eq(calls.saves, 1)
			helpers.assert_eq(state.llm_enabled, true)
		end)
	end)

	helpers.it("requires real service acknowledgement and then a fresh response after explicit Start", function()
		with_activation("ollama", { true }, { version_receipts = { BAD, GOOD },
			service_deferred = true, offer_pick = pick_once("start") }, function(action, state, calls)
			action()
			assert_off(state, calls)
			helpers.assert_eq(calls.service_repairs, 1)
			helpers.assert_eq(#calls.version_requests, 1)
			helpers.assert_eq(calls.service_authorized(), true)
			helpers.assert_eq(action(), false, "a sibling toggle cannot supersede an unsettled explicit service repair")
			calls.service_callback(true)
			helpers.assert_eq(#calls.version_requests, 2)
			helpers.assert_eq(state.llm_enabled, true)
			helpers.assert_eq(calls.saves, 1)
			helpers.assert_eq(calls.bootstrap, 0)
		end)
	end)

	helpers.it("requires install acknowledgement, service publication and fresh response for explicit Install", function()
		with_activation("ollama", { true }, { ollama_installed = false,
			version_receipts = { BAD, GOOD }, service_deferred = true,
			offer_pick = pick_once("install") }, function(action, state, calls)
			action()
			assert_off(state, calls)
			helpers.assert_eq(calls.ollama_installs, 1)
			helpers.assert_eq(calls.service_repairs, 0)
			calls.bootstrap_callback(true)
			assert_off(state, calls)
			helpers.assert_eq(calls.service_repairs, 1)
			helpers.assert_eq(#calls.version_requests, 1)
			calls.service_callback(true)
			helpers.assert_eq(#calls.version_requests, 2)
			helpers.assert_eq(calls.saves, 1)
			helpers.assert_eq(calls.requirements, 1)
		end)
	end)

	helpers.it("retains explicit install intent while paused and proves the service afresh after resume", function()
		with_activation("ollama", { true }, { ollama_installed = false,
			version_receipts = { BAD, GOOD }, offer_pick = pick_once("install") }, function(action, state, calls)
			action()
			helpers.assert_eq(action(), false, "a second toggle cannot escape an owned installation")
			local owner = calls.pause_owners.llm_activation
			helpers.assert_eq(owner.pause(), true)
			calls.set_paused(true)
			calls.set_pause_epoch(1)
			calls.bootstrap_callback(true)
			assert_off(state, calls)
			helpers.assert_eq(calls.service_repairs, 0)
			calls.set_pause_epoch(2)
			helpers.assert_eq(owner.resume(), true)
			calls.set_paused(false)
			local stage = calls.resume_timers[#calls.resume_timers]
			stage.callback()
			helpers.assert_eq(calls.service_repairs, 0)
			helpers.assert_eq(require("adapters.timer_scheduler").cancel(stage), true)
			helpers.assert_eq(calls.service_repairs, 1)
			helpers.assert_eq(#calls.version_requests, 2)
			helpers.assert_eq(calls.saves, 1)
			helpers.assert_eq(state.llm_enabled, true)
		end)
	end)

	helpers.it("never converts a service pause refusal into an AI enable", function()
		with_activation("ollama", {}, { version_receipts = { BAD },
			service_deferred = true, offer_pick = pick_once("start") }, function(action, state, calls)
			action()
			local owner = calls.pause_owners.llm_activation
			helpers.assert_eq(owner.pause(), true)
			calls.set_paused(true)
			calls.set_pause_epoch(1)
			helpers.assert_eq(calls.service_authorized(), false)
			calls.service_callback(false)
			assert_off(state, calls)
			calls.set_pause_epoch(2)
			helpers.assert_eq(owner.resume(), true)
			calls.set_paused(false)
			local stage = calls.resume_timers[#calls.resume_timers]
			stage.callback()
			helpers.assert_eq(require("adapters.timer_scheduler").cancel(stage), true)
			assert_off(state, calls)
			helpers.assert_eq(calls.service_repairs, 1)
			helpers.assert_eq(#calls.version_requests, 1)
		end)
	end)

	for _, source in ipairs({ "startup_debt", "provisioning_debt" }) do
		helpers.it("fences ordinary publication until exact " .. source .. " retires", function()
			local options = { version_deferred = true }
			with_activation("ollama", { true }, options, function(action, state, calls)
				action()
				options[source] = true
				calls.version_callback(GOOD)
				assert_off(state, calls)
				helpers.assert_eq(action(), false)
				helpers.assert_eq(#calls.version_requests, 1)
				options[source] = false
				helpers.assert_eq(action(), true)
				calls.version_callback(GOOD)
				helpers.assert_eq(calls.saves, 1)
				helpers.assert_eq(state.llm_enabled, true)
			end)
		end)
	end

	helpers.it("does not probe the local endpoint for an API backend", function()
		with_activation("api", { true }, { version_dispatch_mode = "throw" }, function(action, state, calls)
			helpers.assert_eq(action(), true)
			helpers.assert_eq(calls.version_requests, {})
			helpers.assert_eq(calls.bootstrap, 0)
			helpers.assert_eq(calls.saves, 1)
			helpers.assert_eq(state.llm_enabled, true)
		end)
	end)
end)

return true
