--- tests/hardware/run_notification_text_receipts.lua
--- ==============================================================================
--- MODULE: Virtual Desktop Notification Text Receipts
--- DESCRIPTION:
--- Sends through the production notifier and installed notify-send to an owned
--- Dunst daemon on a private D-Bus session and Xvfb display. Native Gio history
--- receipts prove option-looking text remains literal and cannot alter urgency,
--- application identity or timeout. No notification APIs or syscalls are mocked.
--- Run with ERGOPTI_TEST_PRIVATE_DBUS=1 dbus-run-session -- xvfb-run -a luajit.
--- This is virtual graphical validation, not a physical desktop or Wayland test.
--- ==============================================================================

local uv = require("luv")
local lgi = require("lgi")
local Gio, GLib = lgi.Gio, lgi.GLib
local Notifier = require("adapters.notifier")
assert(os.getenv("ERGOPTI_TEST_PRIVATE_DBUS") == "1", "an explicitly owned test bus is required")
assert(os.getenv("DBUS_SESSION_BUS_ADDRESS") and os.getenv("DISPLAY"), "private D-Bus and virtual X11 are required")
local connection = assert(Gio.bus_get_sync(Gio.BusType.SESSION))
local service, path = "org.freedesktop.Notifications", "/org/freedesktop/Notifications"
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-notification-text-XXXXXX"))
local checks, failures = 0, 0
local daemon, exited

-- Dunst 1.9 history exposes category but no urgency. Fixture-owned urgency rules
-- record their actual matched severity, independently of the expected cases.
local URGENCY_RECEIPTS = {
	["ergopti-fixture-low"] = "LOW",
	["ergopti-fixture-normal"] = "NORMAL",
	["ergopti-fixture-critical"] = "CRITICAL",
}

local function assert_native_urgency(note, expected)
	local actual = URGENCY_RECEIPTS[note.category]
	assert(actual, "native urgency rule did not produce a classified receipt")
	if note.urgency ~= nil then
		assert(note.urgency == actual, "native history urgency disagrees with the matched rule")
	end
	assert(actual == expected, "caller text changed the native urgency")
end

local function call(destination, object_path, interface, method, parameters, signature)
	local answer, err = connection:call_sync(destination, object_path, interface, method,
		parameters, signature and GLib.VariantType.new(signature) or nil,
		Gio.DBusCallFlags.NO_AUTO_START, 1000)
	assert(answer, tostring(err))
	return answer.value
end

local function command(method, signature)
	return call(service, path, "org.dunstproject.cmd0", method, nil, signature)
end

local function owns_service()
	return call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
		"NameHasOwner", GLib.Variant("(s)", { service }), "(b)")[1]
end

local function await(predicate, milliseconds)
	local deadline = uv.hrtime() + milliseconds * 1000000
	repeat
		uv.run("nowait")
		if predicate() then return true end
		uv.sleep(10)
	until uv.hrtime() >= deadline
	return false
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

local ok, err = xpcall(function()
	assert(not owns_service(), "refusing to control a pre-existing desktop notification service")
	local config = assert(io.open(root .. "/dunstrc", "w"))
	assert(config:write("[global]\nhistory_length = 100\nignore_dbusclose = false\nmarkup = no\n"
		.. "format = \"%s\\n%b\"\n[urgency_low]\ntimeout = 0\nset_category = ergopti-fixture-low\n"
		.. "[urgency_normal]\ntimeout = 0\nset_category = ergopti-fixture-normal\n"
		.. "[urgency_critical]\ntimeout = 0\nset_category = ergopti-fixture-critical\n"
		.. "[fixture_wrong_urgency]\nsummary = Owned urgency-negative control\nset_category = ergopti-fixture-normal\n"))
	assert(config:close())
	local log = assert(uv.fs_open(root .. "/daemon.log", "w", 384))
	daemon = assert(uv.spawn("dunst", { args = { "-config", root .. "/dunstrc" }, stdio = { nil, log, log } }, function()
		exited = true
		uv.close(daemon)
	end))
	assert(uv.fs_close(log))
	assert(await(owns_service, 3000), "owned Dunst did not acquire its private bus name")
	local cases = {
		{ title = "--help", body = "Literal option title" },
		{ title = "-u", body = "Literal short option title" },
		{ title = "Help body", body = "--help" },
		{ title = "Urgency body", body = "--urgency=critical" },
		{ title = "Timeout body", body = "--expire-time=1" },
		{ title = "Application body", body = "--app-name=another-app" },
		{ title = "Separator body", body = "--" },
		{ title = "Short help body", body = "-?" },
		{ title = "Ordinary title", body = "Ordinary body" },
		{ title = "Literal ' quote", body = "Line one\n$(printf caller-text) é漢", level = "success" },
		{ title = "Warning title", body = "--urgency=critical", level = "warning", prefix = "⚠ ", urgency = "NORMAL" },
		{ body = "--expire-time=1", level = "error", prefix = "✖ ", urgency = "NORMAL" },
	}
	for index, case in ipairs(cases) do
		check("native notification text and immutable options " .. index, function()
			command("NotificationCloseAll")
			command("NotificationClearHistory")
			assert(Notifier.send(case.body, { title = case.title, level = case.level }), "production command was not admitted")
			local history
			assert(await(function()
				command("NotificationCloseAll")
				history = command("NotificationListHistory", "(aa{sv})")[1]
				return #history > 0
			end, 800), "admitted caller text never reached the actual notification service")
			assert(#history == 1, "one send must create exactly one native notification")
			local note = history[1]
			assert(note.summary == (case.prefix or "") .. (case.title or "Ergopti+"), "native summary bytes changed")
			assert(note.body == case.body, "native body bytes changed")
			assert(note.appname == "Ergopti+", "caller text changed the native application identity")
			assert_native_urgency(note, case.urgency or "LOW")
			assert(note.timeout == 5000000, "caller text changed the native timeout")
		end)
	end
	check("native urgency proof rejects an independently misclassified native rule", function()
		command("NotificationCloseAll")
		command("NotificationClearHistory")
		assert(Notifier.send("Owned negative-control body", { title = "Owned urgency-negative control", level = "info" }))
		local history
		assert(await(function()
			command("NotificationCloseAll")
			history = command("NotificationListHistory", "(aa{sv})")[1]
			return #history > 0
		end, 800), "negative-control notification did not reach native history")
		assert(#history == 1)
		local note = history[1]
		assert(note.summary == "Owned urgency-negative control")
		assert(note.body == "Owned negative-control body")
		assert(note.appname == "Ergopti+")
		assert(note.timeout == 5000000)
		assert(note.category == "ergopti-fixture-normal", "the deliberate wrong native rule must actually run")
		local accepted = pcall(assert_native_urgency, note, "LOW")
		assert(accepted == false, "a wrong native severity receipt must not pass the original urgency assertion")
	end)
end, debug.traceback)

if daemon and not exited then
	assert(uv.process_kill(daemon, "sigterm"))
	if not await(function() return exited end, 2000) then
		assert(uv.process_kill(daemon, "sigkill"))
		assert(await(function() return exited end, 2000), "owned notification daemon did not retire")
	end
end
uv.run()
for name in uv.fs_scandir_next, assert(uv.fs_scandir(root)) do assert(uv.fs_unlink(root .. "/" .. name)) end
assert(uv.fs_rmdir(root))
assert(not uv.loop_alive(), "fixture retained native process ownership")
if not ok then io.stderr:write(tostring(err) .. "\n"); os.exit(1) end
print(string.format("Virtual desktop notification receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
