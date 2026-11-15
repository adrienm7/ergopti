--- apps/app_cloner.lua
-- The application-owned child is invoked directly, without a global Lua init.
local literal_driver = os.getenv("ERGOPTI_LITERAL_DRIVER_ROOT")
if literal_driver and literal_driver ~= "" then
	local literal_shared = assert(os.getenv("ERGOPTI_LITERAL_SHARED_ROOT"), "literal shared root unavailable")
	assert(loadfile(literal_driver .. "/core/lifecycle/engine/literal_module_loader.lua"))().install(literal_driver, literal_shared, os.getenv("ERGOPTI_RUNTIME_PREFIX"), os.getenv("ERGOPTI_LITERAL_DIRECT") == "1" and "child-direct" or (os.getenv("ERGOPTI_LITERAL_DAEMON") == "1" and "daemon" or nil))
end


--- ==============================================================================
--- MODULE: App Cloner (Linux)
--- DESCRIPTION:
--- The Linux App Cloner program, opened from Applications > App Cloner in the
--- tray: asks for an installed application, the clone's name, an optional item
--- to open at launch and its icon, then writes the clone
--- (apps/app_cloner_core.lua). The steps and their wording follow the macOS
--- ShortcutBuilder.
---
--- Usage: app_cloner.lua --locales-dir DIR [--locale CODE]
--- ==============================================================================

local M = {}

--- The folders the system installs desktop entries into, searched in order.
M.SYSTEM_APPLICATIONS = "/usr/share/applications/"

--- Whether a command exits 0.
local function succeeded(command)
	-- Both os.execute ABIs (a LuaJIT number, or Lua 5.2 true/exit/code) read as one code.
	local code = require("core.ui.ui.native_dialog").exit_code(os.execute(command))
	return code == 0
end

--- The real filesystem ports of a clone run.
--- @return table ports
function M.native_ports()
	local quote = require("core.text.engine.utils_core").shell_quote
	local ConfigPaths = require("infra.config_paths")
	-- The real account home: a clone's profile and the shared VS Code settings
	-- live there, never in the temporary folder home() falls back to.
	local home = assert(ConfigPaths.account_home(), "the account has no home folder")
	local data_home = ConfigPaths.data_home()
	return {
		home = home,
		data_home = data_home,
		read = function(path)
			local file = io.open(path, "rb")
			if not file then return nil end
			local text = file:read("*a")
			file:close()
			return text
		end,
		exists = function(path) return succeeded("test -e " .. quote(path)) end,
		-- An Electron program's marker sits next to its real executable; a bare
		-- name is looked up on PATH and its links are followed first.
		has_marker = function(program, marker)
			local pipe = io.popen("p=$(command -v " .. quote(program) .. " 2>/dev/null) && readlink -f \"$p\"")
			local real = pipe and pipe:read("*l")
			if pipe then pipe:close() end
			if not real or real == "" then return false end
			local folder = require("core.fs.engine.native_path").dirname(real) or "/"
			return succeeded("test -e " .. quote(folder .. "/" .. marker))
		end,
		write = function(plan) return require("apps.app_cloner_core").write(plan) end,
	}
end

--- Validates the optional item to open, as the macOS builder's
--- validateOpenArg does (BAP-005): a path, absolute or under « ~ », must exist;
--- anything else must be a URL with « :// », or Teams' documented single-slash
--- forms. A typo such as « https:/x » or « localhost:3000 » is refused.
--- @param item string The trimmed answer.
--- @param exists function exists(path) -> boolean.
--- @param home string The account's home folder.
--- @return string|nil error_key
--- @return string|nil value Substituted into the message.
--- @return string item The item to open, « ~ » expanded (the launcher's exec
---   word is quoted, so no shell would expand it).
local function invalid_open_item(item, exists, home)
	if item == "" then return nil, nil, item end
	local path = item
	if item == "~" or item:sub(1, 2) == "~/" then path = home .. item:sub(2) end
	if path:sub(1, 1) == "/" then
		if exists(path) then return nil, nil, path end
		return "apps.cloner.err_path_missing", item, item
	end
	if item:find("://", 1, true) or item:match("^msteams:/l/") or item:match("^msteams:/calendar") then
		return nil, nil, item
	end
	return "apps.cloner.err_url_format", nil, item
end

