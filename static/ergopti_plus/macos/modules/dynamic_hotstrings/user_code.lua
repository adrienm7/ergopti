--- modules/dynamic_hotstrings/user_code.lua

--- ==============================================================================
--- MODULE: Programmable Hotstrings (macOS)
--- DESCRIPTION:
--- Binds the shared programmable-hotstring lifecycle (_shared/lua/
--- dynamic_hotstrings/user_code_driver.lua) to this driver: user callbacks are
--- deferred outside the event tap through its consumed-input owner. Every
--- driver output requires the original source, cursor and lifecycle receipt.
---
--- FEATURES & RATIONALE:
--- 1. Deferred out of the tap. A callback runs as a consumed-input action of the
---    synthetic input owner, and a retired or cancelled one gives its slot back
---    through commit(false).
--- 2. The keymap owns the activation interval (apply_time), checks that the
---    dynamic group is enabled (current), and a registered magic action
---    pre-empts a suffix (claims).
--- 3. A report raised inside a running callback is deferred until it returns
---    (defer_report), so the notification cannot re-enter the tap.
--- ==============================================================================
local Driver = require("dynamic_hotstrings.user_code_driver")
local FileSystem = require("adapters.file_system")
local SyntheticInput = require("adapters.synthetic_input")
local ConfigPaths = require("infra.config_paths")
local Logger = require("infra.logger")
local Notifier = require("adapters.application_notifier")
local I18n = require("infra.i18n")
local Manifest = require("infra.manifest_reader")

--- Notification kind per severity on this driver's notifier.
local NOTIFY_KIND = { error = "error", warning = "warn" }

--- Group whose enablement gates a user hotstring.
local DYNAMIC_GROUP = "dynamichotstrings"

--- Asks the keymap and defers each callback to its consumed-input owner.
--- @param keymap table Native input owner.
--- @return table binding
local function native_binding(keymap)
	return {
		capture = function(rule) return keymap.capture_user_hotstring(rule) end,
		current = function(capture)
			return keymap.is_group_enabled(DYNAMIC_GROUP) == true and keymap.owns_user_hotstring(capture) == true
		end,
		publication_current = function(capture) return keymap.owns_user_hotstring_publication(capture) end,
		publication_cached = function(capture) return keymap.owns_user_hotstring_publication_cached(capture) end,
		invoke = function(rule, context, done, capture)
			capture.execution_context = context
			local cancelled, scheduled, settled, retired = false, false, false, false
			local function retire()
				if retired then return true end
				if keymap.owns_user_hotstring(capture) == true
					and keymap.commit_user_hotstring(false, capture, rule) ~= true then return false end
				retired = true
				return true
			end
			return {
				start = function()
					scheduled = SyntheticInput.defer_consumed_input_action("programmable hotstring", function()
						if cancelled then retire(); settled = true; return end
						if context.cancelled() then done(false); settled = true; return end
						local ok, result = pcall(rule.callback, context)
						if ok then done(result) else done(nil, "callback-error") end
						settled = true
					end) == true
					return scheduled
				end,
				cancel = function()
					cancelled = true
					if not scheduled then return true end
					return settled and retire()
				end,
			}
		end,
		retire = function(capture, rule)
			if keymap.owns_user_hotstring(capture) ~= true then return true end
			return keymap.commit_user_hotstring(false, capture, rule) == true
		end,
		commit = function(result, capture, rule, publication)
			return keymap.commit_user_hotstring(result, capture, rule, function()
				return capture.execution_context.cancelled() == false
			end, publication)
		end,
	}
end

return Driver.new({
	logger = Logger,
	log = "dynamic_hotstrings.user_code",
	platform = "macos",
	-- Resolved at call time: a collaborator replaced after load is still the one used.
	read = function(path) return FileSystem.read_with_status(path) end,
	write = function(path, content, expected) return FileSystem.write_if_unchanged(path, content, expected) end,
	config_dir = function() return ConfigPaths.get_config_dir() end,
	translate = function(key) return I18n.get(key) end,
	notify = function(text, severity) return Notifier.send(text, { kind = NOTIFY_KIND[severity] }) end,
	default_time_seconds = function() return Manifest.default_for(Driver.TIME_ACTIVATION_KEY) end,
	native_binding = native_binding,
	apply_time = function(keymap, seconds) return keymap.set_user_hotstring_time_activation(seconds) end,
	claims = function(keymap, buffer) return keymap.has_registered_magic_action(buffer) end,
	defer_report = function(report, kind, id)
		if SyntheticInput.is_collecting_callback() then
			return SyntheticInput.defer_after_callback("programmable hotstring error", report, kind, id) == true
		end
		return nil
	end,
	preview_view = function(row) return row.preview end,
})
