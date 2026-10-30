--- tests/hardware/run_layout_rows_live.lua

--- ==============================================================================
--- MODULE: Number-Row Options Loaded Live Into a Real X Server
--- DESCRIPTION:
--- Drives the production layout manager end to end on an owned Xvfb server: the
--- composer's real save path installs the shipped check composition (a compiled
--- .keylayout), the registry's Ergo-L is installed from the packaged copy, and the
--- number-row options are applied with layout_registry.apply_rows, which converts
--- the .keylayout with the options (the shared Lua converter), installs the XKB
--- files in a private user tree (the real Python installer) and loads them into the
--- running server. Every claim is read back from the server with
--- `xkbcomp -xkb $DISPLAY -`: base and Shift exchanged on the moved keys, Ctrl and
--- AltGr levels and the layout's dead keys untouched, three builds in a row with no
--- restart.
---
--- The layouts are installed with no session type, as the layout manager does from
--- a Wayland session: an Xorg session never installs into the user tree, it only
--- loads an installed layout live, which is what this file proves. No keyboard,
--- desktop settings daemon or Wayland compositor is involved. Missing native
--- prerequisites fail.
--- ==============================================================================

local ffi = require("ffi")
local uv = require("luv")

ffi.cdef([[
	int setenv(const char *, const char *, int);
	int unsetenv(const char *);
]])

local AWAIT_MS = 60000
local _checks, _failures = 0, 0
local _server_pid = nil
local _scratch = nil





-- =======================================
-- =======================================
-- ======= 1/ Owned native fixture =======
-- =======================================
-- =======================================

local function quote(text) return "'" .. text:gsub("'", "'\\''") .. "'" end

local function check(condition, text)
	_checks = _checks + 1
	if not condition then _failures = _failures + 1 end
	print((condition and "  ok   " or "  FAIL ") .. text)
	return condition
end

