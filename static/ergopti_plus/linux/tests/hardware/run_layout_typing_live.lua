--- tests/hardware/run_layout_typing_live.lua

--- ==============================================================================
--- MODULE: Layout Typing Into Real GTK And Qt Editors
--- DESCRIPTION:
--- Drives the daemon's real layout chain on an owned X server holding a real
--- XKB keymap and reads what real editors received through AT-SPI:
--- mousepad (GTK 3) and kwrite (Qt 5, KDE Frameworks).
---
--- Production code under test: layouts/engine/registry/emulation.lua with its
--- production wiring (M.start), the shared emulation engine, the registry's
--- shipped .keylayout files, layouts/adapters/keyboard_layout.lua and
--- layouts/adapters/xkb_capture.lua on the server's own keymap (libxkbcommon),
--- hotstrings/engine/injector.lua, platform/input/modifier_broker.lua,
--- platform/input/uinput_writer.lua, shortcuts/engine/accented_shortcuts.lua,
--- gestures/engine/combo_emitter.lua, and layouts/engine/registry/registry.lua
--- with the real Python installer for the Bépo user-tree install.
---
--- Replaced edges: the last uinput hop is XTest (tests/hardware/lib/
--- xtest_uinput_backend.lua, keycode evdev + 8), and the keyboard hook is the
--- small pass-through below. It reports a press as the hook does
--- ({ code, mods, char }), puts back every key nothing consumed on the same
--- writer and feeds the modifiers to the capture state, as the grab does.
---
--- Expected text comes from the hand-read oracle
--- (_shared/tests/corpus/layouts/keylayout_vectors.json), never from the
--- engine under test, except where a check says so.
---
--- Run through run_layout_typing_live.sh, which owns the X server, the D-Bus
--- and accessibility buses and the window manager. Exit 0 = every check held.
--- ==============================================================================

package.path = "./?.lua;./?/init.lua;../_shared/?.lua;../_shared/?/init.lua;" .. package.path

local ffi = require("ffi")
local uv = require("luv")

ffi.cdef([[
	int setenv(const char *, const char *, int);
]])

local SCRATCH = assert(os.getenv("ERGOPTI_LIVE_SCRATCH"), "run through run_layout_typing_live.sh")
if os.getenv("ERGOPTI_LIVE_DEBUG") then
	require("core.logger.engine").set_sink(function(line) io.stderr:write(line, "\n") end)
end
local PYTHON_ATSPI = assert(os.getenv("ERGOPTI_LIVE_ATSPI_PYTHON"), "run through run_layout_typing_live.sh")
local SETTLE_MS = 250
local AWAIT_MS = 60000

local _checks, _failures = 0, 0
local _receipt = {}





-- =======================================
-- =======================================
-- ======= 1/ Harness ====================
-- =======================================
-- =======================================

local function quote(text) return "'" .. text:gsub("'", "'\\''") .. "'" end

local function show(text) return string.format("%q", text) end

