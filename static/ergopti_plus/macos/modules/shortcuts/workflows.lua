--- modules/shortcuts/workflows.lua

--- ==============================================================================
--- MODULE: User Workflows (macOS)
--- DESCRIPTION:
--- The macOS ports of the shared workflow owner
--- (_shared/shortcuts/engine/workflows/owner.lua): workflows.json and the
--- approvals in the config folder (atomic FileSystem writes), keys and text
--- through the gesture registry's synthetic input, `open` for an app, a URL
--- or a file, the clipboard adapter, the pointer adapter, the gesture
--- registry for Ergopti actions, the notification owner, a login /bin/sh for
--- a shell step and the focus-aware alert for its confirmation.
---
--- FEATURES & RATIONALE:
--- 1. One owner per driver, built on first use; a second init with other
---    ports raises; stop() releases it with the driver.
--- 2. Every OS call goes through an existing adapter or owner: this module
---    holds no `hs.` call (the purity ledger).
--- 3. A click at coordinates needs the exact mouse ownership the click
---    actions keep (actions_click.lua); until it is shared it is a named
---    refusal, as the screen steps are until the screen vision service lands.
--- 4. A shell step runs `/usr/bin/env ERGOPTI_VAR_x=… /bin/sh -l -c <command>`:
---    the variables are argv entries, never shell text.
--- ==============================================================================

local Logger = require("core.logger.engine.logger")
local Json = require("core.text.engine.json")
local Owner = require("shortcuts.engine.workflows.owner")
local Model = require("shortcuts.engine.workflows.model")

local LOG = "modules.shortcuts.workflows"

--- The real services; tests replace any of them through init(deps).
--- @return table
local function default_deps()
	return {
		shell = require("core.process.adapters.shell_runner"),
		timer = require("core.events.timer_scheduler"),
		file_system = require("core.fs.adapters.file_system"),
		paths = require("settings.engine.paths"),
		shared_paths = require("core.fs.engine.paths"),
		actions = function() return require("gestures.engine.actions") end,
		clipboard = require("clipboard.adapters.clipboard"),
		mouse = require("adapters.mouse_control"),
		notifications = require("core.ui.engine.notifications"),
		window_info = require("platform.focus.window_info"),
		dialog = require("core.ui.engine.dialog_util"),
		i18n = require("core.i18n.engine.i18n"),
	}
end

--- Runs a program and answers done(ok, stdout).
--- @param deps table
--- @param program string
--- @param args table
--- @param done function
--- @return function|nil cancel
local function run(deps, program, args, done)
	local started, handle = deps.shell.run(program, args, function(ok, out)
		if ok then done(true, out) else done(false, "step_failed") end
	end)
	if not started then return nil end
	return function() if handle and type(handle.terminate) == "function" then pcall(handle.terminate) end end
end

--- The effect ports of the macOS driver.
--- @param deps table
--- @return table
local function effect_ports(deps)
	return {
		send_shortcut = function(combo, done) done(deps.actions().send_input_value("send_shortcut", combo) == true) end,
		type_text = function(text, done) done(deps.actions().type_text(text) == true) end,
		after = function(ms, fn)
			local handle = deps.timer.after(ms / 1000, fn)
			return function() deps.timer.cancel(handle) end
		end,
		open = function(kind, value, done)
			local args = kind == "app" and { "-a", value } or { value }
			return run(deps, "/usr/bin/open", args, function(ok) done(ok) end)
		end,
		-- `open -a` brings a running application to the front, or launches it
		focus_app = function(app, done) return run(deps, "/usr/bin/open", { "-a", app }, function(ok) done(ok) end) end,
		clipboard_get = function(done)
			local text = deps.clipboard.read()
			if type(text) == "string" then done(text) else done(nil, "step_failed") end
		end,
		clipboard_set = function(text, done) done(deps.clipboard.write(text) == true) end,
		mouse_move = function(x, y, done) done(deps.mouse.setPos(x, y) ~= false) end,
		mouse_click = function(_, _, _, _, done)
			Logger.warn(LOG, "A click at coordinates is not wired on macOS yet (mouse ownership of actions_click).")
			done(false, "step_failed")
		end,
		run_action = function(action, done)
			local actions = deps.actions()
			if actions.get_action_parameter_spec(action) ~= nil then
				Logger.warn(LOG, "A workflow step names '%s', which takes a parameter.", action)
				return done(false, "step_failed")
			end
			done(actions.execute_single(action, "workflow_step") ~= false)
		end,
		notify = function(text, done) done(deps.notifications.notify(text) == true) end,
		shell = function(command, env, _, done)
			local args, names = {}, {}
			for name in pairs(env) do names[#names + 1] = name end
			table.sort(names)
			for _, name in ipairs(names) do args[#args + 1] = name .. "=" .. env[name] end
			for _, part in ipairs({ "/bin/sh", "-l", "-c", command }) do args[#args + 1] = part end
			return run(deps, "/usr/bin/env", args, function(ok, out) done(ok, ok and (out or "") or out) end)
		end,
		confirm_shell = function(workflow, commands, done)
			local allow = deps.i18n.get("workflows.confirm_shell.allow")
			local ok, clicked = pcall(deps.dialog.block_alert, deps.i18n.get("workflows.confirm_shell.title"),
				Owner.fill(deps.i18n.get("workflows.confirm_shell.body"), { workflow.name, table.concat(commands, "\n") }),
				deps.i18n.get("button.cancel"), allow, "warning")
			done(ok and clicked == allow)
		end,
		app_front = function(app, done)
			local front = deps.window_info.frontmost_application()
			local id = front and tostring(front.bundle_id):lower() or ""
			local wanted = app:lower()
			done(id ~= "" and (id == wanted or id:find(wanted, 1, true) ~= nil))
		end,
	}
end

return Owner.driver_module({
	log = LOG,
	default_services = default_deps,
	options = function(services)
		local function shared_json(relative)
			local text, status = services.file_system.read_with_status(services.shared_paths.shared(relative))
			if status ~= "ok" then error("workflows: cannot read _shared/" .. relative) end
			return assert(Json.decode(text), "workflows: _shared/" .. relative .. " is not JSON")
		end
		local Runner = require("shortcuts.engine.workflows.runner")
		local timeouts = Runner.registry_timeouts()
		return {
			store = Owner.store_ports({
				config_path = function(name) return services.paths.get_config_dir() .. "/" .. name end,
				read_with_status = services.file_system.read_with_status,
				write = services.file_system.write,
				catalogue = shared_json(Model.CATALOGUE_PATH),
				vocabulary = services.actions().send_vocabulary(),
				wait_max_ms = timeouts.wait_max_ms,
			}),
			effects = effect_ports(services),
			after = function(ms, fn)
				local handle = services.timer.after(ms / 1000, fn)
				return function() services.timer.cancel(handle) end
			end,
			translate = function(key) return services.i18n.get(key) end,
			notify = function(text)
				if services.notifications.notify(text, nil, "error") ~= true then
					Logger.warn(LOG, "A workflow notice could not be shown.")
				end
			end,
			timeouts = timeouts,
		}
	end,
})
