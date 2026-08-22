--- ui/menu/menu_llm/activation_pause_owner.lua

--- Owns the asynchronous work started by the top-level LLM enable action.
--- A pause fences the current authorization before touching its post-resume
--- timer and joining the exact requirements capability supplied by the menu.
--- Resume only stages re-authorization; business work cannot continue until
--- ScriptControl has published RESUMED for the same epoch.

local M = {}

local Logger = require("infra.logger")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "menu_llm.activation_pause_owner"

local function timer_live(handle)
	return type(handle) == "table" and handle.timer ~= nil
end

--- @param options table
--- @return table controller
function M.new(options)
	options = options or {}
	local script_control = options.script_control
	local pause_join = type(options.pause_join) == "function"
		and options.pause_join or function() return true, false end
	local current = nil
	local serial = 0
	local resume_stage = nil
	local registered = false
	local requirement_join_settled = true
	local requirement_replay_needed = false
	local stage_resume

	local function read_pause_state()
		if type(script_control) ~= "table"
			or type(script_control.is_paused) ~= "function"
			or type(script_control.get_pause_epoch) ~= "function" then
			return true, -1, false
		end
		local paused_ok, paused = xpcall(script_control.is_paused, debug.traceback)
		local epoch_ok, epoch = xpcall(script_control.get_pause_epoch, debug.traceback)
		if not paused_ok or type(paused) ~= "boolean"
			or not epoch_ok or type(epoch) ~= "number" then
			return true, -1, false
		end
		return paused, epoch, true
	end

	local function cancel_resume_stage()
		local stage = resume_stage
		if stage == nil then return true end
		stage.cancelled = true
		local handle = stage.handle
		if not timer_live(handle) then
			if resume_stage == stage then resume_stage = nil end
			return true
		end
		local ok, settled_or_err = xpcall(function()
			return TimerScheduler.cancel(handle)
		end, debug.traceback)
		if not ok or settled_or_err ~= true then
			Logger.error(LOG, "LLM activation resume-stage cancellation refused: %s.",
				tostring(settled_or_err))
			return false
		end
		if resume_stage == stage then resume_stage = nil end
		return true
	end

	local function invoke_resume(token, resumed_from_pause)
		if current ~= token or token.cancelled == true or token.pending ~= true then
			return false
		end
		local ok, result_or_err = xpcall(function()
			return token.resume(token, resumed_from_pause)
		end, debug.traceback)
		if not ok or result_or_err ~= true then
			Logger.error(LOG, "LLM activation continuation refused: %s.",
				tostring(result_or_err))
			return false
		end
		return true
	end

	local function finish_stage(stage)
		if resume_stage ~= stage or stage.cancelled == true then return false end
		local handle = stage.handle
		if timer_live(handle) then
			if stage.observing == true then return false end
			if type(TimerScheduler.onSettled) ~= "function" then return false end
			stage.observing = true
			local ok, registered_or_err = xpcall(function()
				return TimerScheduler.onSettled(handle, function()
					stage.observing = false
					finish_stage(stage)
				end)
			end, debug.traceback)
			if not ok or registered_or_err ~= true then
				stage.observing = false
				Logger.error(LOG, "LLM activation resume-stage observation refused: %s.",
					tostring(registered_or_err))
				return false
			end
			return false
		end

		if resume_stage == stage then resume_stage = nil end
		local token = stage.token
		if current ~= token or token.cancelled == true or token.pending ~= true then
			return false
		end
		local paused, epoch, state_ok = read_pause_state()
		if state_ok ~= true or epoch ~= stage.epoch then return false end
		if paused == true then
			-- A zero-delay timer may be queued before the last resume owner commits.
			-- Keep one exact stage owned until the public bit changes or rollback
			-- calls pause() and cancels it.
			return stage_resume(token, stage.epoch)
		end

		token.authorization = token.authorization + 1
		token.authorized = true
		token.paused = false
		token.epoch = epoch
		token.rollback_authorization = nil
		token.rollback_epoch = nil
		local resumed = invoke_resume(token, true)
		if resumed == true then requirement_replay_needed = false end
		return resumed
	end

	stage_resume = function(token, epoch)
		if current ~= token or token.cancelled == true or token.pending ~= true then
			return false
		end
		if cancel_resume_stage() ~= true then return false end
		local stage = {
			token = token,
			epoch = epoch,
			cancelled = false,
			observing = false,
			handle = nil,
		}
		resume_stage = stage
		local callback_during_acquisition = false
		local acquiring = true
		local ok, handle_or_err, committed = xpcall(function()
			return TimerScheduler.after(0, function()
				if acquiring then
					callback_during_acquisition = true
					return
				end
				finish_stage(stage)
			end)
		end, debug.traceback)
		acquiring = false
		if ok and type(handle_or_err) == "table" then stage.handle = handle_or_err end
		if not ok or committed ~= true or not timer_live(stage.handle)
			or callback_during_acquisition == true then
			Logger.error(LOG, "LLM activation resume-stage acquisition refused: %s.",
				tostring(ok and committed or handle_or_err))
			if not timer_live(stage.handle) and resume_stage == stage then
				resume_stage = nil
			end
			return false
		end
		return true
	end

	local owner = {}

	function owner.pause()
		local token = current
		if token ~= nil and token.cancelled ~= true and token.pending == true
			and token.paused ~= true then
			token.rollback_authorization = token.authorization
			token.rollback_epoch = token.epoch
			token.authorization = token.authorization + 1
			token.authorized = false
			token.paused = true
		end
		local stage_settled = cancel_resume_stage()
		local join_ok, join_result, had_tasks = xpcall(pause_join, debug.traceback)
		if had_tasks == true then requirement_replay_needed = true end
		requirement_join_settled = join_ok == true and join_result == true
		if requirement_join_settled ~= true then
			Logger.error(LOG, "LLM activation requirement-task join refused: %s.",
				tostring(join_result))
		end
		return stage_settled == true and requirement_join_settled == true
	end

	function owner.resume()
		local token = current
		if cancel_resume_stage() ~= true then return false end
		if requirement_join_settled ~= true then return false end
		if token == nil then
			requirement_replay_needed = false
			return true
		end
		if token.cancelled == true then
			if current == token then current = nil end
			requirement_replay_needed = false
			return true
		end
		local paused, epoch, state_ok = read_pause_state()
		if state_ok ~= true then return false end
		if paused == true then return stage_resume(token, epoch) end

		-- This is rollback of an uncommitted PAUSE. Restore the captured logical
		-- authorization; only a requirement task the manager proved revoked and
		-- settled is replayed, while unrelated bootstrap work keeps its sole owner.
		if token.rollback_authorization ~= nil then
			token.authorization = token.rollback_authorization
		end
		token.authorized = true
		token.paused = false
		token.epoch = epoch
		token.rollback_authorization = nil
		token.rollback_epoch = nil
		local resumed = invoke_resume(token, requirement_replay_needed == true)
		if resumed == true then requirement_replay_needed = false end
		return resumed
	end

	if type(script_control) == "table"
		and type(script_control.register_pause_owner) == "function" then
		local ok, result_or_err = xpcall(function()
			return script_control.register_pause_owner("llm_activation", owner)
		end, debug.traceback)
		registered = ok == true and result_or_err == true
		if not registered then
			Logger.error(LOG, "LLM activation pause-owner registration refused: %s.",
				tostring(result_or_err))
		end
	end

	local controller = {}

	function controller.is_registered() return registered end

	function controller.begin(resume)
		if registered ~= true or type(resume) ~= "function" or current ~= nil then return nil end
		local paused, epoch, state_ok = read_pause_state()
		if state_ok ~= true or paused == true then return nil end
		serial = serial + 1
		requirement_join_settled = true
		requirement_replay_needed = false
		local token = {
			serial = serial,
			authorization = 1,
			authorized = true,
			paused = false,
			pending = true,
			cancelled = false,
			epoch = epoch,
			resume = resume,
		}
		current = token
		return token
	end

	function controller.capture(token)
		if current ~= token or token.pending ~= true then return nil end
		return token.authorization
	end

	function controller.is_current(token, authorization)
		if current ~= token or token.pending ~= true or token.cancelled == true
			or token.authorized ~= true or token.authorization ~= authorization then
			return false
		end
		local paused, epoch, state_ok = read_pause_state()
		return state_ok == true and paused ~= true and epoch == token.epoch
	end

	function controller.complete(token)
		if current ~= token then return false end
		token.authorized = false
		token.pending = false
		if cancel_resume_stage() ~= true then return false end
		if current == token then current = nil end
		requirement_replay_needed = false
		return true
	end

	function controller.cancel()
		local token = current
		if token == nil then return cancel_resume_stage() end
		token.authorization = token.authorization + 1
		token.authorized = false
		token.cancelled = true
		if cancel_resume_stage() ~= true then return false end
		if current == token then current = nil end
		requirement_replay_needed = false
		return true
	end

	function controller.owner_for_test() return owner end

	return controller
end

return M
