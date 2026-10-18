--- infra/input_access.lua

--- ==============================================================================
--- MODULE: Input Access Failure (Linux)
--- DESCRIPTION:
--- What the daemon does when the session cannot read the keyboard or write to
--- /dev/uinput: tell the user, in their language, what fixes it, then exit with
--- a status the service manager will not blindly retry.
---
--- WHY THIS EXISTS:
--- install.sh adds the user to the `input` and `uinput` groups, and group
--- membership is only read when a session opens. So the FIRST launch — the
--- service the installer starts, or the user trying it right away — always ran
--- without them. The daemon printed one line to a console nobody sees and exited
--- 1; systemd restarted it every three seconds, for ever; no tray icon ever
--- appeared and nothing on screen said why. The same silence met a user whose
--- uinput module was not loaded.
---
--- FEATURES & RATIONALE:
--- 1. A desktop notification, not a log line: it is the one surface a user who
---    just ran the installer is looking at. Translated through the shared
---    catalogue like the macOS "accessibility required" message it mirrors.
--- 2. EXIT_ACCESS (78, EX_CONFIG) rather than 1. The unit declares it in
---    RestartPreventExitStatus, because no restart can fix group membership —
---    only a new session can — and a restart loop would repeat the notification
---    every three seconds.
--- 3. With --tray the icon stays up, naming the failure, until the user quits:
---    a desktop launch that vanished looked like an app that never started.
--- ==============================================================================

local M = {}

--- sysexits.h EX_CONFIG. Pinned by ergopti-hotstrings.service's
--- RestartPreventExitStatus= (tests/unit/infra/test_input_access.lua).
M.EXIT_ACCESS = 78

M.TITLE_KEY = "startup.linux_input_access_title"
M.NOTIFICATION_LABEL_KEY = "startup.linux_input_access_label"
M.BODY_KEY = "startup.linux_input_access_body"

-- errno for a node that exists but this user may not open.
local EACCES = 13

--- Whether a node exists but this session is denied access to it.
---
--- Only EACCES means "log out and back in". An absent path (a mistyped
--- --device, an unplugged keyboard) is a different problem with a different
--- message, and telling that user to re-login would send them the wrong way.
--- @param path string
--- @param open function|nil io.open by default; a seam for the tests.
--- @return boolean
function M.is_denied(path, open)
	local handle, _, errno = (open or io.open)(path, "rb")
	if handle then
		handle:close()
		return false
	end
	return errno == EACCES
end

--- Reports an input-access failure to the user.
--- @param deps table i18n, notifier, print; optional script_dir for an isolated caller.
--- @param detail string What exactly could not be opened, for the console.
--- @return integer The exit status the daemon must use.
function M.report(deps, detail)
	deps = type(deps) == "table" and deps or {}
	local i18n = deps.i18n
	local title, body = M.TITLE_KEY, M.BODY_KEY
	local notification_label = M.NOTIFICATION_LABEL_KEY
	if i18n then
		pcall(i18n.init)
		local ok_title, translated_title = pcall(i18n.get, M.TITLE_KEY)
		local ok_body, translated_body = pcall(i18n.get, M.BODY_KEY)
		local ok_label, translated_label = pcall(i18n.get, M.NOTIFICATION_LABEL_KEY)
		if ok_title and type(translated_title) == "string" then title = translated_title end
		if ok_body and type(translated_body) == "string" then body = translated_body end
		if ok_label and type(translated_label) == "string" then notification_label = translated_label end
	end
	if body:find("{1}", 1, true) then
		local root = deps.script_dir or require("infra.paths").driver_root()
		local command = "bash " .. require("adapters.shell_runner").quote(root .. "/install.sh") .. " --setup-perms"
		body = body:gsub("{1}", function() return command end)
	end

	local out = deps.print or print
	out(title .. " — " .. tostring(detail))
	out(body)

	if deps.notifier and type(deps.notifier.send) == "function" then
		pcall(deps.notifier.send, body, { title = notification_label, level = "error" })
	end
	if deps.tray then M.hold_tray(deps, notification_label) end
	return M.EXIT_ACCESS
end

--- Keeps a tray icon that names the failure until the user quits it.
---
--- A desktop launch (the AppImage, the menu entry) has only the tray to show
--- that the app started at all. Exiting after a notification left nothing on
--- screen, which a user reads as "it does not launch" and the AppImage
--- catalogue test fails outright: it starts the app without the input group
--- and requires a window or a tray icon.
--- @param deps table tray (tray_menu adapter); i18n, sleep_ms optional.
--- @param label string The translated failure, shown as the first row.
function M.hold_tray(deps, label)
	local tray = deps.tray
	tray.setIcon({ title = "Ergopti" })
	if tray.getBackend() == nil then return end
	local quit_label = "Quit"
	if deps.i18n then
		local ok, translated = pcall(deps.i18n.get, "menu.global.quit")
		-- The menu key carries the row's emoji, which a lone row does not need.
		if ok and type(translated) == "string" then quit_label = translated:gsub("^%S+%s+", "") end
	end
	local quit = false
	tray.setFallbackMenu(label, quit_label, function() quit = true end)
	local sleep_ms = deps.sleep_ms or require("adapters.event_loop").sleep_ms
	while not quit do
		tray.pump()
		sleep_ms(100)
	end
	tray.destroy()
end

return M
