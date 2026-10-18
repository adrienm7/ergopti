--- tests/support/modules/llm/selection_translation_destination.lua

--- ==============================================================================
--- MODULE: Selection Translation Native Destination Fixture
--- DESCRIPTION:
--- Supplies native window, AX element and observer ports to the real keymap
--- destination tracker. The tracker, its classification and its lifecycle remain
--- production code; focus notifications are delivered explicitly by scenarios.
--- ==============================================================================

local M = {}

--- Starts the real classified-destination tracker over native boundary doubles.
--- @param world table Translation fixture.
--- @return table tracker Native-boundary observations and controls.
function M.attach(world)
	local native = { reads = 0, callbacks = {}, windows = {} }
	local function watcher(callback)
		local item = { running = false }
		function item:start() self.running = true; return self end
		function item:stop() self.running = false; return self end
		function item:isRunning() return self.running end
		function item:callback(fn) callback = fn; return self end
		function item:addWatcher() return self end
		function item:notify(...)
			if self.running then callback(...) end
		end
		native.callbacks[#native.callbacks + 1] = item
		return item
	end
	local function focused_window()
		native.reads = native.reads + 1
		if not world.focus then return nil end
		if native.windows[world.focus] then return native.windows[world.focus] end
		local pid, id = world.focus:match("^(%d+):(%d+)$")
		assert(pid and id, "native fixture requires a pid:window identity")
		local app = { pid = function() return tonumber(pid) end, name = function() return "TranslateApp" end }
		function app:newWatcher(callback) return watcher(callback) end
		local element = {}
		function element:attributeValue(attribute)
			if attribute == "AXRole" then return world.secure and "AXSecureTextField" or "AXTextField" end
			if attribute == "AXSubrole" then return nil end
			error("unmodeled AX attribute " .. tostring(attribute))
		end
		local window = { element = element, app = app }
		function window:id() return tonumber(id) end
		function window:application() return app end
		function window:title() return "Draft" end
		function window:newWatcher(callback) return watcher(callback) end
		native.windows[world.focus] = window
		return window
	end
	hs.window.focusedWindow = focused_window
	hs.application.watcher.new = function(callback) return watcher(callback) end
	hs.axuielement = {
		applicationElementForPID = function(pid)
			native.reads = native.reads + 1
			local window = focused_window()
			if not window or window:application():pid() ~= pid then return nil end
			return { attributeValue = function(_, attribute)
				assert(attribute == "AXFocusedUIElement")
				return window.element
			end }
		end,
		observer = { new = function() return watcher(function() end) end },
	}
	package.loaded["modules.keymap.utils"] = nil
	package.loaded["adapters.secure_field_detector"] = nil
	native.utils = require("modules.keymap.utils")
	native.utils.start_ignored_win_tracking({}, {})
	-- A normal asynchronous classification, rather than a fabricated receipt.
	native.utils.is_ignored_window({}, {})
	for _, timer in ipairs(hs.timer.__timers) do
		if timer.running and timer.fired == 0 and timer.delay == 0 then timer:fire() end
	end
	assert(native.utils.capture_text_destination(), "real destination tracking must classify the native fixture")
	function native.change_focus(identity)
		world.focus = identity
		local last = #native.callbacks
		for index = 1, last do native.callbacks[index]:notify("TranslateApp", hs.application.watcher.activated) end
	end
	world.native_destination = native
	return native
end

return M
