--- tests/desktop/cover_window.lua

--- ==============================================================================
--- MODULE: Covering Window For The Desktop Proofs
--- DESCRIPTION:
--- A plain GTK window with a text field, from another process, which the
--- desktop proofs open over an Ergopti page so the page is covered by a window
--- the compositor focused and the user types in, as an editor would be. It
--- presents itself once, writes "mapped" to the file named by its first
--- argument when the compositor activates it, mirrors what its field receives
--- into "<file>.typed", and stays until it is killed.
--- ==============================================================================

local ready_path = assert(arg[1], "usage: cover_window.lua <ready file>")
local lgi = require("lgi")
local Gtk = lgi.require("Gtk", "3.0")
local GLib = lgi.GLib

--- Replaces one small file's content.
--- @param path string
--- @param text string
local function write(path, text)
	local file = assert(io.open(path, "w"))
	file:write(text)
	file:close()
end

local window = Gtk.Window({ title = "Ergopti proof cover", default_width = 1200, default_height = 760 })
local entry = Gtk.Entry()
window:add(entry)
window.on_destroy = function() Gtk.main_quit() end
entry.on_changed = function() write(ready_path .. ".typed", entry:get_text()) end
window:show_all()
window:present()

-- Reported once activated, so the proof waits for the compositor's focus
-- decision instead of a fixed delay.
local reported = false
GLib.timeout_add(GLib.PRIORITY_DEFAULT, 50, function()
	if not reported and window.is_active then
		write(ready_path, "mapped\n")
		reported = true
	end
	return true
end)
Gtk.main()
