--- modules/llm/agent_connectors.lua

--- ==============================================================================
--- MODULE: AI Agent Connectors (macOS)
--- DESCRIPTION:
--- Carries out one action of the AI agent once the user accepted it: a
--- Calendar event, a Reminders reminder, a Mail draft, or one of the user's
--- Shortcuts. Also lists those Shortcuts, the tools System 2 may name.
---
--- FEATURES & RATIONALE:
--- 1. Every action arrives validated by the shared agent.lua: its fields are
---    known, its dates are real local times, its shortcut is one of the list.
--- 2. Calendar, Reminders and Mail are driven by AppleScript through osascript,
---    as an asynchronous task. Dates are built from their numeric components,
---    never parsed from a localized date string, and every text goes through
---    agent.applescript_string.
--- 3. A Mail draft is only opened for review: the script never sends it.
--- 4. A refused Automation permission (error -1743) is reported as such, so the
---    runner can tell the user which application to allow.
--- 5. Shortcuts run through /usr/bin/shortcuts with argv, never a shell; an
---    input goes through a private temporary file removed once the run ends.
--- ==============================================================================

local M = {}

local Agent       = require("llm.agent")
local Logger      = require("infra.logger")
local ShellRunner = require("adapters.shell_runner")
local FileSystem  = require("adapters.file_system")

local LOG = "llm.agent_connectors"

local OSASCRIPT_BIN = "/usr/bin/osascript"
local SHORTCUTS_BIN = "/usr/bin/shortcuts"

-- The application each scripted action drives, named in the permission notice
M.APPS = { calendar = "Calendar", reminder = "Reminders", mail = "Mail" }

-- System Settings pane where the user grants the Automation permission
M.AUTOMATION_SETTINGS_URL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"

-- The Apple event error macOS returns when the Automation permission is refused
local NOT_AUTHORIZED_CODE = "-1743"




-- ======================================
-- ======================================
-- ======= 1/ AppleScript texts =========
-- ======================================
-- ======================================

--- AppleScript lines that build a date variable from a local time, component by
--- component. The day is set to 1 first so that changing the month can never
--- overflow (31 January + one month is not a day of February).
--- @param name string Variable name.
--- @param value string Local time "YYYY-MM-DDTHH:MM".
--- @return table lines
local function date_lines(name, value)
	local y, mo, d, h, mi = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d)$")
	if not y then error("agent_connectors: invalid local time " .. tostring(value)) end
	return {
		"set " .. name .. " to current date",
		"set day of " .. name .. " to 1",
		"set year of " .. name .. " to " .. tonumber(y),
		"set month of " .. name .. " to " .. tonumber(mo),
		"set day of " .. name .. " to " .. tonumber(d),
		"set time of " .. name .. " to " .. (tonumber(h) * 3600 + tonumber(mi) * 60),
	}
end

