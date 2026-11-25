--- _shared/shortcuts/engine/workflows/effects.lua

--- ==============================================================================
--- MODULE: User Workflow Effects (Shared)
--- DESCRIPTION:
--- Turns each effect of the shared interpreter into one call of the driver's
--- OS ports, for the macOS and Linux drivers: keys, text, waits, opening and
--- focusing, the clipboard, the mouse, Ergopti actions, notifications, shell
--- commands and the screen steps. The runner hands
--- its effects to perform(); cancel() stops the pending one.
---
--- FEATURES & RATIONALE:
--- 1. One mapping for both Lua drivers: each driver supplies the same small
---    set of ports, so a step means the same thing on macOS and Linux.
--- 2. A missing capability is named, never skipped: a screen step without
---    the screen services answers screen_service_missing, a port that says no
---    answers step_failed with its own reason when it has one.
--- 3. The variables reach a shell command as ERGOPTI_VAR_<name> environment
---    variables, never inside its text.
--- ==============================================================================

local M = {}

--- The prefix of a variable's environment name in a shell step.
M.ENV_PREFIX = "ERGOPTI_VAR_"

-- The run reasons (steps.json run_reasons) this mapping answers itself.
local RUN_REASON = { screen_service_missing = "screen_service_missing", step_failed = "step_failed" }

-- The effects that need the screen services (capture, OCR, matching).
local SCREEN_OPS = { wait_for = true, capture = true, ocr = true, click_target = true }

-- The ports every driver must supply.
local REQUIRED_PORTS = {
	"send_shortcut", "type_text", "after", "open", "focus_app", "clipboard_get", "clipboard_set",
	"mouse_move", "mouse_click", "run_action", "notify", "shell", "app_front",
}

--- The environment of a shell step: each variable under its prefixed name.
--- @param variables table name -> string.
--- @return table name -> string
function M.environment(variables)
	local env = {}
	for name, value in pairs(variables or {}) do env[M.ENV_PREFIX .. name] = tostring(value) end
	return env
end

--- Builds one driver's effect performer.
--- @param ports table {
---   send_shortcut(combo, done), type_text(text, done),
---   after(ms, fn) -> cancel function,
---   open(target_kind, value, done), focus_app(app, done),
---   clipboard_get(done(text|nil, reason)), clipboard_set(text, done),
---   mouse_move(x, y, done), mouse_click(x, y, button, count, done),
---   run_action(action, done), notify(text, done),
---   shell(command, env, deadline_ms, done(ok, stdout_or_reason)) -> cancel function|nil,
---   app_front(app, done(boolean)),
---   screen = table|nil the screen steps' adapter: { wait_for, capture, ocr,
---     click_target, visible } each (effect, done(result)) -> cancel|nil.
---   Every done(true) means success; done(false, reason) a refusal. }
--- @return table { perform(effect, done, workflow), cancel(effect) }
function M.new(ports)
	assert(type(ports) == "table", "workflow effects need their ports")
	for _, name in ipairs(REQUIRED_PORTS) do
		assert(type(ports[name]) == "function", "workflow effects need the port " .. name)
	end
	local cancels = {}
	local performer = {}

	-- A done for the ports that answer ok/refusal.
	local function plain(done)
		return function(ok, reason)
			if ok then done({ ok = true }) else done({ ok = false, reason = reason or RUN_REASON.step_failed }) end
		end
	end

	--- Performs one effect of the interpreter.
	--- @param effect table
	--- @param done function done({ ok, value, reason })
	--- @param workflow table|nil The running workflow (the shell confirmation names it).
	function performer.perform(effect, done, workflow)
		local op = effect.op
		local function keep(cancel) if cancel then cancels[effect] = cancel end end
		local function finish(result) cancels[effect] = nil; done(result) end
		if SCREEN_OPS[op] or (op == "probe" and effect.condition.type == "visible") then
			local screen = ports.screen
			local name = op == "probe" and "visible" or op
			if type(screen) ~= "table" or type(screen[name]) ~= "function" then
				return finish({ ok = false, reason = RUN_REASON.screen_service_missing })
			end
			return keep(screen[name](effect, finish))
		end
		if op == "send_keys" then return ports.send_shortcut(effect.combo, plain(finish)) end
		if op == "type_text" then return ports.type_text(effect.text, plain(finish)) end
		if op == "wait" then return keep(ports.after(effect.duration_ms, function() finish({ ok = true }) end)) end
		if op == "open" then return ports.open(effect.target_kind, effect.value, plain(finish)) end
		if op == "focus_app" then return ports.focus_app(effect.app, plain(finish)) end
		if op == "clipboard_get" then
			return ports.clipboard_get(function(text, reason)
				if text == nil then finish({ ok = false, reason = reason or RUN_REASON.step_failed })
				else finish({ ok = true, value = text }) end
			end)
		end
		if op == "clipboard_set" then return ports.clipboard_set(effect.text, plain(finish)) end
		if op == "mouse_move" then return ports.mouse_move(effect.x, effect.y, plain(finish)) end
		if op == "mouse_click" then
			return ports.mouse_click(effect.x, effect.y, effect.button or "left", effect.count or 1, plain(finish))
		end
		if op == "run_action" then return ports.run_action(effect.action, plain(finish)) end
		if op == "notify" then return ports.notify(effect.text, plain(finish)) end
		if op == "shell" then
			return keep(ports.shell(effect.command, M.environment(effect.environment), effect.deadline_ms,
				function(ok, value)
					if ok then finish({ ok = true, value = value }) else finish({ ok = false, reason = value or RUN_REASON.step_failed }) end
				end))
		end
		if op == "probe" then
			local condition = effect.condition
			if condition.type == "app_front" then
				return ports.app_front(condition.app, function(front) finish({ ok = true, value = front == true }) end)
			end
			if condition.type == "matches" and condition.source == "clipboard" then
				return ports.clipboard_get(function(text, reason)
					if text == nil then return finish({ ok = false, reason = reason or RUN_REASON.step_failed }) end
					local value = condition.value or ""
					local answer
					if condition.op == "empty" then answer = text == ""
					elseif condition.op == "equals" then answer = text == value
					elseif condition.op == "contains" then answer = text:find(value, 1, true) ~= nil
					else answer = text:sub(1, #value) == value end
					finish({ ok = true, value = answer })
				end)
			end
		end
		error("workflow effects: no performer for effect " .. tostring(op), 2)
	end

	--- Stops a pending effect (a wait, a shell child, a screen scan).
	--- @param effect table
	function performer.cancel(effect)
		local cancel = cancels[effect]
		cancels[effect] = nil
		if cancel then cancel() end
	end

	return performer
end

return M
