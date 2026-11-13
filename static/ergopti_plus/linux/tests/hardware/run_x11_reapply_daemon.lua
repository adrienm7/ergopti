--- tests/hardware/run_x11_reapply_daemon.lua

--- ==============================================================================
--- MODULE: The Daemon Keeps An X11 User-Tree Layout Against The Desktop
--- DESCRIPTION:
--- Run by run_x11_reapply_live.sh inside its headless GNOME Shell or Plasma X11
--- session, after the W4 checks. Loads the registry's Bépo live through the
--- layout manager (layout_registry.apply_rows, the real Python installer's
--- install and apply-x11), which arms modules/keymap/x11_layout_reapply.lua
--- with its production collaborators: the keymap watch worker, the xkbcomp
--- read and number_row_live. A new keyboard then makes the desktop put its own
--- layouts back, and the server must hold Bépo again without any other call.
--- Exit 0 = every check held.
--- ==============================================================================

package.path = "./?.lua;./?/init.lua;../_shared/?.lua;../_shared/?/init.lua;" .. package.path

local uv = require("luv")
if os.getenv("ERGOPTI_LIVE_DEBUG") then
	require("core.logger.engine").set_sink(function(line) io.stderr:write(line, "\n") end)
end
local ffi = require("ffi")
ffi.cdef("int setenv(const char *, const char *, int); int unsetenv(const char *);")

local _checks, _failures = 0, 0
local function check(condition, text)
	_checks = _checks + 1
	if not condition then _failures = _failures + 1 end
	print((condition and "  ok   " or "  FAIL ") .. text)
	return condition
end

local function capture(command)
	local handle = assert(io.popen(command, "r"))
	local output = handle:read("*a")
	handle:close()
	return output
end

local function read(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

--- Runs the loop until `done()` holds or `ms` pass.
local function run_until(done, ms)
	local timer = uv.new_timer()
	timer:start(50, 50, function() end)
	local deadline = uv.now() + ms
	while not done() and uv.now() < deadline do uv.run("once") end
	timer:stop()
	timer:close()
	return done()
end

local function await(start)
	local result
	start(function(...) result = { ... } end)
	run_until(function() return result ~= nil end, 120000)
	return result or { false, "timeout" }
end

local function symbols() return capture('xkbcomp -xkb "$DISPLAY" - 2>/dev/null'):match('xkb_symbols%s+"([^"]*)"') or "" end

if not os.execute("command -v xinput >/dev/null 2>&1") then
	io.stderr:write("ENVIRONMENT: xinput is missing\n")
	os.exit(2)
end

local runner_python = (capture("command -v python3 2>/dev/null"):gsub("%s+$", ""))
package.loaded["modules.keymap.managed_python"] = { ensure = function(_, done) done(true, runner_python) end }
ffi.C.setenv("ERGOPTI_XKB_USER_HOME", assert(os.getenv("HOME")), 1)
local Registry = require("modules.keymap.layout_registry")
local Reapply = require("modules.keymap.x11_layout_reapply")

print("=== the daemon keeps Bépo against " .. tostring(os.getenv("XDG_CURRENT_DESKTOP")) .. " under X11 ===")
local registry_dir = "../../layouts/registry/"
local index = require("core.text.engine.json").decode(read(registry_dir .. "index.json"))
local entry
for _, candidate in ipairs(index.layouts) do if candidate.id == "bepo" then entry = candidate end end
local session = os.getenv("XDG_SESSION_TYPE")
ffi.C.unsetenv("XDG_SESSION_TYPE")
local installed = await(function(done) Registry.install_local(entry, read(registry_dir .. entry.file), done) end)
ffi.C.setenv("XDG_SESSION_TYPE", session, 1)
check(installed[1] == true, "Bépo is installed by the layout manager (" .. tostring(installed[2]) .. ")")
local applied = await(function(done) Registry.apply_rows("bepo", { order = "native", edges = false }, done) end)
check(applied[1] == true, "the layout manager loads it into the server (" .. symbols() .. ")")
check(run_until(function() return Reapply._shared_status() == "watching" end, 10000),
	"the daemon watches the X11 keymap (" .. tostring(Reapply._shared_status()) .. ")")
os.execute("xinput create-master w4daemon")
-- The daemon may load Bépo again before a poll of the server sees the
-- desktop's layouts: its own count of re-applies is the evidence.
check(run_until(function() return Reapply._shared_reapplies() >= 1 end, 30000),
	"the daemon sees the desktop put its own layouts back and loads Bépo again ("
		.. Reapply._shared_reapplies() .. " re-apply)")
local restored = run_until(function() return symbols():find("+bepo+", 1, true) ~= nil end, 60000)
check(restored, "the server holds Bépo again with no other call (" .. symbols() .. ")")
check(Reapply._shared_reapplies() == 1, "one re-apply, not a loop (" .. Reapply._shared_reapplies() .. ")")
check(Reapply._shared_status() == "watching", "the watch goes on after the re-apply")
Reapply.shutdown()
print(string.format("=== %d check(s), %d failure(s) ===", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
