--- tests/unit/modules/llm/test_mlx_warmup_gated_on_disable.lua

--- ==============================================================================
--- MODULE: Regression — api_mlx self-retry warmup stops on pause/disable (M-3)
--- DESCRIPTION:
--- api_mlx.warmup() has its own self-rescheduling retry chain (TimerScheduler.after
--- 2s) that is gated only on _is_ready/_load_failed/_warmup_in_flight. Before M-3,
--- calling pause_all() bumped warmup_controller._warmup_gen (stopping the scheduled
--- chain) but left api_mlx's own retry free to keep POSTing through the pause and
--- fire the "server ready" notification mid-pause.
---
--- Fix: api_mlx.stop_warmup() sets _warmup_stopped=true + bumps _warmup_gen; the
--- early check in M.warmup() short-circuits any pending retry. resume_warmup()
--- clears the flag. script_control.pause_all() calls stop_warmup(); resume_all()
--- calls resume_warmup() before re-arming warmup_controller.
---
--- THE DISABLE HALF WAS NEVER WIRED. stop_warmup() had exactly ONE production
--- caller — script_control.pause_all() — so only the PAUSE path was covered.
--- prediction_engine.set_llm_enabled(false) called M.reset(), which stops the
--- prediction timers and cancels streaming but never touched either warmup
--- driver. WarmupController's own chain went unnoticed because it self-guards on
--- _get_llm_enabled(); api_mlx's 2s self-retry has no such gate. With the MLX
--- backend and a large model, turning AI OFF in the tray menu therefore left the
--- 2s POST loop running indefinitely, and when the model finally loaded api_mlx
--- fired a user-facing "server ready" notification WHILE AI WAS DISABLED —
--- violating PROJECT_MEMORY project-macos-llm-runtime-enable-gate.
---
--- Fix: set_llm_enabled(false) now mirrors pause_all() — WarmupController.stop()
--- plus a pcall'd lazy api_mlx.stop_warmup(); the enable path mirrors
--- resume_all() with resume_warmup() before schedule_warmup_with_retry().
---
--- Tests:
---   1. api_mlx exports stop_warmup and resume_warmup.            (source)
---   2. M.warmup() has a _warmup_stopped guard.                   (source)
---   3. script_control.pause_all source calls api.stop_warmup.    (source)
---   4. script_control.resume_all source calls api.resume_warmup. (source)
---   5. BEHAVIOURAL: set_llm_enabled(false) stops the self-retry POST loop.
---
--- Sections 1-2 are deliberately kept: they still encode the real pause-side
--- invariant. They were, however, a FALSE GREEN for the disable half — this file
--- was titled "stops on pause/disable" while only ever grepping script_control,
--- which has no bearing on set_llm_enabled. Section 3 closes that gap by
--- actually driving the retry chain across the gate.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_src(selector)
	local src = helpers.read_driver_source(selector)
	return src
end





-- ======================================================================
-- ======================================================================
-- ======= 1/ api_mlx exports stop_warmup and resume_warmup (M-3) =======
-- ======================================================================
-- ======================================================================

helpers.describe("M-3: api_mlx self-retry gate (source — public API)", function()

	helpers.it("api_mlx.lua defines M.stop_warmup", function()
		local src = read_src("local function read_user_port_override") -- modules/llm/api_mlx.lua
		helpers.assert_true(src:find("function M%.stop_warmup", 1, false) ~= nil
			or src:find("M.stop_warmup", 1, true) ~= nil,
			"api_mlx must expose M.stop_warmup() so pause_all can stop the self-retry chain")
	end)

	helpers.it("api_mlx.lua defines M.resume_warmup", function()
		local src = read_src("local function read_user_port_override") -- modules/llm/api_mlx.lua
		helpers.assert_true(src:find("function M%.resume_warmup", 1, false) ~= nil
			or src:find("M.resume_warmup", 1, true) ~= nil,
			"api_mlx must expose M.resume_warmup() so resume_all can re-enable the retry chain")
	end)

	helpers.it("api_mlx.lua has a _warmup_stopped guard in M.warmup()", function()
		local src = read_src("local function read_user_port_override") -- modules/llm/api_mlx.lua
		helpers.assert_true(src:find("_warmup_stopped", 1, true) ~= nil,
			"M.warmup() must check _warmup_stopped to short-circuit mid-pause retries")
	end)
end)





-- ====================================================================================
-- ====================================================================================
-- ======= 2/ script_control.lua calls stop/resume_warmup on pause/resume (M-3) =======
-- ====================================================================================
-- ====================================================================================

