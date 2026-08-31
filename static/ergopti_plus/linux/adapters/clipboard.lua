--- adapters/clipboard.lua

--- ==============================================================================
--- MODULE: Clipboard Adapter (Linux)
--- DESCRIPTION:
--- Reads and writes the system clipboard, and pastes it — the route for text the
--- active keyboard layout cannot type as keystrokes.
---
--- WHEN THIS IS USED, AND WHY THAT CHANGED:
--- The plan this driver was built from expected the clipboard to be the COMMON
--- path, on the reasoning that accented replacements cannot be typed. That was
--- true of ydotool and is no longer true here: adapters/keyboard_layout.lua
--- resolves characters against the session's own XKB keymap, so é, ç, «, € and
--- everything else the user's layout can produce is typed as a real keystroke.
--- What is left for the clipboard is what the layout genuinely cannot reach —
--- an emoji, a CJK character, a symbol on no key at all. That is a rarer path
--- and a better one to be rare: pasting is visible, racy against clipboard
--- managers, and destroys whatever the user had copied unless it is put back.
---
--- WHY IT STILL HAS TO EXIST:
--- Without it, an unresolvable character means an expansion that erases the
--- trigger and types nothing — the user loses text they had. Refusing to expand
--- would be honest but useless for exactly the replacements people reach for.
---
--- FEATURES & RATIONALE:
--- 1. Save, set, paste, restore. The restore is the part that is easy to skip
---    and the part users notice: an expansion that silently eats a copied
---    password or URL is worse than one that does not fire.
--- 2. Two backends, chosen by the session rather than by probing order.
---    wl-copy/wl-paste under Wayland, xclip under X11 — asking the wrong one
---    hangs rather than failing, which is why the display server decides.
--- 3. The paste keystroke goes through uinput like everything else, so it obeys
---    the same grab and the same ordering as the rest of an injection.
--- 4. Bounded waits everywhere. A clipboard tool with no selection owner blocks
---    forever by design; every read is given a timeout so an expansion cannot
---    wedge the daemon.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Shell = require("adapters.shell_runner")
local DisplayServer = require("infra.display_server")
local EvdevCodes = require("infra.evdev_codes")

local LOG = "adapters.clipboard"




-- ===============================================
-- ===============================================
-- ======= 1/ Constants ==========================
-- ===============================================
-- ===============================================

-- Seconds a clipboard read may take before it is abandoned. `xclip -o` with no
-- selection owner blocks forever rather than returning empty, and a blocked read
-- on the injection path is a frozen daemon.
local READ_TIMEOUT_S = 1

-- Milliseconds to let the target application register the new clipboard content
-- before the paste keystroke arrives. A paste that races the set pastes what was
-- there before, which is the previous expansion — the most confusing possible
-- output.
local SETTLE_MS = 30

-- Milliseconds to let the paste complete before the previous content is put
-- back. Restoring too early restores it into the paste itself.
local RESTORE_DELAY_MS = 120

-- Time allowed for the focused application to publish a Ctrl+C selection.
local COPY_SETTLE_MS = 80

-- evdev key values.
local VALUE_DOWN = 1
local VALUE_UP   = 0

-- KEY_V, the second half of the paste chord.
local KEY_V = 47




-- ===============================================
-- ===============================================
-- ======= 2/ Backends ===========================
-- ===============================================
-- ===============================================

--- The commands for the running session, or nil when no tool is installed.
--- @return table|nil { name, read, write_prefix }
local function backend()
	if DisplayServer.is_wayland() then
		if Shell.has_command("wl-copy") and Shell.has_command("wl-paste") then
			return {
				name  = "wl-clipboard",
				-- --no-newline: wl-paste appends one, and an expansion that grows a
				-- trailing newline every time it round-trips is a corruption.
				read  = string.format("timeout %d wl-paste --no-newline 2>/dev/null", READ_TIMEOUT_S),
				write = "wl-copy",
			}
		end
		return nil
	end

	if DisplayServer.is_x11() then
		if Shell.has_command("xclip") then
			return {
				name  = "xclip",
				read  = string.format("timeout %d xclip -selection clipboard -o 2>/dev/null", READ_TIMEOUT_S),
				write = "xclip -selection clipboard -in",
			}
		end
		if Shell.has_command("xsel") then
			return {
				name  = "xsel",
				read  = string.format("timeout %d xsel --clipboard --output 2>/dev/null", READ_TIMEOUT_S),
				write = "xsel --clipboard --input",
			}
		end
		return nil
	end

	return nil
