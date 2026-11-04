--- _shared/lua/shortcuts/physical_editor_window.lua

--- ==============================================================================
--- MODULE: Shared Physical Shortcut Window Protocol
--- DESCRIPTION:
--- Keeps one exact native page/session attached to a shared editor owner. Only
--- native adapters open windows and supply source, availability and picker ports.
--- ==============================================================================

local Editor = require("shortcuts.physical_editor")
local Json = require("json")
local M = {}
local LABELS = {
	title = "physical_shortcuts.window_title", ["position-label"] = "physical_shortcuts.position",
	["manual-hint"] = "physical_shortcuts.manual_hint", capture = "physical_shortcuts.capture",
	["capture-reason"] = "physical_shortcuts.capture_unavailable", empty = "physical_shortcuts.empty",
	edit = "physical_shortcuts.edit", ["modifier-label"] = "ui_typing.tab_modifiers",
	choose = "dialog.action_picker.label", add = "button.add", remove = "button.remove",
	save = "button.save", cancel = "button.cancel", close = "button.close", saved = "common.saved",
	source_changed = "physical_shortcuts.source_changed", save_failed = "physical_shortcuts.save_failed",
	saved_reopen = "physical_shortcuts.saved_reopen", collision = "physical_shortcuts.collision",
	unavailable = "physical_shortcuts.position_unavailable", window_unavailable = "physical_shortcuts.window_unavailable",
}

--- Creates a shared protocol over a still-owned native page.
--- @param options table Editor ports plus page_current, send, close and translate.
--- @return table window Exact session message and close operations.
function M.new(options)
	for _, name in ipairs({ "page_current", "send", "close", "translate" }) do
		assert(type(options[name]) == "function", "physical window port is incomplete")
	end
	local window, editor, ready, busy, retired = {}, nil, false, false, false
	local close_requested, editor_closed, editor_retiring, native_closed = false, false, false, false
	local native_close = options.close
	local function current() return not retired and options.page_current() == true end
	local ports = {}
	for key, value in pairs(options) do ports[key] = value end
	ports.current = function(receipt)
		return current() and options.current(receipt) == true and current()
	end
	ports.emit = function(packet)
		if current() then return options.send("selected", packet) == true end
		return false
	end
	ports.emit_position = function(packet)
		if not current() then return false end
		return options.send("captured", packet) == true and current()
	end
	editor = Editor.new(ports)
	local editor_close = editor.close
	local function retire_editor()
		if editor_closed then return true end
		if editor_retiring then return false end
		editor_retiring = true
		local called, acknowledged = pcall(editor_close)
		editor_retiring = false
		if called and acknowledged == true then editor_closed = true end
		return editor_closed
	end
	--- Routes closed shared-page operations to their exact native session.
	--- @param message table Closed editor, position observation or retirement request.
	--- @return boolean handled
	function window.receive(message)
		if busy or type(message) ~= "table" then return false end
		local fields = { ready = { action = true }, choose = { action = true, request = true },
			capture_position = { action = true, request = true }, cancel_position = { action = true },
			save = { action = true, token = true }, remove = { action = true, slot = true }, close = { action = true } }
		local allowed = fields[message.action]
		if not allowed then return false end
		for key in pairs(message) do if not allowed[key] then return false end end
		if message.action == "close" then return window.close() end
		if not current() then return false end
		if message.action == "ready" then
			if ready then return false end
			busy = true
			local called, packet, reason = pcall(editor.open)
			busy = false
			if not current() then return false end
			if not called or not packet then
				packet = { entries = {}, positions = {}, capture = false, readonly = true,
					reason = called and reason == "source_changed" and "source_changed" or "window_unavailable" }
			end
			packet.entries, packet.positions = Json.array(packet.entries), Json.array(packet.positions)
			packet.strings = {}
			for key, name in pairs(LABELS) do packet.strings[key] = options.translate(name) end
			if not current() then return false end
			ready = options.send("init", packet) == true
			return ready
		end
		if not ready then return false end
		if message.action == "cancel_position" then return editor.cancel_position() end
		if message.action == "capture_position" then
			local called, enrolled = pcall(editor.capture_position, message.request)
			if not called or enrolled ~= true then options.send("refused", "unavailable") end
			return called and enrolled == true
		end
		if message.action == "choose" then
			local called, opened = pcall(editor.choose, message.request)
			if not called or opened ~= true then options.send("refused", "save_failed") end
			return called and opened == true
		end
		busy = true
		local called, result
		if message.action == "save" then called, result = pcall(editor.save, message.token)
		else called, result = pcall(editor.remove, message.slot) end
		busy = false
		if not current() then return false end
		if called and type(result.entries) == "table" then result.entries = Json.array(result.entries) end
		return options.send("result", called and result or { committed = false, reason = "save_failed" }) == true
	end
	--- Closes only after original observation and native-page retirement acknowledge.
	--- Refusal retains the exact remaining operation; commands stay revoked.
	--- @return boolean closed Both original owners acknowledged retirement.
	function window.close()
		if busy or native_closed then return false end
		-- Reserve before the page getter or either retirement callback can reenter.
		busy = true
		if not close_requested then
			local called, owned = pcall(current)
			if not called or owned ~= true or retired then busy = false; return false end
		end
		close_requested, retired = true, true
		if retire_editor() ~= true then busy = false; return false end
		local called, acknowledged = pcall(native_close)
		if called and acknowledged == true then native_closed = true end
		busy = false
		return native_closed
	end
	--- Revokes the page and retries only its original observation retirement.
	--- This does not acknowledge native-page destruction.
	--- @return boolean retired Original editor retirement acknowledged.
	function window.retire()
		retired = true
		return retire_editor()
	end
	return window
end
return M
