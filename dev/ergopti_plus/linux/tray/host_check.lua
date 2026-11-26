--- tray/host_check.lua

--- ==============================================================================
--- MODULE: Tray Host Check (Linux)
--- DESCRIPTION:
--- Tells the user, in their language, when nothing on their desktop shows the
--- tray icon, and what to install.
---
--- FEATURES & RATIONALE:
--- 1. Windows and macOS always show their icon. On Linux an icon needs a host:
---    a panel that reads StatusNotifierItems through org.kde.StatusNotifierWatcher,
---    or an XEmbed system tray. GNOME has neither without its AppIndicator
---    extension, and the daemon used to log « Tray icon created » there while
---    the user had no icon, no menu and no word of why (TRAY-03).
--- 2. Checked once, [ui] tray_host_check_delay_ms after the icon is created: a
---    login starts the daemon and the panel together, and the extension
---    registers its watcher only once the shell has loaded.
--- 3. Said three ways, because the one surface that would normally say it is
---    the missing one: the status window beside the icon, a notification and
---    the console; the log carries the facts the probe read.
--- 4. A probe that cannot read the session is an error in the log, not a « no
---    tray » message: telling a user whose tray works that it is missing would
---    be a false alarm.
--- ==============================================================================

local M = {}

local LOG = "tray.host_check"




-- =====================================
-- =====================================
-- ======= 1/ Decision =================
-- =====================================
-- =====================================

--- Whether the facts a probe read describe a session that shows tray icons.
--- @param facts table { watcher, host, xembed } from status_notifier_host.probe().
--- @return boolean
function M.has_host(facts)
	if facts.watcher == true and facts.host ~= false then return true end
	return facts.xembed == true
end




-- =====================================
-- =====================================
-- ======= 2/ Check ====================
-- =====================================
-- =====================================

--- The package that carries the GNOME Shell extension hosting
--- StatusNotifierItems, per distribution family (install.sh's gnome-tray).
--- openSUSE, Alpine and Void package none (their indexes, 2026-11-25): naming
--- a package there sent the user to a `zypper install` that finds nothing.
M.EXTENSION_PACKAGES = {
	arch = "gnome-shell-extension-appindicator",
	debian = "gnome-shell-extension-appindicator",
	fedora = "gnome-shell-extension-appindicator",
}

--- Where the extension is installed from on a family that packages none; the
--- same page install.sh names.
M.EXTENSION_PAGE = "https://extensions.gnome.org/extension/615/appindicator-support/"

--- What {1} names on this distribution: its package, or the extension's page.
--- @param os_release string|nil /etc/os-release's content.
--- @return string
function M.extension_source(os_release)
	local family = require("core.ui.engine.gui_stack").distro_family(os_release)
	return M.EXTENSION_PACKAGES[family] or M.EXTENSION_PAGE
end

--- Reads /etc/os-release, nil when neither copy can be read.
--- @return string|nil
local function read_os_release()
	local handle = io.open("/etc/os-release", "r") or io.open("/usr/lib/os-release", "r")
	if not handle then return nil end
	local content = handle:read("*a")
	handle:close()
	return content
end

--- A translated text with {1} filled by where the extension comes from; the
--- product name stays the same in every language.
--- @param i18n table
--- @param key string
--- @param source string M.extension_source's answer.
--- @return string
local function text(i18n, key, source)
	local value = i18n.get(key)
	return (value:gsub("{1}", function() return source end))
end

--- Runs the check and tells the user when no host shows the icon.
--- @param deps table { probe, i18n, logger, tray?, notifier?, print?, os_release? }:
---   probe is status_notifier_host.probe; tray the TrayMenu adapter (its status
---   window); os_release the file's content, read from disk when absent.
--- @return boolean|nil true with a host, false when the user was told there is
---   none, nil when the session could not be read.
function M.check(deps)
	local Logger = deps.logger
	local facts, reason = deps.probe()
	if not facts then
		Logger.error(LOG, "Tray host check could not read the session (%s); the icon may not be visible.",
			tostring(reason))
		return nil
	end
	local summary = string.format("watcher %s, host %s, XEmbed tray %s", tostring(facts.watcher),
		tostring(facts.host), tostring(facts.xembed))
	if M.has_host(facts) then
		Logger.info(LOG, "Tray host present (%s).", summary)
		return true
	end
	Logger.error(LOG, "No tray host (%s): the icon and its menu are not visible; telling the user.", summary)
	local source = M.extension_source(deps.os_release or read_os_release())
	local title = text(deps.i18n, "startup.linux_tray_host_missing_title", source)
	local body = text(deps.i18n, "startup.linux_tray_host_missing_body", source)
	local out = deps.print or print
	out(title)
	out(body)
	if deps.notifier and type(deps.notifier.send) == "function" then
		local sent, err = pcall(deps.notifier.send, body, { title = title, level = "warning" })
		if not sent then Logger.error(LOG, "The no-tray-host notification failed: %s.", tostring(err)) end
	end
	if deps.tray and deps.tray.showStatusWindow(title, body) ~= true then
		Logger.error(LOG, "The no-tray-host window could not be shown.")
	end
	return false
end

--- Schedules the check once the panel has had time to register its host.
--- @param deps table M.check's deps, plus after(seconds, fn) -> boolean armed and timings.
--- @return boolean armed
function M.schedule(deps)
	local delay = deps.timings.ms("ui", "tray_host_check_delay_ms") / 1000
	local armed = deps.after(delay, function() M.check(deps) end)
	if armed ~= true then
		deps.logger.error(LOG, "Tray host check could not be scheduled; a missing tray host would go unsaid.")
	end
	return armed == true
end

return M
