--- tests/unit/modules/keystats/context_tracker/test_context_tracker_ax_dead_element.lua

--- ==============================================================================
--- MODULE: Context Tracker — a dead or unwatchable focused element
--- DESCRIPTION:
--- Issue #104 logged two ERRORs with tracebacks per focus change: removing the
--- AXValueChanged watcher of an element macOS had already destroyed raised
--- "AXUIElementRef is invalid", and watching a secure text field raised
--- "Illegal argument". Both are ordinary focus traffic. The dead element's
--- watcher is gone with it, so the focus change completes and the element is
--- never retried; an unwatchable element is simply not watched. Any other
--- mutation failure stays an ERROR (ax-dead-element).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds one AX element double.
--- @param name string Identity used by the observer double.
--- @return table element
local function element(name)
	return { name = name, attributeValue = function() return nil end }
end

--- Attaches the tracker, then delivers focus changes through its real callback.
--- @param remove_error string|nil Error raised when removing the first element's watcher.
--- @param add_error string|nil Error raised when watching the second element.
--- @return table result { rendered, removed }
local function focus_through(remove_error, add_error)
	package.loaded["modules.keystats.context_tracker"] = nil
	local first, second, third = element("first"), element("second"), element("third")
	local removed = {}
	local handler = nil
	local observer = {}
	function observer.addWatcher(_, target)
		if target == second and add_error then error(add_error, 0) end
		return observer
	end
	function observer.removeWatcher(_, target)
		removed[#removed + 1] = target.name
		if target == first and remove_error then error(remove_error, 0) end
		return observer
	end
	function observer.callback(_, fn) handler = fn; return observer end
	function observer.start() return observer end
	function observer.stop() return observer end
	local tracker = helpers.load_with_stubs("modules.keystats.context_tracker", {
		axuielement = {
			observer = { new = function() return observer end },
			applicationElement = function()
				return { attributeValue = function(_, name)
					if name == "AXFocusedUIElement" then return first end
					return nil
				end }
			end,
		},
	})
	local core_state = { is_enabled = true, is_secure_field = false, active_app_name = "Editor", ax_observer = nil }
	helpers.assert_true(tracker.init(core_state, {
		flush_buffer = function() return true end,
		append_log = function() return true end,
	}, function() return false end))
	helpers.assert_eq(tracker.update_ax_observer(4242), true)
	assert(handler, "the observer callback must be installed")
	local lines = {}
	local Logger = require("infra.logger")
	helpers.admit_logger_privacy(Logger)
	Logger.set_level("DEBUG")
	Logger.set_sink(function(line) lines[#lines + 1] = line end)
	local ok, err = pcall(function()
		handler(observer, second, "AXFocusedUIElementChanged", {})
		handler(observer, third, "AXFocusedUIElementChanged", {})
	end)
	Logger.set_sink(nil)
	if not ok then error(err, 0) end
	return { rendered = table.concat(lines, "\n"), removed = removed }
end

helpers.describe("context tracker: dead or unwatchable focused elements (ax-dead-element)", function()
	helpers.it("completes the focus change when the previous element is already destroyed", function()
		local result = focus_through("...ergopti_plus/macos/modules/keystats/context_tracker.lua:631: AXUIElementRef is invalid\nstack traceback:\n\t[C]: in method 'removeWatcher'")
		helpers.assert_true(result.rendered:find("[ERROR]", 1, true) == nil, result.rendered)
		helpers.assert_eq(result.removed, { "first", "second" },
			"the dead element is never retried; the next focus removes its successor")
	end)

	helpers.it("skips watching an element that refuses value notifications", function()
		local result = focus_through(nil, "...ergopti_plus/macos/modules/keystats/context_tracker.lua:631: Illegal argument\nstack traceback:\n\t[C]: in method 'addWatcher'")
		helpers.assert_true(result.rendered:find("[ERROR]", 1, true) == nil, result.rendered)
		helpers.assert_eq(result.removed, { "first" }, "an unwatched element has no watcher to remove")
	end)

	helpers.it("keeps any other watcher failure an ERROR", function()
		local result = focus_through(nil, "context_tracker.lua:631: observer refused the watcher")
		helpers.assert_contains(result.rendered, "[ERROR]")
		helpers.assert_contains(result.rendered, "Replacement AXValueChanged watcher setup failed")
	end)
end)