end

--- Whether a clipboard route exists on this session.
--- @return boolean available, string|nil reason
function M.is_available()
	local b = backend()
	if b then return true end
	return false, DisplayServer.kind() == DisplayServer.UNKNOWN
		and "no display server"
		or "no clipboard tool installed (wl-clipboard on Wayland, xclip or xsel on X11)"
end

--- Reads the clipboard.
--- @return string The contents, or "" when empty or unreadable.
function M.read()
	local b = backend()
	if not b then return "" end
	return Shell.exec(b.read)
end

--- Reads one trustworthy clipboard snapshot.
--- Unlike read(), this path preserves command failure separately from a valid
--- empty clipboard so a transaction never overwrites content it could not save.
--- @param selected_backend table
--- @return boolean ok
--- @return string contents
--- @return string|nil error_message
local function read_backend_checked(selected_backend)
	local ok, contents, error_message = Shell.exec_checked(selected_backend.read)
	if not ok then return false, "", error_message end
	return true, contents, nil
end

--- Writes through the backend selected at the start of a transaction.
--- @param selected_backend table
--- @param text string
--- @return boolean
local function write_backend_checked(selected_backend, text)
	local ok, command = pcall(Shell.with_exact_stdin, selected_backend.write, text or "")
	if not ok then return false end
	local ran, result = pcall(Shell.run, command)
	return ran and result == true
end

--- Runs an injected wait and rejects both exceptions and explicit failure.
--- @param sleep_ms function
--- @param duration_ms number
--- @return boolean
local function wait_checked(sleep_ms, duration_ms)
	local ok, result = pcall(sleep_ms, duration_ms)
	return ok and result ~= false
end

--- Reads one trustworthy clipboard snapshot.
--- @return boolean ok
--- @return string contents
--- @return string|nil error_message
function M.read_checked()
	local selected_backend = backend()
	if not selected_backend then
		local _, why = M.is_available()
		return false, "", why
	end
	return read_backend_checked(selected_backend)
end

--- Writes the clipboard.
---
--- Through a heredoc rather than an argument: a replacement can contain
--- newlines, quotes and anything else a user typed into a TOML file, and an
--- argument list is the wrong shape for arbitrary bytes.
--- @param text string
--- @return boolean
function M.write(text)
	local b = backend()
	if not b then return false end
	return write_backend_checked(b, text)
end




-- ===============================================
-- ===============================================
-- ======= 3/ Pasting ============================
-- ===============================================
-- ===============================================

--- Emits Ctrl+V through the caller's uinput channel.
---
--- Ctrl+V and not Shift+Insert: it is what every graphical toolkit binds, and
--- the terminals that want Ctrl+Shift+V accept it in their own text fields
--- anyway. There is no keystroke that works in every application, which is a
--- property of the desktop rather than a choice available here.
--- @param uinput table Channel exposing emit(code, value) -> boolean.
--- @return boolean True only when the complete chord reached the wire.
local function press_paste(uinput)
	if uinput.emit(EvdevCodes.KEY_LEFTCTRL, VALUE_DOWN) ~= true then return false end
	if uinput.emit(KEY_V, VALUE_DOWN) ~= true then return false end
	if uinput.emit(KEY_V, VALUE_UP) ~= true then return false end
	if uinput.emit(EvdevCodes.KEY_LEFTCTRL, VALUE_UP) ~= true then return false end
	return true
end

