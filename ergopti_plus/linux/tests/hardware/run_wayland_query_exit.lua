--- tests/hardware/run_wayland_query_exit.lua
--- ==============================================================================
--- MODULE: Native Wayland Focus Command Exit Regression
--- DESCRIPTION:
--- Private real clients emit identical valid JSON with different exit statuses.
--- Focus metadata requires successful acquisition, independently of JSON syntax.
--- ==============================================================================

local root, selected = assert(arg[1]), assert(arg[2])
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path
require("compat.utf8").install()
local uv = require("luv")
local Shell = require("adapters.shell_runner")
local Display = require("infra.display_server")
local FAILURE_STATUS = 73
local cases = {
	{ name = "sway", binary = "swaymsg", arguments = "-t get_tree",
		payload = '{"focused":true,"id":19,"pid":4242,"name":"Owned Sway title","app_id":"owned.sway"}',
		app = "owned.sway", title = "Owned Sway title", identity = "sway:4242:19" },
	{ name = "hyprland", binary = "hyprctl", arguments = "activewindow -j",
		payload = '{"address":"0x123","pid":4242,"title":"Owned Hyprland title","class":"owned.hyprland"}',
		app = "owned.hyprland", title = "Owned Hyprland title", identity = "hyprland:4242:0x123" },
	{ name = "niri", binary = "niri", arguments = "msg --json focused-window",
		payload = '{"id":21,"pid":4242,"title":"Owned Niri title","app_id":"owned.niri"}',
		app = "owned.niri", title = "Owned Niri title", identity = "niri:4242:21" },
}
local directory = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-focus-exit-XXXXXX"))
local previous = {}
for _, name in ipairs({ "PATH", "DISPLAY", "WAYLAND_DISPLAY", "XDG_SESSION_TYPE", "XDG_CURRENT_DESKTOP", "DBUS_SESSION_BUS_ADDRESS", "AT_SPI_BUS_ADDRESS" }) do
	previous[#previous + 1] = { name = name, value = uv.os_getenv(name) }
end
local function write_client(case, payload, status)
	local file = assert(io.open(directory .. "/" .. case.binary, "wb"))
	assert(file:write("#!/bin/sh\n", "test \"$*\" = ", Shell.quote(case.arguments), " || exit ", tostring(FAILURE_STATUS), "\n",
		"printf '%s\\n' ", Shell.quote(payload), "\nexit ", tostring(status), "\n"))
	assert(file:close())
	assert(uv.fs_chmod(directory .. "/" .. case.binary, 448))
end
local checks = 0
local function verify_focus(window, expected)
	local info, identity, pid = window.focused_process_snapshot()
	local simple = window.getFocused()
	local snapshot, snapshot_id = window.focused_snapshot()
	assert(info.appId == (expected and expected.app or ""), "failed client output must not publish an application")
	assert(info.windowTitle == (expected and expected.title or ""), "failed client output must not publish a title")
	assert(identity == (expected and expected.identity or nil), "failed client output must not publish a native identity")
	assert(pid == (expected and 4242 or nil), "failed client output must not publish a process")
	assert(simple.appId == info.appId and simple.windowTitle == info.windowTitle)
	assert(snapshot.appId == info.appId and snapshot.windowTitle == info.windowTitle and snapshot_id == identity)
	checks = checks + 6
end
local ok, failure = xpcall(function()
	local index
	for i, case in ipairs(cases) do
		write_client(case, "", FAILURE_STATUS)
		if case.name == selected then index = i end
	end
	assert(index, "unknown private compositor fixture")
	local case = cases[index]
	assert(uv.os_setenv("PATH", directory .. ":/usr/bin:/bin"))
	assert(uv.os_unsetenv("DISPLAY"))
	assert(uv.os_setenv("WAYLAND_DISPLAY", "owned-no-compositor-socket"))
	assert(uv.os_setenv("XDG_SESSION_TYPE", "wayland"))
	assert(uv.os_setenv("XDG_CURRENT_DESKTOP", selected))
	assert(uv.os_setenv("DBUS_SESSION_BUS_ADDRESS", "unix:path=" .. directory .. "/no-session-bus"))
	assert(uv.os_setenv("AT_SPI_BUS_ADDRESS", "unix:path=" .. directory .. "/no-accessibility-bus"))
	assert(Display.refresh() == Display.WAYLAND)
	local window = require("adapters.window_info")
	local command = case.binary .. " " .. case.arguments
	write_client(case, case.payload, 0)
	local status = os.execute(command .. " >/dev/null 2>&1")
	assert(status == true or status == 0, "the real private positive client must succeed")
	local admitted, output = Shell.exec_checked(command)
	assert(admitted and output == case.payload .. "\n", "the same real JSON bytes must be captured")
	verify_focus(window, case)
	print("POSITIVE native focus client=" .. selected .. " exit=0 checks=" .. tostring(checks))
	write_client(case, case.payload, FAILURE_STATUS)
	local a, kind, code = os.execute(command .. " >/dev/null 2>&1")
	assert((type(a) == "number" and a == FAILURE_STATUS * 256)
		or (a == nil and kind == "exit" and code == FAILURE_STATUS), "the real private client must exit with the declared failure")
	local acknowledged, retained, detail = Shell.exec_checked(command)
	assert(acknowledged == false and retained == output and detail == "command exited with status " .. FAILURE_STATUS)
	print("NEGATIVE native focus client=" .. selected .. " exit=" .. FAILURE_STATUS .. " identical_json=true")
	verify_focus(window, nil)
	if cases[index + 1] then
		local fallback = cases[index + 1]
		write_client(fallback, fallback.payload, 0)
		verify_focus(window, fallback)
	end
end, debug.traceback)
local cleaned, cleanup_error = pcall(function()
	for _, entry in ipairs(previous) do
		if entry.value == nil then assert(uv.os_unsetenv(entry.name)) else assert(uv.os_setenv(entry.name, entry.value)) end
		assert(uv.os_getenv(entry.name) == entry.value, "restore exact environment presence and bytes")
	end
	Display.refresh()
	for _, case in ipairs(cases) do assert(uv.fs_unlink(directory .. "/" .. case.binary)) end
	assert(uv.fs_rmdir(directory))
end)
assert(ok, failure)
assert(cleaned, cleanup_error)
print("Native Wayland client exit " .. selected .. ": " .. checks .. " focus assertions passed; environment and files retired")