--- Formats an AppleScript record from ordered { key, value } pairs.
--- @param pairs_list table Array of { key, AppleScript expression }.
--- @return string record
local function record(pairs_list)
	local parts = {}
	for _, pair in ipairs(pairs_list) do parts[#parts + 1] = pair[1] .. ":" .. pair[2] end
	return "{" .. table.concat(parts, ", ") .. "}"
end

--- Appends every line of `more` to `lines`.
local function append(lines, more)
	for _, line in ipairs(more) do lines[#lines + 1] = line end
end

--- The AppleScript that adds a calendar action to the first writable calendar.
--- @param action table A validated calendar action.
--- @return string script
function M.calendar_script(action)
	local lines = {}
	append(lines, date_lines("startDate", action.start))
	append(lines, date_lines("endDate", action["end"]))
	local properties = {
		{ "summary", Agent.applescript_string(action.title) },
		{ "start date", "startDate" },
		{ "end date", "endDate" },
	}
	if action.location then properties[#properties + 1] = { "location", Agent.applescript_string(action.location) } end
	if action.notes then properties[#properties + 1] = { "description", Agent.applescript_string(action.notes) } end
	append(lines, {
		'tell application "Calendar"',
		"\tset targetCalendar to missing value",
		"\trepeat with candidate in calendars",
		"\t\tif writable of candidate then",
		"\t\t\tset targetCalendar to candidate",
		"\t\t\texit repeat",
		"\t\tend if",
		"\tend repeat",
		'\tif targetCalendar is missing value then error "no writable calendar"',
		"\tset newEvent to make new event at end of events of targetCalendar with properties "
			.. record(properties),
	})
	for _, address in ipairs(action.attendees or {}) do
		lines[#lines + 1] = "\ttell newEvent to make new attendee at end of attendees with properties "
			.. record({ { "email", Agent.applescript_string(address) } })
	end
	lines[#lines + 1] = "end tell"
	return table.concat(lines, "\n")
end

--- The AppleScript that adds a reminder action to the default list.
--- @param action table A validated reminder action.
--- @return string script
function M.reminder_script(action)
	local lines = {}
	local properties = { { "name", Agent.applescript_string(action.title) } }
	if action.notes then properties[#properties + 1] = { "body", Agent.applescript_string(action.notes) } end
	if action.due then
		append(lines, date_lines("dueDate", action.due))
		properties[#properties + 1] = { "due date", "dueDate" }
	end
	append(lines, {
		'tell application "Reminders"',
		"\tmake new reminder with properties " .. record(properties),
		"end tell",
	})
	return table.concat(lines, "\n")
end

--- The AppleScript that opens a mail action as a draft for review. It never
--- sends it: the user reviews it and sends it from Mail.
--- @param action table A validated mail action.
--- @return string script
function M.mail_script(action)
	local properties = {}
	if action.subject then properties[#properties + 1] = { "subject", Agent.applescript_string(action.subject) } end
	properties[#properties + 1] = { "content", Agent.applescript_string(action.body) }
	properties[#properties + 1] = { "visible", "true" }
	local lines = {
		'tell application "Mail"',
		"\tset newMessage to make new outgoing message with properties " .. record(properties),
	}
	for _, address in ipairs(action.to or {}) do
		lines[#lines + 1] = "\ttell newMessage to make new to recipient at end of to recipients with properties "
			.. record({ { "address", Agent.applescript_string(address) } })
	end
	lines[#lines + 1] = "\tactivate"
	lines[#lines + 1] = "end tell"
	return table.concat(lines, "\n")
end

local SCRIPTS = { calendar = M.calendar_script, reminder = M.reminder_script, mail = M.mail_script }




-- ======================================
-- ======================================
-- ======= 2/ Processes =================
-- ======================================
-- ======================================

--- Starts one process and reports its completion exactly once.
--- @param executable string Absolute path.
--- @param args table argv.
--- @param label string What runs, for the log.
--- @param on_done function fn(exit_code, stdout, stderr).
--- @return boolean started
local function run_process(executable, args, label, on_done)
	local handle = ShellRunner.spawn(executable, args, function(exit_code, stdout, stderr)
		on_done(exit_code, stdout, stderr)
	end)
	if handle.isSettled() then
		Logger.error(LOG, "%s could not be constructed.", label)
		return false
	end
	if not handle.start() then
		Logger.error(LOG, "%s could not start.", label)
		return false
	end
	return true
end

--- Runs an action through an AppleScript.
--- @param action table A validated calendar, reminder or mail action.
--- @param on_done function fn(ok, detail) detail = { reason, permission = app name }.
--- @return boolean started
local function run_script(action, on_done)
	local app = M.APPS[action.type]
	local script = SCRIPTS[action.type](action)
	Logger.start(LOG, "Running the %s connector (%s, %d byte(s) of AppleScript).", action.type, app, #script)
	local started = run_process(OSASCRIPT_BIN, { "-e", script }, "The " .. action.type .. " connector",
		function(exit_code, _, stderr)
			if exit_code == 0 then
				Logger.success(LOG, "The %s connector completed.", action.type)
				on_done(true, nil)
				return
			end
			local detail = type(stderr) == "string" and stderr:gsub("%s+$", "") or ""
			if detail:find(NOT_AUTHORIZED_CODE, 1, true) or detail:find("Not authorized to send Apple events", 1, true) then
				Logger.error(LOG, "The %s connector was refused the Automation permission for %s.", action.type, app)
				on_done(false, { reason = "automation refused", permission = app })
				return
			end
			Logger.error(LOG, "The %s connector failed (exit %s): %s.", action.type, tostring(exit_code), detail)
			on_done(false, { reason = "exit " .. tostring(exit_code) .. ": " .. detail })
		end)
	if not started then
		Logger.error(LOG, "The %s connector ended before running.", action.type)
		on_done(false, { reason = "osascript did not start" })
	end
	return started
end

--- Removes a temporary input file, logging a failure.
--- @param path string
local function remove_input(path)
	local ok, removed = pcall(FileSystem.delete, path)
	if not ok or removed == false then
		Logger.error(LOG, "The shortcut input file could not be removed: %s.", tostring(removed))
	end
end

--- Runs one of the user's Shortcuts, with the action's input when present.
--- @param action table A validated shortcut action.
--- @param on_done function fn(ok, detail).
--- @return boolean started
local function run_shortcut(action, on_done)
	local args = { "run", action.name }
	local input_path = nil
	if action.input then
		local path, detail = FileSystem.create_secure_temp_file()
		if not path then
			Logger.error(LOG, "The shortcut input file could not be created: %s.", tostring(detail))
			on_done(false, { reason = "no input file" })
			return false
		end
		-- Appended in place: an atomic write would replace the private file by a
		-- new one with the default permissions
		if FileSystem.append(path, action.input) ~= true then
			Logger.error(LOG, "The shortcut input could not be written.")
			remove_input(path)
			on_done(false, { reason = "input not written" })
			return false
		end
		input_path = path
		args[#args + 1] = "-i"
		args[#args + 1] = path
	end
	Logger.start(LOG, "Running the shortcut connector (%d argument(s)).", #args)
	local started = run_process(SHORTCUTS_BIN, args, "The shortcut connector", function(exit_code, _, stderr)
		-- The run is over: the shortcut has read its input
		if input_path then remove_input(input_path) end
		if exit_code == 0 then
			Logger.success(LOG, "The shortcut connector completed.")
			on_done(true, nil)
			return
		end
		local detail = type(stderr) == "string" and stderr:gsub("%s+$", "") or ""
		Logger.error(LOG, "The shortcut connector failed (exit %s): %s.", tostring(exit_code), detail)
		on_done(false, { reason = "exit " .. tostring(exit_code) .. ": " .. detail })
	end)
	if not started then
		if input_path then remove_input(input_path) end
		Logger.error(LOG, "The shortcut connector ended before running.")
		on_done(false, { reason = "shortcuts did not start" })
	end
	return started
end




-- ======================================
-- ======================================
-- ======= 3/ Public API ================
-- ======================================
-- ======================================

--- Carries out one validated action.
--- @param action table A validated action (agent.validate_action).
--- @param on_done function fn(ok, detail): detail.reason on a failure, and
---        detail.permission (the application to allow) when macOS refused the
---        Automation permission. Called exactly once, possibly synchronously.
--- @return boolean started True when the process was started.
function M.run(action, on_done)
	if type(action) ~= "table" or type(on_done) ~= "function" then
		error("agent_connectors.run: an action and on_done are required")
	end
	if SCRIPTS[action.type] then return run_script(action, on_done) end
	if action.type == "shortcut" then return run_shortcut(action, on_done) end
	error("agent_connectors.run: unknown action type " .. tostring(action.type))
end

--- Lists the names of the user's Shortcuts.
--- @param max number How many names to keep at most.
--- @param on_done function fn(names|nil): nil when the list could not be read.
--- @return boolean started
function M.list_tools(max, on_done)
	if type(max) ~= "number" or type(on_done) ~= "function" then
		error("agent_connectors.list_tools: a maximum and on_done are required")
	end
	local started = run_process(SHORTCUTS_BIN, { "list" }, "The shortcuts list", function(exit_code, stdout, stderr)
		if exit_code ~= 0 or type(stdout) ~= "string" then
			Logger.error(LOG, "The shortcuts list failed (exit %s): %s.", tostring(exit_code),
				tostring(stderr or ""):gsub("%s+$", ""))
			on_done(nil)
			return
		end
		local names = {}
		for line in stdout:gmatch("[^\r\n]+") do
			local name = line:match("^%s*(.-)%s*$")
			if name ~= "" and #names < max then names[#names + 1] = name end
		end
		Logger.info(LOG, "Shortcuts listed: %d tool(s).", #names)
		on_done(names)
	end)
	if not started then on_done(nil) end
	return started
end

--- Opens System Settings at the Automation permissions.
--- @return boolean started
function M.open_automation_settings()
	return ShellRunner.open(M.AUTOMATION_SETTINGS_URL) == true
end

return M
