--- tests/unit/modules/llm/warmup/test_warmup_replays_after_model_identity.lua

--- ==============================================================================
--- MODULE: Deferred Warmup Replay Regression Tests
--- DESCRIPTION:
--- With the remote API backend (a local oMLX entry), the runtime gate opened
--- before the persisted API entries were restored. The warmup found no model,
--- logged "backend model not resolved yet" and nothing ever retried it, so the
--- backend never became ready: every prediction was skipped and the AI menu
--- title showed a red dot while the server was running.
---
--- FEATURES & RATIONALE:
--- 1. Replay: Publishing the model identity replays the skipped warmup once.
--- 2. No Intent: Without a skipped warmup the replay acquires nothing.
--- 3. Pause: A pause parks the replay until resume instead of warming.
--- 4. Owner Wiring: The API identity restore calls the replay hook.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ===========================================
-- ===========================================
-- ======= 1/ Fixture ========================
-- ===========================================
-- ===========================================

local MODULE_NAMES = {
	"adapters.timer_scheduler",
	"infra.logger",
	"infra.timings",
	"modules.llm.warmup_controller",
}

--- Runs one isolated scenario against the real warmup controller.
--- @param scenario function Receives controller, scheduler, and mutable state.
local function with_fixture(scenario)
	local saved = {}
	for _, name in ipairs(MODULE_NAMES) do
		saved[name] = package.loaded[name]
		package.loaded[name] = nil
	end

	local state = { model = "", warmups = {} }
	local scheduler = { handles = {} }
	function scheduler.after(_, callback)
		local handle = { active = true, callback = callback }
		scheduler.handles[#scheduler.handles + 1] = handle
		return handle, true
	end
	function scheduler.cancel(handle)
		if type(handle) == "table" then handle.active = false end
		return true
	end
	function scheduler.onSettled(_, observer) observer(); return true end
	-- Fires only the timers armed so far: the retry the attempt arms stays pending.
	function scheduler.fire_pending()
		for index = 1, #scheduler.handles do
			local handle = scheduler.handles[index]
			if handle.active then
				handle.active = false
				handle.callback()
			end
		end
	end

	local function noop() end
	package.loaded["adapters.timer_scheduler"] = scheduler
	package.loaded["infra.logger"] = setmetatable({}, { __index = function() return noop end })
	package.loaded["infra.timings"] = { sec = function() return 1 end }

	local controller = require("modules.llm.warmup_controller")
	controller.init({
		core_llm = {
			get_current_model = function() return state.model end,
			is_backend_ready = function() return false end,
			is_backend_load_failed = function() return false end,
			get_backend = function() return "api" end,
			get_active_profile = function() return nil end,
			warmup_model = function(model)
				state.warmups[#state.warmups + 1] = model
				return true, true
			end,
		},
		get_llm_enabled = function() return true end,
	})

	local ok, err = xpcall(function()
		scenario(controller, scheduler, state)
	end, debug.traceback)
	for _, name in ipairs(MODULE_NAMES) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end




-- ===========================================
-- ===========================================
-- ======= 2/ Behaviour ======================
-- ===========================================
-- ===========================================

helpers.describe("Deferred warmup replay after the model identity appears", function()

	helpers.it("replays the startup warmup once the API entry is restored", function()
		with_fixture(function(controller, scheduler, state)
			helpers.assert_eq(controller.schedule_warmup_with_retry("set_llm_enabled"), true)
			helpers.assert_eq(#scheduler.handles, 0, "an unresolved model arms no timer")

			state.model = "mlx-community--Qwen3.5-4B-MLX-4bit"
			helpers.assert_eq(controller.retry_deferred_warmup("remote API identity restore"), true)
			helpers.assert_eq(#scheduler.handles, 1, "the replay must arm the warmup timer")
			scheduler.fire_pending()
			helpers.assert_eq(state.warmups[1], "mlx-community--Qwen3.5-4B-MLX-4bit")
		end)
	end)

	helpers.it("acquires nothing when no warmup was skipped", function()
		with_fixture(function(controller, scheduler, state)
			state.model = "model"
			helpers.assert_eq(controller.retry_deferred_warmup("remote API identity restore"), true)
			helpers.assert_eq(#scheduler.handles, 0)
		end)
	end)

	helpers.it("replays only once", function()
		with_fixture(function(controller, scheduler, state)
			controller.schedule_warmup_with_retry("set_llm_enabled")
			state.model = "model"
			controller.retry_deferred_warmup("first")
			controller.retry_deferred_warmup("second")
			helpers.assert_eq(#scheduler.handles, 1)
		end)
	end)

	helpers.it("parks the deferred intent across a pause", function()
		with_fixture(function(controller, scheduler, state)
			controller.schedule_warmup_with_retry("set_llm_enabled")
			helpers.assert_eq(controller.pause_warmup(), true)
			state.model = "model"
			helpers.assert_eq(controller.retry_deferred_warmup("remote API identity restore"), true)
			helpers.assert_eq(#scheduler.handles, 0, "no warmup while paused")
			helpers.assert_eq(controller.resume_warmup(), true)
			helpers.assert_eq(#scheduler.handles, 1, "resume restores the parked warmup")
		end)
	end)
end)

helpers.describe("The API identity restore replays the deferred warmup", function()
	helpers.it("load_api_entries calls retry_deferred_warmup after setting the entry", function()
		local src = helpers.read_driver_source("function M.load_api_entries")
		helpers.assert_true(src ~= nil, "the LLM core source must be locatable")
		local body = src:match("function M%.load_api_entries%(%).-\nend\n")
		helpers.assert_true(body ~= nil, "load_api_entries body must be extractable")
		local set_pos = body:find("ApiRemote.set_active_entry_id", 1, true)
		local replay_pos = body:find("WarmupController.retry_deferred_warmup", 1, true)
		helpers.assert_true(set_pos ~= nil and replay_pos ~= nil and replay_pos > set_pos,
			"the replay must follow the active API entry restore")
	end)
end)
