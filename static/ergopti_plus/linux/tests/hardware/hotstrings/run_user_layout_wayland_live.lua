--- tests/hardware/hotstrings/run_user_layout_wayland_live.lua

--- ==============================================================================
--- MODULE: A User-Tree Layout Loaded By A Wayland Compositor (W1 to W3)
--- DESCRIPTION:
--- Run by `../core/run_input_sources_live.sh gnome|kde tests/hardware/hotstrings/run_user_layout_wayland_live.lua`
--- inside a headless GNOME Shell or KWin Wayland session. Installs the
--- registry's Bépo layout in the private user XKB tree through the layout
--- manager and the real Python installer, then applies it live
--- (layout_registry.apply_rows, the installer's apply-wayland: two slots,
--- the desktop setting, XWayland read-back). It prints what the compositor
--- did, the answers to W1 to W3 of docs/design/layout-option-emulation.md:
--- W1 the compositor compiles an id found only in ~/.config/xkb with the
--- ERGOPTI_SEVEN_LEVEL type; W2 the new keymap is the one the session holds
--- right after the setting moves; W3 a second build under the other slot
--- replaces the first with no restart. Bépo types symbols first on its number
--- row, so its digits-first build changes the row (Ergopti types digits on
--- both levels: no option changes it).
---
--- GNOME Shell reads the user tree's registry only when it starts: the first
--- run, on a session that started before the install, checks that the
--- installer leaves the setting alone and asks for a new login (exit 3);
--- ../core/run_input_sources_live.sh then restarts the shell on the same HOME and runs
--- this script again with ERGOPTI_LIVE_PHASE=after_login, which checks W1 to W3.
--- ==============================================================================

package.path = "./?.lua;./?/init.lua;../_shared/?.lua;../_shared/?/init.lua;" .. package.path

local uv = require("luv")
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

local function await(start)
	local result
	local timer = uv.new_timer()
	timer:start(100, 100, function() end)
	start(function(...) result = { ... } end)
	local deadline = uv.now() + 120000
	while result == nil and uv.now() < deadline do uv.run("once") end
	timer:stop()
	timer:close()
	return result or { false, "timeout" }
end

local runner_python = (capture("command -v python3 2>/dev/null"):gsub("%s+$", ""))
package.loaded["layouts.engine.managed_python"] = { ensure = function(_, done) done(true, runner_python) end }
ffi.C.setenv("ERGOPTI_XKB_USER_HOME", assert(os.getenv("HOME")), 1)
local Registry = require("layouts.engine.registry.registry")

local desktop = os.getenv("XDG_CURRENT_DESKTOP")
print("=== user-tree layout on " .. tostring(desktop) .. " Wayland (W1 to W3) ===")
local registry_dir = "../../layouts/registry/"
local index = require("core.text.engine.json").decode(read(registry_dir .. "index.json"))
local LAYOUT = "bepo"
local entry
for _, candidate in ipairs(index.layouts) do if candidate.id == LAYOUT then entry = candidate end end
local after_login = os.getenv("ERGOPTI_LIVE_PHASE") == "after_login"
if not after_login then
	local session = os.getenv("XDG_SESSION_TYPE")
	ffi.C.unsetenv("XDG_SESSION_TYPE")
	local installed = await(function(done) Registry.install_local(entry, read(registry_dir .. entry.file), done) end)
	ffi.C.setenv("XDG_SESSION_TYPE", session, 1)
	check(installed[1] == true, LAYOUT .. " is installed in the user tree (" .. tostring(installed[2]) .. ")")
end

local function keymap() return capture('xkbcomp -xkb "$DISPLAY" - 2>/dev/null') end

local function apply(order)
	local result = await(function(done) Registry.apply_rows(LAYOUT, { order = order, edges = false }, done) end)
	local detail = result[1] == true and ("slot " .. tostring(type(result[2]) == "table" and result[2].slot))
		or (tostring(result[2]) .. " " .. tostring(result[3]) .. " live_code=" .. tostring(result[5]))
	return result[1] == true, detail
end

if desktop == "GNOME" and not after_login then
	local sources = capture("gsettings get org.gnome.desktop.input-sources sources")
	local refused, refusal = apply("native")
	check(not refused and refusal:find("live_code=needs_relogin", 1, true) ~= nil,
		"GNOME: a layout registered after the shell started waits for the next login (" .. refusal .. ")")
	check(capture("gsettings get org.gnome.desktop.input-sources sources") == sources,
		"GNOME: the session's input sources are left as they were (" .. (sources:gsub("%s+$", "")) .. ")")
	print(string.format("=== %d check(s), %d failure(s), new login requested ===", _checks, _failures))
	os.exit(_failures == 0 and 3 or 1)
end

local ok, detail = apply("native")
check(ok, "W1/W2: the compositor loads the user-tree id and the session holds it (" .. detail .. ")")
local map = keymap()
check(map:find("ERGOPTI_SEVEN_LEVEL", 1, true) ~= nil, "W1: the session's keymap carries the ERGOPTI_SEVEN_LEVEL type")
local first = map:match("key <AE01>%s*(%b{})") or ""
local again, again_detail = apply("digits")
check(again, "W3: a second build under the other slot loads with no restart (" .. again_detail .. ")")
local second = keymap():match("key <AE01>%s*(%b{})") or ""
check(first ~= "" and second ~= "" and first ~= second, "W3: the number row the session types changed between the builds")
if os.getenv("ERGOPTI_LIVE_GNOME_UNSAFE") then
	print("diagnostic: gsettings sources " .. capture("gsettings get org.gnome.desktop.input-sources sources"))
	print("diagnostic: shell view " .. capture("gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell"
		.. " --method org.gnome.Shell.Eval 'const m = Main.panel.statusArea.keyboard._inputSourceManager;"
		.. " JSON.stringify({current: m.currentSource && m.currentSource.id,"
		.. " sources: Object.values(m.inputSources).map(s => s.id)})'"))
	print("diagnostic: XWayland " .. tostring(os.getenv("DISPLAY")) .. " auth " .. tostring(os.getenv("XAUTHORITY"))
		.. " symbols " .. (keymap():match('xkb_symbols%s+"([^"]*)"') or "unreadable")
		.. " AE01 " .. ((keymap():match("key <AE01>%s*(%b{})") or ""):gsub("%s+", " ")))
	print("diagnostic: user tree " .. capture("ls -R \"$HOME/.config/xkb\" 2>&1 | tr '\\n' ' '"))
end
print(string.format("=== %d check(s), %d failure(s) ===", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
