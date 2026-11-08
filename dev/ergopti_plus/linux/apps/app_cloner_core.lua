--- apps/app_cloner_core.lua

--- ==============================================================================
--- MODULE: App Cloner Core (Linux)
--- DESCRIPTION:
--- Builds an isolated copy of an installed application, the Linux counterpart
--- of the macOS App Cloner's stub bundle: a desktop entry of its own (name,
--- icon, window class) whose launcher starts the untouched source program with
--- a private profile folder.
---
--- FEATURES & RATIONALE:
--- 1. Nothing of the source is copied or patched, as on macOS: the launcher
---    passes the profile through the program's own options, chosen by its family
---    in _shared/data/app_cloner/families.json (Chromium and Electron
---    --user-data-dir, Firefox --profile, VS Code with the shared extensions).
--- 2. A program of no family gets separate XDG base directories instead
---    (configuration, data, cache, state), which every toolkit honours, so its
---    settings are still its own.
--- 3. The clone is a plain desktop entry and a POSIX sh launcher under the
---    user's data folder: it runs without Ergopti, and removing the two files
---    and the profile folder removes it.
--- 4. Pure where it can be: parsing, family detection and the generated texts
---    take their filesystem through ports, so the tests drive them directly.
--- ==============================================================================

local M = {}

local Json = require("json")
local NativePath = require("native_path")
local TextUtils = require("text_utils")

local quote = TextUtils.shell_quote




-- ======================================
-- ======================================
-- ======= 1/ Shared families ===========
-- ======================================
-- ======================================

--- Reads the shared family catalogue.
--- @param path string|nil Absolute path; the shared tree's by default.
--- @return table catalogue
function M.load_families(path)
	path = path or require("infra.paths").shared("data/app_cloner/families.json")
	assert(type(path) == "string", "the shared App Cloner families are unavailable")
	local file = assert(io.open(path, "rb"), "cannot read " .. path)
	local raw = file:read("*a")
	file:close()
	local catalogue = Json.decode(raw)
	assert(type(catalogue) == "table" and type(catalogue.families) == "table"
		and type(catalogue.detection_order) == "table", "the shared App Cloner families are malformed")
	return catalogue
end

--- The family name of a program, or "native".
--- @param catalogue table
--- @param program string Program path or name from the Exec line.
--- @param has_marker function|nil has_marker(program, marker) -> boolean.
--- @return string family
function M.family(catalogue, program, has_marker)
	local name = (NativePath.basename(program) or program):lower():gsub("%.exe$", "")
	for _, family in ipairs(catalogue.detection_order) do
		for _, executable in ipairs(catalogue.families[family].executables or {}) do
			if name == executable then return family end
		end
	end
	if has_marker then
		for _, family in ipairs(catalogue.detection_order) do
			for _, marker in ipairs(catalogue.families[family].markers or {}) do
				if has_marker(program, marker) then return family end
			end
		end
	end
	return "native"
end

--- The family's arguments for Linux with their placeholders filled.
--- @param catalogue table
--- @param family string
--- @param values table { profile, window_class, home }
--- @return table words
function M.family_arguments(catalogue, family, values)
	local words = {}
	local definition = catalogue.families[family]
	if not definition then return words end
	for _, argument in ipairs(definition.arguments or {}) do
		local wanted = argument.platforms == nil
		for _, platform in ipairs(argument.platforms or {}) do
			if platform == "linux" then wanted = true end
		end
		if wanted then
			words[#words + 1] = (argument.value:gsub("{([%a_]+)}", function(name)
				return assert(values[name], "no value for {" .. name .. "}")
			end))
		end
	end
	return words
end




-- ======================================
-- ======================================
-- ======= 2/ Desktop entries ===========
-- ======================================
-- ======================================

--- Decodes the string escapes of a desktop-entry value (\s \n \t \r \\).
local function unescape_value(value)
	return (value:gsub("\\(.)", function(c)
		return ({ s = " ", n = "\n", t = "\t", r = "\r", ["\\"] = "\\" })[c] or ("\\" .. c)
	end))
end

--- Reads the keys of a desktop entry's [Desktop Entry] group.
--- @param text string Desktop file contents.
--- @return table entry Unlocalised keys only.
function M.parse_desktop_entry(text)
	local entry, group = {}, nil
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		line = line:gsub("\r$", "")
		local header = line:match("^%s*%[(.-)%]%s*$")
		if header then
			group = header
		elseif group == "Desktop Entry" and not line:match("^%s*#") then
			local key, value = line:match("^%s*([%w%-]+)%s*=%s*(.-)%s*$")
			if key and entry[key] == nil then entry[key] = unescape_value(value) end
		end
	end
	return entry
