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
	--- Routes closed shared-page operations to their exact native session.
	--- @param message table Closed editor, position observation or retirement request.
	--- @return boolean handled
	function window.receive(message)
		if busy or not current() or type(message) ~= "table" then return false end
		local fields = { ready = { action = true }, choose = { action = true, request = true },
			capture_position = { action = true, request = true }, cancel_position = { action = true },
			save = { action = true, token = true }, remove = { action = true, slot = true }, close = { action = true } }
		local allowed = fields[message.action]
		if not allowed then return false end
		for key in pairs(message) do if not allowed[key] then return false end end
		if message.action == "close" then return window.close() end
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
	--- Retires the exact native page only after its close acknowledges completion.
	--- @return boolean closed
	function window.close()
		if busy or retired or not current() then return false end
		busy = true
		local called, closed = pcall(options.close)
		busy = false
		if not called or closed ~= true then return false end
		retired = true
		editor.close()
		return true
	end
	--- Revokes a native closed page without acquiring or publishing configuration.
	function window.retire()
		retired = true
		editor.close()
	end
	return window
end
return M
