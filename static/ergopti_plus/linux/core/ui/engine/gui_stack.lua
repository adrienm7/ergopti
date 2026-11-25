--- core/ui/engine/gui_stack.lua

--- ==============================================================================
--- MODULE: Desktop Toolkit Start Check (Linux)
--- DESCRIPTION:
--- GTK 3, libayatana-appindicator3 and WebKitGTK 4.1 are system libraries the
--- package formats cannot carry: they must match the host's GLib, GL and C
--- library. The owned-runtimes registry decides them as SYS: checked at start,
--- refused in words. lgi is the private runtime's (PIN) in every package and
--- the host's only in a source install. This module is that check and that
--- refusal.
---
--- FEATURES & RATIONALE:
--- 1. The tray needs GTK 3 and libayatana-appindicator3. Without either there
---    is no icon and no menu, so the daemon refused nothing and ran invisibly:
---    the user saw an app that never started. With --tray it now refuses to
---    start, names the library, and exits EX_UNAVAILABLE so the unit does not
---    restart it every three seconds.
--- 2. The windows (settings, metrics, editors) need lgi and WebKitGTK 4.1.
---    Hotstrings and the tray work without them, so a missing one is told once
---    at start and the daemon continues; the windows stay closed.
--- 3. WebKitGTK 4.1 is required by version, not by namespace: lgi.WebKit2
---    resolves whatever version is installed, and 4.0 links libsoup 2, which
---    the windows were never built for.
--- 4. The words come from the shared catalogue in the user's language; the
---    component names are product names and stay as they are.
--- ==============================================================================

local M = {}

local LOG = "core.ui.engine.gui_stack"

--- sysexits.h EX_UNAVAILABLE, as the AppImage C library preflight uses.
M.EXIT_UNAVAILABLE = 69

--- The WebKitGTK namespace and version every window is built for.
M.WEBKIT_NAMESPACE = "WebKit2"
M.WEBKIT_VERSION = "4.1"

--- The component names a refusal shows.
M.LGI_COMPONENT = "lgi (Lua GObject Introspection)"
M.WEBKIT_COMPONENT = "WebKitGTK " .. M.WEBKIT_VERSION

M.TITLE_KEY = "startup.linux_gui_stack_title"
M.TRAY_BODY_KEY = "startup.linux_gui_stack_tray_body"
M.WINDOWS_BODY_KEY = "startup.linux_gui_stack_windows_body"

--- The host package that provides each component for LuaJIT, per distribution
--- family. The generic lua-lgi is a Lua 5.4 build on Arch, Fedora and openSUSE:
--- a user who installed it after the generic sentence still had no windows
--- (field report, Arch Linux, 2026-11-25). The first candidate of install.sh's
--- _lua_module_candidates and _desktop_backend_package for the same manager;
--- tests/unit/core/lifecycle/test_gui_stack.lua holds the two to each other.
M.HOST_PACKAGES = {
	lgi = {
		arch = "lua51-lgi", debian = "lua-lgi", fedora = "lua-lgi-compat",
		suse = "luajit-lgi", alpine = "lua5.1-lgi", void = "lua51-lgi",
	},
	webkit = {
		arch = "webkit2gtk-4.1", debian = "gir1.2-webkit2-4.1", fedora = "webkit2gtk4.1",
		suse = "typelib-1_0-WebKit2-4_1", alpine = "webkit2gtk-4.1", void = "libwebkit2gtk41",
	},
}

--- A release that names a component differently from its family, by
--- /etc/os-release ID. Leap 15.6 carries lua51-lgi and no luajit-lgi
--- (checked against its index on 2026-11-25): naming the Tumbleweed package
--- sent a Leap user to a `zypper install` that found nothing. install.sh's
--- zypper candidates already try both.
M.RELEASE_PACKAGES = {
	lgi = { ["opensuse-leap"] = "lua51-lgi" },
}

--- The package manager of each family, as install.sh names it.
M.FAMILY_MANAGERS = { arch = "pacman", debian = "apt", fedora = "dnf", suse = "zypper", alpine = "apk", void = "xbps" }

