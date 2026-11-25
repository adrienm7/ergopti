--- modules/shortcuts/workflows.lua

--- ==============================================================================
--- MODULE: User Workflows (Linux)
--- DESCRIPTION:
--- The Linux ports of the shared workflow owner
--- (_shared/shortcuts/engine/workflows/owner.lua): workflows.json and the
--- approvals in the config folder, keys and text through the daemon's uinput
--- device, xdg-open and gtk-launch, the clipboard owner, xdotool for the
--- pointer, the gesture executor for Ergopti actions, the desktop notifier and
--- a login /bin/sh for a shell step. The run_workflow action and Escape reach
--- the owner here.
---
--- FEATURES & RATIONALE:
--- 1. One owner per daemon, built on first use (init is idempotent only for
---    the same ports; a second set raises) and stopped with the daemon.
--- 2. A capability the session lacks is a named refusal: the pointer steps
---    need X11 (xdotool), as center_mouse does; focusing an app needs wmctrl.
---    The screen steps answer screen_service_missing until the screen vision
---    service is wired (feat/keep-awake-autoclick).
--- 3. A shell step runs `env ERGOPTI_VAR_x=… /bin/sh -l -c <command>`: the
---    variables are argv entries of env, never shell text.
--- ==============================================================================

local Logger = require("core.logger.engine.shim")
local Json = require("core.text.engine.json")
local Paths = require("core.fs.engine.paths")
local Owner = require("shortcuts.engine.workflows.owner")
local Model = require("shortcuts.engine.workflows.model")

local LOG = "modules.shortcuts.workflows"

--- @param relative string Path under _shared/.
--- @return table The decoded JSON file; raises when it cannot be read.
local function shared_json(relative)
	local path = Paths.shared(relative)
	local file = assert(io.open(path, "rb"), "workflows: cannot open " .. tostring(path))
	local text = file:read("*a")
	file:close()
	return assert(Json.decode(text), "workflows: " .. tostring(path) .. " is not JSON")
end

--- The real OS services; tests replace any of them through init(deps).
--- @return table
local function default_deps()
	return {
		shell = require("core.process.adapters.shell_runner"),
		timer = require("core.events.timer_scheduler"),
		file_system = require("core.fs.adapters.file_system"),
		settings_paths = require("settings.engine.paths"),
		shortcuts = require("modules.shortcuts.manager"),
		gestures = function() return require("gestures.engine.manager") end,
		clipboard = require("clipboard.adapters.clipboard"),
		notifier = require("platform.focus.application_notifier"),
		window_info = require("platform.focus.window_info"),
		i18n = require("core.i18n.engine.i18n"),
		session_type = function() return os.getenv("XDG_SESSION_TYPE") end,
		rename = os.rename,
	}
end

--- Runs a program asynchronously and answers done(ok, stdout).
--- @param deps table
--- @param program string
--- @param args table
--- @param timeout_ms number|nil
--- @param done function
--- @return function|nil cancel
local function run(deps, program, args, timeout_ms, done)
	local handle, refusal = deps.shell.run_async(program, args, { timeout_ms = timeout_ms }, function(answer)
		if answer.ok == true then done(true, answer.stdout) else done(false, answer.timed_out and "timeout" or "step_failed") end
	end)
	if not handle then
		Logger.error(LOG, "%s could not start for a workflow step: %s.", program, tostring(refusal))
		done(false, "step_failed")
		return nil
	end
	return function() if type(handle.cancel) == "function" then pcall(handle.cancel) end end
end

