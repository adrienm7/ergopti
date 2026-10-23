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

local LOG = "infra.input_access"

--- sysexits.h EX_CONFIG. Pinned by ergopti-hotstrings.service's
--- RestartPreventExitStatus= (tests/unit/infra/lifecycle/test_input_access.lua).
M.EXIT_ACCESS = 78

M.TITLE_KEY = "startup.linux_input_access_title"
M.NOTIFICATION_LABEL_KEY = "startup.linux_input_access_label"
M.BODY_KEY = "startup.linux_input_access_body"
-- No keyboard device at all (a sandbox hides /dev/input): the input groups are
-- not the cause, so this body does not name them.
M.NO_DEVICE_BODY_KEY = "startup.linux_input_access_no_device_body"

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
	local body_key = deps.body_key or M.BODY_KEY
	local title, body = M.TITLE_KEY, body_key
	local notification_label = M.NOTIFICATION_LABEL_KEY
	if i18n then
		pcall(i18n.init)
		local ok_title, translated_title = pcall(i18n.get, M.TITLE_KEY)
		local ok_body, translated_body = pcall(i18n.get, body_key)
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
	if deps.tray then M.hold_tray(deps, { label = notification_label, title = title, body = body }) end
	return M.EXIT_ACCESS
end

--- The window title of the degraded state: the product name, which is what
--- the AppImage catalogue and a user's task switcher show.
M.WINDOW_TITLE = "Ergopti+"

--- A translated label, or its key when the catalogue cannot supply one.
--- @param i18n table|nil
--- @param key string
--- @return string
local function label_for(i18n, key)
	if not i18n then return key end
	local ok, translated = pcall(i18n.get, key)
	return (ok and type(translated) == "string") and translated or key
end

--- Opens a path or URL on the desktop, logging a refusal or a failed launch.
--- @param target string
local function open_on_desktop(target)
	local request, reason = require("adapters.desktop_opener").open(target, function(result)
		if result.ok ~= true then
			require("logger.shim").error(LOG, "Desktop open of %s failed (%s).",
				target, tostring(result.error or result.code))
		end
	end)
	if not request then
		require("logger.shim").error(LOG, "Desktop open of %s refused: %s.", target, tostring(reason))
	end
end

--- The bug form, prefilled with nothing the daemon would need to collect.
--- @return string
local function bug_form_url()
	local documents = require("ui.healthcheck.bridge").config()
	return require("diagnostics.issue_link").build_url(documents.templates, documents.repository, "bug", {})
end

--- Default side effects of the degraded menu; tests replace each one.
local DEFAULT_ACTIONS = {
	open_logs = function() open_on_desktop(require("infra.config_paths").get_logs_dir()) end,
	report_bug = function() open_on_desktop(bug_form_url()) end,
	-- The menu's actions start desktop helpers on the libuv loop, which the
	-- daemon's own loop never runs in this state: drain it beside the tray.
	run_once = function()
		local ok, luv = pcall(require, "luv")
		if ok and type(luv) == "table" then luv.run("nowait") end
	end,
}

--- The degraded menu: what is wrong, how to read more, and the ways out.
---
--- The shared renderer is not initialised in this state, so the tray adapter's
--- fallback builder draws it; every label still comes from the shared catalogue.
--- @param deps table tray; i18n optional; actions overrides.
--- @param texts table { label, title, body }.
--- @param show_details function Shows the status window.
--- @param on_quit function
local function install_degraded_menu(deps, texts, show_details, on_quit)
	local actions = deps.actions or DEFAULT_ACTIONS
	local quit_label = label_for(deps.i18n, "menu.global.quit")
	-- The menu key carries the row's emoji, which this short menu does not need.
	if quit_label ~= "menu.global.quit" then quit_label = quit_label:gsub("^%S+%s+", "") end
	deps.tray.setFallbackMenu(texts.label, quit_label, on_quit, {
		{ { label = texts.title, fn = show_details } },
		{
			{ label = label_for(deps.i18n, "menu.debug.open_logs"), fn = actions.open_logs },
			{ label = label_for(deps.i18n, "menu.debug.report_bug"), fn = actions.report_bug },
		},
	})
end

--- Keeps a tray icon that names the failure until the user quits it.
---
--- A desktop launch (the AppImage, the menu entry) has only the tray to show
--- that the app started at all. Exiting after a notification left nothing on
--- screen, which a user reads as "it does not launch" and the AppImage
--- catalogue test fails outright: it starts the app without the input group
--- and requires a window or a tray icon.
---
--- The status window opens at once as well. The catalogue screenshots the
--- first named window it finds; with only an icon it left-clicks it, which
--- pops the menu, then right-clicks the same spot, which lands outside the
--- grabbed menu and closes it, so its screenshot showed the bare icon.
--- @param deps table tray (tray_menu adapter); i18n, sleep_ms, actions optional.
--- @param texts table { label, title, body }: translated label, title, body.
function M.hold_tray(deps, texts)
	local Logger = require("logger.shim")
	local tray = deps.tray
	tray.setIcon({ title = "Ergopti" })
	if tray.getBackend() == nil then return end
	local actions = deps.actions or DEFAULT_ACTIONS
	local function show_details()
		if not tray.showStatusWindow(M.WINDOW_TITLE, texts.title .. "\n\n" .. texts.body) then
			Logger.error(LOG, "The status window could not be shown.")
		end
	end
	local quit = false
	install_degraded_menu(deps, texts, show_details, function() quit = true end)
	show_details()
	Logger.start(LOG, "Holding the degraded tray until Quit.")
	local sleep_ms = deps.sleep_ms or require("adapters.event_loop").sleep_ms
	while not quit do
		tray.pump()
		actions.run_once()
		sleep_ms(100)
	end
	tray.destroy()
	Logger.success(LOG, "Degraded tray released by Quit.")
end

return M