--- The command line a user types to install one package.
local INSTALL_COMMANDS = {
	arch = "sudo pacman -S --needed %s", debian = "sudo apt install %s", fedora = "sudo dnf install %s",
	suse = "sudo zypper install %s", alpine = "sudo apk add %s", void = "sudo xbps-install %s",
}

--- /etc/os-release ID and ID_LIKE tokens, mapped to a family.
local FAMILY_OF_ID = {
	arch = "arch", debian = "debian", ubuntu = "debian", fedora = "fedora", rhel = "fedora", centos = "fedora",
	suse = "suse", opensuse = "suse", ["opensuse-leap"] = "suse", ["opensuse-tumbleweed"] = "suse", sles = "suse",
	alpine = "alpine", void = "void",
}

--- The Lua versions other than LuaJIT's 5.1 an lgi package may be built for,
--- and the module directories distributions install them in.
local OTHER_LUA_VERSIONS = { "5.4", "5.3", "5.2", "5.5" }
local LUA_MODULE_ROOTS = { "/usr/lib/lua", "/usr/lib64/lua", "/usr/lib/x86_64-linux-gnu/lua", "/usr/local/lib/lua" }




-- =====================================
-- =====================================
-- ======= 1/ Checks ===================
-- =====================================
-- =====================================

--- The library the tray cannot load.
--- @param indicator table platform.tray.appindicator or a test double.
--- @return string|nil The component name, nil when the tray can bind or the
---   only problem is a session without a display.
function M.tray_missing(indicator)
	if indicator.is_available() then return nil end
	return indicator.missing_component()
end

--- The library the windows cannot load.
--- @param load_lgi function|nil Returns ok, lgi like pcall(require, "lgi"); a test seam.
--- @return string|nil The component name, nil when WebKitGTK 4.1 loads.
--- @return string|nil "lgi" or "webkit", the key of M.HOST_PACKAGES.
function M.windows_missing(load_lgi)
	local ok, lgi = (load_lgi or function() return pcall(require, "lgi") end)()
	if not ok or type(lgi) ~= "table" or type(lgi.require) ~= "function" then return M.LGI_COMPONENT, "lgi" end
	local loaded, namespace = pcall(lgi.require, M.WEBKIT_NAMESPACE, M.WEBKIT_VERSION)
	if not loaded or namespace == nil then return M.WEBKIT_COMPONENT, "webkit" end
	return nil
end