--- The effect ports of the Linux driver.
--- @param deps table
--- @return table
local function effect_ports(deps)
	local function x11_only(done)
		if deps.session_type() == "wayland" then
			Logger.warn(LOG, "A pointer step needs X11: Wayland lets no client move the pointer.")
			done(false, "step_failed")
			return false
		end
		return true
	end
	local BUTTONS = { left = "1", middle = "2", right = "3" }
	return {
		send_shortcut = function(combo, done)
			done(deps.shortcuts.action_handlers()["send_shortcut"](nil, combo) == true)
		end,
		type_text = function(text, done) done(deps.shortcuts.insert_text(text) == true) end,
		after = function(ms, fn)
			local handle = deps.timer.after(ms / 1000, fn)
			return function() deps.timer.cancel(handle) end
		end,
		open = function(kind, value, done)
			if kind == "app" then return run(deps, "gtk-launch", { "--", value }, nil, function(ok) done(ok) end) end
			return run(deps, "xdg-open", { value }, nil, function(ok) done(ok) end)
		end,
		focus_app = function(app, done)
			if not x11_only(done) then return end
			return run(deps, "wmctrl", { "-x", "-a", app }, nil, function(ok) done(ok) end)
		end,
		clipboard_get = function(done)
			local ok, text = deps.clipboard.read_checked()
			if ok then done(text) else done(nil, "step_failed") end
		end,
		clipboard_set = function(text, done) done(deps.clipboard.write(text) == true) end,
		mouse_move = function(x, y, done)
			if not x11_only(done) then return end
			return run(deps, "xdotool", { "mousemove", tostring(x), tostring(y) }, nil, function(ok) done(ok) end)
		end,
		mouse_click = function(x, y, button, count, done)
			if not x11_only(done) then return end
			return run(deps, "xdotool", { "mousemove", tostring(x), tostring(y), "click", "--repeat", tostring(count),
				BUTTONS[button] }, nil, function(ok) done(ok) end)
		end,
		run_action = function(action, done)
			local gestures = deps.gestures()
			if not gestures.is_runnable(action) or gestures.get_action_parameter_spec(action) ~= nil then
				Logger.warn(LOG, "A workflow step names '%s', which is no parameterless action here.", action)
				return done(false, "step_failed")
			end
			done(gestures.execute_action(action, "workflow_step") == true)
		end,
		notify = function(text, done)
			done(deps.notifier.send(text, { level = "info" }) == true)
		end,
		shell = function(command, env, deadline_ms, done)
			local args = {}
			local names = {}
			for name in pairs(env) do names[#names + 1] = name end
			table.sort(names)
			for _, name in ipairs(names) do args[#args + 1] = name .. "=" .. env[name] end
			for _, part in ipairs({ "/bin/sh", "-l", "-c", command }) do args[#args + 1] = part end
			return run(deps, "env", args, deadline_ms, function(ok, stdout)
				if ok then done(true, (tostring(stdout or ""):gsub("[\r\n]+$", ""))) else done(false, stdout) end
			end)
		end,
		app_front = function(app, done)
			local focused = deps.window_info.getFocused()
			local wanted = app:lower()
			local id = tostring(focused.appId or ""):lower()
			done(id ~= "" and (id == wanted or id:find(wanted, 1, true) ~= nil))
		end,
	}
end

return Owner.driver_module({
	log = LOG,
	default_services = default_deps,
	options = function(services)
		local vocabulary = services.shortcuts.send_vocabulary()
		local Runner = require("shortcuts.engine.workflows.runner")
		local timeouts = Runner.registry_timeouts()
		return {
			store = Owner.store_ports({
				config_path = function(name) return services.settings_paths.config(name) end,
				read_with_status = services.file_system.read_with_status,
				-- A temporary sibling renamed over the file: rename(2) replaces it atomically
				write = function(path, text)
					local temporary = path .. ".tmp"
					if not services.file_system.write(temporary, text) then return false, "cannot write " .. temporary end
					return services.rename(temporary, path)
				end,
				catalogue = shared_json(Model.CATALOGUE_PATH),
				vocabulary = vocabulary,
				wait_max_ms = timeouts.wait_max_ms,
			}),
			effects = effect_ports(services),
			after = function(ms, fn)
				local handle = services.timer.after(ms / 1000, fn)
				return function() services.timer.cancel(handle) end
			end,
			translate = function(key) return services.i18n.get(key) end,
			notify = function(text)
				if services.notifier.send(text, { level = "error", private = true }) ~= true then
					Logger.warn(LOG, "A workflow notice could not be shown.")
				end
			end,
			timeouts = timeouts,
		}
	end,
})