--- Delivers text by clipboard: save, set, paste, restore.
---
--- The restore is not optional. An expansion that eats whatever the user had
--- copied is a worse failure than one that does not fire, because the user does
--- not find out until they paste something else.
--- @param text string Text to deliver.
--- @param uinput table Channel exposing emit(code, value).
--- @param sleep_ms function Blocking sleep, injected so this module owns no timer.
--- @return boolean True when the paste was issued.
function M.paste_text(text, uinput, sleep_ms)
	if type(text) ~= "string" or text == "" then return false end
	if type(uinput) ~= "table" or type(uinput.emit) ~= "function" then
		Logger.error(LOG, "paste_text(): no uinput channel to press the paste chord with.")
		return false
	end

	local b = backend()
	if not b then
		local _, why = M.is_available()
		Logger.error(LOG, "paste_text(): %s.", tostring(why))
		return false
	end

	local snapshot_ok, saved, snapshot_error = read_backend_checked(b)
	if not snapshot_ok then
		Logger.error(LOG, "paste_text(): could not snapshot the clipboard via %s — %s.",
			b.name, tostring(snapshot_error or "command failed"))
		return false
	end

	if not write_backend_checked(b, text) then
		Logger.error(LOG, "paste_text(): could not set the clipboard via %s.", b.name)
		return false
	end

	local paste_ok, issued = pcall(function()
		if not wait_checked(sleep_ms, SETTLE_MS) then return false end
		if not press_paste(uinput) then return false end
		if not wait_checked(sleep_ms, RESTORE_DELAY_MS) then return false end
		return true
	end)

	-- Restored even when it was empty: writing "" back is what leaves the
	-- clipboard as the user left it, and skipping the restore on an empty save
	-- would leave our replacement sitting there.
	if not write_backend_checked(b, saved) then
		Logger.warn(LOG, "paste_text(): the previous clipboard content could not be restored.")
		return false
	end
	if not paste_ok or not issued then
		Logger.error(LOG, "paste_text(): checked paste chord emission failed.")
		return false
	end

	Logger.debug(LOG, "Pasted %d byte(s) via %s.", #text, b.name)
	return true
end

--- Copies and replaces the focused selection while preserving the clipboard.
--- @param transform function selected_text -> replacement_text
--- @param emit_combo function combo -> boolean
--- @param sleep_ms function Blocking millisecond wait.
--- @return boolean ok
--- @return string|nil reason
function M.transform_selection(transform, emit_combo, sleep_ms)
	if type(transform) ~= "function" or type(emit_combo) ~= "function"
			or type(sleep_ms) ~= "function" then
		return false, "invalid_dependencies"
	end
	local b = backend()
	if not b then
		local _, why = M.is_available()
		return false, why
	end

	local snapshot_ok, saved, snapshot_error = read_backend_checked(b)
	if not snapshot_ok then return false, snapshot_error or "clipboard_snapshot_failed" end
	local sentinel = "__ERGOPTI_SELECTION_PROBE_" .. tostring({}) .. "__"

	local function restore()
		return write_backend_checked(b, saved)
	end
	local function fail(reason)
		if not restore() then return false, "clipboard_restore_failed" end
		return false, reason
	end
	if not write_backend_checked(b, sentinel) then
		return fail("clipboard_probe_write_failed")
	end

	local copy_ok, copied = pcall(emit_combo, "ctrl+c")
	if not copy_ok or copied ~= true then return fail("copy_chord_failed") end
	if not wait_checked(sleep_ms, COPY_SETTLE_MS) then return fail("copy_settle_failed") end

	local selection_ok, selected, selection_error = read_backend_checked(b)
	if not selection_ok then
		return fail(selection_error or "selection_read_failed")
	end
	if selected == sentinel then return fail("no_selection") end

	local transformed_ok, replacement = pcall(transform, selected)
	if not transformed_ok or type(replacement) ~= "string" then
		return fail("selection_transform_failed")
	end
	if not write_backend_checked(b, replacement) then
		return fail("replacement_write_failed")
	end

	local paste_ok, pasted = pcall(function()
		if not wait_checked(sleep_ms, SETTLE_MS) then return false end
		if emit_combo("ctrl+v") ~= true then return false end
		if not wait_checked(sleep_ms, RESTORE_DELAY_MS) then return false end
		return true
	end)
	local restored = restore()
	if not restored then return false, "clipboard_restore_failed" end
	if not paste_ok or pasted ~= true then return false, "paste_chord_failed" end
	Logger.debug(LOG, "Replaced a %d-byte selection via %s.", #selected, b.name)
	return true
end

return M