--- Runs the clone dialogs and writes the clone.
--- @param ports table { dialogs, t, catalogue, home, data_home, read, exists, has_marker, write }
--- @return string outcome "created", "cancelled" or "failed"
function M.run(ports)
	local Core = require("apps.app_cloner_core")
	local dialogs, t = ports.dialogs, ports.t
	local title = t("apps.cloner.btn_clone")

	local source_path = dialogs.file(t("apps.cloner.msg_choose_source"),
		{ filename = M.SYSTEM_APPLICATIONS, filter = "*.desktop" })
	if not source_path then return "cancelled" end
	local text = ports.read(source_path)
	local source = text and Core.parse_desktop_entry(text) or {}
	if not source.Exec or source.Exec == "" then
		dialogs.message("error", t("apps.cloner.title_error"), t("apps.cloner.err_source_unreadable"))
		return "failed"
	end
	local source_name = source.Name or (source_path:match("([^/]+)%.desktop$") or source_path)

	local name
	repeat
		name = dialogs.entry(t("apps.cloner.title_clone_name"), t("apps.cloner.msg_clone_name_launcher"),
			{ initial = t("apps.cloner.default_clone_name", source_name), ok = t("apps.cloner.btn_validate"),
				cancel = t("button.cancel") })
		if name == nil then return "cancelled" end
		name = require("core.text.engine.utils_core").trim(name)
		if name == "" then
			dialogs.message("warning", t("apps.cloner.title_empty_input"), t("apps.cloner.err_open_empty"))
		end
	until name ~= ""

	local open_item
	while true do
		open_item = dialogs.entry(t("apps.cloner.title_open_arg"), t("apps.cloner.msg_open_optional_portable"),
			{ initial = "", ok = t("apps.cloner.btn_validate"), cancel = t("button.cancel") })
		if open_item == nil then return "cancelled" end
		open_item = require("core.text.engine.utils_core").trim(open_item)
		local key, value, resolved = invalid_open_item(open_item, ports.exists, ports.home)
		if not key then
			open_item = resolved
			break
		end
		dialogs.message("warning", t("apps.cloner.title_invalid_input"), t(key, value))
	end

	local icon = nil
	if not dialogs.question(t("apps.cloner.title_icon_style"), t("apps.cloner.msg_icon_style_portable"),
		t("apps.cloner.btn_original_icon"), t("apps.cloner.btn_custom_icon")) then
		icon = dialogs.file(t("apps.cloner.prompt_choose_icon"), { filename = ports.home .. "/" })
	end

	-- Each line is the locale's own label/value pattern (French spaces its colon).
	local summary = table.concat({
		t("common.label_value", t("apps.cloner.summary_source"), source_name),
		t("common.label_value", t("apps.cloner.summary_name"), name),
		t("common.label_value", t("apps.cloner.summary_url"), open_item ~= "" and open_item or "—"),
		t("common.label_value", t("apps.cloner.summary_icon"), icon or source.Icon or "—"),
	}, "\n")
	if not dialogs.question(t("apps.cloner.title_summary"), summary, t("apps.cloner.btn_clone"), t("button.cancel")) then
		return "cancelled"
	end

	local plan, reason = Core.plan({
		source = source, source_path = source_path, name = name, open_item = open_item, icon = icon,
		catalogue = ports.catalogue, data_home = ports.data_home, home = ports.home, has_marker = ports.has_marker,
		taken = function(id)
			return ports.exists(ports.data_home .. "/ergopti/" .. ports.catalogue.profile_folder .. "/" .. id)
				or ports.exists(ports.data_home .. "/applications/" .. ports.catalogue.window_class_prefix .. id .. ".desktop")
		end,
	})
	local ok = plan ~= nil
	if ok then ok, reason = ports.write(plan) end
	if not ok then
		dialogs.message("error", t("apps.cloner.title_error"), tostring(reason or t("apps.cloner.error_unknown")))
		return "failed"
	end
	dialogs.message("info", title, t("apps.cloner.msg_created", name, plan.profile))
	return "created", plan
end

--- Runs the program.
--- @param argv table
--- @return number status
function M.main(argv)
	local options, reason = require("apps.encryptor").parse_arguments(argv)
	if not options or #options.files > 0 then
		io.stderr:write("app_cloner.lua: ", reason or "App Cloner takes no file", "\n")
		return 64
	end
	local ports = M.native_ports()
	ports.dialogs = require("apps.dialogs").new()
	ports.t = require("apps.app_strings").load(options.locales_dir, options.locale)
	ports.catalogue = require("apps.app_cloner_core").load_families()
	M.run(ports)
	return 0
end

if type(arg) == "table" and type(arg[0]) == "string" and require("core.fs.engine.native_path").basename(arg[0]) == "app_cloner.lua" then
	local argv = {}
	for index = 1, #arg do argv[index] = arg[index] end
	os.exit(M.main(argv))
end

return M