local function check(condition, text)
	_checks = _checks + 1
	if not condition then _failures = _failures + 1 end
	local line = (condition and "  ok   " or "  FAIL ") .. text
	print(line)
	_receipt[#_receipt + 1] = line
	return condition
end

local function section(title)
	print("== " .. title)
	_receipt[#_receipt + 1] = "== " .. title
end

local function read(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end

local function write(path, text)
	local handle = assert(io.open(path, "wb"))
	handle:write(text)
	handle:close()
end

local function capture(command)
	local handle = assert(io.popen(command, "r"))
	local output = handle:read("*a")
	handle:close()
	return output
end

-- The editors are stopped by pattern (stop_editor): procps must be present.
local has_pkill = os.execute("command -v pkill >/dev/null 2>&1")
assert(has_pkill == true or has_pkill == 0, "ENVIRONMENT: pkill is missing")

local function sleep_ms(ms) uv.sleep(ms) end

--- Runs one asynchronous registry operation on the real event loop.
local function await(start)
	local result
	local timer = uv.new_timer()
	timer:start(100, 100, function() end)
	start(function(...) result = { n = select("#", ...), ... } end)
	local deadline = uv.now() + AWAIT_MS
	while result == nil and uv.now() < deadline do uv.run("once") end
	timer:stop()
	timer:close()
	return result or { false, "timeout" }
end

local CONFIG_PATH = SCRATCH .. "/config/ergopti/config.toml"

--- Writes config.toml from [section] -> { key = value } tables.
local function write_config(document)
	local lines = {}
	local sections = {}
	for name in pairs(document) do sections[#sections + 1] = name end
	table.sort(sections)
	for _, name in ipairs(sections) do
		lines[#lines + 1] = "[" .. name .. "]"
		local keys = {}
		for key in pairs(document[name]) do keys[#keys + 1] = key end
		table.sort(keys)
		for _, key in ipairs(keys) do
			local value = document[name][key]
			lines[#lines + 1] = key .. " = " .. (type(value) == "string" and ('"' .. value .. '"') or tostring(value))
		end
	end
	write(CONFIG_PATH, table.concat(lines, "\n") .. "\n")
end





-- =======================================
-- =======================================
-- ======= 2/ Editors ====================
-- =======================================
-- =======================================

local EDITORS = {
	-- --disable-server: each start is its own process, not a request to a primary instance.
	{ name = "mousepad", toolkit = "GTK", command = "mousepad --disable-server", class = "mousepad" },
	{ name = "kwrite", toolkit = "Qt", command = "kwrite", class = "kwrite" },
}

--- Starts an editor on an empty file and waits for its accessible text.
local function start_editor(editor)
	local file = SCRATCH .. "/" .. editor.name .. ".txt"
	write(file, "")
	editor.pid = capture(editor.command .. " " .. quote(file) .. " >" .. quote(SCRATCH .. "/" .. editor.name .. ".log")
		.. " 2>&1 & echo $!"):match("%d+")
	for _ = 1, 100 do
		sleep_ms(200)
		local text = capture(PYTHON_ATSPI .. " tests/hardware/atspi_editor_text.py " .. editor.name .. " 2>/dev/null")
		if text:match("^TEXT ") then return true end
	end
	return false
end

--- Stops an editor and waits until it is gone: a GApplication still exiting
--- keeps its bus name, and the next instance then fails to register.
local function stop_editor(editor)
	-- Anchored on the command, so the shell running pgrep never matches.
	local pattern = quote("^" .. editor.command .. " " .. SCRATCH .. "/" .. editor.name .. ".txt")
	os.execute("pkill -f " .. pattern .. " 2>/dev/null")
	for attempt = 1, 100 do
		if capture("pgrep -f " .. pattern .. " 2>/dev/null") == "" then break end
		-- KDE applications can linger in their session save: the proof does not need it.
		if attempt == 50 then os.execute("pkill -KILL -f " .. pattern .. " 2>/dev/null") end
		sleep_ms(100)
	end
	assert(capture("pgrep -f " .. pattern .. " 2>/dev/null") == "", editor.name .. " did not exit")
	sleep_ms(500)
	editor.pid = nil
end

--- Raises the editor by its window title (mousepad hands its window to a
--- primary instance, so the started pid owns none).
local function focus(editor)
	local found = os.execute("timeout 20 xdotool search --sync --name " .. quote(editor.name .. "\\.txt")
		.. " windowactivate --sync >/dev/null 2>&1")
	if found ~= true and found ~= 0 then
		error(editor.name .. " has no window to focus; windows: "
			.. capture("xdotool search --name . getwindowname %@ 2>/dev/null"):gsub("\n", " | "))
	end
	sleep_ms(SETTLE_MS)
end

--- The editor's whole text, read through AT-SPI.
local function editor_text(editor)
	sleep_ms(SETTLE_MS)
	local out = capture(PYTHON_ATSPI .. " tests/hardware/atspi_editor_text.py " .. editor.name .. " 2>/dev/null")
	local hex = out:match("^TEXT (%x*)")
	if not hex then return nil end
	return (hex:gsub("%x%x", function(byte) return string.char(tonumber(byte, 16)) end))
end

-- Bound once the daemon's chain exists (section 3): every key the harness
-- itself presses goes through the same writer, never through xdotool's key
-- command, which rebinds a spare keycode and so changes the server keymap
-- under the injector's receipt.
local select_all, clear

local function clipboard()
	return capture("xclip -o -selection clipboard 2>/dev/null")
end





-- =======================================
-- =======================================
-- ======= 3/ The daemon's chain =========
-- =======================================
-- =======================================

-- The keyboard hook's view of what the hand holds, which the injector and the
-- combo emitter read to suspend or keep the held modifiers (adapters/
-- keyboard_hook.lua held_text_modifier_codes / held_shortcut_modifier_codes).
local KEY = { shift = 42, ctrl = 29, altgr = 100, caps = 58 }
local _held = {}
local _emergency = {}
local function held_codes(roles)
	local codes = {}
	for name, down in pairs(_held) do if down and roles[name] then codes[#codes + 1] = KEY[name] end end
	table.sort(codes)
	return codes
end
package.loaded["platform.input.keyboard_hook"] = {
	held_text_modifier_codes = function() return held_codes({ shift = true, altgr = true }) end,
	held_shortcut_modifier_codes = function() return held_codes({ ctrl = true }) end,
	held_forwarded_keys = function() return {} end,
	held_modifiers = function()
		local mods = {}
		for name, down in pairs(_held) do if down then mods[name] = true end end
		return mods
	end,
	number_row_mode = function() return require("layouts.engine.emulation.number_row_preferences").settings().order end,
	emergency_stop = function(reason) _emergency[#_emergency + 1] = tostring(reason) end,
}

local Backend = require("tests.hardware.lib.xtest_uinput_backend")
local Writer = require("platform.input.uinput_writer")
local wire = Backend.new()
Writer._set_backend(wire)
local fake_node = SCRATCH .. "/uinput"
write(fake_node, "")
Writer._set_path_for_test(fake_node)

local runner_python = (capture("command -v python3 2>/dev/null"):gsub("%s+$", ""))
package.loaded["layouts.engine.managed_python"] = { ensure = function(_, done) done(true, runner_python) end }

local Injector = require("hotstrings.engine.injector")
local KeyboardLayout = require("layouts.adapters.keyboard_layout")
local XkbCapture = require("layouts.adapters.xkb_capture")
local Emulation = require("layouts.engine.registry.emulation")
local Accented = require("shortcuts.engine.accented_shortcuts")
local ComboEmitter = require("gestures.engine.combo_emitter")
local NumberRow = require("layouts.engine.emulation.number_row_preferences")
local EvdevCodes = require("platform.input.evdev_codes")

assert(Injector.open_fast_channel(), "the injector's channel did not open on the XTest backend")

-- Each refusal of the injector, named in the failing check.
local _refusals = {}
local type_directly = Injector.type_directly
Injector.type_directly = function(text)
	local result = type_directly(text)
	if not result.ok then _refusals[#_refusals + 1] = show(text) .. ": " .. tostring(result.error) end
	return result
end


local _chars = {}
local _accented_on = false
local _deferred = {}

--- Reads the server keymap again. Right after a keymap upload the source probe
--- still holds the change events and refuses; the daemon's loop drains them
--- and refreshes on its next tick, which the retry stands for.
local function refresh_layout()
	for _ = 1, 20 do
		if KeyboardLayout.refresh() then return end
		uv.run("nowait")
		sleep_ms(100)
	end
	local _, reason = XkbCapture.source_generation()
	if os.getenv("ERGOPTI_LIVE_DEBUG") then os.execute("xkbcomp -xkb $DISPLAY " .. quote(SCRATCH .. "/failed.xkb") .. " 2>/dev/null") end
	error("the server keymap did not resolve: " .. tostring(reason))
end

-- One output owner per physical key, as platform/input/keyboard_hook.lua keeps them.
local _owners = {}

--- Puts back one physical event as the grab's pass-through does
--- (keyboard_hook _forward_raw): an edge settled by the broker, written by the
--- injector's raw emitter inside the broker's dispatch.
local function pass(code, value)
	_owners[code] = _owners[code] or {}
	local receipt = Injector.output_broker().edge(_owners[code], code, value, Injector.emit_key)
	assert(receipt.ok, "pass-through of " .. code .. ":" .. value .. " refused (" .. tostring(receipt.disposition) .. ")")
	XkbCapture.process(code, value)
end

--- One physical press and release through the hook's consumption order:
--- accented shortcuts, then the layout emulation, else the key goes back.
local function strike(code)
	local mods = {}
	for name, down in pairs(_held) do if down then mods[name] = true end end
	local detail = { code = code, value = 1, mods = mods, char = XkbCapture.peek_text(code) }
	local consumed = false
	if Accented.on_key(detail, {
		active = function() return _accented_on end,
		emulating = function() return Emulation.status().active == true end,
		defer = function(fn) _deferred[#_deferred + 1] = fn; return true end,
		press = function(combo) return (ComboEmitter.press(combo)) end,
		number_row_mode = function() return NumberRow.settings().order end,
	}) then
		consumed = true
		local queue = _deferred
		_deferred = {}
		for _, fn in ipairs(queue) do fn() end
	elseif Emulation.on_key(detail) then
		consumed = true
	end
	if not consumed then
		pass(code, 1)
		pass(code, 0)
	end
	return consumed
end

local function hold(name) _held[name] = true; pass(KEY[name], 1) end

select_all = function()
	local pressed, outcome = ComboEmitter.press("ctrl+a")
	assert(pressed, "Ctrl+A could not be pressed: " .. tostring(outcome and outcome.kind))
	sleep_ms(SETTLE_MS)
end

clear = function(editor)
	focus(editor)
	select_all()
	pass(EvdevCodes.KEY_BACKSPACE, 1)
	pass(EvdevCodes.KEY_BACKSPACE, 0)
	sleep_ms(SETTLE_MS)
end
local function release(name) _held[name] = nil; pass(KEY[name], 0) end

--- Plays one oracle press ("shift altgr SC010"): modifiers, the key, release.
local function play(press)
	local words = {}
	for word in press:gmatch("%S+") do words[#words + 1] = word end
	local code = tonumber(words[#words]:match("^SC(%x+)$"), 16)
	assert(code, "unreadable press " .. press)
	local caps = false
	for index = 1, #words - 1 do
		local name = words[index]
		if name == "caps" then caps = true; pass(KEY.caps, 1); pass(KEY.caps, 0) else hold(name) end
	end
	strike(code)
	for index = #words - 1, 1, -1 do if words[index] ~= "caps" then release(words[index]) end end
	if caps then pass(KEY.caps, 1); pass(KEY.caps, 0) end
end

local function emulate(document)
	write_config(document)
	assert(Emulation.reload(), "the emulation reload failed")
end

local _started = false
local function start_emulation(document)
	write_config(document)
	if _started then return assert(Emulation.reload()) end
	_started = true
	assert(Emulation.start({
		injector = Injector,
		is_paused = function() return false end,
		dispatch_char = function(char) _chars[#_chars + 1] = char end,
		magic_evdev = function() return nil end,
	}), "the emulation did not start")
end





-- =======================================
-- =======================================
-- ======= 4/ Scenarios ==================
-- =======================================
-- =======================================

local VECTORS = require("core.text.engine.json").decode(read("../_shared/tests/corpus/layouts/keylayout_vectors.json")).vectors
local EMULATED = { ergopti = "ergopti", ergopti_plus = "ergopti_plus", ergol = "ergol" }

local function layout_config(id)
	if id == "ergopti" or id == "ergopti_plus" then
		return { layout = { ergopti_base = true, ergopti_alt_gr = true, ergopti_variant = id, emulated_layout = "" } }
	end
	return { layout = { ergopti_base = true, ergopti_alt_gr = true, emulated_layout = id } }
end

--- The keylayout oracle, typed over AZERTY into one editor.
local function oracle_vectors(editor)
	for _, layout in ipairs({ "ergopti", "ergopti_plus", "ergol" }) do
		emulate(layout_config(EMULATED[layout]))
		for _, vector in ipairs(VECTORS) do
			if vector.layout == layout and vector.types ~= nil then
				clear(editor)
				_chars, _refusals = {}, {}
				for _, press in ipairs(vector.press) do play(press) end
				local got = editor_text(editor)
				check(got == vector.types, string.format("%s %s %s: %s types %s (got %s%s)", editor.toolkit,
					layout, vector.id, table.concat(vector.press, ", "), show(vector.types), show(got or "?"),
					#_refusals > 0 and ("; injector refused " .. table.concat(_refusals, ", ")) or ""))
				check(table.concat(_chars) == vector.types, string.format(
					"%s %s %s: the character path receives %s (got %s)", editor.toolkit, layout, vector.id,
					show(vector.types), show(table.concat(_chars))))
			end
		end
	end
end

--- Ctrl chords take the Command-level character's AZERTY key.
local function shortcuts(editor)
	emulate(layout_config("ergopti"))
	-- ergopti_shortcut_letter: SC018 sends c.
	clear(editor)
	play("SC010")
	play("SC011")
	play("SC012")
	local typed = editor_text(editor)
	select_all()
	write(SCRATCH .. "/clip", "")
	os.execute("xclip -selection clipboard -i " .. quote(SCRATCH .. "/clip"))
	hold("ctrl")
	local consumed = strike(0x18)
	release("ctrl")
	sleep_ms(SETTLE_MS)
	check(consumed, editor.toolkit .. " Ctrl + SC018 is consumed by the emulation")
	check(clipboard() == typed and typed ~= "", editor.toolkit .. " Ctrl + SC018 (Ergopti c) copies "
		.. show(typed) .. " (clipboard " .. show(clipboard()) .. ")")
	-- ergopti_shortcut_command_level: SC010 sends z, undo.
	clear(editor)
	play("SC011")
	sleep_ms(400)
	play("SC012")
	local before = editor_text(editor)
	hold("ctrl")
	strike(0x10)
	release("ctrl")
	local after = editor_text(editor)
	check(after ~= nil and #after < #before and before:sub(1, #after) == after,
		editor.toolkit .. " Ctrl + SC010 (Ergopti z) undoes: " .. show(before) .. " -> " .. show(after or "?"))
end

--- A row switched off types the session's French layout.
local function rows_off(editor)
	local document = layout_config("ergopti_plus")
	document.layout.emulate_top_row = false
	emulate(document)
	clear(editor)
	play("SC010")
	play("SC01E")
	local got = editor_text(editor)
	-- AZERTY's own a on SC010, Ergopti➕'s a on the emulated home row SC01E.
	check(got == "aa", editor.toolkit .. " top row off: SC010 types AZERTY a, the home row stays Ergopti➕ ("
		.. show(got or "?") .. ")")
end

--- A key AZERTY makes dead (SC01A, dead_circumflex) types the emulated character.
local function french_dead_key(editor)
	emulate(layout_config("ergopti_plus"))
	local Shared = require("layouts.engine.composer.keylayout_emulation")
	local registry = require("layouts.engine.registry.registry")
	local shipped = registry.shipped_layout("ergopti_plus")
	local keycodes = require("core.text.engine.json").decode(read("../_shared/layouts/data/mac_keycodes.json"))
	local physical = require("core.text.engine.json").decode_lossless(read("../_shared/layouts/data/keycodes/physical_keys.json"))
	local model = Shared.load(shipped.text, keycodes, shipped.entry.keycode_convention, {})
	local session = Shared.new_session(model, Shared.row_map(physical, require("core.text.engine.json").is_null))
	local all_rows = {}
	for _, row in ipairs(require("layouts.engine.layout.rows_policy").IDS) do all_rows["emulate_" .. row] = true end
	Shared.configure(session, { base = true, alt_gr = true, layout = all_rows, number_row = "native", edges = false })
	local code_of = {}
	for code, key in pairs(physical.keys) do if key.evdev then code_of[key.evdev] = code end end
	local _, first = Shared.decide(session, code_of[0x1A], false, false, false, false, false, false, nil)
	local _, second = Shared.decide(session, code_of[0x12], false, false, false, false, false, false, nil)
	clear(editor)
	play("SC01A")
	play("SC012")
	local got = editor_text(editor)
	check(first ~= nil and first ~= "" and got == first .. second, editor.toolkit
		.. " SC01A, dead on AZERTY, types Ergopti➕'s " .. show(first or "?") .. " and the next key is not composed ("
		.. show(got or "?") .. ")")
end

--- « é → C »: Ctrl+é copies, AltGr+é types the layout, Ctrl+2 stays with digits first.
local function accented(editor)
	write_config({ layout = { ergopti_base = false, ergopti_variant = "none" },
		shortcuts = { ["e_acute"] = nil } })
	write(CONFIG_PATH, "[layout]\nergopti_base = false\nergopti_variant = \"none\"\n"
		.. "[shortcuts.e_acute]\nenabled = true\nletter = \"c\"\n")
	assert(Emulation.reload())
	_accented_on = true
	local KEY_2 = 3
	check(XkbCapture.peek_text(KEY_2) == "é", "AZERTY types é on KEY_2 (" .. show(XkbCapture.peek_text(KEY_2) or "?") .. ")")
	clear(editor)
	assert(Injector.type_directly("accent").ok, "the injector could not type the sample")
	select_all()
	write(SCRATCH .. "/clip", "")
	os.execute("xclip -selection clipboard -i " .. quote(SCRATCH .. "/clip"))
	hold("ctrl")
	local consumed = strike(KEY_2)
	release("ctrl")
	sleep_ms(SETTLE_MS)
	check(consumed and clipboard() == "accent", editor.toolkit .. " Ctrl+é copies (clipboard " .. show(clipboard()) .. ")")
	-- AltGr+é: what the server's keymap gives on level 3 of KEY_2, typed by the key itself.
	clear(editor)
	hold("altgr")
	local altgr_consumed = strike(KEY_2)
	release("altgr")
	play("SC039")
	local altgr_text = editor_text(editor)
	local expected = capture("xkbcomp -xkb $DISPLAY - 2>/dev/null"):match("key <AE02>%s*%b{}") or ""
	check(not altgr_consumed and altgr_text ~= nil and altgr_text ~= "" and altgr_text ~= "é",
		editor.toolkit .. " AltGr+é is not a shortcut and types the layout's level 3 then space: "
		.. show(altgr_text or "?") .. " (" .. expected:gsub("%s+", " ") .. ")")
	-- Digits first: KEY_2 is a digit, Ctrl+KEY_2 stays Ctrl+2.
	write(CONFIG_PATH, read(CONFIG_PATH) .. "[layout_number_row]\n")
	local doc = read(CONFIG_PATH):gsub("%[layout_number_row%]\n", "")
	doc = doc:gsub("%[layout%]\n", "[layout]\ndirect_access_digits = \"digits\"\n")
	write(CONFIG_PATH, doc)
	check(NumberRow.settings().order == "digits", "the number row types digits first")
	local mark = #wire.events
	hold("ctrl")
	local digit_consumed = strike(KEY_2)
	release("ctrl")
	local sent = {}
	for index = mark + 1, #wire.events do sent[#sent + 1] = wire.events[index].code .. ":" .. wire.events[index].value end
	check(not digit_consumed and table.concat(sent, " ") == "29:1 3:1 3:0 29:0",
		editor.toolkit .. " Ctrl+2 with digits first stays Ctrl+KEY_2 (wire " .. table.concat(sent, " ") .. ")")
	_accented_on = false
end

--- Bépo installed in the user tree: monnaie then cédille types ₢ at once.
local function bepo_compose()
	local Registry = require("layouts.engine.registry.registry")
	local registry_dir = "../../layouts/registry/"
	local index = require("core.text.engine.json").decode(read(registry_dir .. "index.json"))
	local bepo
	for _, entry in ipairs(index.layouts) do if entry.id == "bepo" then bepo = entry end end
	local text = read(registry_dir .. bepo.file)
	ffi.C.setenv("XDG_SESSION_TYPE", "", 1)
	local installed = await(function(done) Registry.install_local(bepo, text, done) end)
	check(installed[1] == true, "Bépo is installed in the user tree: " .. tostring(installed[2]))
	ffi.C.setenv("XDG_SESSION_TYPE", "x11", 1)
	local applied = await(function(done) Registry.apply_rows("bepo", { order = "native", edges = false }, done) end)
	check(applied[1] == true, "Bépo is loaded into the running server: " .. tostring(applied[2]) .. " "
		.. tostring(applied[3]))
	local xcompose = read(SCRATCH .. "/home/.XCompose") or ""
	check(xcompose:find("<onefifth> <dead_cedilla>", 1, true) ~= nil, "~/.XCompose carries the Bépo rules inline")
	refresh_layout()
	write(CONFIG_PATH, "[layout]\nergopti_base = false\nergopti_variant = \"none\"\n")
	assert(Emulation.reload())
	-- The installed Compose rule for ₢ names the two keysyms (DKS-001 gives the
	-- monnaie dead key a borrowed trigger), and libxkbcommon finds their keys
	-- and levels in the server's keymap.
	local compose = read(SCRATCH .. "/config/xkb/compose/bepo.XCompose") or ""
	local first, second = compose:match("\n<([%w_]+)> <([%w_]+)>%s*: \"₢\"")
	check(first ~= nil, "the installed Compose file has the ₢ rule: <" .. tostring(first) .. "> <" .. tostring(second) .. ">")
	if not first then return end
	write(SCRATCH .. "/bepo.xkb", capture("xkbcomp -xkb $DISPLAY - 2>/dev/null"))
	local probe = capture("luajit tests/hardware/lib/xkb_dead_key_chord.lua " .. quote(SCRATCH .. "/bepo.xkb")
		.. " " .. first .. " " .. second)
	local chords = {}
	for line in probe:gmatch("[^\n]+") do
		local name, code, mods = line:match("^(%S+) (%d+) ?(.*)$")
		if name then chords[name] = { code = tonumber(code), mods = mods } end
	end
	check(chords[first] and chords[second], "the Bépo keymap types both keysyms (" .. probe:gsub("\n", "; ") .. ")")
	if not (chords[first] and chords[second]) then return end
	for _, editor in ipairs(EDITORS) do
		stop_editor(editor)
		check(start_editor(editor), editor.toolkit .. " editor restarted with the Bépo ~/.XCompose")
		clear(editor)
		for _, name in ipairs({ first, second }) do
			local chord = chords[name]
			for mod in chord.mods:gmatch("%S+") do hold(mod) end
			strike(chord.code)
			for mod in chord.mods:gmatch("%S+") do release(mod) end
		end
		local got = editor_text(editor)
		check(got == "₢", editor.toolkit .. " monnaie then cédille types ₢ at once (got " .. show(got or "?") .. ")")
	end
end





-- =======================================
-- =======================================
-- ======= 5/ Run ========================
-- =======================================
-- =======================================

print("=== layout typing into real GTK and Qt editors, AZERTY (fr) XKB ===")
-- The first XTest event makes the server announce the XTest keyboard as the
-- core keyboard, a new desktop keymap source for the capture. A daemon on a
-- real session writes from one virtual keyboard from its start; the harness
-- does the same by writing once before it reads the keymap.
pass(KEY.shift, 1)
pass(KEY.shift, 0)
refresh_layout()
start_emulation(layout_config("ergopti_plus"))
for _, editor in ipairs(EDITORS) do
	check(start_editor(editor), editor.toolkit .. " editor " .. editor.name .. " exposes its text on the accessibility bus")
end
local ONLY = os.getenv("ERGOPTI_LIVE_ONLY")
for _, editor in ipairs(EDITORS) do
	if ONLY and ONLY ~= editor.toolkit then goto next_editor end
	section(editor.toolkit .. " (" .. editor.name .. ")")
	oracle_vectors(editor)
	shortcuts(editor)
	rows_off(editor)
	french_dead_key(editor)
	accented(editor)
	::next_editor::
end
section("Bépo registry layout, desktop Compose")
bepo_compose()
for _, editor in ipairs(EDITORS) do stop_editor(editor) end
check(#_emergency == 0, "no output emergency stop (" .. table.concat(_emergency, "; ") .. ")")
Injector.close_fast_channel()
wire.shutdown()

local summary = string.format("=== %d check(s), %d failure(s) ===", _checks, _failures)
print(summary)
_receipt[#_receipt + 1] = summary
write(SCRATCH .. "/receipt.txt", table.concat(_receipt, "\n") .. "\n")
os.exit(_failures == 0 and 0 or 1)