helpers.describe("M-3: script_control wires api_mlx stop/resume (source)", function()

	helpers.it("pause_all calls api.stop_warmup", function()
		local src = read_src("local function log_shortcut_if_available") -- modules/shortcuts/script_control.lua
		-- The pause block must call stop_warmup() on the api_mlx handle
		helpers.assert_true(src:find("stop_warmup", 1, true) ~= nil,
			"script_control.pause_all must call api.stop_warmup() to halt the api_mlx self-retry chain (M-3)")
	end)

	helpers.it("resume_all calls api.resume_warmup", function()
		local src = read_src("local function log_shortcut_if_available") -- modules/shortcuts/script_control.lua
		helpers.assert_true(src:find("resume_warmup", 1, true) ~= nil,
			"script_control.resume_all must call api.resume_warmup() to re-enable the api_mlx self-retry chain (M-3)")
	end)

	helpers.it("resume_warmup appears before schedule_warmup_with_retry in resume_all", function()
		local src = read_src("local function log_shortcut_if_available") -- modules/shortcuts/script_control.lua
		local resume_pos = src:find("resume_warmup", 1, true)
		local sched_pos  = src:find("schedule_warmup_with_retry", 1, true)
		helpers.assert_true(resume_pos ~= nil and sched_pos ~= nil,
			"both resume_warmup and schedule_warmup_with_retry must be present")
		helpers.assert_true(resume_pos < sched_pos,
			"resume_warmup() must be called BEFORE schedule_warmup_with_retry in resume_all")
	end)
end)




-- ===============================================
-- ===============================================
-- ======= 3/ Behavioural Disable Gate ===========
-- ===============================================
-- ===============================================

-- Source greps cannot see this: they only prove script_control is wired, which
-- says nothing about set_llm_enabled. Here the real api_mlx retry chain is driven
-- across the gate — TimerScheduler.after QUEUES instead of firing, the HTTP client
-- counts POSTs and always answers non-200 (so warmup always reschedules itself),
-- and every queued callback is drained AFTER the gate closes.

-- Upper bound on drained callbacks. Without the fix every drained retry enqueues
-- two more, so an unbounded drain would never terminate.
local MAX_DRAINED_CALLBACKS = 50

