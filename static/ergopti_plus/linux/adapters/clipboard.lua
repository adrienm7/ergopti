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
---    forever by design; every read and write has a timeout so an expansion cannot
---    wedge the daemon.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local Shell = require("core.process.adapters.shell_runner")
local DisplayServer = require("core.ui.engine.display_server")
local EvdevCodes = require("infra.evdev_codes")

local LOG = "adapters.clipboard"




-- ===============================================
-- ===============================================
-- ======= 1/ Constants ==========================
-- ===============================================
-- ===============================================

-- Seconds a clipboard operation may take before it is abandoned. A stalled
-- display can block setters as well as readers and freeze the injection path.
local IO_TIMEOUT_S = 1

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

-- Seconds the change-counter read may take. It runs just before a tap-hold's
-- Ctrl+C, so a hung selection owner must not hold the copy back for long.
local COUNTER_TIMEOUT_S = "0.5"

-- evdev key values.
local VALUE_DOWN = 1
local VALUE_UP   = 0

-- KEY_V on a US layout. The chord presses whichever key types "v" in the live
-- layout (keyboard_layout.shortcut_keycode): on Ergopti this code is a comma,
-- and Ctrl+comma pasted nothing — or opened an editor's settings — while the
-- expansion was recorded as delivered.
local US_KEY_V = 47




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
				read  = string.format("timeout %d wl-paste --no-newline 2>/dev/null", IO_TIMEOUT_S),
				write = "wl-copy",
				-- A file manager publishes a copied selection under this target
				-- (RFC 2483); the plain read gets its text form, if any.
				read_uri_list = string.format(
					"timeout %d wl-paste --no-newline --type text/uri-list 2>/dev/null", IO_TIMEOUT_S),
				-- Every MIME type the owner offers, one per line: a borrower
				-- checks it before replacing formats it could not put back.
				list_types = string.format("timeout %d wl-paste --list-types 2>/dev/null", IO_TIMEOUT_S),
				-- wl-paste exits 1 on an empty clipboard and on a failed read
				-- alike; only its message tells them apart.
				owned = function()
					local empty = Shell.exec_checked(string.format(
						"{ timeout %d wl-paste --list-types 2>&1 >/dev/null; } | grep -qx 'Nothing is copied'",
						IO_TIMEOUT_S))
					if empty then return false end
					return nil
				end,
				-- Gives an empty clipboard back empty, not as an owned "" entry.
				clear = function()
					return Shell.exec_checked(string.format("timeout %d wl-copy --clear", IO_TIMEOUT_S)) == true
				end,
				-- One advertised type's exact bytes, for a multi-format snapshot.
				read_target = function(target)
					return string.format("timeout %d wl-paste --no-newline --type %s 2>/dev/null", IO_TIMEOUT_S,
						Shell.quote(target))
				end,
			}
		end
		return nil
	end

	if DisplayServer.is_x11() then
		if Shell.has_command("xclip") then
			return {
				name  = "xclip",
				read  = string.format("timeout %d xclip -selection clipboard -o 2>/dev/null", IO_TIMEOUT_S),
				write = "xclip -selection clipboard -in",
				read_uri_list = string.format(
					"timeout %d xclip -selection clipboard -t text/uri-list -o 2>/dev/null", IO_TIMEOUT_S),
				-- The ICCCM TARGETS answer: every target the owner can convert to.
				list_types = string.format(
					"timeout %d xclip -selection clipboard -t TARGETS -o 2>/dev/null", IO_TIMEOUT_S),
				-- xclip exits 1 on an ownerless clipboard and on a failed read alike.
				owned = function() return (require("adapters.x11_selection_stamp").owned()) end,
				-- Gives an unowned clipboard back unowned, not as an owned "" entry.
				clear = function() return (require("adapters.x11_selection_stamp").disown()) == true end,
				read_target = function(target)
					return string.format("timeout %d xclip -selection clipboard -t %s -o 2>/dev/null", IO_TIMEOUT_S,
						Shell.quote(target))
				end,
			}
		end
		if Shell.has_command("xsel") then
			return {
				name  = "xsel",
				read  = string.format("timeout %d xsel --clipboard --output 2>/dev/null", IO_TIMEOUT_S),
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
	local bounded = string.format("timeout %d %s", IO_TIMEOUT_S, selected_backend.write)
	local ok, command = pcall(Shell.with_exact_stdin, bounded, text or "")
	if not ok then return false end
	local ran, result = pcall(Shell.run, command)
	return ran and result == true
end

-- Targets that carry the text the writer restores, or ICCCM bookkeeping
-- with no payload of its own. Anything else (text/html, image/png, a file
-- manager's copied files...) is a format the single-type writers cannot
-- offer back alongside the text.
local TEXT_EQUIVALENT_TARGETS = {
	["TARGETS"] = true, ["TIMESTAMP"] = true, ["MULTIPLE"] = true,
	["SAVE_TARGETS"] = true, ["DELETE"] = true, ["INSERT_SELECTION"] = true,
	["INSERT_PROPERTY"] = true, ["UTF8_STRING"] = true, ["STRING"] = true,
	["TEXT"] = true, ["COMPOUND_TEXT"] = true, ["text/plain"] = true,
}

-- ICCCM bookkeeping an owner answers itself; it carries no saved payload.
local BOOKKEEPING_TARGETS = {
	["TARGETS"] = true, ["TIMESTAMP"] = true, ["MULTIPLE"] = true, ["SAVE_TARGETS"] = true,
	["DELETE"] = true, ["INSERT_SELECTION"] = true, ["INSERT_PROPERTY"] = true,
}

--- Whether one advertised target is the restored text or bookkeeping.
--- @param target string One line of the type listing.
--- @return boolean
local function is_text_equivalent_target(target)
	if TEXT_EQUIVALENT_TARGETS[target] then return true end
	-- text/plain;charset=utf-8 and its spelling variants name the same text.
	local charset = target:lower():match("^text/plain%s*;%s*charset%s*=%s*\"?([%w%-_]+)\"?$")
	return charset == "utf-8" or charset == "utf8"
end

--- Lists the clipboard formats a restore of the text alone would destroy.
--- @param selected_backend table
--- @return boolean ok False when the formats could not be enumerated.
--- @return table lost Advertised formats other than the text.
--- @return boolean offers_text Whether a text format is advertised at all.
local function formats_lost_by_text_restore(selected_backend)
	if not selected_backend.list_types then return false, {}, false end
	local ok, listing = Shell.exec_checked(selected_backend.list_types)
	if not ok then return false, {}, false end
	local lost, offers_text = {}, false
	for line in listing:gmatch("[^\r\n]+") do
		local target = require("core.text.engine.utils_core").trim(line)
		if target ~= "" and not is_text_equivalent_target(target) then lost[#lost + 1] = target
		elseif target ~= "" and not BOOKKEEPING_TARGETS[target] then offers_text = true end
	end
	return true, lost, offers_text
end


-- Bytes a multi-format snapshot may hold in all; a larger clipboard (a raw
-- screenshot in several encodings) is refused rather than held in memory.
local MAX_RICH_SNAPSHOT_BYTES = 64 * 1024 * 1024

--- Reads every advertised format's bytes for the multi-format owner.
--- @param selected_backend table
--- @return table|nil targets Ordered { { name, data } }, nil when one read failed.
local function read_all_targets(selected_backend)
	local ok, listing = Shell.exec_checked(selected_backend.list_types)
	if not ok then return nil end
	local targets, seen, total = {}, {}, 0
	for line in listing:gmatch("[^\r\n]+") do
		local name = require("core.text.engine.utils_core").trim(line)
		if name ~= "" and not BOOKKEEPING_TARGETS[name] and not seen[name] then
			seen[name] = true
			local read_ok, data = Shell.exec_checked(selected_backend.read_target(name))
			if not read_ok then
				Logger.warn(LOG, "The clipboard owner refused its %s format; borrowing refused.", name)
				return nil
			end
			total = total + #data
			if total > MAX_RICH_SNAPSHOT_BYTES then
				Logger.warn(LOG, "Clipboard formats exceed %d bytes; borrowing refused.", MAX_RICH_SNAPSHOT_BYTES)
				return nil
			end
			targets[#targets + 1] = { name = name, data = data }
		end
	end
	if #targets == 0 then return nil end
	return targets
end

--- Accepts a saved snapshot only when it can be restored whole.
--- Raw readers may return NUL, but the literal sh -c writer cannot carry it.
--- The text writers offer a single type: a clipboard holding HTML, an image
--- or copied files next to its text is saved format by format and restored
--- by the native multi-format owner (adapters/clipboard_owner.lua), as
--- Windows (ClipboardAll) and macOS (readAllData) restore it. Where that
--- owner cannot run, refuse before an owner acquires restoration debt or
--- mutates the clipboard.
--- @return boolean ok
--- @return table snapshot { text, targets|nil } targets set for a multi-format restore.
--- @return string|nil reason
local function read_restorable_snapshot(selected_backend)
	local ok, contents, reason = read_backend_checked(selected_backend)
	local text_withheld = false
	if not ok then
		-- A clipboard nobody owns (nothing copied yet this session, or its owner
		-- quit) makes xclip and wl-paste fail as a broken read does. It is an
		-- empty clipboard, given back unowned as macOS clears its pasteboard,
		-- so a clipboard manager records no empty entry (ADD-2, decided by the
		-- maintainer on 2026-11-11); any other failure still refuses.
		local owned = selected_backend.owned and selected_backend.owned()
		if owned == false then
			if type(selected_backend.clear) ~= "function" then return false, nil, reason end
			return true, { text = "", unowned = true }, nil
		end
		if owned ~= true then return false, nil, reason end
		-- An owner offering no text (a screenshot copied alone) fails the text
		-- read too: its own formats are saved whole, as Windows' ClipboardAll
		-- saves them (CBL-001). A text format that fails to read still refuses.
		text_withheld, contents = true, ""
	end
	local listed, lost, offers_text = formats_lost_by_text_restore(selected_backend)
	if text_withheld and (not listed or offers_text or #lost == 0) then return false, nil, reason end
	if not listed then
		-- xsel cannot ask for TARGETS: nothing proves the text is all there is.
		Logger.warn(LOG, "Clipboard formats cannot be listed via %s; borrowing refused (install %s).",
			selected_backend.name, DisplayServer.is_wayland() and "wl-clipboard" or "xclip")
		return false, nil, "clipboard_formats_unknown"
	end
	if #lost == 0 then
		if contents:find("\0", 1, true) then
			Logger.warn(LOG, "Clipboard snapshot cannot be restored through the text writer.")
			return false, nil, "clipboard_snapshot_not_restorable"
		end
		return true, { text = contents }, nil
	end
	-- Format names only: they describe the clipboard, not its content.
	if not require("adapters.clipboard_owner").available() then
		Logger.warn(LOG, "Clipboard also holds %s, and no multi-format owner runs on this session; borrowing refused.",
			table.concat(lost, ", "))
		return false, nil, "clipboard_snapshot_not_restorable"
	end
	local targets = read_all_targets(selected_backend)
	if not targets then return false, nil, "clipboard_snapshot_not_restorable" end
	return true, { text = contents, targets = targets }, nil
end

--- Restores a snapshot through the writer that can carry all of it.
--- @param selected_backend table
--- @param snapshot table From read_restorable_snapshot.
--- @return boolean
local function restore_snapshot(selected_backend, snapshot)
	if snapshot.unowned then return selected_backend.clear() == true end
	if snapshot.targets then return require("adapters.clipboard_owner").write(snapshot.targets) end
	return write_backend_checked(selected_backend, snapshot.text)
end

--- Whether the clipboard may be restored over the text Ergopti put there. A
--- copy made by another application during the paste replaced that text, and
--- restoring over it would lose what the user just copied. An unreadable
--- clipboard proves no such copy, so the restore stays owed.
--- @param selected_backend table
--- @param text string The text written for the paste.
--- @return boolean|nil restorable nil when ownership could not be read.
local function holds_pasted_text(selected_backend, text)
	local ok, contents = read_backend_checked(selected_backend)
	if not ok then return nil end
	if contents == text then return true end
	Logger.info(LOG, "Another application copied during the paste; its content is kept, not restored over.")
	return false
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

--- Decodes the TIMESTAMP an X11 selection owner answers: xclip prints the raw
--- 32-bit property, little-endian, and some builds print it as decimal text.
--- @param raw string xclip's output.
--- @return number|nil timestamp
local function decode_selection_timestamp(raw)
	local digits = raw:match("^%s*(%d+)%s*$")
	if digits then return tonumber(digits) end
	if #raw == 4 or #raw == 8 then
		local b1, b2, b3, b4 = raw:byte(1, 4)
		return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
	end
	return nil
end

--- The clipboard's change counter, for the tap-hold copy check: the X11
--- CLIPBOARD owner's TIMESTAMP (ICCCM), which a toolkit renews each time it
--- takes the selection, so copying the same text again still moves it; xclip
--- reads it, and libX11 directly when xclip is absent
--- (adapters/x11_selection_stamp.lua). Wayland gives clients no timestamp:
--- there the count of selection changes a `wl-paste --watch` child saw
--- (adapters/wayland_selection_counter.lua) stands in, and a compositor with
--- no data-control (GNOME) leaves it nil with its reason, the copy unchecked.
--- @return number|nil counter
--- @return string|nil reason Why there is none: "unsupported" when the session
---   can never have one, "unreadable" when this read failed.
function M.change_counter()
	if DisplayServer.is_wayland() then return require("adapters.wayland_selection_counter").read() end
	if not DisplayServer.is_x11() then return nil, "unsupported" end
	if not Shell.has_command("xclip") then
		return require("adapters.x11_selection_stamp").read(tonumber(COUNTER_TIMEOUT_S))
	end
	local ok, output = Shell.exec_checked(string.format(
		"timeout %s xclip -selection clipboard -t TIMESTAMP -o 2>/dev/null", COUNTER_TIMEOUT_S))
	if not ok then return nil, "unreadable" end
	local counter = decode_selection_timestamp(output)
	if counter == nil then return nil, "unreadable" end
	return counter
end

--- The command that prints the PRIMARY selection, or nil when no tool can.
---
--- PRIMARY is what the application publishes as soon as text is selected, with
--- no keystroke sent to it — the only probe that cannot type into the focused
--- window. Ctrl+C would copy in an editor and interrupt the running program in a
--- terminal.
--- @return string|nil
local function primary_read_command()
	if DisplayServer.is_wayland() then
		if Shell.has_command("wl-paste") then
			return string.format("timeout %d wl-paste --primary --no-newline 2>/dev/null", IO_TIMEOUT_S)
		end
		return nil
	end
	if DisplayServer.is_x11() then
		if Shell.has_command("xclip") then
			return string.format("timeout %d xclip -selection primary -o 2>/dev/null", IO_TIMEOUT_S)
		end
		if Shell.has_command("xsel") then
			return string.format("timeout %d xsel --primary --output 2>/dev/null", IO_TIMEOUT_S)
		end
	end
	return nil
end

--- Reads the PRIMARY selection.
--- @return boolean ok False when no tool can read it or the read failed.
--- @return string text The selection; "" when nothing is published.
--- @return string|nil reason Why the read failed.
function M.read_primary()
	local command = primary_read_command()
	if not command then
		return false, "", "no PRIMARY selection reader on this session"
	end
	local ok, text, err = Shell.exec_checked(command)
	if not ok then
		-- An empty PRIMARY makes wl-paste and xclip exit non-zero: that is "no
		-- selection", which the caller treats exactly like a failed read.
		return false, "", err
	end
	return true, text or "", nil
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

--- Requires a caller's live destination without making native focus atomic.
--- Cleanup never uses this admission: the saved clipboard must still be restored.
--- @param admission function|nil Full-phase destination check.
--- @return boolean accepted
local function admitted(admission)
	if admission == nil then return true end
	if type(admission) ~= "function" then return false end
	local checked, current = pcall(admission)
	return checked and current == true
end

--- Resolves the paste shortcut before a caller's final native range observation.
--- @return integer code Exact layout key or the adapter's canonical US fallback.
function M.paste_keycode()
	return require("adapters.keyboard_layout").shortcut_keycode("v", US_KEY_V)
end

--- Emits Ctrl+V through the caller's uinput channel.
---
--- Ctrl+V and not Shift+Insert: it is what every graphical toolkit binds, and
--- the terminals that want Ctrl+Shift+V accept it in their own text fields
--- anyway. There is no keystroke that works in every application, which is a
--- property of the desktop rather than a choice available here.
--- @param uinput table Channel exposing emit(code, value) -> boolean.
--- @param admission function|nil Full-phase destination check.
--- @param selected_backend table Captured clipboard command owner.
--- @param text string Expected clipboard payload.
--- @return boolean True only when the complete chord reached the wire.
local function press_paste(uinput, admission, selected_backend, text)
	local key_v = M.paste_keycode()
	if not admitted(admission) then return false end
	-- A copy during the settle delay changes what Ctrl+V would insert. A
	-- successful setter alone cannot authorize pasting another owner's bytes.
	if holds_pasted_text(selected_backend, text) ~= true then return false end
	if not admitted(admission) then return false end
	if uinput.emit(EvdevCodes.KEY_LEFTCTRL, VALUE_DOWN) ~= true then return false end
	if uinput.emit(key_v, VALUE_DOWN) ~= true then return false end
	if uinput.emit(key_v, VALUE_UP) ~= true then return false end
	if uinput.emit(EvdevCodes.KEY_LEFTCTRL, VALUE_UP) ~= true then return false end
	return true
end

--- Reserves reversible clipboard preparation before any desktop I/O starts.
--- The caller retains this owner across its final native range observation.
--- @param text string Private replacement bytes.
--- @param sleep_ms function Existing blocking wait implementation.
--- @param key_v integer Previously resolved paste shortcut.
--- @param admission function Original write admission.
--- @return table stage Explicit prepare, paste and close lifetime.
function M.new_paste_stage(text, sleep_ms, key_v, admission)
	assert(type(text) == "string" and text ~= "" and type(key_v) == "number", "invalid clipboard preparation")
	local stage, b, saved = {}, nil, nil
	local busy, revoked, restore_required, prepared = false, false, false, false
	local written, restore_attempted = false, false
	local function current()
		return not revoked and admitted(admission) and not revoked
	end
	local function restore()
		if busy then return false end
		if not restore_required then return true end
		busy = true
		local ok, restored = pcall(function()
			-- A failed setter can have changed the clipboard, but an unrelated
			-- copy may also have arrived. Keep the inverse pending if the bytes
			-- do not identify either our payload or the saved snapshot.
			local read_ok, current = read_backend_checked(b)
			if not read_ok then return false end
			if current ~= text and current ~= saved.text then
				if written and not restore_attempted then return true end
				return false
			end
			restore_attempted = true
			return restore_snapshot(b, saved)
		end)
		busy = false
		if ok and restored == true then restore_required, saved = false, nil end
		return not restore_required
	end
	--- Revokes first; an in-flight set must unwind before restoration can run.
	--- @return boolean settled
	function stage.close()
		revoked = true
		return not busy and restore()
	end
	--- Prepares the saved clipboard and canonical settle delay without key output.
	--- @return boolean ready
	function stage.prepare()
		if busy or revoked or prepared then return false end
		busy = true
		local ok, ready = pcall(function()
			if not current() then return false end
			b = backend()
			if not b or not current() then return false end
			local read_ok, snapshot = read_restorable_snapshot(b)
			if not read_ok then return false end
			saved = snapshot
			if not current() then return false end
			-- A failed/throwing setter may already have changed the clipboard.
			restore_required = true
			if not write_backend_checked(b, text) then return false end
			written = true
			if not current() then return false end
			if not wait_checked(sleep_ms, SETTLE_MS) then return false end
			return current()
		end)
		busy = false
		prepared = ok and ready == true and not revoked
		if not prepared then stage.close() end
		return prepared
	end
	--- Pastes only while the clipboard still contains the prepared bytes.
	--- The final read may retire the destination, so admission follows it again.
	--- @param channel table Checked short output transaction.
	--- @return boolean issued
	function stage.paste(channel)
		if busy or revoked or not prepared then return false end
		busy = true
		local ok, issued = pcall(function()
			if not current() then return false end
			if holds_pasted_text(b, text) ~= true then return false end
			if not current() then return false end
			if channel.emit(EvdevCodes.KEY_LEFTCTRL, VALUE_DOWN) ~= true then return false end
			if not current() then return false end
			if channel.emit(key_v, VALUE_DOWN) ~= true then return false end
			if channel.emit(key_v, VALUE_UP) ~= true then return false end
			if channel.emit(EvdevCodes.KEY_LEFTCTRL, VALUE_UP) ~= true then return false end
			return wait_checked(sleep_ms, RESTORE_DELAY_MS)
		end)
		busy = false
		return ok and issued == true
	end
	return stage
end

--- Delivers text by clipboard: save, set, paste, restore.
---
--- The restore is not optional. An expansion that eats whatever the user had
--- copied is a worse failure than one that does not fire, because the user does
--- not find out until they paste something else.
--- @param text string Text to deliver.
--- @param uinput table Channel exposing emit(code, value).
--- @param sleep_ms function Blocking sleep, injected so this module owns no timer.
--- @param admission function|nil Rechecks the retained destination after blocking phases.
--- @return boolean True when the paste was issued.
--- @return string|nil Fixed failure reason when clipboard restoration was refused.
function M.paste_text(text, uinput, sleep_ms, admission)
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

	if not admitted(admission) then return false end
	local snapshot_ok, saved, snapshot_error = read_restorable_snapshot(b)
	if not snapshot_ok then
		Logger.error(LOG, "paste_text(): could not snapshot the clipboard via %s — %s.",
			b.name, tostring(snapshot_error or "command failed"))
		return false
	end

	if not admitted(admission) then return false end
	if not write_backend_checked(b, text) then
		-- A failed launcher may already have transferred ownership, or another
		-- application may have copied. Restore only identifiable contents.
		local read_ok, current = read_backend_checked(b)
		local restored = read_ok and (current == text or current == saved.text) and restore_snapshot(b, saved)
		Logger.error(LOG, "paste_text(): could not set the clipboard via %s.", b.name)
		if not restored then return false, "clipboard restoration failed" end
		return false
	end

	local paste_ok, issued = pcall(function()
		if not admitted(admission) then return false end
		if not wait_checked(sleep_ms, SETTLE_MS) then return false end
		-- The shortcut lookup may query the layout, so validate after it and
		-- immediately before Ctrl DOWN, not merely before the settle delay.
		if not press_paste(uinput, admission, b, text) then return false end
		if not wait_checked(sleep_ms, RESTORE_DELAY_MS) then return false end
		return admitted(admission)
	end)

	-- Restored even when it was empty: an owned "" is written back and an
	-- unowned clipboard is cleared, which leaves it as the user left it;
	-- skipping the restore would leave our replacement sitting there.
	local held = holds_pasted_text(b, text)
	if held == nil or (held and not restore_snapshot(b, saved)) then
		Logger.warn(LOG, "paste_text(): the previous clipboard content could not be restored.")
		return false, "clipboard restoration failed"
	end
	if not paste_ok or not issued then
		-- An admitted transaction distinguishes expected destination retirement
		-- from real wire failures after cleanup; only it should notify errors.
		if admission == nil then Logger.error(LOG, "paste_text(): checked paste chord emission failed.") end
		return false
	end

	Logger.debug(LOG, "Pasted %d byte(s) via %s.", #text, b.name)
	return true
end

--- Copies the focused selection into the clipboard, which the caller restores.
---
--- A sentinel goes in first: an application with nothing selected leaves the
--- clipboard alone on Ctrl+C, and without the sentinel the previous content
--- would read as the selection.
--- @param b table The session's clipboard backend.
--- @param emit_combo function combo -> boolean
--- @param sleep_ms function Blocking millisecond wait.
--- @param publication table|nil Original destination retained across copy boundaries.
--- @return boolean ok
--- @return string selected_or_reason The selection, or why there is none.
local function copy_selection(b, emit_combo, sleep_ms, publication)
	local function current() return publication == nil or admitted(publication.current) end
	if not current() then return false, "destination_changed" end
	local sentinel = "__ERGOPTI_SELECTION_PROBE_" .. tostring({}) .. "__"
	if not write_backend_checked(b, sentinel) then return false, "clipboard_probe_write_failed", sentinel end
	if not current() then return false, "destination_changed", sentinel end
	local copy_ok, copied = pcall(emit_combo, "ctrl+c", publication)
	if not copy_ok or copied ~= true then return false, "copy_chord_failed", sentinel end
	if not current() then return false, "destination_changed", sentinel end
	if not wait_checked(sleep_ms, COPY_SETTLE_MS) then return false, "copy_settle_failed", sentinel end
	if not current() then return false, "destination_changed", sentinel end
	local selection_ok, selected, selection_error = read_backend_checked(b)
	if not current() then return false, "destination_changed", selection_ok and selected or sentinel end
	if not selection_ok then return false, selection_error or "selection_read_failed", sentinel end
	if selected == sentinel then return false, "no_selection", sentinel end
	return true, selected
end

--- Checks the injected dependencies of a selection probe.
--- @param emit_combo any
--- @param sleep_ms any
--- @return table|nil backend The session's clipboard backend.
--- @return string|nil reason Why the probe cannot run.
local function selection_backend(emit_combo, sleep_ms)
	if type(emit_combo) ~= "function" or type(sleep_ms) ~= "function" then
		return nil, "invalid_dependencies"
	end
	local b = backend()
	if not b then
		local _, why = M.is_available()
		return nil, why
	end
	return b, nil
end

--- Reads the focused selection by copying it, then puts the clipboard back.
--- The selection is left as it was, for a caller that replaces it later.
--- @param emit_combo function combo -> boolean
--- @param sleep_ms function Blocking millisecond wait.
--- @return boolean ok
--- @return string text The selection ("" when there is none).
--- @return string|nil reason "no_selection", or why the read failed.
function M.read_selection(emit_combo, sleep_ms)
	local b, why = selection_backend(emit_combo, sleep_ms)
	if not b then return false, "", why end
	local snapshot_ok, saved, snapshot_error = read_restorable_snapshot(b)
	if not snapshot_ok then return false, "", snapshot_error or "clipboard_snapshot_failed" end
	local copied, selected, probe = copy_selection(b, emit_combo, sleep_ms)
	if not copied and probe ~= nil then
		local ok, current = read_backend_checked(b)
		if not ok then return false, "", "clipboard_ownership_unknown" end
		if current ~= probe and current ~= saved.text then return false, "", selected end
	end
	if copied then
		-- A later copy must not be replaced with the old snapshot.
		local read_ok, current = read_backend_checked(b)
		if not read_ok then return false, "", "clipboard_ownership_unknown" end
		if current ~= selected then return true, selected, nil end
	end
	if not restore_snapshot(b, saved) then return false, "", "clipboard_restore_failed" end
	if not copied then return false, "", selected end
	Logger.debug(LOG, "Read a %d-byte selection via %s.", #selected, b.name)
	return true, selected, nil
end

--- Reads the file manager's selection by copying it: the text/uri-list it
--- publishes on Ctrl+C, then puts the clipboard's text back. xsel cannot ask
--- for a target, so it has no route; the caller parses the list
--- (_shared/core/fs/engine).
--- @param emit_combo function combo -> boolean
--- @param sleep_ms function Blocking millisecond wait.
--- @return boolean ok
--- @return string uri_list The text/uri-list ("" when nothing was copied).
--- @return string|nil reason "no_file_selection", or why the read failed.
function M.read_selection_uri_list(emit_combo, sleep_ms)
	local b, why = selection_backend(emit_combo, sleep_ms)
	if not b then return false, "", why end
	if not b.read_uri_list then return false, "", b.name .. " cannot read a text/uri-list" end
	local snapshot_ok, saved, snapshot_error = read_restorable_snapshot(b)
	if not snapshot_ok then return false, "", snapshot_error or "clipboard_snapshot_failed" end
	-- A text sentinel first, as copy_selection does: files copied earlier
	-- would otherwise still answer the uri-list read when nothing is selected.
	local sentinel = "__ERGOPTI_SELECTION_PROBE_" .. tostring({}) .. "__"
	if not write_backend_checked(b, sentinel) then
		local ok, current = read_backend_checked(b)
		if not ok then return false, "", "clipboard_ownership_unknown" end
		if current ~= sentinel and current ~= saved.text then return false, "", "clipboard_probe_write_failed" end
		if not restore_snapshot(b, saved) then return false, "", "clipboard_restore_failed" end
		return false, "", "clipboard_probe_write_failed"
	end
	local copy_ok, copied = pcall(emit_combo, "ctrl+c")
	local settled = copy_ok and copied == true and wait_checked(sleep_ms, COPY_SETTLE_MS)
	-- Nothing copied leaves the sentinel. wl-copy offers it under text types
	-- only, so the uri-list read fails; xclip answers every target with its
	-- text, so the read returns the sentinel itself. Both are "no file selected".
	local read_ok, uri_list = false, ""
	if settled then read_ok, uri_list = Shell.exec_checked(b.read_uri_list) end
	if settled and read_ok and uri_list ~= "" and uri_list ~= sentinel then
		local ok, current = Shell.exec_checked(b.read_uri_list)
		if not ok or current ~= uri_list then return false, "", "clipboard_ownership_unknown" end
	else
		local ok, current = read_backend_checked(b)
		if not ok then return false, "", "clipboard_ownership_unknown" end
		if current ~= sentinel and current ~= saved.text then return false, "", "clipboard_ownership_unknown" end
	end
	if not restore_snapshot(b, saved) then return false, "", "clipboard_restore_failed" end
	if not settled then return false, "", "copy_chord_failed" end
	if not read_ok or uri_list == "" or uri_list == sentinel then return false, "", "no_file_selection" end
	Logger.debug(LOG, "Read a %d-byte uri-list selection via %s.", #uri_list, b.name)
	return true, uri_list, nil
end

--- Copies and replaces the focused selection while preserving the clipboard.
--- @param transform function selected_text -> replacement_text
--- @param emit_combo function combo -> boolean
--- @param sleep_ms function Blocking millisecond wait.
--- @param publication table|nil Original destination admission, retained through cleanup.
--- @return boolean ok
--- @return string|nil reason
function M.transform_selection(transform, emit_combo, sleep_ms, publication)
	if type(transform) ~= "function" then return false, "invalid_dependencies" end
	local function current() return publication == nil or admitted(publication.current) end
	if not current() then return false, "destination_changed" end
	local b, why = selection_backend(emit_combo, sleep_ms)
	if not b then return false, why end
	if not current() then return false, "destination_changed" end

	local snapshot_ok, saved, snapshot_error = read_restorable_snapshot(b)
	if not snapshot_ok then return false, snapshot_error or "clipboard_snapshot_failed" end
	-- PRIMARY follows the application's live selection without a keystroke.
	-- Read before the copy, it tells whether this application publishes the
	-- range being transformed; only then can it prove the range unchanged
	-- right before the paste (LCP-003). Windows and macOS replace the
	-- selection they read; a field identity alone does not pin its range.
	local primary_ok, primary_before = M.read_primary()

	local owned, previous_owned
	local function restore()
		return restore_snapshot(b, saved)
	end
	local function fail(reason)
		-- Before the sentinel is written we own no clipboard change to undo.
		-- A copy made after the snapshot must not be overwritten on refusal.
		if owned == nil then return false, reason end
		local ok, content = read_backend_checked(b)
		if not ok then return false, "clipboard_ownership_unknown" end
		if content ~= owned and content ~= previous_owned then return false, reason end
		if not restore() then return false, "clipboard_restore_failed" end
		return false, reason
	end
	if not current() then return fail("destination_changed") end
	local copied, selected, probe = copy_selection(b, emit_combo, sleep_ms, publication)
	if not copied then
		owned, previous_owned = probe, saved.text
		return fail(selected)
	end
	owned = selected
	local range_observable = primary_ok and primary_before == selected
	if not range_observable then
		Logger.debug(LOG, "The selected range is not published as PRIMARY; only the field is rechecked.")
	end

	local transformed_ok, replacement = pcall(transform, selected)
	if not transformed_ok or type(replacement) ~= "string" then
		return fail("selection_transform_failed")
	end
	if not current() then return fail("destination_changed") end
	local still_owned, contents = read_backend_checked(b)
	if not still_owned or contents ~= owned then return fail("clipboard_changed") end
	previous_owned, owned = owned, replacement
	if not write_backend_checked(b, replacement) then
		return fail("replacement_write_failed")
	end
	if not current() then return fail("destination_changed") end

	local range_changed = false
	local paste_ok, pasted = pcall(function()
		if not wait_checked(sleep_ms, SETTLE_MS) then return false end
		if not current() then return false end
		local read_ok, contents = read_backend_checked(b)
		if not read_ok or contents ~= replacement then return false end
		if range_observable then
			local still_ok, primary_now = M.read_primary()
			if not still_ok or primary_now ~= selected then
				range_changed = true
				return false
			end
		end
		if not current() then return false end
		if emit_combo("ctrl+v", publication) ~= true then return false end
		if not current() then return false end
		if not wait_checked(sleep_ms, RESTORE_DELAY_MS) then return false end
		return true
	end)
	-- Restore only while the replacement is still identifiable as ours.
	local read_ok, content = read_backend_checked(b)
	if not read_ok then return false, "clipboard_ownership_unknown" end
	if content == replacement and not restore() then return false, "clipboard_restore_failed" end
	if not current() then return false, "destination_changed" end
	if range_changed then
		Logger.warn(LOG, "The selection changed before the paste; the transformed text was not pasted.")
		return false, "selection_changed"
	end
	if not paste_ok or pasted ~= true then return false, "paste_chord_failed" end
	Logger.debug(LOG, "Replaced a %d-byte selection via %s.", #selected, b.name)
	return true
end

return M
