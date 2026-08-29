--- modules/llm/dependency_bootstrap_pause_owner.lua

--- ==============================================================================
--- MODULE: Dependency Bootstrap Pause Owner
--- DESCRIPTION:
--- Provides one reusable, backend-local ScriptControl owner for dependency
--- bootstrap work. It fences an accepted bootstrap before resource teardown,
--- waits for exact timer/task joins supplied by the checker, and stages replay
--- until ScriptControl has published RESUMED for the same pause epoch.
---
--- FEATURES & RATIONALE:
--- 1. Fail-closed admission: configured owners reject work throughout PAUSED and
---    every unpublished pause/resume transition.
--- 2. Exact replay identity: only an intent whose acquisition committed is
---    replayed, and only after the same resume epoch becomes publicly active.
--- 3. Transactional staging: the zero-delay resume timer is retained and
---    cancellable, including native start/stop refusal cleanup debt.
--- 4. Backend isolation: every constructed controller registers one fixed owner
---    identifier and has no access to a sibling backend's resources or intent.
--- ==============================================================================

local M = {}

local Logger         = require("infra.logger")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "llm.dependency_bootstrap_pause_owner"





-- =====================================
-- =====================================
-- ======= 1/ Controller Factory =======
-- =====================================
-- =====================================

--- Creates one backend-local dependency-bootstrap pause controller.
--- @param options table Owner name, diagnostic label, quiesce hook, and replay hook.
--- @return table controller Opaque lifecycle controller.
function M.new(options)
	options = options or {}
	local owner_name = options.owner_name
	local label = type(options.label) == "string" and options.label or tostring(owner_name)
	local quiesce = type(options.quiesce) == "function"
		and options.quiesce or function() return true end
	local replay = type(options.replay) == "function"
		and options.replay or function() return true end
	local replay_failure = type(options.replay_failure) == "function"
		and options.replay_failure or function() return false end
	local script_control = nil
	local configuration_attempted = false
	local registered = false
	local current = nil
	local serial = 0
	local resume_stage = nil
	local stage_resume

	--- Reports whether a scheduler handle still owns a native timer candidate.
	--- @param handle table|nil TimerScheduler handle.
	--- @return boolean live
	local function timer_live(handle)
		return type(handle) == "table" and handle.timer ~= nil
	end

	--- Reads the complete ScriptControl admission publication.
	--- Before production configuration, the controller remains usable by isolated
	--- checker tests; a failed configuration attempt permanently fails closed.
	--- @return boolean paused
	--- @return boolean transition_pending
	--- @return integer epoch
	--- @return boolean valid
	local function read_control_state()
		if script_control == nil then
			return false, false, 0, configuration_attempted ~= true
		end
		local paused_ok, paused = xpcall(script_control.is_paused, debug.traceback)
		local transition_ok, transition_pending = xpcall(
			script_control.is_pause_transition_pending, debug.traceback)
		local epoch_ok, epoch = xpcall(script_control.get_pause_epoch, debug.traceback)
		if not paused_ok or type(paused) ~= "boolean"
			or not transition_ok or type(transition_pending) ~= "boolean"
			or not epoch_ok or type(epoch) ~= "number" then
			return true, true, -1, false
		end
		return paused, transition_pending, epoch, true
	end

	--- Returns the active epoch only while new business work may be admitted.
	--- @return integer|nil epoch
	local function admission_epoch()
		if configuration_attempted and registered ~= true then return nil end
		local paused, transition_pending, epoch, valid = read_control_state()
		if valid ~= true or paused == true or transition_pending == true then return nil end
		return epoch
	end

	--- Invokes the checker-owned exact resource join.
	--- @return boolean settled
	local function invoke_quiesce()
		local ok, settled_or_error = xpcall(quiesce, debug.traceback)
		if not ok or settled_or_error ~= true then
			Logger.error(LOG, "%s bootstrap quiescence refused: %s.",
				label, tostring(settled_or_error))
			return false
		end
		return true
	end

	--- Cancels the exact post-resume staging timer.
	--- @return boolean settled
	local function cancel_resume_stage()
		local stage = resume_stage
		if stage == nil then return true end
		stage.cancelled = true
		if stage.acquiring == true then
			stage.cancel_requested = true
			Logger.debug(LOG,
				"%s bootstrap resume-stage cancellation joined acquisition.", label)
			return false
		end
		if not timer_live(stage.handle) then
			if resume_stage == stage then resume_stage = nil end
			return true
		end
		local ok, settled_or_error = xpcall(function()
			return TimerScheduler.cancel(stage.handle)
		end, debug.traceback)
		if not ok or settled_or_error ~= true then
			Logger.error(LOG, "%s bootstrap resume-stage cancellation refused: %s.",
				label, tostring(settled_or_error))
			return false
		end
		if resume_stage == stage then resume_stage = nil end
		return true
	end

	--- Transfers an unreplayable committed intent to its checker terminal owner.
	--- @param token table Exact bootstrap intent token.
	--- @param reason string Stable failure reason.
	--- @return boolean consumed
	local function consume_replay_failure(token, reason)
		if current ~= token then return token.cancelled == true end
		if token.cancelled == true or token.intent_committed ~= true then return false end
		local ok, consumed_or_error = xpcall(function()
			return replay_failure(token, reason)
		end, debug.traceback)
		if not ok or consumed_or_error ~= true then
			Logger.error(LOG, "%s bootstrap replay failure was not consumed: %s.",
				label, tostring(consumed_or_error))
			return false
		end
		token.authorization = token.authorization + 1
		token.authorized = false
		token.paused = true
		token.cancelled = true
		token.intent_committed = false
		token.resume_needed = false
		if current == token then current = nil end
		return true
	end

	--- Re-authorizes and replays one committed intent after exact RESUMED.
	--- @param stage table Settled staging descriptor.
	--- @return boolean replayed
	local function activate_resume(stage)
		local token = stage.token
		if current ~= token or token.cancelled == true
			or token.intent_committed ~= true or token.resume_needed ~= true then
			return false
		end
		token.authorization = token.authorization + 1
		local replay_authorization = token.authorization
		token.authorized = true
		token.paused = false
		token.epoch = stage.epoch
		local ok, replayed_or_error = xpcall(function()
			return replay(token, stage.epoch)
		end, debug.traceback)
		if not ok or replayed_or_error ~= true then
			token.authorization = token.authorization + 1
			token.authorized = false
			token.paused = true
			Logger.error(LOG, "%s bootstrap replay refused: %s.",
				label, tostring(replayed_or_error))
			consume_replay_failure(token, "replay refused")
			return false
		end
		-- Replay may synchronously complete the token or trigger another pause
		-- through a native/user callback. Clear debt only while this exact replay
		-- authorization is still current; a nested pause owns the newer debt.
		if current == token and token.authorization == replay_authorization
			and token.authorized == true and token.paused ~= true then
			local epoch = admission_epoch()
			if epoch == stage.epoch then token.resume_needed = false end
		end
		return true
	end

	--- Finishes or re-stages one post-resume continuation.
	--- @param stage table Exact staging descriptor.
	--- @return boolean settled
	local function finish_resume_stage(stage)
		if resume_stage ~= stage then return false end
		if timer_live(stage.handle) then return false end
		if resume_stage == stage then resume_stage = nil end
		if stage.cancelled == true then
			-- complete() fences before attempting native cancellation. If that
			-- rollback initially refused, exact later settlement can now release
			-- the otherwise-blocking cancelled token as well as its stage.
			if current == stage.token and stage.token.cancelled == true then
				current = nil
			end
			return false
		end
		-- A candidate whose native start did not commit may still survive as
		-- exact rollback debt. Its eventual settlement only releases that debt;
		-- it must never authorize the replay it failed to stage.
		if stage.committed ~= true then return false end
		local paused, transition_pending, epoch, valid = read_control_state()
		if valid ~= true or epoch ~= stage.epoch then
			Logger.error(LOG, "%s bootstrap resume stage lost its exact epoch.", label)
			consume_replay_failure(stage.token, "resume stage lost its exact epoch")
			return false
		end
		-- A rolled-back resume publishes stable PAUSED for this same epoch. Keep
		-- the intent parked; the next explicit resume call will stage it again.
		if paused == true and transition_pending ~= true then return false end
		if transition_pending == true then
			return stage_resume(stage.token, stage.epoch)
		end
		return activate_resume(stage)
	end

	--- Retains one zero-delay timer until the public pause state reaches RESUMED.
	--- @param token table Current bootstrap intent token.
	--- @param epoch integer Exact ScriptControl resume generation.
	--- @return boolean committed
	stage_resume = function(token, epoch)
		if current ~= token or token.cancelled == true
			or token.intent_committed ~= true or token.resume_needed ~= true then
			return false
		end
		if cancel_resume_stage() ~= true then return false end
		local stage = {
			token = token,
			epoch = epoch,
			cancelled = false,
			cancel_requested = false,
			acquiring = true,
			committed = false,
			handle = nil,
		}
		resume_stage = stage
		local acquiring = true
		local callback_during_acquisition = false
		local ok, handle_or_error, committed = xpcall(function()
			return TimerScheduler.after(0, function()
				if acquiring then
					callback_during_acquisition = true
					return
				end
				finish_resume_stage(stage)
			end)
		end, debug.traceback)
		if ok and type(handle_or_error) == "table" then stage.handle = handle_or_error end
		stage.acquiring = false
		acquiring = false
		-- TimerScheduler fences a one-shot before invoking its user callback,
		-- but a native stop refusal keeps the exact handle live. Settlement is
		-- therefore the authoritative replay edge; the ordinary callback below
		-- is merely an immediate retry when stop completed synchronously.
		local observed_ok, observed = xpcall(function()
			return TimerScheduler.onSettled(stage.handle, function()
				finish_resume_stage(stage)
			end)
		end, debug.traceback)
		if not observed_ok or observed ~= true then
			Logger.error(LOG, "%s bootstrap resume-stage settlement observer refused: %s.",
				label, tostring(observed))
			stage.cancelled = true
			cancel_resume_stage()
			return false
		end
		local _, _, current_epoch, valid = read_control_state()
		if not ok or committed ~= true or not timer_live(stage.handle)
			or callback_during_acquisition == true
			or stage.cancel_requested == true or stage.cancelled == true
			or resume_stage ~= stage or current ~= token
			or token.cancelled == true or token.intent_committed ~= true
			or token.resume_needed ~= true or valid ~= true
			or current_epoch ~= epoch then
			Logger.error(LOG, "%s bootstrap resume-stage acquisition refused: %s.",
				label, tostring(ok and committed or handle_or_error))
			stage.cancelled = true
			cancel_resume_stage()
			return false
		end
		stage.committed = true
		return true
	end

	local owner = {}

	--- Fences callbacks before asking the checker to cancel and join exact work.
	--- @return boolean settled
	function owner.pause()
		local token = current
		if token ~= nil and token.cancelled ~= true then
			if token.paused ~= true then
				token.authorization = token.authorization + 1
				token.authorized = false
				token.paused = true
			end
			if token.intent_committed == true then token.resume_needed = true end
		end
		local stage_settled = cancel_resume_stage()
		local work_settled = invoke_quiesce()
		return stage_settled == true and work_settled == true
	end

	--- Joins retained cleanup, then stages replay behind exact RESUMED publication.
	--- @return boolean committed
	function owner.resume()
		if cancel_resume_stage() ~= true then return false end
		if invoke_quiesce() ~= true then return false end
		local token = current
		if token == nil or token.cancelled == true
			or token.intent_committed ~= true or token.resume_needed ~= true then
			return true
		end
		local _, _, epoch, valid = read_control_state()
		if valid ~= true then return false end
		return stage_resume(token, epoch)
	end

	local controller = {}

	--- Registers this controller under its fixed ScriptControl owner identifier.
	--- @param control table ScriptControl facade.
	--- @return boolean committed
	function controller.configure(control)
		if registered == true and script_control == control then return true end
		if configuration_attempted == true then
			Logger.error(LOG, "%s bootstrap pause-owner replacement refused.", label)
			return false
		end
		configuration_attempted = true
		if type(owner_name) ~= "string" or owner_name == ""
			or type(control) ~= "table"
			or type(control.is_paused) ~= "function"
			or type(control.is_pause_transition_pending) ~= "function"
			or type(control.get_pause_epoch) ~= "function"
			or type(control.register_pause_owner) ~= "function" then
			Logger.error(LOG, "%s bootstrap pause-owner dependencies are unavailable.", label)
			return false
		end
		script_control = control
		local ok, registered_or_error = xpcall(function()
			return control.register_pause_owner(owner_name, owner)
		end, debug.traceback)
		registered = ok == true and registered_or_error == true
		if not registered then
			Logger.error(LOG, "%s bootstrap pause-owner registration refused: %s.",
				label, tostring(registered_or_error))
		end
		return registered
	end

	--- Reports whether production ScriptControl registration committed.
	--- @return boolean registered_now
	function controller.is_registered()
		return registered
	end

	--- Reports whether a new caller may enter the backend now.
	--- @return boolean admitted
	function controller.is_admitted()
		return admission_epoch() ~= nil
	end

	--- Begins one backend-local intent under the current active epoch.
	--- @return table|nil token Exact authorization token.
	function controller.begin()
		if current ~= nil then return nil end
		local epoch = admission_epoch()
		if epoch == nil then return nil end
		serial = serial + 1
		local token = {
			serial = serial,
			authorization = 1,
			authorized = true,
			paused = false,
			cancelled = false,
			intent_committed = false,
			resume_needed = false,
			epoch = epoch,
		}
		current = token
		return token
	end

	--- Marks the current intent replayable after its native acquisition committed.
	--- @param token table Exact token returned by begin().
	--- @return boolean committed
	function controller.commit(token)
		if current ~= token or token.cancelled == true or token.authorized ~= true then
			return false
		end
		token.intent_committed = true
		return true
	end

	--- Reports whether this exact token already owns replayable committed intent.
	--- Unlike is_current(), this remains observable after pause revokes admission.
	--- @param token table Exact token returned by begin().
	--- @return boolean committed
	function controller.is_committed(token)
		return current == token and token.cancelled ~= true
			and token.intent_committed == true
	end

	--- Captures the current in-memory authorization identity.
	--- @param token table Exact token returned by begin().
	--- @return integer|nil authorization
	function controller.capture(token)
		if current ~= token or token.cancelled == true or token.authorized ~= true then
			return nil
		end
		local epoch = admission_epoch()
		if epoch == nil or epoch ~= token.epoch then return nil end
		return token.authorization
	end

	--- Verifies identity, public admission, and exact epoch together.
	--- @param token table Exact token returned by begin().
	--- @param authorization integer Captured authorization identity.
	--- @return boolean current_now
	function controller.is_current(token, authorization)
		if current ~= token or token.cancelled == true or token.authorized ~= true
			or token.authorization ~= authorization then
			return false
		end
		local epoch = admission_epoch()
		return epoch ~= nil and epoch == token.epoch
	end

	--- Completes one terminal intent after every exact resource settled.
	--- @param token table Exact token returned by begin().
	--- @return boolean settled
	function controller.complete(token)
		if current ~= token then return false end
		token.authorization = token.authorization + 1
		token.authorized = false
		token.cancelled = true
		token.intent_committed = false
		token.resume_needed = false
		if cancel_resume_stage() ~= true then return false end
		if current == token then current = nil end
		return true
	end

	--- Exposes the registered lifecycle owner to faithful behavioral tests.
	--- @return table pause_owner
	function controller.owner_for_test()
		return owner
	end

	--- Exposes the current opaque token to faithful behavioral tests.
	--- @return table|nil token
	function controller.current_for_test()
		return current
	end

	return controller
end

return M