end

--- Splits an Exec value into its words, as the Desktop Entry specification
--- quotes them, and drops the field codes (%f %U …) a clone's launcher
--- replaces with its own arguments.
--- @param exec string Decoded Exec value.
--- @return table|nil words Nil when the quoting is malformed.
function M.exec_words(exec)
	local words, current, in_quotes, has_word = {}, {}, false, false
	local index = 1
	while index <= #exec do
		local c = exec:sub(index, index)
		if in_quotes then
			if c == "\\" and exec:sub(index + 1, index + 1):match('["`$\\]') then
				current[#current + 1] = exec:sub(index + 1, index + 1)
				index = index + 1
			elseif c == '"' then
				in_quotes = false
			else
				current[#current + 1] = c
			end
		elseif c == '"' then
			in_quotes, has_word = true, true
		elseif c == " " or c == "\t" then
			if has_word then words[#words + 1] = table.concat(current) end
			current, has_word = {}, false
		else
			current[#current + 1] = c
			has_word = true
		end
		index = index + 1
	end
	if in_quotes then return nil end
	if has_word then words[#words + 1] = table.concat(current) end
	local kept = {}
	for _, word in ipairs(words) do
		if not word:match("^%%[fFuUdDnNickvm]$") then kept[#kept + 1] = (word:gsub("%%%%", "%%")) end
	end
	return kept
end

--- Quotes one Exec argument as the Desktop Entry specification reads it,
--- then escapes it as a string value.
--- @param word string
--- @return string
function M.desktop_exec_word(word)
	assert(not word:find("[%z\1-\31\127]"), "a desktop Exec word cannot hold control characters")
	local quoted = '"' .. word:gsub('[\\"`$]', "\\%0") .. '"'
	quoted = quoted:gsub("%%", "%%%%")
	return (quoted:gsub("\\", "\\\\"))
end

--- Escapes a desktop-entry string value.
--- @param value string
--- @return string
function M.desktop_value(value)
	assert(not value:find("[%z\1-\8\11-\31\127]"), "a desktop value cannot hold control characters")
	return (value:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\t", "\\t"))
end

--- A file-name-safe identifier for a clone name.
--- @param name string
--- @return string slug
function M.slug(name)
	local slug = name:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
	if slug == "" then slug = "clone" end
	return slug:sub(1, 48)
end




-- ======================================
-- ======================================
-- ======= 3/ Clone plan ================
-- ======================================
-- ======================================

--- Whether an open item is a web address a browser can open as an app.
local function is_web_url(value)
	return type(value) == "string" and value:match("^[Hh][Tt][Tt][Pp][Ss]?://") ~= nil
end

--- Plans a clone: the files to write and the folders to create.
--- @param request table { source = parsed entry, source_path, name, open_item, icon,
---   catalogue, data_home, home, has_marker, taken }
--- @return table|nil plan { id, family, profile, launcher_path, launcher_text, desktop_path, desktop_text,
---   folders, links }
--- @return string|nil reason Why the source cannot be cloned.
function M.plan(request)
	local source, catalogue = request.source, request.catalogue
	local words = source.Exec and M.exec_words(source.Exec)
	if not words or #words == 0 then return nil, "the source declares no program" end
	local program = table.remove(words, 1)
	local family = M.family(catalogue, program, request.has_marker)

	local base = M.slug(request.name)
	local id, suffix = base, 1
	while request.taken(id) do
		suffix = suffix + 1
		id = base .. "-" .. suffix
	end
	local root = request.data_home .. "/ergopti/" .. catalogue.profile_folder .. "/" .. id
	local profile = root .. "/profile"
	local window_class = catalogue.window_class_prefix .. id
	local plan = {
		id = id, family = family, profile = profile, folders = { profile }, links = {},
		launcher_path = root .. "/launch.sh",
		desktop_path = request.data_home .. "/applications/" .. window_class .. ".desktop",
	}

	local launch = { program }
	for _, word in ipairs(words) do launch[#launch + 1] = word end
	for _, word in ipairs(M.family_arguments(catalogue, family,
		{ profile = profile, window_class = window_class, home = request.home })) do
		launch[#launch + 1] = word
	end
	local family_definition = catalogue.families[family]
	if family_definition and family_definition.share_user_settings then
		-- As macOS does: the clone reads the main instance's settings, keybindings
		-- and snippets, while its windows, state and accounts stay its own.
		plan.links[#plan.links + 1] = { target = request.home .. "/.config/Code/User", link = profile .. "/User" }
	end
	local open_item = request.open_item
	if open_item and open_item ~= "" then
		if family_definition and family_definition.web_app and is_web_url(open_item) then
			launch[#launch + 1] = (family_definition.web_app:gsub("{url}", function() return open_item end))
		else
			launch[#launch + 1] = open_item
		end
	end

	local lines = { "#!/bin/sh", "# Ergopti App Cloner launcher, generated for one clone; edit through App Cloner.",
		"# Source: " .. (request.source_path or "?"):gsub("[\r\n]", " ") }
	if family == "native" then
		for _, pair in ipairs({ { "XDG_CONFIG_HOME", "config" }, { "XDG_DATA_HOME", "data" },
			{ "XDG_CACHE_HOME", "cache" }, { "XDG_STATE_HOME", "state" } }) do
			local folder = profile .. "/" .. pair[2]
			plan.folders[#plan.folders + 1] = folder
			lines[#lines + 1] = "export " .. pair[1] .. "=" .. quote(folder)
		end
	end
	local exec_line = "exec"
	for _, word in ipairs(launch) do exec_line = exec_line .. " " .. quote(word) end
	lines[#lines + 1] = exec_line .. ' "$@"'
	plan.launcher_text = table.concat(lines, "\n") .. "\n"

	local desktop = {
		"[Desktop Entry]",
		"Type=Application",
		"Name=" .. M.desktop_value(request.name),
		"Exec=" .. M.desktop_exec_word("/bin/sh") .. " " .. M.desktop_exec_word(plan.launcher_path) .. " %U",
		"Terminal=false",
	}
	local icon = request.icon or source.Icon
	if icon and icon ~= "" then desktop[#desktop + 1] = "Icon=" .. M.desktop_value(icon) end
	if family == "chromium" or family == "firefox" then
		desktop[#desktop + 1] = "StartupWMClass=" .. window_class
	end
	desktop[#desktop + 1] = "X-Ergopti-Clone=true"
	plan.desktop_text = table.concat(desktop, "\n") .. "\n"
	return plan
end




-- ======================================
-- ======================================
-- ======= 4/ Writing ===================
-- ======================================
-- ======================================

--- Runs a command and returns whether it exited 0.
local function succeeded(command)
	-- Both os.execute ABIs (a LuaJIT number, or Lua 5.2 true/exit/code) read as one code.
	local code = require("ui.native_dialog").exit_code(os.execute(command))
	return code == 0
end

--- Writes one file whole, failing loudly.
local function write_file(path, text)
	local file, err = io.open(path, "wb")
	if not file then return false, err end
	local ok, write_err = file:write(text)
	file:close()
	if not ok then return false, write_err end
	return true
end

--- Writes a planned clone to disk. A failure removes what this run created.
--- @param plan table From M.plan.
--- @return boolean ok
--- @return string|nil reason
function M.write(plan)
	local root = NativePath.dirname(plan.launcher_path)
	local applications = NativePath.dirname(plan.desktop_path)
	local function undo()
		os.execute("rm -rf " .. quote(root))
		os.remove(plan.desktop_path)
	end
	for _, folder in ipairs({ root, applications }) do
		if not succeeded("mkdir -p " .. quote(folder)) then undo() return false, "cannot create " .. folder end
	end
	for _, folder in ipairs(plan.folders) do
		if not succeeded("mkdir -p -m 700 " .. quote(folder)) then undo() return false, "cannot create " .. folder end
	end
	for _, link in ipairs(plan.links) do
		if succeeded("test -d " .. quote(link.target)) and not succeeded("test -e " .. quote(link.link)) then
			if not succeeded("ln -s " .. quote(link.target) .. " " .. quote(link.link)) then
				undo() return false, "cannot link " .. link.link
			end
		end
	end
	local ok, err = write_file(plan.launcher_path, plan.launcher_text)
	if not ok or not succeeded("chmod 755 " .. quote(plan.launcher_path)) then
		undo() return false, "cannot write the launcher: " .. tostring(err)
	end
	ok, err = write_file(plan.desktop_path, plan.desktop_text)
	if not ok then undo() return false, "cannot write the desktop entry: " .. tostring(err) end
	-- Menus refresh from the folder; the cache update is a courtesy where installed.
	os.execute("command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "
		.. quote(applications) .. " >/dev/null 2>&1")
	return true
end

return M
