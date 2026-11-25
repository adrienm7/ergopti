--- ui/layout_manager/tray_actions.lua

--- ==============================================================================
--- MODULE: Layout Manager Tray Actions (Linux)
--- DESCRIPTION:
--- The layout manager's essential actions without its window: install and
--- activate the Ergopti layout, activate it, uninstall it. The tray's Layout
--- menu draws them (menu.toml layout_user_install), and the layout manager's
--- bridge offers them when its window cannot open (on_window_unavailable).
---
--- FEATURES & RATIONALE:
--- 1. The layout manager is core, but its window needs lgi and WebKitGTK 4.1,
---    which a system can lack: the AppImage refused it with a raw « native
---    window acquisition refused » (maintainer decision, 2026-11-25). Every
---    action here runs the layout manager's own registry operations
---    (modules/keymap/layout_registry.lua): nothing installs XKB another way.
--- 2. Each step's result is said in plain translated words: a notice on
---    success; on failure a persistent notice and a red tray row
---    (core/ui/engine/component_status.lua) that leaves once the step's goal
---    holds, as the window's result line would have said it.
--- 3. After an install or an uninstall the daemon reloads a layout that ships
---    hotstrings and the emulation follows a changed emulated layout, exactly
---    as the window's controller does (_shared/layouts/engine/manager_bridge.lua).
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")

local LOG = "ui.layout_manager.tray_actions"

-- The registry failure codes with their own explanation, the page's
-- FAILURE_KEYS (_shared/ui/layout_manager/script.js) plus the Xorg refusal the
-- Linux registry explains (layout_registry user_message); any other code reads
-- as the generic failure, its detail in the log.
M.FAILURE_KEYS = {
	busy = "layout_manager.failure_busy",
	provided_by_bundle = "layout_manager.failure_provided_by_bundle",
	foreign_file = "layout_manager.failure_foreign_file",
	download_failed = "layout_manager.failure_download",
	python_missing = "layouts.linux_needs_python",
	session_unsupported = "layout_manager.failure_session_unsupported",
	xorg_session = "layouts.linux_xorg_session",
}

-- The texts of each step: its success notice, its failure notice and the red
-- tray row a failure leaves.
local STEPS = {
	install = {
		done = "layouts.linux_ergopti_installed_active",
		failed = "layouts.linux_ergopti_install_failed",
		label = "layouts.linux_ergopti_install_failed_label",
	},
	activate = {
		done = "layouts.linux_ergopti_activated",
		failed = "layouts.linux_ergopti_activate_failed",
		label = "layouts.linux_ergopti_activate_failed_label",
	},
	uninstall = {
		done = "layouts.linux_ergopti_uninstalled",
		failed = "layouts.linux_ergopti_uninstall_failed",
		label = "layouts.linux_ergopti_uninstall_failed_label",
	},
}





-- =====================================
-- =====================================
-- ======= 1/ Dependencies =============
-- =====================================
-- =====================================

-- Collaborators a test supplies in place of the daemon's.
local _test_deps = nil