helpers.describe("M-3: set_llm_enabled(false) stops the api_mlx self-retry chain (behavioural)", function()
	helpers.it("no warmup POST fires after the LLM enable gate closes", function()
		-- Save every module we are about to replace so the suite is left clean
		local saved = {}
		for _, name in ipairs({
			"adapters.http_client", "adapters.timer_scheduler", "modules.llm.api_mlx",
			"modules.llm.api_mlx_discovery", "modules.llm.prediction_engine",
			"modules.llm", "modules.llm.warmup_controller", "modules.llm.prompt_builder",
			"modules.llm.streaming_handler", "modules.llm.app_filter", "modules.llm.api_common",
			"ui.tooltip", "modules.keylogger", "infra.notifications", "infra.keycodes",
		}) do
			saved[name] = package.loaded[name]
		end

		-- Deferred timer queue: nothing runs until the drain below
		local timer_queue = {}
		package.loaded["adapters.timer_scheduler"] = {
			after = function(delay, fn)
				local handle = { delay = delay, fn = fn, cancelled = false }
				timer_queue[#timer_queue + 1] = handle
				return handle, true
			end,
			every     = function(_, _) return { cancelled = false }, true end,
			cancel    = function(handle)
				if type(handle) == "table" then handle.cancelled = true; handle.timer = nil end
				return true
			end,
			cancelAll = function() end,
			now       = function() return 0 end,
		}

		-- Counting HTTP client: always non-200 so warmup always self-reschedules
		local post_count = 0
		package.loaded["adapters.http_client"] = {
			new = function()
				return {
					post = function(_url, _headers, _payload, cb)
						post_count = post_count + 1
						if cb then cb({ ok = false, status = 500, body = "" }) end
					end,
					get      = function(_url, _headers, cb) if cb then cb({ ok = false, status = 500, body = "" }) end end,
					cancel   = function() end,
					isActive = function() return false end,
				}
			end,
		}

		-- Discovery already done, so warmup goes straight to the POST
		package.loaded["modules.llm.api_mlx_discovery"] = {
			init                     = function(_) end,
			reset                    = function() end,
			set_base_url             = function(_) end,
			is_discovered            = function() return true end,
			discover                 = function(cb) if cb then cb() end end,
			mark_undiscovered        = function() end,
			set_expected_model_id    = function(_) end,
			get_completions_endpoint = function() return "http://127.0.0.1:3460/v1/completions" end,
			get_chat_endpoint        = function() return "http://127.0.0.1:3460/v1/chat/completions" end,
			get_server_model_id      = function() return "some-model" end,
			get_model_hf_path        = function() return nil end,
			read_active_model_arg    = function() return nil end,
		}

		-- Silence the "server ready" notification path
		package.loaded["infra.notifications"] = { notify = function() end }

		-- Load the REAL api_mlx against those adapters
		package.loaded["modules.llm.api_mlx"] = nil
		local ApiMlx = require("modules.llm.api_mlx")

		-- Minimal prediction_engine dependency set
		package.loaded["modules.llm"] = {
			DEFAULT_STATE = {
				llm_enabled = false, llm_temperature = 0.1, llm_context_length = 4000,
				llm_min_words = 2, llm_max_words = 0, llm_num_predictions = 3,
				llm_pred_indent = 0, llm_val_modifiers = { "alt" }, llm_nav_modifiers = { "ctrl" },
				llm_show_info_bar = false, llm_sequential_mode = false, llm_debounce = 0.3,
				llm_auto_raise_temp = true, llm_streaming = false, llm_streaming_multi = false,
				llm_instant_on_word_end = false,
			},
			get_current_model       = function() return "some-model" end,
			get_backend             = function() return "mlx" end,
			set_llm_model_mlx       = function(_) end,
			set_llm_model_ollama    = function(_) end,
			set_runtime_llm_enabled = function(_) end,
			set_llm_streaming       = function(_) end,
			cancel_streaming        = function() return true end,
			is_backend_ready        = function() return false end,
			get_active_profile      = function() return nil end,
			fetch_llm_prediction    = function(...) end,
		}
		package.loaded["modules.llm.warmup_controller"] = {
			schedule_warmup_with_retry = function(_) end,
			init = function(_) end, start = function() end, stop = function() end,
		}
		package.loaded["modules.llm.prompt_builder"]    = { build = function() return nil, "stubbed", nil end }
		package.loaded["modules.llm.streaming_handler"] = {
			init = function(_) end,
			build_callbacks = function(_) return function() end, function() end, function() end end,
			arm_watchdog = function(_) return true end, stop_watchdog = function() return true end,
			reset_failure_count = function() end, cancel_streaming = function() return true end,
		}
		package.loaded["modules.llm.app_filter"] = { is_blocked = function() return false end }
		package.loaded["modules.llm.api_common"] = {
			MIN_CALL_INTERVAL_SEC = 0.5,
			get_retry_policy = function() return 2, 0.18, 5 end,
			get_rate_limit_min_interval_s = function(_) return 0 end,
		}
		package.loaded["infra.keycodes"] = { F16_LLM_CHAIN_SIGNAL = 106 }
		package.loaded["ui.tooltip"] = {
			set_navigate_callback = function(_) end, set_enter_validates = function(_) end,
			set_chain_start = function(_) return true end, mark_chain_complete = function() return true end,
			get_current_index = function() return nil end, navigate = function(_) end,
			show = function() end, hide = function() return true end, hide_forced = function() return true end,
			set_llm_timeout = function(_) end, reset_llm_timer = function() end,
			show_loading = function() return true end, show_predictions = function() return true end,
			tint = function(_) return nil end,
		}
		package.loaded["modules.keylogger"] = {
			get_live_stats = function() return { wpm_physical = 0 } end,
			log_llm_dismissed = function(_, _p) end,
		}

		package.loaded["modules.llm.prediction_engine"] = nil
		local PredictionEngine = require("modules.llm.prediction_engine")

		-- Arrange: a live, non-stopped warmup chain
		ApiMlx.reset_endpoints()
		ApiMlx.resume_warmup()
		PredictionEngine.set_llm_enabled(true)

		ApiMlx.warmup("some-model", nil)
		local initial_posts   = post_count
		local scheduled_after = #timer_queue

		-- Act: close the gate, THEN let every already-queued callback fire
		PredictionEngine.set_llm_enabled(false)

		local drained = 0
		local i = 1
		while i <= #timer_queue and drained < MAX_DRAINED_CALLBACKS do
			local handle = timer_queue[i]
			i = i + 1
			drained = drained + 1
			if handle and handle.fn then handle.fn() end
		end

		local observed = post_count

		-- Restore before asserting so a red assertion never leaves the suite poisoned
		for name, mod in pairs(saved) do package.loaded[name] = mod end
		package.loaded["modules.llm.api_mlx"]           = nil
		package.loaded["modules.llm.prediction_engine"] = nil

		-- Arrangement guards: without these a broken setup (no POST, no retry armed)
		-- would satisfy the real assertion below for entirely the wrong reason
		helpers.assert_eq(initial_posts, 1,
			"the initial warmup must issue exactly one POST — otherwise the assertion below is meaningless")
		helpers.assert_true(scheduled_after > 0,
			"the non-200 response must have scheduled a 2s self-retry — otherwise there is no retry chain left to gate")

		helpers.assert_eq(observed, 1,
			"no warmup POST may fire after set_llm_enabled(false) — set_llm_enabled must call api_mlx.stop_warmup() " ..
			"exactly as script_control.pause_all() does, otherwise the 2s self-retry keeps POSTing while AI is off " ..
			"and eventually fires the user-facing 'server ready' notification with the LLM disabled (M-3)")
	end)
end)
