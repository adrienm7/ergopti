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
--- ==============================================================================

local M = {}

--- sysexits.h EX_CONFIG. Pinned by ergopti-hotstrings.service's
--- RestartPreventExitStatus= (tests/unit/infra/test_input_access.lua).
M.EXIT_ACCESS = 78

M.TITLE_KEY = "startup.linux_input_access_title"
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
--- @param deps table { i18n = module|nil, notifier = module|nil, print = function|nil }
--- @param detail string What exactly could not be opened, for the console.
--- @return integer The exit status the daemon must use.
function M.report(deps, detail)
	deps = type(deps) == "table" and deps or {}
	local i18n = deps.i18n
	local title, body = M.TITLE_KEY, M.BODY_KEY
	if i18n then
		pcall(i18n.init)
		local ok_title, translated_title = pcall(i18n.get, M.TITLE_KEY)
		local ok_body, translated_body = pcall(i18n.get, M.BODY_KEY)
		if ok_title and type(translated_title) == "string" then title = translated_title end
		if ok_body and type(translated_body) == "string" then body = translated_body end
	end

	local out = deps.print or print
	out(title .. " — " .. tostring(detail))
	out(body)

	if deps.notifier and type(deps.notifier.send) == "function" then
		pcall(deps.notifier.send, body, { title = title, level = "error" })
	end
	return M.EXIT_ACCESS
end

return M
