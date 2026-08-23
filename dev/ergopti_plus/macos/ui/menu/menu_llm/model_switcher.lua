--- ui/menu/menu_llm/model_switcher.lua

--- ==============================================================================
--- MODULE: LLM Model Switcher
--- DESCRIPTION:
--- Encapsulates all model-switching logic for the LLM tray menu: power-level
--- inference, profile recommendation, profile mismatch detection, and the
--- guarded async switch flow.
---
--- FEATURES & RATIONALE:
--- 1. Power inference: derives a model's "power level" from its parameter count
---    and MoE topology without any hard-coded model names.
--- 2. Profile recommendation: maps power level to the optimal profile and offers
---    a dialog so the user can accept or decline the change.
--- 3. MLX lock: disables predictions during a server restart so stale callbacks
---    never reach a dead port.
--- 4. Zero UI coupling: no menu-building code lives here — only domain logic and
---    side-effect calls through injected deps, making this testable in isolation.
--- ==============================================================================

local M = {}

local llm_mod       = require("modules.llm")
local i18n          = require("infra.i18n")
local Logger        = require("infra.logger")
local dialog        = require("infra.dialog_util")
local notifications = require("infra.notifications")
local ProfileLabel  = require("ui.menu.menu_llm.profile_label")
local PredictionLockRegistry = require("ui.menu.menu_llm.prediction_lock_registry")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "model_switcher"

-- Minimum parameter thresholds (in billions) that trigger a profile upgrade.
local MODEL_ADVANCED_PARAMS_THRESHOLD_B    = 2
local MODEL_BATCH_PARAMS_THRESHOLD_B       = 4

-- Numeric power levels — higher means the model can handle more complex prompts.
local PROFILE_POWER_RAW            = 0
local PROFILE_POWER_BASIC          = 1
local PROFILE_POWER_ADVANCED       = 2
local PROFILE_POWER_BATCH_ADVANCED = 3

local PROFILE_POWER_LEVELS = {
	raw           = PROFILE_POWER_RAW,
	basic         = PROFILE_POWER_BASIC,
	advanced      = PROFILE_POWER_ADVANCED,
	batch_advanced = PROFILE_POWER_BATCH_ADVANCED,
	batch         = PROFILE_POWER_ADVANCED,
	parallel      = PROFILE_POWER_BASIC,
}





-- =============================
-- =============================
-- ======= 1/ Public API =======
-- =============================
-- =============================