local function read(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end

local function capture(command)
	local handle = assert(io.popen(command, "r"))
	local output = handle:read("*a")
	handle:close()
	return output
end

local function setenv(name, value)
	if value == nil then
		assert(ffi.C.unsetenv(name) == 0, "unsetenv " .. name)
	else
		assert(ffi.C.setenv(name, value, 1) == 0, "setenv " .. name)
	end
end

local function cleanup()
	if _server_pid then os.execute("kill " .. _server_pid .. " 2>/dev/null") end
	if _scratch then os.execute("rm -rf " .. quote(_scratch)) end
end

local function fail_environment(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	cleanup()
	os.exit(1)
end

for _, tool in ipairs({ "Xvfb", "setxkbmap", "xkbcomp", "python3" }) do
	if capture("command -v " .. tool .. " 2>/dev/null") == "" then fail_environment(tool .. " is not installed") end
end

_scratch = assert(uv.fs_mkdtemp("/tmp/ergopti-rows-live-XXXXXX"))
for _, dir in ipairs({ "/config", "/home" }) do assert(uv.fs_mkdir(_scratch .. dir, 448)) end
-- -noreset: without it the server forgets an uploaded keymap when the last client,
-- a one-shot xkbcomp, disconnects. -displayfd answers once clients are accepted.
_server_pid = capture("Xvfb -displayfd 9 -noreset -screen 0 640x480x8 9>" .. quote(_scratch .. "/display")
	.. " >/dev/null 2>&1 & echo $!"):match("%d+")
local display
for _ = 1, 100 do
	display = (read(_scratch .. "/display") or ""):match("^(%d+)%s")
	if display then break end
	uv.sleep(50)
end
if not display then fail_environment("Xvfb did not start") end
display = ":" .. display
setenv("DISPLAY", display)
setenv("WAYLAND_DISPLAY", nil)
setenv("XDG_CONFIG_HOME", _scratch .. "/config")
setenv("HOME", _scratch .. "/home")
setenv("ERGOPTI_XKB_USER_HOME", _scratch .. "/home")
setenv("ERGOPTI_XKB_USER_ROOT", nil)
setenv("XDG_CURRENT_DESKTOP", nil)

local Registry = require("modules.keymap.layout_registry")





-- ===============================
-- ===============================
-- ======= 2/ Server reads =======
-- ===============================
-- ===============================

--- The keymap the server holds, as xkbcomp prints it.
local function server_keymap()
	return capture("xkbcomp -xkb " .. quote(display) .. " - 2>/dev/null")
end

--- The keysym names of one key in group 1 of a printed keymap.
local function levels(keymap, key)
	local block = keymap:match("key <" .. key .. ">%s*(%b{})")
	if not block then return {} end
	local list = block:match("symbols%[Group1%]%s*=%s*(%b[])") or block:match("(%b[])")
	local names = {}
	for name in (list or ""):gmatch("[^%[%],%s]+") do names[#names + 1] = name end
	return names
end

--- Every dead keysym the keymap binds, counted by name.
local function dead_keys(keymap)
	local counts = {}
	for name in keymap:gmatch("dead_[%w_]+") do counts[name] = (counts[name] or 0) + 1 end
	return counts
end

local function same(left, right)
	if #left ~= #right then return false end
	for index = 1, #left do if left[index] ~= right[index] then return false end end
	return true
end

local function show(list) return "[" .. table.concat(list, ", ") .. "]" end

--- Runs one asynchronous registry operation on the real event loop.
local function await(label, start)
	local result
	local timer = uv.new_timer()
	timer:start(100, 100, function() end)
	start(function(...) result = { n = select("#", ...), ... } end)
	local deadline = uv.now() + AWAIT_MS
	while result == nil and uv.now() < deadline do uv.run("once") end
	timer:stop()
	timer:close()
	if not check(result ~= nil, label .. " settled") then return { false } end
	return result
end





-- ==================================
-- ==================================
-- ======= 3/ Install sources =======
-- ==================================
-- ==================================

local DIGIT_KEYS = { "AE01", "AE02", "AE03", "AE04", "AE05", "AE06", "AE07", "AE08", "AE09", "AE10" }
local EDGE_KEYS = { "TLDE", "AE11", "AE12" }
-- ERGOPTI_SEVEN_LEVEL: 1 base, 2 Caps, 3 Shift, 4 Shift+Caps, 5 the chord level
-- (Ctrl, Alt, Win), 6 AltGr, 7 Shift+AltGr.
local BASE, CAPS, SHIFT, CHORD, ALTGR, SHIFT_ALTGR = 1, 2, 3, 5, 6, 7

print("=== number-row options, loaded live into a real X server ===")
print("display " .. display .. ", user tree " .. _scratch .. "/config/xkb")

-- No session type: the layout manager installs from a Wayland or unknown session.
setenv("XDG_SESSION_TYPE", nil)
local shared = require("infra.paths").shared("modules/layouts/composer_check/")
local saved = await("the composer saves the shipped check composition", function(done)
	Registry.composer_save({
		declaration = read(shared .. "composition.json"),
		keylayout = read(shared .. "composed.keylayout"),
		use = false,
	}, done)
end)
check(saved[1] == true, "the compiled composition is installed: " .. tostring(saved[2]) .. " " .. tostring(saved[3]))

local registry_dir = require("infra.paths").driver_root() .. "/../../layouts/registry/"
local index = require("json").decode(read(registry_dir .. "index.json"))
local ergol
for _, entry in ipairs(index.layouts) do if entry.id == "ergol" then ergol = entry end end
local ergol_text = read(registry_dir .. ergol.file)
local installed = await("the Ergo-L copy is installed", function(done)
	Registry.install_local(ergol, ergol_text, done)
end)
check(installed[1] == true, "Ergo-L is installed: " .. tostring(installed[2]) .. " " .. tostring(installed[3]))





-- =====================================
-- =====================================
-- ======= 4/ Options, read back =======
-- =====================================
-- =====================================

setenv("XDG_SESSION_TYPE", "x11")

--- Applies options to one layout and returns the server keymap after the acknowledgement.
local function apply(id, rows)
	local result = await("apply_rows " .. id .. " " .. rows.order .. (rows.edges and "+edges" or ""), function(done)
		Registry.apply_rows(id, rows, done)
	end)
	local outcome = result[1] == true and "applied" or (tostring(result[2]) .. " " .. tostring(result[3])
		.. " " .. tostring(result[5]))
	check(result[1] == true, "the options are applied to " .. id .. ": " .. outcome)
	return server_keymap(), result[2]
end

--- The moved keys exchange base and Shift; the chord and AltGr levels stay.
local function check_moved(label, native, moved, keys)
	for _, key in ipairs(keys) do
		local before, after = levels(native, key), levels(moved, key)
		check(after[BASE] == before[SHIFT] and after[SHIFT] == before[BASE],
			label .. " " .. key .. " exchanges base and Shift: " .. show(before) .. " -> " .. show(after))
		check(after[CHORD] == before[CHORD] and after[ALTGR] == before[ALTGR]
			and after[SHIFT_ALTGR] == before[SHIFT_ALTGR],
			label .. " " .. key .. " keeps its Ctrl and AltGr levels")
		check(after[CAPS] == after[BASE], label .. " " .. key .. " types its new base cell with Caps Lock")
	end
end

local function check_unmoved(label, native, moved, keys)
	for _, key in ipairs(keys) do
		check(same(levels(native, key), levels(moved, key)), label .. " " .. key .. " is unchanged: "
			.. show(levels(moved, key)))
	end
end

local function check_dead_keys(label, native, moved)
	local before, after = dead_keys(native), dead_keys(moved)
	local kept, count = true, 0
	for name, number in pairs(before) do
		count = count + 1
		if after[name] ~= number then kept = false end
	end
	check(count > 0 and kept, label .. " keeps the layout's " .. count .. " dead keys")
end

-- Ergo-L holds the digits on the base level: « symbols » moves them behind Shift.
local ergol_native = apply("ergol", { order = "native", edges = false })
check(levels(ergol_native, "AE01")[BASE] == "1", "Ergo-L types 1 on the bare digit key")
check(ergol_native:match('xkb_symbols%s+"[^"]*%+ergol') ~= nil, "the server holds the Ergo-L symbols")
local ergol_symbols, report = apply("ergol", { order = "symbols", edges = true })
check(type(report) == "table" and report.rows and report.rows.order == "symbols",
	"the layout manager reports the ordering in effect")
check_moved("Ergo-L symbols", ergol_native, ergol_symbols, DIGIT_KEYS)
check_moved("Ergo-L symbols+edges", ergol_native, ergol_symbols, EDGE_KEYS)
check_dead_keys("Ergo-L symbols", ergol_native, ergol_symbols)

-- The composition takes AZERTY's base and Shift: « digits » brings the digits forward,
-- its Ctrl level is QWERTY's base (the composition's shortcuts), a digit.
local composed_native = apply("composed", { order = "native", edges = false })
check(levels(composed_native, "AE01")[BASE] == "ampersand", "the composition types & on the bare 1 key")
check(levels(composed_native, "AE01")[CHORD] == "1", "the composition's Ctrl level is its shortcut layer")
local composed_digits = apply("composed", { order = "digits", edges = false })
check_moved("composed digits", composed_native, composed_digits, DIGIT_KEYS)
check_unmoved("composed digits without edges", composed_native, composed_digits, EDGE_KEYS)
check_dead_keys("composed digits", composed_native, composed_digits)
check(levels(composed_digits, "AD11")[BASE] == "dead_circumflex"
	and levels(composed_digits, "AD11")[SHIFT] == "dead_diaeresis", "AZERTY's ^ and ¨ stay dead keys")

-- A layout that already has the ordering keeps it, and says why.
local _, inert = apply("composed", { order = "symbols", edges = false })
check(type(inert) == "table" and inert.rows and inert.rows.reason == "already_symbols_first",
	"an ordering already in effect is inert: " .. tostring(inert and inert.rows and inert.rows.reason))
check(same(levels(server_keymap(), "AE01"), levels(composed_native, "AE01")), "and types what the layout holds")

-- Three builds in a row, no restart: each read back is the one just applied.
for _, order in ipairs({ "digits", "native", "digits" }) do
	local keymap = apply("composed", { order = order, edges = false })
	local wanted = order == "digits" and composed_digits or composed_native
	check(same(levels(keymap, "AE05"), levels(wanted, "AE05")), "consecutive build " .. order .. " is the one held")
end

Registry.shutdown()
cleanup()
print(string.format("%d checks, %d failures", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