--- Replaces the collaborators; tests only (nil restores the daemon's).
--- @param deps table|nil { registry, i18n, notifier, status, ask, daemon_state, emulation, layout_id }
function M._set_deps_for_test(deps)
	_test_deps = deps
end

--- The registry layout these actions install, from the shared layout defaults.
--- @return string
local function default_layout_id()
	local Json = require("core.text.engine.json")
	local path = require("core.fs.engine.paths").shared("layouts/data/defaults.json")
	local raw = type(path) == "string" and require("core.fs.adapters.file_system").read(path) or nil
	local ok, doc = pcall(Json.decode, raw or "")
	local id = ok and type(doc) == "table" and type(doc.registry) == "table" and doc.registry.ergopti_layout_id or nil
	if type(id) ~= "string" or id == "" then
		error("_shared/layouts/data/defaults.json declares no registry.ergopti_layout_id", 0)
	end
	return id
end

--- The collaborators: a test's, or the daemon's modules.
--- @return table
local function resolve()
	if _test_deps then return _test_deps end
	return {
		registry = require("modules.keymap.layout_registry"),
		i18n = require("core.i18n.engine.i18n"),
		notifier = require("platform.system.notifier"),
		status = require("core.ui.engine.component_status"),
		ask = require("menu.ui.builder.dialogs").ask_yes_no,
		daemon_state = require("core.ui.ui.webview_manager").get_daemon_state(),
		emulation = require("modules.keymap.layout_emulation"),
		layout_id = default_layout_id(),
	}
end

--- A translated text, or its key when the catalogue cannot answer.
--- @param deps table
--- @param key string
--- @return string
local function t(deps, key)
	local ok, text = pcall(deps.i18n.get, key)
	return ok and type(text) == "string" and text or key
end

--- A translated text with its {n} placeholders filled.
--- @param deps table
--- @param key string
--- @param ... string Values for {1}, {2}...
--- @return string
local function fill(deps, key, ...)
	local text, values = t(deps, key), { ... }
	return (text:gsub("{(%d)}", function(index) return values[tonumber(index)] end))
end





-- =====================================
-- =====================================
-- ======= 2/ State ====================
-- =====================================
-- =====================================

--- Where the Ergopti layout stands: busy, unreadable and installed are the
--- status_rows of menu.toml's layout_user_install, not_installed draws its
--- install command.
--- @param deps table|nil
--- @return string state busy, unreadable, installed or not_installed.
--- @return table snapshot The registry snapshot it was read from.
function M.state(deps)
	deps = deps or resolve()
	local snapshot = deps.registry.snapshot()
	if snapshot.busy then return "busy", snapshot end
	if snapshot.record_error ~= nil then return "unreadable", snapshot end
	if (snapshot.installed or {})[deps.layout_id] then return "installed", snapshot end
	return "not_installed", snapshot
end

--- Whether the Ergopti layout is installed now; a failing read keeps a problem.
--- @param deps table
--- @return boolean|nil
local function installed_now(deps)
	local ok, snapshot = pcall(deps.registry.snapshot)
	if not ok or type(snapshot) ~= "table" then return nil end
	return (snapshot.installed or {})[deps.layout_id] ~= nil
end

-- What each step's red row needs to hold to stay: the goal it failed is still unmet.
local STILL_FAILED = {
	install = function(deps) return installed_now(deps) ~= true end,
	activate = function(deps)
		local ok, snapshot = pcall(deps.registry.snapshot)
		return not (ok and type(snapshot) == "table" and snapshot.active == deps.layout_id)
	end,
	uninstall = function(deps) return installed_now(deps) ~= false end,
}





-- =====================================
-- =====================================
-- ======= 3/ Outcomes =================
-- =====================================
-- =====================================

--- Rebuilds the tray, whose rows follow the registry state.
--- @param deps table
local function tray_changed(deps)
	local state = deps.daemon_state
	if type(state) == "table" and type(state.on_config_changed) == "function" then
		local ok, err = pcall(state.on_config_changed)
		if not ok then Logger.error(LOG, "The tray could not be rebuilt after a layout step: %s.", tostring(err)) end
	end
end

--- Says a step's success.
--- @param deps table
--- @param step string install, activate or uninstall.
local function say_done(deps, step)
	Logger.success(LOG, "Ergopti layout %s step done from the tray.", step)
	local ok, err = pcall(deps.notifier.send, t(deps, STEPS[step].done),
		{ title = t(deps, "layouts.linux_ergopti_title"), level = "success" })
	if not ok then Logger.error(LOG, "The %s success notice could not be posted: %s.", step, tostring(err)) end
end

--- Says a step's failure: a persistent notice and a red tray row.
--- @param deps table
--- @param step string install, activate or uninstall.
--- @param code any The registry failure code.
--- @param detail any The registry's technical detail, for the log.
local function say_failed(deps, step, code, detail)
	Logger.error(LOG, "Ergopti layout %s step failed from the tray (%s): %s.", step, tostring(code), tostring(detail))
	local reason = t(deps, M.FAILURE_KEYS[tostring(code)] or "layout_manager.failure_other")
	local title, body = t(deps, "layouts.linux_ergopti_title"), fill(deps, STEPS[step].failed, reason)
	local recorded = deps.status.report({
		code = "ergopti_layout_" .. step .. "_failed",
		label = t(deps, STEPS[step].label),
		title = title,
		body = body,
		active = function() return STILL_FAILED[step](deps) end,
	}, { notifier = deps.notifier })
	-- A problem is reported once per daemon: a repeated failure still says itself.
	if not recorded then
		local ok, err = pcall(deps.notifier.send, body, { title = title, level = "error", persistent = true })
		if not ok then Logger.error(LOG, "The %s failure notice could not be posted: %s.", step, tostring(err)) end
	end
end

--- Reloads what an installed or removed layout changes, as the window does:
--- a layout shipping hotstrings through a daemon reload, else the emulation
--- when it is the emulated layout.
--- @param deps table
--- @param extension boolean Whether the layout carries a hotstring extension.
local function layout_changed(deps, extension)
	local state = deps.daemon_state
	if extension then
		if type(state) ~= "table" or type(state.on_reload) ~= "function" then
			Logger.error(LOG, "The Ergopti layout's extension changed but the daemon cannot reload.")
			return
		end
		local ok, accepted = pcall(state.on_reload)
		if not ok or accepted ~= true then
			Logger.error(LOG, "The reload after the Ergopti layout changed was refused: %s.", tostring(accepted))
		end
		return
	end
	local emulation = deps.emulation
	local ok, status = pcall(emulation.status)
	if ok and type(status) == "table" and status.id == deps.layout_id then emulation.reload_if_started() end
end





-- =====================================
-- =====================================
-- ======= 4/ Actions ==================
-- =====================================
-- =====================================

--- Activates the installed Ergopti layout.
--- @param deps table|nil
--- @return boolean dispatched
function M.activate(deps)
	deps = deps or resolve()
	Logger.start(LOG, "Activating the Ergopti layout from the tray…")
	return deps.registry.select(deps.layout_id, function(ok, code, detail)
		if ok then say_done(deps, "activate") else say_failed(deps, "activate", code, detail) end
		tray_changed(deps)
	end) == true
end

--- Installs the Ergopti layout, then activates it.
--- @param deps table|nil
--- @return boolean dispatched
function M.install_and_activate(deps)
	deps = deps or resolve()
	local id = deps.layout_id
	local extension = require("layouts.engine.manager_bridge").carries_extension(deps.registry.snapshot(), id)
	Logger.start(LOG, "Installing the Ergopti layout from the tray…")
	local dispatched = deps.registry.install(id, function(ok, code, detail)
		if not ok then
			say_failed(deps, "install", code, detail)
			tray_changed(deps)
			return
		end
		deps.registry.select(id, function(selected, select_code, select_detail)
			if selected then say_done(deps, "install") else say_failed(deps, "activate", select_code, select_detail) end
			tray_changed(deps)
			-- Installed either way: its hotstrings or the emulation follow it.
			layout_changed(deps, extension)
		end)
	end)
	-- The busy row shows the step in flight.
	if dispatched then tray_changed(deps) end
	return dispatched == true
end

--- Uninstalls the Ergopti layout.
--- @param deps table|nil
--- @return boolean dispatched
function M.uninstall(deps)
	deps = deps or resolve()
	local extension = require("layouts.engine.manager_bridge").carries_extension(deps.registry.snapshot(), deps.layout_id)
	Logger.start(LOG, "Uninstalling the Ergopti layout from the tray…")
	local dispatched = deps.registry.uninstall(deps.layout_id, function(ok, code, detail)
		if ok then say_done(deps, "uninstall") else say_failed(deps, "uninstall", code, detail) end
		tray_changed(deps)
		if ok then layout_changed(deps, extension) end
	end)
	if dispatched then tray_changed(deps) end
	return dispatched == true
end





-- =====================================
-- =====================================
-- ======= 5/ Tray rows ================
-- =====================================
-- =====================================

--- The Layout menu's Ergopti rows (menu.toml layout_user_install).
--- @param deps table|nil
--- @return table rows
function M.rows(deps)
	deps = deps or resolve()
	local ManifestMenu = require("menu.engine.manifest_menu")
	local COMMAND = require("settings.engine.keys").COMMAND
	local state = M.state(deps)
	if state == "busy" or state == "unreadable" then
		return ManifestMenu.status_rows("layout_menu", "layout_user_install", state) or {}
	end
	if state == "not_installed" then
		return ManifestMenu.template_rows("layout_user_install_commands", {
			[COMMAND.USER_LAYOUT_INSTALL] = function() return M.install_and_activate(deps) end,
		}, {}, {}) or {}
	end
	local rows = {}
	for _, row in ipairs(ManifestMenu.status_rows("layout_menu", "layout_user_install", "installed") or {}) do
		rows[#rows + 1] = row
	end
	for _, row in ipairs(ManifestMenu.template_rows("layout_user_installed_commands", {
		[COMMAND.USER_LAYOUT_ACTIVATE] = function() return M.activate(deps) end,
		[COMMAND.USER_LAYOUT_UNINSTALL] = function() return M.uninstall(deps) end,
	}, {}, {}) or {}) do
		rows[#rows + 1] = row
	end
	return rows
end





-- =====================================
-- =====================================
-- ======= 6/ Without the window =======
-- =====================================
-- =====================================

--- Offers the layout manager's essential action when its window cannot open:
--- install and activate Ergopti, or activate the installed one, in a native
--- question; without a dialog, or while a step runs, a notice points to the
--- tray rows. The user always learns what they can do.
--- @param info table { app_name, component, locale, detail } from the webview manager.
--- @param deps table|nil
--- @return boolean delivered Always true: the user received an offer or a notice.
function M.offer_without_window(info, deps)
	deps = deps or resolve()
	info = type(info) == "table" and info or {}
	local state = M.state(deps)
	Logger.warn(LOG, "The layout manager window is unavailable (%s); offering its actions without it (%s).",
		tostring(info.component or info.detail), state)
	local title = t(deps, "layouts.linux_ergopti_title")
	local menu_title = t(deps, "menu.layout.title")
	local answer
	if state == "not_installed" then
		answer = deps.ask(title, fill(deps, "layouts.linux_manager_offer_install", menu_title),
			t(deps, "menu.layout.user_layout_install"), t(deps, "common.cancel"))
		if answer == true then M.install_and_activate(deps) end
	elseif state == "installed" then
		answer = deps.ask(title, fill(deps, "layouts.linux_manager_offer_activate", menu_title,
			t(deps, "menu.layout.user_layout_uninstall")), t(deps, "menu.layout.user_layout_activate"),
			t(deps, "common.cancel"))
		if answer == true then M.activate(deps) end
	end
	if answer == nil then
		-- No dialog could ask (or a step runs): the tray rows still can.
		local ok, err = pcall(deps.notifier.send, fill(deps, "layouts.linux_manager_use_tray", menu_title),
			{ title = title, level = "warning", persistent = true })
		if not ok then Logger.error(LOG, "The layout manager's tray notice could not be posted: %s.", tostring(err)) end
	elseif answer == false then
		Logger.info(LOG, "The window-less layout offer was declined.")
	end
	return true
end

return M
