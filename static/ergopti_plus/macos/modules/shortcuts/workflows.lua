--- modules/shortcuts/workflows.lua

--- ==============================================================================
--- MODULE: User Workflows (macOS)
--- DESCRIPTION:
--- The macOS ports of the shared workflow owner
--- (_shared/shortcuts/engine/workflows/owner.lua): workflows.json and the
--- approvals in the config folder (atomic FileSystem writes), keys and text
--- through the gesture registry's synthetic input, `open` for an app, a URL
--- or a file, the clipboard adapter, the pointer adapter, the gesture
--- registry for Ergopti actions, the notification owner and a login /bin/sh
--- for a shell step.
---
--- FEATURES & RATIONALE:
--- 1. One owner per driver, built on first use; a second init with other
---    ports raises; stop() releases it with the driver.
--- 2. Every OS call goes through an existing adapter or owner: this module
---    holds no `hs.` call (the purity ledger).
--- 3. A click at coordinates goes through the synthetic click owner
---    (platform/input/synthetic_click.lua). The screen steps run on the screen
---    vision service, started by its session (platform/vision/vision_session.lua):
---    captures, embedded images written as private template files and the
---    drawn region's file all live in its cache folder.
--- 4. A shell step runs `/usr/bin/env ERGOPTI_VAR_x=… /bin/sh -l -c <command>`:
---    the variables are argv entries, never shell text.
--- ==============================================================================

local Logger = require("core.logger.engine.logger")
local Json = require("core.text.engine.json")
local Owner = require("shortcuts.engine.workflows.owner")
local Model = require("shortcuts.engine.workflows.model")
local Screen = require("shortcuts.engine.workflows.screen")

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
		click = require("platform.input.synthetic_click"),
		notifications = require("core.ui.engine.notifications"),
		window_info = require("platform.focus.window_info"),
		i18n = require("core.i18n.engine.i18n"),
		vision_session = require("platform.vision.vision_session"),
		screen_ports = function() return require("adapters.auto_click_ports").ports() end,
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
		mouse_click = function(x, y, button, count, done)
			local clicked = deps.click.click(x, y, button, count)
			if clicked then done(true) else done(false, "step_failed") end
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
			local args = {}
			for _, name in ipairs(require("core.text.engine.table_util").sorted_keys(env)) do args[#args + 1] = name .. "=" .. env[name] end
			for _, part in ipairs({ "/bin/sh", "-l", "-c", command }) do args[#args + 1] = part end
			return run(deps, "/usr/bin/env", args, function(ok, out) done(ok, ok and (out or "") or out) end)
		end,
		app_front = function(app, done)
			local front = deps.window_info.frontmost_application()
			local id = front and tostring(front.bundle_id):lower() or ""
			local wanted = app:lower()
			done(id ~= "" and (id == wanted or id:find(wanted, 1, true) ~= nil))
		end,
	}
end

--- The screen vision adapter of the shared screen steps.
--- @param deps table
--- @param ports table The effect ports (the click reuses mouse_click).
--- @param matcher_options table auto_click_defaults.json.
--- @return table
local function screen_vision(deps, ports, matcher_options)
	local templates, files = {}, 0
	local function vision() return deps.vision_session.service() end
	local function window_image(done)
		local front = deps.screen_ports().foreground()
		if not front then return done(nil, "no_foreground_window") end
		vision().capture_window(front.window, done)
	end
	local function image_capture(done)
		return function(image, reason)
			if image then done({ image = image }) else done(nil, reason) end
		end
	end
	local function private_file(prefix)
		files = files + 1
		return deps.vision_session.cache_dir() .. "/workflow_" .. prefix .. "_" .. files .. ".png"
	end
	return {
		window_image = window_image,
		capture = function(mode, done)
			if mode == "window" then return window_image(image_capture(done)) end
			if mode == "full" then
				local bounds = deps.mouse.getMonitorBounds(1)
				return vision().capture_region({ x = bounds.left, y = bounds.top,
					width = bounds.right - bounds.left, height = bounds.bottom - bounds.top }, image_capture(done))
			end
			-- A drawn region: screencapture's interactive selection writes the file,
			-- in the cache folder the started service created.
			vision()
			local path = private_file("region")
			run(deps, "/usr/sbin/screencapture", { "-i", "-x", path }, function(ok)
				if ok and deps.file_system.read_with_status(path) ~= nil then done({ path = path })
				else done(nil, "capture_refused") end
			end)
		end,
		template = function(bytes, _, done)
			if templates[bytes] == nil then
				vision() -- the started service owns the cache folder
				local path = private_file("template")
				if not deps.file_system.write(path, bytes) then return done(nil, "template_unreadable") end
				templates[bytes] = path
			end
			done({ path = templates[bytes] })
		end,
		match = function(image, list, done) vision().match(image, list, matcher_options, done) end,
		recognize = function(capture, done)
			local options = { layout = capture.layout or "block", languages = deps.screen_ports().languages() }
			if capture.image then return vision().recognize_text(capture.image, options, done) end
			vision().recognize_file(capture.path, options, done)
		end,
		save = function(capture, done) done(capture.path or capture.image.source) end,
		click = function(x, y, button, done) ports.mouse_click(x, y, button, 1, done) end,
		click_point = require("shortcuts.engine.auto_click_matcher").click_point,
		find_text = function(words, targets) return vision().find_text(words, targets) end,
		after = function(ms, fn)
			local handle = deps.timer.after(ms / 1000, fn)
			return function() deps.timer.cancel(handle) end
		end,
		now_ms = function() return deps.screen_ports().now_ms() end,
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
			effects = (function()
				local ports = effect_ports(services)
				local matcher = shared_json("shortcuts/data/auto_click_defaults.json")
				ports.screen = Screen.new(screen_vision(services, ports, matcher), {
					catalogue = shared_json(Model.CATALOGUE_PATH), poll_ms = timeouts.wait_for_poll_ms,
					text_max_distance = matcher.text_max_distance, threshold = matcher.threshold,
				})
				return ports
			end)(),
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
