--- ui/bundled_apps.lua

--- ==============================================================================
--- MODULE: Bundled Apps Launcher (Linux)
--- DESCRIPTION:
--- The rows of the tray's Applications submenu (ui/menu/menu_apps.lua): the
--- bundled App Cloner and Encryptor,
--- the same two apps macOS ships as bundles next to its driver. Each row starts
--- its app as a separate process (apps/*.lua) run by the daemon's own
--- interpreter, with the active locale and the shared locales folder, as
--- macOS's menu_apps.lua hands them to its bundles.
---
--- FEATURES & RATIONALE:
--- 1. A separate process: the apps wait on dialogs and on a half-second key
---    derivation, which inside the daemon would stall the keyboard.
--- 2. Opening Encryptor also writes its desktop entry, the Linux drop target:
---    files dropped on it, or opened with it from the file manager, reach the
---    same program. The entry is rewritten at each opening, because the
---    interpreter and module paths it records move with an update (an AppImage
---    mounts at a new path on every run).
--- 3. One environment for both starts (app_environment): the tray's child and
---    the desktop entry's launcher get the daemon's module paths and private
---    runtime, which the daemon holds in package.path, not in its environment.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local TextUtils = require("text_utils")
local NativePath = require("native_path")

local LOG = "ui.bundled_apps"

local quote = TextUtils.shell_quote

--- The bundled apps, in the order macOS lists its bundles (alphabetical).
M.APPS = {
	{ name = "App Cloner", script = "apps/app_cloner.lua", description_key = "menu.apps.clone_desc" },
	{ name = "Encryptor", script = "apps/encryptor.lua", description_key = "menu.apps.encrypt_desc",
		desktop_entry = "ergopti-encryptor" },
}

-- The live child handles, pinned until their exit callback closes them.
M._children = {}

local DEFAULT_DEPS = {
	exepath = function() return require("luv").exepath() end,
	driver_root = function() return require("infra.paths").driver_root() end,
	locales_dir = function() return require("infra.paths").shared("data/locales") end,
	locale = function() return require("infra.i18n").get_locale() end,
	text = function(key) return require("infra.i18n").get(key) end,
	getenv = os.getenv,
	data_home = function() return require("infra.config_paths").data_home() end,
	-- `environment` overrides the daemon's own variables of the same name.
	spawn = function(executable, args, environment, on_exit)
		local uv = require("luv")
		local merged, env = {}, {}
		for name, value in pairs(uv.os_environ()) do merged[name] = value end
		for _, pair in ipairs(environment) do merged[pair[1]] = pair[2] end
		for name, value in pairs(merged) do env[#env + 1] = name .. "=" .. value end
		local handle
		handle = uv.spawn(executable, { args = args, env = env, detached = true, stdio = { nil, nil, nil } }, function(code)
			M._children[handle] = nil
			if handle and not handle:is_closing() then handle:close() end
			on_exit(code)
		end)
		if not handle then return false end
		M._children[handle] = true
		uv.unref(handle)
		return true
	end,
	write_file = function(path, text)
		local folder = NativePath.dirname(path)
		local status = os.execute("mkdir -p " .. quote(folder))
		if not (status == true or status == 0) then return false end
		local file = io.open(path, "wb")
		if not file then return false end
		file:write(text)
		file:close()
		return true
	end,
}




-- ======================================
-- ======================================
-- ======= 1/ Launch ====================
-- ======================================
-- ======================================

--- The app's command-line words after the interpreter.
--- @param app table One of M.APPS.
--- @param deps table
--- @return table|nil words
local function app_words(app, deps)
	local root, locales = deps.driver_root(), deps.locales_dir()
	if type(root) ~= "string" or type(locales) ~= "string" then return nil end
	local words = { root .. "/" .. app.script, "--locales-dir", locales }
	local locale = deps.locale()
	if type(locale) == "string" and locale ~= "" then
		words[#words + 1] = "--locale"
		words[#words + 1] = locale
	end
	return words
end

--- The environment an app needs beyond the daemon's own: the daemon's module
--- paths and private runtime, as ordered { name, value } pairs. The daemon
--- sets its package.path itself (ergopti_hotstrings.lua) and exports no
--- LUA_PATH, so an app started without these could not load one module of
--- its own (tests/desktop/run_encryptor.sh).
--- @param deps table
--- @return table pairs
function M.app_environment(deps)
	local pairs_list = { { "LUA_PATH", package.path }, { "LUA_CPATH", package.cpath } }
	for _, name in ipairs({ "ERGOPTI_RUNTIME_PREFIX", "ERGOPTI_LITERAL_DRIVER_ROOT", "ERGOPTI_LITERAL_SHARED_ROOT",
		"ERGOPTI_LITERAL_DIRECT", "ERGOPTI_LITERAL_NATIVE_MODULES" }) do
		local value = deps.getenv(name)
		if value and value ~= "" then pairs_list[#pairs_list + 1] = { name, value } end
	end
	return pairs_list
end

--- The sh launcher a desktop entry runs: the daemon's interpreter, module
--- paths and private runtime, then the app with the files it is given.
--- @param executable string
--- @param words table From app_words.
--- @param deps table
--- @return string text
function M.launcher_text(executable, words, deps)
	local lines = { "#!/bin/sh", "# Ergopti bundled app launcher, rewritten each time the tray opens the app." }
	for _, pair in ipairs(M.app_environment(deps)) do
		lines[#lines + 1] = "export " .. pair[1] .. "=" .. quote(pair[2])
	end
	local exec = "exec " .. quote(executable)
	for _, word in ipairs(words) do exec = exec .. " " .. quote(word) end
	lines[#lines + 1] = exec .. ' -- "$@"'
	return table.concat(lines, "\n") .. "\n"
end

--- Writes an app's desktop entry and its launcher.
--- @return boolean ok
local function install_desktop_entry(app, executable, words, deps)
	local Core = require("apps.app_cloner_core")
	local data_home = deps.data_home()
	local launcher = data_home .. "/ergopti/apps/" .. app.desktop_entry .. ".sh"
	local entry = table.concat({
		"[Desktop Entry]",
		"Type=Application",
		"Name=" .. Core.desktop_value(app.name),
		"Comment=" .. Core.desktop_value(deps.text(app.description_key)),
		"Exec=" .. Core.desktop_exec_word("/bin/sh") .. " " .. Core.desktop_exec_word(launcher) .. " %F",
		"Icon=dialog-password",
		"MimeType=application/octet-stream;",
		"Terminal=false",
		"X-Ergopti-Bundled-App=true",
	}, "\n") .. "\n"
	return deps.write_file(launcher, M.launcher_text(executable, words, deps))
		and deps.write_file(data_home .. "/applications/" .. app.desktop_entry .. ".desktop", entry)
end

--- Starts one bundled app.
--- @param app table One of M.APPS.
--- @param deps table|nil Test seam.
--- @return boolean started
function M.launch(app, deps)
	deps = deps or DEFAULT_DEPS
	local executable = deps.exepath()
	local words = app_words(app, deps)
	if type(executable) ~= "string" or executable:sub(1, 1) ~= "/" or not words then
		Logger.error(LOG, "Cannot locate the interpreter or the app '%s'.", app.name)
		return false
	end
	if app.desktop_entry and not install_desktop_entry(app, executable, words, deps) then
		-- The app still opens from the tray; only the drop target is missing.
		Logger.warn(LOG, "The desktop entry of '%s' could not be written.", app.name)
	end
	Logger.start(LOG, "Opening bundled app '%s'…", app.name)
	local started = deps.spawn(executable, words, M.app_environment(deps), function(code)
		if code ~= 0 then Logger.error(LOG, "Bundled app '%s' exited %s.", app.name, tostring(code)) end
	end)
	if not started then
		Logger.error(LOG, "Bundled app '%s' could not start.", app.name)
		return false
	end
	Logger.success(LOG, "Bundled app '%s' opened.", app.name)
	return true
end




-- ======================================
-- ======================================
-- ======= 2/ Submenu ===================
-- ======================================
-- ======================================

--- The provider rows: one per bundled app, labelled as on macOS.
--- @param deps table|nil
--- @return table rows
function M.rows(deps)
	deps = deps or DEFAULT_DEPS
	local rows = {}
	for _, app in ipairs(M.APPS) do
		rows[#rows + 1] = {
			label = app.name .. " — " .. deps.text(app.description_key),
			action = function() return M.launch(app, deps) end,
		}
	end
	return rows
end

return M
