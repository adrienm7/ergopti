--- modules/dynamic_hotstrings/user_code.lua

--- ==============================================================================
--- MODULE: Programmable Hotstrings (Linux)
--- DESCRIPTION:
--- Binds the shared programmable-hotstring lifecycle (_shared/lua/
--- dynamic_hotstrings/user_code_driver.lua) to this driver: user callbacks are
--- deferred through libuv under the daemon-owned source, cursor and lifecycle
--- receipts. Static previews never evaluate source callbacks.
---
--- FEATURES & RATIONALE:
--- 1. Deferred, not inline. A callback runs on a zero-delay timer of the
---    scheduler adapter, so it never runs inside the keyboard hook.
--- 2. The daemon owns the activation interval: it travels with every capture
---    instead of being set on the native owner (no apply_time port).
--- ==============================================================================
local Driver = require("dynamic_hotstrings.user_code_driver")
local FileSystem = require("adapters.file_system")
local TimerScheduler = require("adapters.timer_scheduler")
local ConfigPaths = require("infra.config_paths")
local Logger = require("logger.shim")
local Notifier = require("adapters.application_notifier")
local I18n = require("infra.i18n")
local Manifest = require("infra.manifest_reader")

--- Notification options per severity on this driver's notifier.
local NOTIFY_LEVEL = { error = "error", warning = "warning" }

--- Asks the daemon's native ports and defers each callback to a zero-delay timer.
--- @param native table Capture/current/commit native ports.
--- @return table binding
local function native_binding(native)
	return {
		capture = function(rule, seconds) return native.capture(rule, seconds) end,
		current = function(capture) return native.current(capture) end,
		publication_current = function(capture) return native.publication_current(capture) end,
		publication_cached = function(capture) return native.publication_cached(capture) end,
		invoke = function(rule, context, done, capture)
			capture.execution_context = context
			local handle, cancelled
			return {
				start = function()
					handle = TimerScheduler.after(0, function()
						if cancelled then return end
						if context.cancelled() then done(false); return end
						local ok, result = pcall(rule.callback, context)
						if ok then done(result) else done(nil, "callback-error") end
					end)
					return type(handle) == "table" and handle.armed == true
				end,
				cancel = function()
					cancelled = true
					return not handle or TimerScheduler.cancel(handle) == true
				end,
			}
		end,
		commit = function(result, capture, rule, publication)
			return native.commit(result, capture, rule, function()
				return capture.execution_context.cancelled() == false
			end, publication)
		end,
	}
end

return Driver.new({
	logger = Logger,
	log = "dynamic_hotstrings.user_code",
	platform = "linux",
	-- Resolved at call time: a collaborator replaced after load is still the one used.
	read = function(path) return FileSystem.read_with_status(path) end,
	write = function(path, content, expected) return FileSystem.write_if_unchanged(path, content, expected) end,
	config_dir = function() return ConfigPaths.get_config_dir() end,
	translate = function(key) return I18n.get(key) end,
	notify = function(text, severity) return Notifier.send(text, { level = NOTIFY_LEVEL[severity] }) end,
	default_time_seconds = function() return Manifest.default_for(Driver.TIME_ACTIVATION_KEY) end,
	native_binding = native_binding,
})
