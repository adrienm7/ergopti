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
--- 4. The screen steps run on the screen vision service
---    (platform/vision/screen_vision.lua): the front window through its own
---    drawable, the whole screen and a drawn region on X11, an embedded image
---    decoded to the matcher's gray (platform/vision/png_codec.lua), and the
---    OCR through tesseract. A capture's file lands in the driver's cache.
--- 3. A shell step runs `env ERGOPTI_VAR_x=… /bin/sh -l -c <command>`: the
---    variables are argv entries of env, never shell text.
--- ==============================================================================

local Logger = require("core.logger.engine.shim")
local Json = require("core.text.engine.json")
local Paths = require("core.fs.engine.paths")
local Owner = require("shortcuts.engine.workflows.owner")
local Model = require("shortcuts.engine.workflows.model")
local Screen = require("shortcuts.engine.workflows.screen")

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
		vision = function() return require("platform.vision.vision_session").service() end,
		focus = require("platform.focus.x11_focus"),
		png = require("platform.vision.png_codec"),
		locale = function() return require("core.i18n.engine.locale").current_locale() end,
		now_ms = require("core.logger.engine.monotonic").now_ms,
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
			for _, name in ipairs(require("core.text.engine.table_util").sorted_keys(env)) do args[#args + 1] = name .. "=" .. env[name] end
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

--- The screen vision adapter of the shared screen steps.
--- @param deps table
--- @param ports table The effect ports (the click reuses mouse_click).
--- @param catalogue table The step catalogue (limits).
--- @param matcher_options table auto_click_defaults.json.
--- @param timeouts table The registry deadlines.
--- @return table
local function screen_vision(deps, ports, catalogue, matcher_options, timeouts)
	local REFUSED = { capture = "capture_refused", no_window = "no_foreground_window" }
	local templates = {}
	local captures = 0
	local cache_dir = nil
	--- Creates the cache folder, then calls next_step(ok).
	local function with_cache(next_step)
		cache_dir = cache_dir or deps.settings_paths.cache("workflows")
		run(deps, "mkdir", { "-p", cache_dir }, timeouts.step_timeout_ms, function(ok) next_step(ok) end)
	end
	local function window_image(done)
		local window = deps.focus.query()
		if not window then return done(nil, REFUSED.no_window) end
		deps.vision().capture_window(window, done)
	end
	local function image_capture(done)
		return function(image, reason)
			if image then done({ image = image }) else done(nil, reason) end
		end
	end
	return {
		window_image = window_image,
		capture = function(mode, done)
			if mode == "window" then return window_image(image_capture(done)) end
			if mode == "full" then return deps.vision().capture_screen(image_capture(done)) end
			-- A drawn region: the screenshot cascade writes the PNG the OCR reads.
			with_cache(function(ready)
				if not ready then return done(nil, REFUSED.capture) end
				captures = captures + 1
				local path = cache_dir .. "/region_" .. captures .. ".png"
				local command = deps.gestures().region_screenshot_command("'" .. path .. "'")
				run(deps, "/bin/sh", { "-c", command }, timeouts.screen_step_timeout_ms, function(ok)
					if ok then done({ path = path }) else done(nil, REFUSED.capture) end
				end)
			end)
		end,
		template = function(bytes, _, done)
			if templates[bytes] == nil then
				local image, reason = deps.png.decode_gray(bytes, catalogue.limits.template_pixels_max)
				if not image then return done(nil, reason) end
				templates[bytes] = image
			end
			done({ image = templates[bytes] })
		end,
		match = function(image, list, done) deps.vision().match(image, list, matcher_options, done) end,
		recognize = function(capture, done)
			local options = { layout = capture.layout or "block", locale = deps.locale() }
			if capture.image then return deps.vision().recognize_text(capture.image, options, done) end
			deps.vision().recognize_file(capture.path, options, done)
		end,
		save = function(capture, done)
			if capture.path then return done(capture.path) end
			local bytes, reason = deps.png.encode_gray(capture.image)
			if not bytes then return done(nil, reason) end
			with_cache(function(ready)
				captures = captures + 1
				local path = cache_dir .. "/capture_" .. captures .. ".png"
				if ready and deps.file_system.write(path, bytes) then return done(path) end
				done(nil, REFUSED.capture)
			end)
		end,
		click = function(x, y, button, done) ports.mouse_click(x, y, button, 1, done) end,
		click_point = require("shortcuts.engine.auto_click_matcher").click_point,
		find_text = function(words, targets) return deps.vision().find_text(words, targets) end,
		after = function(ms, fn)
			local handle = deps.timer.after(ms / 1000, fn)
			return function() deps.timer.cancel(handle) end
		end,
		now_ms = deps.now_ms,
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
			effects = (function()
				local ports = effect_ports(services)
				local catalogue = shared_json(Model.CATALOGUE_PATH)
				local matcher = shared_json("shortcuts/data/auto_click_defaults.json")
				ports.screen = Screen.new(screen_vision(services, ports, catalogue, matcher, timeouts), {
					catalogue = catalogue, poll_ms = timeouts.wait_for_poll_ms,
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
				if services.notifier.send(text, { level = "error", private = true }) ~= true then
					Logger.warn(LOG, "A workflow notice could not be shown.")
				end
			end,
			timeouts = timeouts,
		}
	end,
})