--- The distribution family /etc/os-release describes.
--- @param text string|nil The file's content.
--- @return string|nil A key of M.FAMILY_MANAGERS, nil when unknown.
function M.distro_family(text)
	if type(text) ~= "string" then return nil end
	local fields = {}
	for key, value in text:gmatch("([%w_]+)=([^\n]*)") do
		fields[key] = value:gsub('^["\']', ""):gsub('["\']$', ""):lower()
	end
	local tokens = { fields.ID }
	for token in (fields.ID_LIKE or ""):gmatch("%S+") do tokens[#tokens + 1] = token end
	for _, token in ipairs(tokens) do
		local family = FAMILY_OF_ID[token]
		if family then return family end
	end
	return nil
end

--- The Lua version an lgi on this system was built for, when it is not 5.1.
--- @param exists function|nil Returns whether a path is a file; a test seam.
--- @return string|nil "5.4" and the like, nil when no other build is present.
function M.foreign_lgi(exists)
	exists = exists or function(path)
		local handle = io.open(path, "rb")
		if handle then handle:close() return true end
		return false
	end
	for _, version in ipairs(OTHER_LUA_VERSIONS) do
		for _, root in ipairs(LUA_MODULE_ROOTS) do
			if exists(root .. "/" .. version .. "/lgi/corelgilua51.so") then return version end
		end
	end
	return nil
end

--- Reads /etc/os-release.
--- @return string|nil
local function read_os_release()
	local handle = io.open("/etc/os-release", "r") or io.open("/usr/lib/os-release", "r")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end




-- =====================================
-- =====================================
-- ======= 2/ Refusal ==================
-- =====================================
-- =====================================

--- A translated text with {1}, {2}, ... filled, or the key when the catalogue cannot answer.
--- @param i18n table|nil
--- @param key string
--- @param ... string The slot values.
--- @return string
local function text(i18n, key, ...)
	local value = key
	if i18n then
		local ok, translated = pcall(i18n.get, key)
		if ok and type(translated) == "string" then value = translated end
	end
	local slots = { ... }
	value = value:gsub("{(%d)}", function(index)
		local slot = slots[tonumber(index)]
		return slot ~= nil and slot or nil
	end)
	return value
end

--- The windows explanation: the exact package and command when the family is
--- known, and why an installed lgi does not count when it is another Lua's.
--- @param deps table { i18n, os_release, file_exists }
--- @param component string
--- @param what string "lgi" or "webkit"
--- @return string
function M.windows_body(deps, component, what)
	local os_release = deps.os_release ~= nil and deps.os_release or read_os_release()
	local family = M.distro_family(os_release)
	local release = type(os_release) == "string"
		and (os_release:match("%f[%w_]ID=[\"']?([^\"'\n]+)") or ""):lower() or ""
	local package = family and ((M.RELEASE_PACKAGES[what] or {})[release] or M.HOST_PACKAGES[what][family])
	local body
	if package then
		-- The windows body when the distribution is known: {2} the package, {3} the command
		body = text(deps.i18n, "startup.linux_gui_stack_windows_package_body", component, package, INSTALL_COMMANDS[family]:format(package))
	else
		body = text(deps.i18n, M.WINDOWS_BODY_KEY, component)
	end
	if what == "lgi" then
		local version = M.foreign_lgi(deps.file_exists)
		if version then
			-- lgi installed for another Lua: {1} its version, {2} the package
			body = body .. " " .. text(deps.i18n, "startup.linux_gui_stack_lgi_other_lua", version, package or M.HOST_PACKAGES.lgi.debian)
		end
	end
	return body
end

--- Runs the start check of a --tray launch.
--- @param deps table { i18n, notifier, print, load_lgi, logger, indicator, status,
---   os_release, file_exists }; indicator is platform.tray.appindicator and status
---   core.ui.engine.component_status unless a test supplies a double.
--- @return integer|nil The exit status when the daemon must not start, nil to continue.
function M.check_at_start(deps)
	local Logger = deps.logger or require("core.logger.engine.shim")
	local out = deps.print or print
	local tray = M.tray_missing(deps.indicator or require("tray.adapters.appindicator"))
	if tray then
		Logger.error(LOG, "Start refused: the tray needs %s, which this system does not provide.", tray)
		local title, body = text(deps.i18n, M.TITLE_KEY), text(deps.i18n, M.TRAY_BODY_KEY, tray)
		out(title)
		out(body)
		-- The daemon exits: the notice is the only surface left, so it stays.
		if deps.notifier and type(deps.notifier.send) == "function" then
			pcall(deps.notifier.send, body, { title = title, level = "error", persistent = true })
		end
		return M.EXIT_UNAVAILABLE
	end
	local windows, what = M.windows_missing(deps.load_lgi)
	if windows then
		Logger.warn(LOG, "Windows unavailable: they need %s, which this system does not provide.", windows)
		local title, body = text(deps.i18n, M.TITLE_KEY), M.windows_body(deps, windows, what)
		out(title)
		out(body)
		local status = deps.status or require("core.ui.engine.component_status")
		status.report({ code = "windows_" .. what, label = text(deps.i18n, "startup.linux_gui_stack_windows_label"),
			title = title, body = body }, { notifier = deps.notifier })
		return nil
	end
	Logger.debug(LOG, "Desktop toolkit present: GTK 3, libayatana-appindicator3, lgi and %s.", M.WEBKIT_COMPONENT)
	return nil
end

return M
