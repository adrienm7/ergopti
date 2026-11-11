--- tests/hardware/run_layout_source_live.lua

--- ==============================================================================
--- MODULE: A Layout Source Installed Live Into a Real X Server
--- DESCRIPTION:
--- What the unified layout editor's « Install and use » sends, end to end on an
--- owned Xvfb server: the payload the editor builds (`tools/layout-source.cjs
--- install-payload`, LayoutSourceIO.installPayload: the TOML source, its
--- .keylayout compiled for Linux and its emulation table) goes through the
--- composer's real save path, which stores the source and the table and installs
--- the layout as `composed`; the layout manager then loads it into the running
--- server (the shared converter, the real Python installer, a private user
--- tree). Every claim is read back: the stored source and table, and the server
--- keymap with xkbcomp (the Ergopti source's base, Shift, Kana-on-AltGr levels,
--- ê on the ISO key, its dead keys). No keyboard, desktop or compositor is
--- involved. Missing native prerequisites fail.
--- USAGE: luajit tests/hardware/run_layout_source_live.lua <install-payload.json>
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

_scratch = assert(uv.fs_mkdtemp("/tmp/ergopti-source-live-XXXXXX"))
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

-- The layout source is what this probe proves, not Ergopti's own Python: its
-- download on consent has its own live probe (run_managed_python_live.lua), so
-- the installer runs here on the runner's interpreter instead of asking.
local runner_python = (capture("command -v python3 2>/dev/null"):gsub("%s+$", ""))
package.loaded["modules.keymap.managed_python"] = { ensure = function(_, done) done(true, runner_python) end }
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





-- ===================================
-- ===================================
-- ======= 3/ Install and read =======
-- ===================================
-- ===================================

-- ERGOPTI_SEVEN_LEVEL: 1 base, 2 Caps, 3 Shift, 4 Shift+Caps, 5 the chord level
-- (Ctrl, Alt, Win), 6 AltGr, 7 Shift+AltGr.
local BASE, SHIFT, ALTGR, SHIFT_ALTGR = 1, 3, 6, 7
local Json = require("json")

local payload_path = arg[1]
if type(payload_path) ~= "string" then fail_environment("usage: run_layout_source_live.lua <install-payload.json>") end
local payload = Json.decode(assert(read(payload_path), "the install payload is readable"))
print("=== a layout source installed and loaded into a real X server ===")
print("display " .. display .. ", user tree " .. _scratch .. "/config/xkb")

-- No session type: the layout manager installs from a Wayland or unknown session.
setenv("XDG_SESSION_TYPE", nil)
local saved = await("the composer saves the editor's source", function(done)
	Registry.composer_save({
		source = payload.source,
		keylayout = payload.keylayout,
		emulation = payload.emulation,
		use = false,
	}, done)
end)
check(saved[1] == true, "the source is installed as the composed layout: " .. tostring(saved[2]) .. " "
	.. tostring(saved[3]))

local settings = assert(Registry.composer_settings())
local folder = require("infra.config_paths").get_config_dir() .. "/" .. settings.folder .. "/"
check(read(folder .. settings.source_file) == payload.source, "the TOML source is stored as sent")
local table_ = Registry.composer_emulation()
check(type(table_) == "table" and table_.platform == "linux" and table_.layout == "ergopti",
	"the Linux emulation table is stored beside it")

setenv("XDG_SESSION_TYPE", "x11")
local loaded = await("the layout manager loads the composed layout", function(done)
	Registry.apply_rows("composed", { order = "native", edges = false }, done)
end)
check(loaded[1] == true, "the composed layout is loaded into the server: " .. tostring(loaded[2]) .. " "
	.. tostring(loaded[3]))
local keymap = server_keymap()

--- One level of a key as the server holds it.
local function at(key, level) return levels(keymap, key)[level] end

for _, case in ipairs({
	{ "AC01", BASE, "a" }, { "AC01", SHIFT, "A" }, { "AC02", BASE, "i" }, { "AD03", BASE, "o" },
	-- Kana compiles to the AltGr level through the converter.
	{ "AC01", ALTGR, "less" }, { "AC02", ALTGR, "greater" }, { "AC01", SHIFT_ALTGR, "lessthanequal" },
	{ "AD03", ALTGR, "oe" }, { "AD03", SHIFT_ALTGR, "OE" },
	-- ê on the ISO key, $ left of 1 (KbdEdit's export numbers them the ANSI way).
	{ "LSGT", BASE, "ecircumflex" }, { "LSGT", SHIFT, "Ecircumflex" }, { "TLDE", BASE, "dollar" },
}) do
	local key, level, wanted = case[1], case[2], case[3]
	check(at(key, level) == wanted, key .. " level " .. level .. " types " .. wanted .. ": " .. show(levels(keymap, key)))
end
local deads = dead_keys(keymap)
local total = 0
for _, count in pairs(deads) do total = total + count end
check(total > 0, "the source's dead keys are in the server keymap (" .. total .. " dead keysyms)")

Registry.shutdown()
cleanup()
print(string.format("%d checks, %d failures", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