--- Creates and returns a model-switcher instance bound to the given context.
--- @param ctx table Context with fields:
---   state         table    Shared preference state.
---   models_mgr    table    Models manager instance.
---   keymap        table    Keymap module (optional).
---   save_prefs    function Persists state to disk.
---   update_menu   function Redraws the tray menu.
--- @return table Instance with fields: switch_model, disable_model, set_llm_profile,
---   apply_recommended_prompt_profile, get_display_model_name, get_model_power_level.
function M.new(ctx)
	local state       = ctx.state
	local models_mgr  = ctx.models_mgr
	local keymap      = ctx.keymap
	local save_prefs  = ctx.save_prefs
	local update_menu = ctx.update_menu
	local profile_mutation_gate = type(ctx.profile_mutation_gate) == "function"
		and ctx.profile_mutation_gate or function() return true end
	local runtime_gate = type(ctx.runtime_gate) == "function"
		and ctx.runtime_gate or function() return true end
	local pause_epoch = type(ctx.pause_epoch) == "function"
		and ctx.pause_epoch or function() return 0 end
	local script_control = type(ctx.script_control) == "table"
		and ctx.script_control or nil
	local prediction_locks = type(ctx.prediction_locks) == "table"
		and ctx.prediction_locks or PredictionLockRegistry.new({
			state = state,
			keymap = keymap,
		})
	local requirement_owner = nil
	if script_control then
		if type(models_mgr.create_requirement_owner) ~= "function" then
			Logger.error(LOG,
				"Model-switch requirement-owner factory is unavailable.")
		else
			local ok, owner = Logger.callback(LOG,
				"Model-switch requirement-owner creation",
				models_mgr.create_requirement_owner,
				"model_switcher")
			if ok == true and type(owner) == "table" then
				requirement_owner = owner
			else
				Logger.error(LOG,
					"Model-switch requirement-owner creation was refused.")
			end
		end
	end

	-- Monotonically-increasing token so stale async callbacks from a previous
	-- switch attempt are silently discarded when a new switch is initiated.
	local req_token = 0
	-- Model and profile selections are independent user intents. A pending model
	-- may still commit, but its recommendation must not replace a newer explicit
	-- profile transaction that committed while requirements were being checked.
	local profile_intent_generation = 0
	-- A failed compensation must remain owned across user retries. A later model
	-- action is forbidden from publishing over an identity that has not settled.
	local model_recovery_debt = nil
	-- Profile selection crosses a different set of boundaries. Its compensation
	-- remains independently retryable so model actions cannot bury profile drift.
	local profile_recovery_debt = nil
	-- Exact ownership for the temporary MLX prediction lock. The owner survives
	-- an async requirements callback becoming stale at a pause boundary; only the
	-- registered pause owner may then restore it, and it does so at most once.
	local prediction_lock = nil
	local prediction_lock_id = {}
	local pause_lock_snapshot = nil
	local pause_owner_registered = script_control == nil
	-- Port changes use the same exact native-task capability as model switches,
	-- but unlike an ordinary switch their committed restart intent must survive a
	-- pause.  The opaque identity and replay stage below keep that intent fenced
	-- until ScriptControl has published the matching RESUME epoch.
	local requirement_intent_serial = 0
	local requirement_intent = nil
	local requirement_replay_stage = nil
	local pause_requirement_intent = function() return true end
	local resume_requirement_intent = function() return true end
	local supersede_requirement_intent = function() return true end
	local dispatch_resumable_requirements
	local model_boundary_depth = 0
	local model_internal_capability = {}
	-- This narrower token may settle recovery through ProfilesManager while an
	-- opaque model boundary is active, but cannot authorize an identity mutation.
	local profile_gate_recovery_capability = {}

	local function run_model_boundary(label, callback, ...)
		if type(callback) ~= "function" then
			Logger.error(LOG, "Model-switch boundary '%s' is unavailable.", tostring(label))
			return false, nil
		end
		local args = table.pack(...)
		model_boundary_depth = model_boundary_depth + 1
		local guarded, ok, result = xpcall(function()
			return Logger.callback(LOG, label, callback,
				table.unpack(args, 1, args.n))
		end, debug.traceback)
		model_boundary_depth = math.max(0, model_boundary_depth - 1)
		if not guarded then
			Logger.error(LOG, "Model-switch boundary '%s' escaped its guard: %s.",
				tostring(label), tostring(ok))
			return false, ok
		end
		return ok, result
	end

	local function call_model_boundary(label, callback, ...)
		if type(callback) ~= "function" then
			Logger.error(LOG, "Model-switch boundary '%s' is unavailable.", tostring(label))
			return false
		end
		local ok, result = run_model_boundary(label, callback, ...)
		return ok == true and result ~= false
	end

	local function call_model_commit_boundary(label, callback, ...)
		if type(callback) ~= "function" then
			Logger.error(LOG, "Model commit boundary '%s' is unavailable.", tostring(label))
			return false
		end
		local ok, result = run_model_boundary(label, callback, ...)
		return ok == true and result == true
	end

	local function runtime_available(label)
		local ok, available = run_model_boundary(label, runtime_gate)
		return ok == true and available == true
	end

	--- Acquires this switcher's lease in the shared startup/model registry. The
	--- local marker is published first so mutate-then-false/throw remains owned.
	--- @param force boolean|nil Reacquire a lock while rolling a failed resume back.
	--- @return boolean committed
	local function acquire_prediction_lock(force)
		if force == true then
			prediction_lock = prediction_lock_id
			return prediction_locks.ensure_locked(prediction_lock_id) == true
		end
		if state.llm_enabled ~= true then return true end
		if state.llm_backend ~= "mlx" then return true end
		prediction_lock = prediction_lock_id
		if prediction_locks.acquire(prediction_lock_id) ~= true then
			Logger.error(LOG,
				"MLX prediction lock was refused; exact recovery ownership retained.")
			return false
		end
		Logger.debug(LOG, "MLX model switch: predictions locked during server restart.")
		return true
	end

	--- Restores one retained prediction lock. A failed setter keeps the exact
	--- owner for retry; a disabled live preference consumes the owner without
	--- resurrecting predictions.
	--- @param allow_paused boolean|nil True only for the pause-owner resume step.
	--- @return boolean settled
	local function restore_prediction_lock(allow_paused)
		local owner = prediction_lock
		if owner == nil then return true end
		if allow_paused ~= true then
			local gate_ok, runtime_available = Logger.callback(LOG,
				"MLX model-switch runtime gate", runtime_gate)
			if not gate_ok or runtime_available ~= true then return false end
		end
		if prediction_locks.release(prediction_lock_id) ~= true then
			Logger.error(LOG,
				"MLX prediction unlock was refused; exact owner retained for retry.")
			return false
		end
		if prediction_lock == owner then prediction_lock = nil end
		Logger.debug(LOG, "MLX model switch: predictions unlocked.")
		return true
	end

	--- Fences and joins the real MLX import probe owned below caller callbacks.
	--- @return boolean settled True only after every exact task completed.
	local function pause_requirement_tasks()
		if type(models_mgr.pause_requirements) ~= "function" then
			Logger.error(LOG,
				"Model-switch requirement pause primitive is unavailable.")
			return false
		end
		local ok, result = Logger.callback(LOG,
			"Model-switch requirement-task pause",
			models_mgr.pause_requirements,
			requirement_owner)
		return ok == true and result == true
	end

	local model_pause_owner = {
		pause = function()
			local epoch = pause_epoch()
			if not pause_lock_snapshot or pause_lock_snapshot.epoch ~= epoch then
				pause_lock_snapshot = {
					epoch = epoch,
					had_lock = prediction_lock ~= nil,
				}
			end
			-- Fence both manager callbacks already dispatched and callbacks queued
			-- by the host before ScriptControl can quiesce the remaining owners.
			local replay_settled = pause_requirement_intent()
			req_token = req_token + 1
			local requirements_settled = pause_requirement_tasks()
			local prediction_settled = true
			if pause_lock_snapshot.had_lock then
				prediction_settled = acquire_prediction_lock(true)
			end
			return replay_settled == true
				and requirements_settled == true
				and prediction_settled == true
		end,
		resume = function()
			local prediction_settled = true
			if pause_lock_snapshot then
				-- A later rollback pause occurs in this same resume epoch and must
				-- reuse the original had-lock snapshot rather than invent a new one.
				pause_lock_snapshot.epoch = pause_epoch()
				if pause_lock_snapshot.had_lock then
					prediction_settled = restore_prediction_lock(true)
				end
			end
			local replay_settled = resume_requirement_intent()
			return prediction_settled == true and replay_settled == true
		end,
	}


	-- =====================================================
	-- ===== 1.1) Model parameter helpers =====
	-- =====================================================

	--- Extracts and normalises the effective parameter counts from a model info table.
	--- @param info table Model info dict (params, params_total, params_active, is_moe).
	--- @return number effective_params  Active params (or total when not MoE).
	--- @return boolean is_moe           True when the topology is Mixture-of-Experts.
	--- @return number active_params     Raw active parameter count.
	--- @return number total_params      Raw total parameter count.
	local function get_effective_model_params(info)
		if type(info) ~= "table" then return 0, false, 0, 0 end
		local total_params  = tonumber(info.params_total) or tonumber(info.params) or 0
		local active_params = tonumber(info.params_active) or total_params
		if active_params <= 0 then active_params = total_params end
		local is_moe = info.is_moe == true
			or (total_params > 0 and active_params > 0 and active_params < total_params)
		local effective_params = is_moe and active_params or total_params
		return effective_params, is_moe, active_params, total_params
	end

	--- Builds a set of lowercased model names from the preset tree.
	--- @param presets table Preset tree (array of providers).
	--- @return table Set keyed by lowercased name.
	local function build_model_name_set(presets)
		local names = {}
		if type(presets) ~= "table" then return names end
		for _, provider in ipairs(presets) do
			for _, family in ipairs(provider.families or {}) do
				for _, m in ipairs(family.models or {}) do
					local n = m and m.name
					if type(n) == "string" and n ~= "" then names[n:lower()] = true end
				end
			end
		end
		return names
	end

	--- Infers whether a model is a completion model by checking for -it / -base suffixes
	--- relative to counterpart names that exist in the preset tree.
	--- Returns true (instruction-tuned/chat), false (base/completion), or nil (unknown).
	--- @param model_name string Model display name.
	--- @return boolean|nil
	local function infer_completion_from_name_pairs(model_name)
		if type(model_name) ~= "string" or model_name == "" then return nil end
		local presets = models_mgr.get_presets()
		local names   = build_model_name_set(presets)
		local name_l  = model_name:lower()
		local base_no_it = name_l:gsub("[-_]it$", "")
		if base_no_it ~= name_l and names[base_no_it] then return false end
		if names[name_l .. "-it"] or names[name_l .. "_it"] then return true end
		local base_no_base = name_l:gsub("[-_]base$", "")
		if base_no_base ~= name_l and names[base_no_base] then return true end
		if names[name_l .. "-base"] or names[name_l .. "_base"] then return false end
		return nil
	end

	--- Maps the legacy/aliased profile id to its canonical power-level key.
	--- @param profile_id string Raw profile id from state.
	--- @return string Canonical key suitable for PROFILE_POWER_LEVELS lookup.
	local function normalize_profile_power_key(profile_id)
		if type(profile_id) ~= "string" then return "basic" end
		if profile_id == "raw" or profile_id == "base_completion" then return "raw" end
		if profile_id == "basic" then return "basic" end
		if profile_id == "advanced" then return "advanced" end
		if profile_id == "batch_advanced" then return "batch_advanced" end
		if profile_id:match("^batch_") or profile_id == "batch" then return "batch" end
		if profile_id:match("^parallel_") or profile_id == "parallel" then return "parallel" end
		return "basic"
	end

	--- Returns the currently active profile id, collapsing legacy aliases.
	--- @return string Normalised profile id.
	local function get_normalized_active_profile_id()
		local pid = state.llm_active_profile or "basic"
		if pid == "parallel" or pid == "parallel_simple" then return "basic" end
		if pid == "batch"    or pid == "batch_simple"    then return "batch_advanced" end
		if pid == "parallel_advanced" then return "advanced" end
		if pid == "base_completion"   then return "raw" end
		return pid
	end


	-- =====================================================
	-- ===== 1.2) Power level & profile recommendation =====
	-- =====================================================

	--- Computes the numeric power level for a model.
	--- @param model_name string Model display name.
	--- @return number Power level constant.
	local function get_model_power_level(model_name)
		if type(model_name) ~= "string" or model_name == "" then return PROFILE_POWER_BASIC end
		local info              = models_mgr.get_model_info(model_name) or {}
		local effective_params  = (get_effective_model_params(info))
		local inferred          = infer_completion_from_name_pairs(model_name)
		local is_completion     = (inferred ~= nil) and inferred or (info.type == "completion")
		if is_completion then return PROFILE_POWER_RAW end
		if effective_params >= MODEL_BATCH_PARAMS_THRESHOLD_B    then return PROFILE_POWER_BATCH_ADVANCED end
		if effective_params >= MODEL_ADVANCED_PARAMS_THRESHOLD_B then return PROFILE_POWER_ADVANCED end
		return PROFILE_POWER_BASIC
	end

	--- Returns the recommended profile id and its power level for a model.
	--- @param model_name string Model display name.
	--- @return string  rec_profile  Recommended profile id.
	--- @return number  power_level  Numeric power level of that profile.
	local function get_recommended_profile_info(model_name)
		if type(model_name) ~= "string" or model_name == "" then
			return "basic", PROFILE_POWER_BASIC
		end
		local info             = models_mgr.get_model_info(model_name) or {}
		local effective_params = (get_effective_model_params(info))
		local inferred         = infer_completion_from_name_pairs(model_name)
		local is_completion    = (inferred ~= nil) and inferred or (info.type == "completion")
		local rec = "basic"
		if is_completion then
			rec = "raw"
		elseif effective_params >= MODEL_BATCH_PARAMS_THRESHOLD_B then
			rec = "batch_advanced"
		elseif effective_params >= MODEL_ADVANCED_PARAMS_THRESHOLD_B then
			rec = "advanced"
		end
		return rec, PROFILE_POWER_LEVELS[rec] or PROFILE_POWER_BASIC
	end

	--- Returns the i18n-localised label for a profile id.
	--- @param profile_id string Profile id.
	--- @return string Human-readable label.
	local function get_profile_label(profile_id)
		local n = tonumber(state.llm_num_predictions) or llm_mod.DEFAULT_STATE.llm_num_predictions
		local labels = {
			raw              = i18n.get("llm.profile.raw.label"),
			basic            = i18n.get("llm.profile.basic.label"),
			advanced         = i18n.get("llm.profile.advanced.label"),
			batch_advanced   = ProfileLabel.format(i18n.get("llm.profile.batch_advanced.label"), n),
			parallel_simple  = i18n.get("llm.profile.basic.label"),
			parallel         = i18n.get("llm.profile.basic.label"),
			batch_simple     = i18n.get("llm.profile.basic.label"),
			batch            = ProfileLabel.format(i18n.get("llm.profile.batch_advanced.label"), n),
			parallel_advanced = i18n.get("llm.profile.advanced.label"),
			base_completion  = i18n.get("llm.profile.raw.label"),
		}
		return labels[profile_id] or tostring(profile_id)
	end


	-- =====================================================
	-- ===== 1.3) Display name resolution =====
	-- =====================================================

	--- Resolves a backend-native model name to its human-readable display name.
	--- @param model_name string Backend model name or display name.
	--- @param preset_list table|nil Optional pre-fetched preset tree.
	--- @return string Display name (falls back to model_name on no match).
	local function get_display_model_name(model_name, preset_list)
		if type(model_name) ~= "string" or model_name == "" then return model_name end
		preset_list = type(preset_list) == "table" and preset_list or models_mgr.get_presets()
		if type(preset_list) ~= "table" then return model_name end
		for _, provider in ipairs(preset_list) do
			for _, family in ipairs(provider.families or {}) do
				for _, m in ipairs(family.models or {}) do
					local dn = m.name or m.repo
					if type(dn) == "string" then
						if dn == model_name then return dn end
						if models_mgr.get_actual_model_name(dn) == model_name then return dn end
					end
				end
			end
		end
		return model_name
	end


	-- =====================================================
	-- ===== 1.4) Guarded requirements check =====
	-- =====================================================

	--- Wraps models_mgr.check_requirements with a generation counter so stale
	--- callbacks from superseded switch attempts are silently discarded.
	--- @param model_name string Model to check.
	--- @param on_ok function Callback when requirements are satisfied.
	--- @param on_fail function Callback when requirements cannot be met.
	--- @param opts table|nil Options forwarded to check_requirements.
	--- @param on_stale function|nil Callback receiving the invalidation reason.
	local function guarded_check_requirements(model_name, on_ok, on_fail, opts, on_stale)
		req_token = req_token + 1
		local my_token = req_token
		local request_backend = state.llm_backend
		local request_pause_epoch = pause_epoch()
		local terminal_sent = false
		local function stale_reason()
			if state.llm_backend ~= request_backend then return "backend" end
			if my_token ~= req_token then return "request" end
			if pause_epoch() ~= request_pause_epoch then return "pause_epoch" end
			if runtime_gate() ~= true then return "paused" end
			return nil
		end
		local guarded_opts = {}
		for key, value in pairs(type(opts) == "table" and opts or {}) do
			guarded_opts[key] = value
		end
		if requirement_owner ~= nil then
			guarded_opts.requirement_owner = requirement_owner
		end
		guarded_opts.is_current = function()
			return stale_reason() == nil
		end
		local function settle_requirements(callback, label, ...)
			if terminal_sent then return false end
			terminal_sent = true
			if type(callback) ~= "function" then return true end
			local ok, result = Logger.callback(LOG, label, callback, ...)
			return ok == true and result == true
		end
		local dispatch_in_progress = true
		local buffered_terminal = nil
		local function deliver_ok(...)
			local reason = stale_reason()
			if reason then
				Logger.debug(LOG, string.format(
					"Stale ok-callback discarded (reason=%s, model=%s, backend=%s, current_backend=%s).",
					tostring(reason), tostring(model_name), tostring(request_backend),
					tostring(state.llm_backend)))
				if type(on_stale) == "function" then
					return settle_requirements(on_stale,
						"Stale model-success continuation", reason)
				end
				terminal_sent = true
				return false
			end
			return settle_requirements(on_ok,
				"Model requirements success continuation", ...)
		end
		local function deliver_fail(...)
			local reason = stale_reason()
			if reason then
				Logger.debug(LOG, string.format(
					"Stale fail-callback discarded (reason=%s, model=%s, backend=%s, current_backend=%s).",
					tostring(reason), tostring(model_name), tostring(request_backend),
					tostring(state.llm_backend)))
				if type(on_stale) == "function" then
					return settle_requirements(on_stale,
						"Stale model-failure continuation", reason)
				end
				terminal_sent = true
				return false
			end
			return settle_requirements(on_fail,
				"Model requirements failure continuation", ...)
		end
		local check_ok, accepted = Logger.callback(LOG, "Model requirements dispatch",
			models_mgr.check_requirements, model_name,
			function(...)
				if dispatch_in_progress then
					if buffered_terminal ~= nil then return false end
					buffered_terminal = { kind = "ok", args = table.pack(...) }
					return true
				end
				return deliver_ok(...)
			end,
			function(...)
				if dispatch_in_progress then
					if buffered_terminal ~= nil then return false end
					buffered_terminal = { kind = "fail", args = table.pack(...) }
					return true
				end
				return deliver_fail(...)
			end,
			guarded_opts)
		dispatch_in_progress = false
		if not check_ok or accepted ~= true then
			buffered_terminal = nil
			settle_requirements(on_fail, "Model requirements dispatch failure")
			return false
		end
		if buffered_terminal ~= nil then
			local terminal = buffered_terminal
			buffered_terminal = nil
			if terminal.kind == "ok" then
				return deliver_ok(table.unpack(terminal.args, 1, terminal.args.n)) == true
			end
			return deliver_fail(table.unpack(terminal.args, 1, terminal.args.n)) == true
		end
		return true
	end

	-- =====================================================
	-- ===== 1.4.1) Resumable requirement intents =========
	-- =====================================================

	--- Reads ScriptControl's published state without treating nil as ACTIVE.
	--- @return boolean readable
	--- @return boolean|nil paused
	local function read_published_pause_state()
		if not script_control or type(script_control.is_paused) ~= "function" then
			return false, nil
		end
		local ok, paused = Logger.callback(LOG,
			"Model-switch published pause state", script_control.is_paused)
		if ok ~= true or type(paused) ~= "boolean" then return false, nil end
		return true, paused
	end

	--- Returns whether one replay stage still owns a native timer capability.
	--- @param stage table|nil Replay-stage owner.
	--- @return boolean live
	local function replay_timer_live(stage)
		return type(stage) == "table"
			and type(stage.handle) == "table"
			and stage.handle.timer ~= nil
	end

	--- Delivers one port-restart intent terminal exactly once.
	--- @param intent table Exact intent identity.
	--- @param authorization integer Captured dispatch authorization.
	--- @param callback function|nil User terminal callback.
	--- @param ... any Terminal arguments.
	--- @return boolean settled
	local function settle_requirement_intent(intent, authorization, callback, ...)
		if requirement_intent ~= intent
			or intent.pending ~= true
			or intent.authorization ~= authorization then
			return false
		end
		intent.pending = false
		intent.needs_replay = false
		intent.authorization = intent.authorization + 1
		requirement_intent = nil
		if type(callback) ~= "function" then return true end
		local ok, result = Logger.callback(LOG,
			"Resumable requirement terminal", callback, ...)
		return ok == true and result == true
	end

	local finish_requirement_replay
	local arm_requirement_replay
	local dispatch_requirement_intent

	--- Cancels the exact deferred replay timer. Callback authorization is revoked
	--- before stop(), and a refused stop retains this same stage for retry.
	--- @return boolean settled
	local function cancel_requirement_replay()
		local stage = requirement_replay_stage
		if stage == nil then return true end
		stage.cancelled = true
		if not replay_timer_live(stage) then
			if requirement_replay_stage == stage then requirement_replay_stage = nil end
			return true
		end
		if type(TimerScheduler.cancel) ~= "function" then
			Logger.error(LOG,
				"Requirement replay timer cannot be cancelled; exact stage retained.")
			return false
		end
		local ok, settled = Logger.callback(LOG,
			"Requirement replay timer cancellation",
			TimerScheduler.cancel, stage.handle)
		if not replay_timer_live(stage)
			and requirement_replay_stage == stage then
			requirement_replay_stage = nil
		end
		return ok == true and settled == true and not replay_timer_live(stage)
	end

	--- Finishes one deferred replay only after its timer handle is proven gone.
	--- A zero-delay callback that runs before ScriptControl publishes RESUMED is
	--- re-staged under the same intent/epoch rather than opening runtime early.
	--- @param stage table Exact replay-stage identity.
	--- @return boolean settled
	finish_requirement_replay = function(stage)
		if requirement_replay_stage ~= stage then return true end
		if replay_timer_live(stage) then
			if stage.settlement_observer_registered ~= true then
				if type(TimerScheduler.onSettled) ~= "function" then
					Logger.error(LOG,
						"Requirement replay timer settlement observer is unavailable.")
					return false
				end
				stage.settlement_observer_registered = true
				local ok, registered = Logger.callback(LOG,
					"Requirement replay timer settlement observer",
					TimerScheduler.onSettled, stage.handle, function()
						stage.settlement_observer_registered = false
						finish_requirement_replay(stage)
					end)
				if ok ~= true or registered ~= true then
					stage.settlement_observer_registered = false
					return false
				end
			end
			return false
		end

		requirement_replay_stage = nil
		if stage.cancelled == true then return true end
		local intent = stage.intent
		if requirement_intent ~= intent
			or intent.pending ~= true
			or intent.needs_replay ~= true
			or intent.authorization ~= stage.authorization
			or pause_epoch() ~= stage.epoch then
			return true
		end
		local pause_ok, paused = read_published_pause_state()
		if pause_ok ~= true then return false end
		if paused == true or not runtime_available(
			"Requirement replay runtime gate") then
			return arm_requirement_replay(intent, stage.epoch)
		end
		return dispatch_requirement_intent(intent)
	end

	--- Arms one exact zero-delay stage for the committed RESUME epoch.
	--- @param intent table Exact resumable intent.
	--- @param epoch integer Captured ScriptControl epoch.
	--- @return boolean committed
	arm_requirement_replay = function(intent, epoch)
		if cancel_requirement_replay() ~= true then return false end
		if requirement_intent ~= intent
			or intent.pending ~= true
			or intent.needs_replay ~= true then
			return false
		end
		if type(TimerScheduler.after) ~= "function" then
			Logger.error(LOG, "Requirement replay scheduler is unavailable.")
			return false
		end
		local stage = {
			intent = intent,
			epoch = epoch,
			authorization = intent.authorization,
			cancelled = false,
			handle = nil,
			settlement_observer_registered = false,
		}
		requirement_replay_stage = stage
		local callback_during_acquisition = false
		local acquiring = true
		local ok, handle, committed = Logger.callback(LOG,
			"Requirement replay timer acquisition",
			TimerScheduler.after, 0, function()
				if acquiring then
					callback_during_acquisition = true
					return
				end
				finish_requirement_replay(stage)
			end)
		acquiring = false
		stage.handle = handle
		if ok == true and type(handle) == "table"
			and committed == true and callback_during_acquisition ~= true
			and replay_timer_live(stage) then
			return true
		end
		stage.cancelled = true
		cancel_requirement_replay()
		Logger.error(LOG,
			"Requirement replay timer acquisition was refused; exact cleanup retained.")
		return false
	end

	--- Dispatches one captured intent through the ordinary guarded manager path.
	--- Its model/backend/authorization tuple must still be exact at dispatch and
	--- terminal time; pause revocation therefore cannot be mistaken for success.
	--- @param intent table Exact resumable intent.
	--- @return boolean accepted
	dispatch_requirement_intent = function(intent)
		if requirement_intent ~= intent or intent.pending ~= true then return false end
		if state.llm_backend ~= intent.backend or state.llm_model ~= intent.model then
			return settle_requirement_intent(intent, intent.authorization,
				intent.on_cancel, "identity_changed")
		end
		if not runtime_available("Resumable requirement dispatch runtime gate") then
			return false
		end
		intent.needs_replay = false
		intent.authorization = intent.authorization + 1
		local authorization = intent.authorization
		local accepted = guarded_check_requirements(intent.model, function(...)
			return settle_requirement_intent(intent, authorization,
				intent.on_success, ...)
		end, function(...)
			return settle_requirement_intent(intent, authorization,
				intent.on_cancel, ...)
		end, intent.opts, function(reason)
			if requirement_intent ~= intent
				or intent.pending ~= true
				or intent.authorization ~= authorization then
				return false
			end
			if intent.needs_replay == true then return true end
			return settle_requirement_intent(intent, authorization,
				intent.on_cancel, reason)
		end)
		if accepted ~= true and requirement_intent == intent
			and intent.pending == true
			and intent.authorization == authorization then
			settle_requirement_intent(intent, authorization,
				intent.on_cancel, "dispatch_refused")
		end
		return accepted == true
	end

	--- Fences a replayable intent before the manager joins its exact native task.
	--- @return boolean settled True only when the old replay timer is gone.
	pause_requirement_intent = function()
		local replay_settled = cancel_requirement_replay()
		local intent = requirement_intent
		if intent ~= nil and intent.pending == true then
			intent.needs_replay = true
			intent.authorization = intent.authorization + 1
		end
		return replay_settled == true
	end

	--- Replays only from a committed PAUSED state. During failed-PAUSE rollback
	--- the published bit is still ACTIVE; returning false preserves the rollback
	--- debt instead of claiming that the fenced port restart was restored.
	--- @return boolean committed
	resume_requirement_intent = function()
		local intent = requirement_intent
		if intent == nil or intent.pending ~= true
			or intent.needs_replay ~= true then
			return true
		end
		if state.llm_backend ~= intent.backend or state.llm_model ~= intent.model then
			return settle_requirement_intent(intent, intent.authorization,
				intent.on_cancel, "identity_changed")
		end
		local pause_ok, paused = read_published_pause_state()
		if pause_ok ~= true or paused ~= true then
			Logger.error(LOG,
				"Requirement replay retained until an exact PAUSED-to-RESUMED transaction.")
			return false
		end
		return arm_requirement_replay(intent, pause_epoch())
	end

	--- Supersedes one logical port restart while leaving its already-dispatched
	--- native task fenced by guarded_check_requirements' next generation.
	--- @param reason string Cancellation reason for the old caller.
	--- @return boolean settled
	supersede_requirement_intent = function(reason)
		if cancel_requirement_replay() ~= true then return false end
		local intent = requirement_intent
		if intent == nil or intent.pending ~= true then return true end
		-- Fence the already-dispatched manager freshness closure before publishing
		-- logical supersession. Otherwise its native terminal could still enter
		-- do_check()/start_server even though this intent callback was discarded.
		req_token = req_token + 1
		return settle_requirement_intent(intent, intent.authorization,
			intent.on_cancel, reason or "superseded")
	end

	--- Starts a requirements check whose exact identity is replayed after RESUME.
	--- Used by the MLX port transition: the port has already committed when its
	--- server restart dispatches, so PAUSE must park rather than discard it.
	--- @param model_name string Captured display-model identity.
	--- @param on_ok function|nil Success terminal.
	--- @param on_fail function|nil Failure terminal.
	--- @param opts table|nil Manager options, including the captured `_mlx_port`.
	--- @return boolean accepted
	dispatch_resumable_requirements = function(model_name, on_ok, on_fail, opts)
		if requirement_owner == nil or pause_owner_registered ~= true then
			Logger.error(LOG,
				"Resumable requirements refused without an exact registered owner.")
			return false
		end
		if type(model_name) ~= "string" or model_name == "" then return false end
		if supersede_requirement_intent("superseded") ~= true then return false end
		local forwarded_opts = {}
		for key, value in pairs(type(opts) == "table" and opts or {}) do
			forwarded_opts[key] = value
		end
		requirement_intent_serial = requirement_intent_serial + 1
		local intent = {
			id = requirement_intent_serial,
			model = model_name,
			backend = state.llm_backend,
			opts = forwarded_opts,
			on_success = on_ok,
			on_cancel = on_fail,
			pending = true,
			needs_replay = false,
			authorization = 0,
		}
		requirement_intent = intent
		local pause_ok, paused = read_published_pause_state()
		if pause_ok == true and paused == true then
			intent.needs_replay = true
			intent.authorization = intent.authorization + 1
			return true
		end
		if not runtime_available("Resumable requirement preflight runtime gate") then
			settle_requirement_intent(intent, intent.authorization,
				intent.on_cancel, "runtime_unavailable")
			return false
		end
		return dispatch_requirement_intent(intent)
	end


	-- =====================================================
	-- ===== 1.5) Profile management =====
	-- =====================================================
	local set_llm_profile
	local settle_recovery_debts

	--- Settles every ProfilesManager registry owner before an identity-facing result,
	--- including voluntary recommendation no-ops that never reach set_llm_profile.
	--- @param action_label string Human-readable action for refusal logging.
	--- @return boolean settled
	local function settle_profile_mutation_gate(action_label)
		-- The gate is an opaque recovery callback and may synchronously invoke a
		-- sibling selection before its predecessor resumes. Publish the same
		-- boundary marker used by runtime/persistence callbacks before entering it.
		local gate_ok, gate_result = run_model_boundary(
			"Profile mutation recovery gate",
			profile_mutation_gate,
			profile_gate_recovery_capability)
		if not gate_ok or gate_result ~= true then
			Logger.error(LOG, "%s refused while a profile registry rollback remains unsettled.",
				action_label)
			return false
		end
		return true
	end

	--- Warns when the selected profile demands significantly more than the model can give.
	--- @param selected_profile_id string Profile the user just activated.
	--- @param model_name string Currently active model.
	local function check_profile_power_mismatch(selected_profile_id, model_name)
		local model_power    = tonumber(state.llm_model_power) or PROFILE_POWER_BASIC
		local selected_power = PROFILE_POWER_LEVELS[normalize_profile_power_key(selected_profile_id)] or PROFILE_POWER_BASIC
		Logger.debug(LOG, string.format(
			"Profile power check: selected=%d vs model=%d.", selected_power, model_power))
		-- One level of mismatch is tolerated (user may intentionally experiment)
		if selected_power > model_power + 1 then
			local rec_profile, _ = get_recommended_profile_info(model_name)
			local msg = string.format(
				i18n.get("menu.llm.profile_power_warning"),
				get_profile_label(rec_profile),
				get_profile_label(selected_profile_id))
			Logger.callback(LOG, "Profile power warning notification",
				notifications.notify, msg, nil, "warning")
		end
	end

	--- Offers to switch to the recommended profile when it differs from the current one.
	--- Completion models are switched silently; chat models prompt the user.
	--- @param model_name string The newly selected model name.
	--- @param opts table|nil Optional { dialog_title, force_dialog, record_intent }.
	--- @return boolean settled True only for a committed recommendation or voluntary no-op.
	local function apply_recommended_prompt_profile(model_name, opts)
		opts = type(opts) == "table" and opts or {}
		if not settle_profile_mutation_gate("Recommended profile follow-up") then
			return false
		end
		if type(model_name) ~= "string" or model_name == "" then
			Logger.warn(LOG, "Cannot recommend a profile because no model is active.")
			Logger.callback(LOG, "Recommended-profile unavailable notification",
				notifications.notify,
				i18n.get("menu.profiles.recommended_unavailable_title"),
				i18n.get("menu.profiles.recommended_unavailable_body"),
				"warning")
			return false
		end
		if type(settle_recovery_debts) ~= "function" then
			Logger.error(LOG, "Cannot recommend a profile: recovery owner unavailable.")
			return false
		end
		if not settle_recovery_debts(opts._model_internal_capability) then return false end

		local rec_profile, _   = get_recommended_profile_info(model_name)
		local rec_label        = get_profile_label(rec_profile)
		local model_info       = models_mgr.get_model_info(model_name) or {}
		local inferred         = infer_completion_from_name_pairs(model_name)
		local is_completion    = (inferred ~= nil) and inferred or (model_info.type == "completion")
		local _, is_moe, active_params, total_params = get_effective_model_params(model_info)
		local display_name     = get_display_model_name(model_name)

		-- Build a human-readable power description for the dialog body
		local power_desc
		if is_completion then
			power_desc = i18n.get("menu.llm.power_completion")
		elseif is_moe and active_params > 0 and total_params > 0 then
			power_desc = string.format(i18n.get("menu.llm.power_moe"), active_params, total_params)
		elseif active_params > 0 then
			power_desc = string.format(i18n.get("menu.llm.power_dense"), active_params)
		else
			power_desc = i18n.get("menu.llm.power_unknown")
		end

		local cur_profile = get_normalized_active_profile_id()
		local cur_label   = get_profile_label(cur_profile)
		Logger.debug(LOG, string.format("Recommended profile: %s (currently: %s).", rec_profile, cur_profile))
		local function commit_recommendation(profile_id)
			if type(set_llm_profile) ~= "function" then
				Logger.error(LOG, "Cannot apply the recommended profile: transaction owner unavailable.")
				return false
			end
			return set_llm_profile(profile_id, {
				record_intent = opts.record_intent ~= false,
				_model_internal_capability = opts._model_internal_capability,
			})
		end
		local function ask_user(title, message)
			local ok, choice = Logger.callback(LOG, "Recommended-profile dialog",
				dialog.block_alert,
				title, message,
				i18n.get("button.confirm"), i18n.get("button.cancel"), "informational")
			Logger.debug(LOG, string.format("Dialog response: ok=%s, choice=%s.",
				tostring(ok), tostring(choice)))
			if not ok then return false, false end
			if choice == i18n.get("button.confirm") then return true, true end
			if choice == i18n.get("button.cancel") then return true, false end
			Logger.error(LOG, "Recommended-profile dialog returned an unexpected choice: %s.",
				tostring(choice))
			return false, false
		end

		if cur_profile ~= rec_profile then
			if is_completion then
				-- Completion models have exactly one correct profile — switch silently.
				Logger.info(LOG, string.format(
					"Completion model: silently switching profile %s → %s.", cur_profile, rec_profile))
				return commit_recommendation(rec_profile)
			else
				local title = type(opts.dialog_title) == "string"
					and opts.dialog_title
					or  i18n.get("menu.llm.model_change_title")
				Logger.debug(LOG, "Displaying profile suggestion dialog…")
				local msg = string.format(
					i18n.get("menu.llm.profile_change_msg"),
					display_name, power_desc, cur_label, rec_label)
				local dialog_ok, accepted = ask_user(title, msg)
				if not dialog_ok then return false end
				if accepted then
					Logger.info(LOG, string.format("Profile changed to %s (accepted).", rec_profile))
					return commit_recommendation(rec_profile)
				else
					-- User refused — the profile is already cur_profile; no setter call
					-- or save needed. Re-applying set_active_profile without persisting
					-- left LLM internal state out of sync with disk (ui-menu-llm-core-5).
					Logger.info(LOG, string.format("Profile kept at %s (refused).", cur_profile))
				end
			end
		elseif opts.force_dialog then
			local title = type(opts.dialog_title) == "string"
				and opts.dialog_title
				or  i18n.get("menu.llm.profile_recommended_title")
			local msg = string.format(
				i18n.get("menu.llm.profile_already_ok_msg"),
				display_name, power_desc, cur_label, rec_label)
			local dialog_ok, accepted = ask_user(title, msg)
			if not dialog_ok then return false end
			if accepted then return commit_recommendation(cur_profile) end
			return true
		else
			Logger.debug(LOG, "Recommended profile already active — no action needed.")
		end
		return true
	end

	local function snapshot_model_transition()
		local ok, actual_name = run_model_boundary(
			"Previous model identity resolution",
			models_mgr.get_actual_model_name,
			state.llm_model)
		if not ok or type(actual_name) ~= "string" then
			Logger.error(LOG, "Cannot snapshot the current model identity for rollback.")
			return nil
		end
		return {
			backend = state.llm_backend,
			model = state.llm_model,
			model_power = state.llm_model_power,
			model_mlx = state.llm_model_mlx,
			model_ollama = state.llm_model_ollama,
			active_profile = state.llm_active_profile,
			actual_name = actual_name,
		}
	end

	local function restore_model_transition(debt)
		local snapshot = debt.snapshot
		state.llm_model = snapshot.model
		state.llm_model_power = snapshot.model_power
		state.llm_model_mlx = snapshot.model_mlx
		state.llm_model_ollama = snapshot.model_ollama
		state.llm_active_profile = snapshot.active_profile

		local failures = {}
		local function restore_boundary(field, label, callback, exact, ...)
			if debt[field] ~= true then return end
			local boundary = exact == true
				and call_model_commit_boundary or call_model_boundary
			if boundary(label, callback, ...) then
				debt[field] = false
			else
				failures[#failures + 1] = label
			end
		end

		restore_boundary("runtime_model", "Model-switch runtime rollback",
			keymap and keymap.set_llm_model, true, snapshot.actual_name)
		restore_boundary("display_model", "Model-switch display rollback",
			keymap and keymap.set_llm_display_model_name, false, snapshot.model)
		restore_boundary("profile", "Model-switch profile rollback",
			llm_mod.set_active_profile, true, snapshot.active_profile)

		if debt.persist then
			local ok, saved = run_model_boundary(
				"Model-switch preference rollback", save_prefs)
			if not ok or saved ~= true then
				failures[#failures + 1] = "preference rollback"
			else
				debt.persist = false
			end
		end
		if debt.menu then
			restore_boundary("menu", "Model-switch menu rollback", update_menu, true)
		end

		if #failures > 0 then
			model_recovery_debt = debt
			Logger.error(LOG,
				"Model-switch rollback remains unsettled at: %s.",
				table.concat(failures, ", "))
			return false
		end
		model_recovery_debt = nil
		return true
	end

	local function settle_model_recovery_debt()
		if not model_recovery_debt then return true end
		Logger.warn(LOG, "Retrying retained model-switch rollback before a new action.")
		return restore_model_transition(model_recovery_debt)
	end

	--- Snapshots the independently observable state and runtime profile identities.
	--- @return table|nil snapshot Exact rollback identities, or nil when unavailable.
	local function snapshot_profile_transition()
		if type(llm_mod.get_active_profile) ~= "function" then
			Logger.error(LOG, "Cannot snapshot the active runtime profile for rollback.")
			return nil
		end
		local ok, active_profile = run_model_boundary(
			"Previous runtime profile resolution", llm_mod.get_active_profile)
		if not ok or type(active_profile) ~= "table"
			or type(active_profile.id) ~= "string" then
			Logger.error(LOG, "Cannot resolve the active runtime profile for rollback.")
			return nil
		end
		return {
			state_profile = state.llm_active_profile,
			runtime_profile = active_profile.id,
		}
	end

	--- Restores every profile boundary reached by a rejected transition.
	--- @param debt table Mutable per-boundary compensation ledger.
	--- @return boolean settled True only when every required compensation commits.
	local function restore_profile_transition(debt)
		local snapshot = debt.snapshot
		state.llm_active_profile = snapshot.state_profile

		local failures = {}
		local runtime_failed = false
		local function reassert_runtime(label, retain_for_preference_retry)
			state.llm_active_profile = snapshot.state_profile
			if debt.runtime_touched ~= true then return true end
			if call_model_commit_boundary(label,
				llm_mod.set_active_profile, snapshot.runtime_profile) then
				debt.runtime = retain_for_preference_retry == true
				return true
			end
			debt.runtime = true
			runtime_failed = true
			failures[#failures + 1] = "runtime rollback"
			return false
		end

		if debt.runtime then
			reassert_runtime("Profile-switch runtime rollback", debt.persist == true)
		end
		if debt.persist then
			local ok, saved = run_model_boundary(
				"Profile-switch preference rollback", save_prefs)
			if ok and saved == true then
				debt.persist = false
				-- A successful preference rollback cannot settle a runtime
				-- compensation that was refused earlier in this attempt.
				if debt.runtime_touched == true and not runtime_failed then
					debt.runtime = false
				end
			else
				failures[#failures + 1] = "preference rollback"
				-- PreferencesTransaction can restore the rejected candidate in place.
				-- Reassert both active identities immediately and retain the runtime bit
				-- so the next persistence retry cannot outlive this compensation.
				reassert_runtime("Profile-switch post-preference runtime reassertion", true)
			end
		end
		if debt.menu then
			if call_model_commit_boundary("Profile-switch menu rollback", update_menu) then
				debt.menu = false
			else
				failures[#failures + 1] = "menu rollback"
				reassert_runtime("Profile-switch post-menu runtime reassertion",
					debt.persist == true)
			end
		end

		-- Later reassertions in the same rollback attempt must not absorb an
		-- earlier runtime refusal; keep that exact boundary for the next retry.
		if runtime_failed then debt.runtime = true end
		if #failures > 0 then
			profile_recovery_debt = debt
			Logger.error(LOG,
				"Profile-switch rollback remains unsettled at: %s.",
				table.concat(failures, ", "))
			return false
		end
		profile_recovery_debt = nil
		return true
	end

	--- Retries retained profile compensation before any identity-changing action.
	--- @return boolean settled True when no profile recovery remains.
	local function settle_profile_recovery_debt()
		if not profile_recovery_debt then return true end
		Logger.warn(LOG, "Retrying retained profile-switch rollback before a new action.")
		return restore_profile_transition(profile_recovery_debt)
	end

	--- Settles recovery ledgers in ownership order before a new menu action.
	--- @return boolean settled True when both model and profile identities are stable.
	settle_recovery_debts = function(capability)
		if model_boundary_depth > 0
			and capability ~= model_internal_capability
			and capability ~= profile_gate_recovery_capability then
			Logger.warn(LOG, "Recovery settlement refused inside an active model boundary.")
			return false
		end
		if not settle_model_recovery_debt() then return false end
		return settle_profile_recovery_debt()
	end

	--- Activates a profile and triggers a power-mismatch check.
	--- A direct profile action cannot publish over an unsettled model rollback.
	--- @param profile_id string Profile to activate.
	--- @param opts table|nil Optional transaction controls. `persist = false` and
	---   `update_menu = false` let a parent transaction own those boundaries;
	---   `record_intent = false` is reserved for model-owned recommendations;
	---   `defer_intent = true` returns a parent-owned intent lease as a second value;
	---   `skip_delete_recovery = true` is reserved for Delete compensation itself.
	--- @return boolean committed True only when every boundary owned by this call commits.
	--- @return table|nil intent_lease Parent-owned commit/cancel lease when requested.
	--- @return table|nil recovery_status Exact failed-transition ownership status.
	set_llm_profile = function(profile_id, opts)
		opts = type(opts) == "table" and opts or {}
		local capability = opts._model_internal_capability
		if model_boundary_depth > 0 and capability ~= model_internal_capability then
			Logger.warn(LOG, "Profile switch refused inside an active model boundary.")
			return false
		end
		if type(profile_id) ~= "string" then return false end
		if opts.skip_delete_recovery ~= true
			and not settle_profile_mutation_gate("Profile switch") then
			return false
		end
		if not settle_recovery_debts(capability) then return false end
		local snapshot = snapshot_profile_transition()
		if not snapshot then return false end

		local debt = {
			snapshot = snapshot,
			runtime = false,
			runtime_touched = false,
			persist = false,
			menu = false,
		}
		local function reject_transition(boundary)
			Logger.error(LOG,
				"Profile-switch transition failed at '%s'; restoring the previous profile.",
				tostring(boundary))
			local persistence_touched = debt.persist == true
			local menu_touched = debt.menu == true
			profile_recovery_debt = debt
			local settled = restore_profile_transition(debt)
			return false, nil, {
				recovery_pending = settled ~= true,
				persistence_touched = persistence_touched,
				menu_touched = menu_touched,
			}
		end

		debt.runtime = true
		debt.runtime_touched = true
		if not call_model_commit_boundary("Profile-switch runtime sync",
			llm_mod.set_active_profile, profile_id) then
			return reject_transition("runtime sync")
		end
		state.llm_active_profile = profile_id
		if opts.persist ~= false then
			debt.persist = true
			local save_ok, saved = run_model_boundary(
				"Profile-switch preference save", save_prefs)
			if not save_ok or saved ~= true then
				return reject_transition("preference save")
			end
		end
		if opts.update_menu ~= false then
			debt.menu = true
			if not call_model_commit_boundary("Profile-switch menu refresh", update_menu) then
				return reject_transition("menu refresh")
			end
		end

		profile_recovery_debt = nil
		local intent_lease = nil
		if opts.defer_intent == true then
			local pending = true
			intent_lease = {
				commit = function()
					if pending ~= true then return false end
					pending = false
					profile_intent_generation = profile_intent_generation + 1
					Logger.debug(LOG, "Deferred profile intent committed by its parent transaction.")
					return true
				end,
				cancel = function()
					if pending ~= true then return false end
					pending = false
					Logger.debug(LOG, "Deferred profile intent cancelled by its parent transaction.")
					return true
				end,
			}
		elseif opts.record_intent ~= false then
			profile_intent_generation = profile_intent_generation + 1
		end
		Logger.info(LOG, "Profile successfully switched to %s.", profile_id)
		Logger.callback(LOG, "Profile power mismatch check",
			check_profile_power_mismatch, profile_id, state.llm_model)
		return true, intent_lease
	end


	-- =====================================================
	-- ===== 1.6) Model switch =====
	-- =====================================================

	--- Changes the active model, handling the MLX server restart lock.
	--- Requirements are checked asynchronously; predictions are locked until the
	--- server confirms readiness so the user never fires against a dead port.
	--- @param new_model string Display name of the model to activate.
	local function switch_model(new_model)
		if model_boundary_depth > 0 then
			Logger.warn(LOG, "Model switch refused inside an active model boundary.")
			return false
		end
		Logger.debug(LOG, string.format("Executing switch_model('%s')…", new_model or "nil"))
		if pause_owner_registered ~= true then
			Logger.error(LOG, "Model switch refused because its pause owner is not registered.")
			return false
		end
		if not runtime_available("Model-switch preflight runtime gate") then
			Logger.error(LOG, "Model switch refused while script control is paused.")
			return false
		end
		if not settle_profile_mutation_gate("Model switch") then return false end
		if not settle_recovery_debts() then return false end
		if not supersede_requirement_intent("model_switch") then return false end
		local request_profile_generation = profile_intent_generation

		-- Lock predictions during the MLX server restart — weights take 60–90 s to reload
		if not acquire_prediction_lock(false) then
			restore_prediction_lock(false)
			return false
		end

		return guarded_check_requirements(new_model, function()
			local callback_ok, callback_result = run_model_boundary(
				"Model-switch success callback", function()
				if not settle_profile_mutation_gate("Model switch continuation") then
					return false
				end
				if not settle_recovery_debts(model_internal_capability) then return false end
				local snapshot = snapshot_model_transition()
				if not snapshot then return false end
				if not keymap or type(keymap.set_llm_model) ~= "function"
					or type(keymap.set_llm_display_model_name) ~= "function" then
					Logger.error(LOG, "Cannot switch model: required keymap setters are unavailable.")
					return false
				end

				local actual_ok, actual_name = run_model_boundary(
					"Candidate model identity resolution",
					models_mgr.get_actual_model_name,
					new_model)
				if not actual_ok or type(actual_name) ~= "string" then
					Logger.error(LOG, "Cannot resolve the candidate model identity.")
					return false
				end
				local candidate_power = get_model_power_level(new_model)
				local debt = {
					snapshot = snapshot,
					runtime_model = false,
					display_model = false,
					profile = false,
					persist = false,
					menu = false,
				}
				local function reject_transition(boundary)
					Logger.error(LOG,
						"Model-switch transition failed at '%s'; restoring the previous identity.",
						tostring(boundary))
					model_recovery_debt = debt
					restore_model_transition(debt)
					return false
				end

				debt.runtime_model = true
				if not call_model_commit_boundary("Model-switch runtime model sync",
					keymap.set_llm_model, actual_name) then
					return reject_transition("runtime model")
				end
				debt.display_model = true
				if not call_model_boundary("Model-switch display-model sync",
					keymap.set_llm_display_model_name, new_model) then
					return reject_transition("display model")
				end

				state.llm_model = new_model
				state.llm_model_power = candidate_power
				if snapshot.backend == "mlx" then
					state.llm_model_mlx = new_model
				else
					state.llm_model_ollama = new_model
				end
				debt.persist = true
				local save_ok, saved = run_model_boundary(
					"Model-switch preference save", save_prefs)
				if not save_ok or saved ~= true then
					return reject_transition("preference save")
				end

				if request_profile_generation == profile_intent_generation then
					-- The recommendation helper can mutate profile runtime, persistence,
					-- and menu state. Mark every compensation before entering it.
					debt.profile = true
					debt.menu = true
					local profile_ok, profile_result = Logger.callback(LOG,
						"Model-switch recommended-profile follow-up",
						apply_recommended_prompt_profile,
						new_model,
						{
							dialog_title = i18n.get("menu.llm.model_change_title"),
							record_intent = false,
							_model_internal_capability = model_internal_capability,
						})
					if not profile_ok or profile_result ~= true then
						return reject_transition("profile follow-up")
					end
				else
					Logger.info(LOG,
						"Skipping the automatic profile recommendation for %s because a newer explicit profile committed.",
						new_model)
				end
				debt.menu = true
				if not call_model_commit_boundary("Model-switch menu refresh", update_menu) then
					return reject_transition("menu refresh")
				end

				model_recovery_debt = nil
				Logger.info(LOG, string.format("Model successfully switched to %s.", new_model))
				Logger.debug(LOG, string.format("Model power cached: %d.", state.llm_model_power))
				return true
			end)
			local unlocked = restore_prediction_lock(false)
			if not callback_ok or not unlocked then
				return false
			end
			return callback_result == true
		end, function()
			-- Requirements failed — restore predictions so the user is not left stranded
			Logger.warn(LOG, string.format("switch_model('%s') failed — restoring predictions.", tostring(new_model)))
			return restore_prediction_lock(false)
		end, nil, function(reason)
			-- A superseding model request owns the existing prediction lock. A
			-- backend change does not necessarily launch another model request, so
			-- it must release the lock captured by this abandoned MLX switch.
			if reason == "backend" then return restore_prediction_lock(false) end
			return true
		end)
	end

	--- Commits the explicit "No Model" state to runtime and preferences.
	--- This is a model-identity change, so it also invalidates any pending
	--- requirements callback before clearing the prediction engine model.
	--- @return boolean True only when runtime and persistence both commit.
	local function disable_model()
		if model_boundary_depth > 0 then
			Logger.warn(LOG, "No Model transition refused inside an active model boundary.")
			return false
		end
		if pause_owner_registered ~= true then
			Logger.error(LOG, "No Model transition refused because its pause owner is not registered.")
			return false
		end
		if not runtime_available("No Model preflight runtime gate") then
			Logger.error(LOG, "No Model transition refused while script control is paused.")
			return false
		end
		if not settle_profile_mutation_gate("No Model transition") then return false end
		if not settle_recovery_debts() then return false end
		if not supersede_requirement_intent("model_disabled") then return false end
		req_token = req_token + 1
		if not restore_prediction_lock(false) then return false end
		local snapshot = snapshot_model_transition()
		if not snapshot then return false end

		if not keymap or type(keymap.set_llm_model) ~= "function"
			or type(keymap.set_llm_display_model_name) ~= "function" then
			Logger.error(LOG, "Cannot select No Model: keymap model setters are unavailable.")
			return false
		end

		local debt = {
			snapshot = snapshot,
			runtime_model = false,
			display_model = false,
			profile = false,
			persist = false,
			menu = false,
		}
		local function reject_transition(boundary)
			Logger.error(LOG,
				"No Model transition failed at '%s'; restoring the previous identity.",
				tostring(boundary))
			model_recovery_debt = debt
			restore_model_transition(debt)
			return false
		end

		debt.runtime_model = true
		if not call_model_commit_boundary(
			"No Model runtime update", keymap.set_llm_model, "") then
			return reject_transition("runtime model")
		end
		debt.display_model = true
		if not call_model_boundary("No Model display update",
			keymap.set_llm_display_model_name, "") then
			return reject_transition("display model")
		end

		state.llm_model = ""
		state.llm_model_power = nil
		debt.persist = true
		local save_ok, saved = run_model_boundary(
			"No Model preference commit", save_prefs)
		if not save_ok or saved ~= true then
			return reject_transition("preference commit")
		end

		debt.menu = true
		if not call_model_commit_boundary("No Model menu refresh", update_menu) then
			return reject_transition("menu refresh")
		end

		model_recovery_debt = nil
		Logger.info(LOG, "Model disabled; runtime and preferences now have no active model.")
		return true
	end

	if script_control then
		if requirement_owner == nil then
			Logger.error(LOG,
				"Model switching has no exact requirement-task owner.")
			pause_owner_registered = false
		elseif type(script_control.register_pause_owner) ~= "function" then
			Logger.error(LOG,
				"Script-control pause-owner registration API is unavailable for model switching.")
			pause_owner_registered = false
		else
			local ok, registered = Logger.callback(LOG,
				"Model-switch pause-owner registration",
				script_control.register_pause_owner,
				"llm_model_switcher",
				model_pause_owner)
			pause_owner_registered = ok == true and registered == true
			if not pause_owner_registered then
				Logger.error(LOG, "Model-switch pause-owner registration was refused.")
			end
		end
	end

	return {
		switch_model                      = switch_model,
		disable_model                     = disable_model,
		set_llm_profile                   = set_llm_profile,
		settle_recovery_debts             = settle_recovery_debts,
		apply_recommended_prompt_profile  = apply_recommended_prompt_profile,
		get_display_model_name            = get_display_model_name,
		get_model_power_level             = get_model_power_level,
		guarded_check_requirements        = guarded_check_requirements,
		dispatch_resumable_requirements   = dispatch_resumable_requirements,
	}
end

return M
