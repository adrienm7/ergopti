--- tests/unit/modules/llm/test_agent_connectors.lua

--- ==============================================================================
--- MODULE: AI Agent Connectors (macOS)
--- DESCRIPTION:
--- Runs modules/llm/agent_connectors.lua with the process launcher and the
--- temporary files faked, and pins what reaches macOS for each action type:
--- the exact AppleScript given to osascript, the argv of /usr/bin/shortcuts,
--- the Shortcuts list, and the Automation refusal.
---
--- ROOT CAUSES ENCODED:
--- 1. A date written as text is read in the user's locale by AppleScript: the
---    scripts must build every date from its numbers, day first set to 1 so a
---    month change never overflows.
--- 2. A model's text inside an AppleScript literal must not end the string.
--- 3. The Mail connector prepares a draft for review and must never send it.
--- 4. A shortcut's input goes through a private file removed once it ran.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "modules.llm.agent_connectors", "adapters.shell_runner", "adapters.file_system", "infra.logger" }

--- Loads the connectors over a fake process launcher and file system.
--- @param scenario function Receives (Connectors, world).
local function with_connectors(scenario)
	helpers.with_fresh_modules(MODULES, function()
		local world = { spawns = {}, opens = {}, files = {}, removed = {}, next_file = 0 }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["adapters.shell_runner"] = {
			spawn = function(executable, args, on_done)
				local record = { executable = executable, args = args, on_done = on_done, started = false }
				world.spawns[#world.spawns + 1] = record
				return {
					isSettled = function() return false end,
					start = function() record.started = true; return true end,
				}
			end,
			open = function(target) world.opens[#world.opens + 1] = target; return true end,
		}
		package.loaded["adapters.file_system"] = {
			create_secure_temp_file = function()
				world.next_file = world.next_file + 1
				local path = "/private/tmp/lua_agent" .. world.next_file
				world.files[path] = ""
				return path
			end,
			append = function(path, content)
				world.files[path] = (world.files[path] or "") .. content
				return true
			end,
			delete = function(path)
				world.removed[#world.removed + 1] = path
				world.files[path] = nil
				return true
			end,
		}
		package.loaded["modules.llm.agent_connectors"] = nil
		local ok, err = pcall(scenario, require("modules.llm.agent_connectors"), world)
		-- with_fresh_modules restores the real module too; the explicit reset keeps
		-- the suite-wide stub hygiene gate able to see it
		package.loaded["adapters.shell_runner"] = nil
		if not ok then error(err, 0) end
	end)
end

--- Runs one action and completes its process with an exit code.
--- @return table spawn, table outcome { ok, detail }
local function run(Connectors, world, action, exit_code, stderr)
	local outcome = {}
	helpers.assert_eq(Connectors.run(action, function(ok, detail) outcome.ok, outcome.detail = ok, detail end), true)
	local spawn = world.spawns[#world.spawns]
	helpers.assert_true(spawn.started, "the process is started")
	helpers.assert_nil(outcome.ok, "nothing is reported before the process ends")
	spawn.on_done(exit_code or 0, "", stderr or "")
	return spawn, outcome
end

helpers.describe("AI agent connectors (macOS)", function()
	helpers.it("adds a calendar event from date components to the first writable calendar", function()
		with_connectors(function(Connectors, world)
			local spawn, outcome = run(Connectors, world, {
				type = "calendar", title = 'Devis "Paul"', start = "2026-10-01T14:00", ["end"] = "2026-10-01T15:30",
				location = "Bureau", notes = "Apporter le devis", attendees = { "paul@example.com" },
			})
			helpers.assert_eq(spawn.executable, "/usr/bin/osascript")
			helpers.assert_eq(spawn.args[1], "-e")
			helpers.assert_eq(#spawn.args, 2, "the script is one argv entry, never a shell string")
			helpers.assert_eq(spawn.args[2], table.concat({
				"set startDate to current date",
				"set day of startDate to 1",
				"set year of startDate to 2026",
				"set month of startDate to 10",
				"set day of startDate to 1",
				"set time of startDate to 50400",
				"set endDate to current date",
				"set day of endDate to 1",
				"set year of endDate to 2026",
				"set month of endDate to 10",
				"set day of endDate to 1",
				"set time of endDate to 55800",
				'tell application "Calendar"',
				"\tset targetCalendar to missing value",
				"\trepeat with candidate in calendars",
				"\t\tif writable of candidate then",
				"\t\t\tset targetCalendar to candidate",
				"\t\t\texit repeat",
				"\t\tend if",
				"\tend repeat",
				'\tif targetCalendar is missing value then error "no writable calendar"',
				'\tset newEvent to make new event at end of events of targetCalendar with properties '
					.. '{summary:"Devis \\"Paul\\"", start date:startDate, end date:endDate, '
					.. 'location:"Bureau", description:"Apporter le devis"}',
				'\ttell newEvent to make new attendee at end of attendees with properties {email:"paul@example.com"}',
				"end tell",
			}, "\n"))
			helpers.assert_eq(outcome.ok, true)
		end)
	end)

	helpers.it("adds a reminder with its due date and notes, and one without a date", function()
		with_connectors(function(Connectors, world)
			local spawn = run(Connectors, world, {
				type = "reminder", title = "Rappeler Paul", due = "2026-02-28T09:05", notes = "Le devis",
			})
			helpers.assert_eq(spawn.args[2], table.concat({
				"set dueDate to current date",
				"set day of dueDate to 1",
				"set year of dueDate to 2026",
				"set month of dueDate to 2",
				"set day of dueDate to 28",
				"set time of dueDate to 32700",
				'tell application "Reminders"',
				'\tmake new reminder with properties {name:"Rappeler Paul", body:"Le devis", due date:dueDate}',
				"end tell",
			}, "\n"))
			spawn = run(Connectors, world, { type = "reminder", title = "Acheter du pain" })
			helpers.assert_eq(spawn.args[2], 'tell application "Reminders"\n'
				.. '\tmake new reminder with properties {name:"Acheter du pain"}\nend tell')
		end)
	end)

	helpers.it("opens a mail draft for review and never sends it", function()
		with_connectors(function(Connectors, world)
			local spawn, outcome = run(Connectors, world, {
				type = "mail", to = { "paul@example.com", "anne@example.com" }, subject = "Devis", body = "Bonjour\\Paul",
			})
			helpers.assert_eq(spawn.args[2], table.concat({
				'tell application "Mail"',
				'\tset newMessage to make new outgoing message with properties '
					.. '{subject:"Devis", content:"Bonjour\\\\Paul", visible:true}',
				'\ttell newMessage to make new to recipient at end of to recipients with properties '
					.. '{address:"paul@example.com"}',
				'\ttell newMessage to make new to recipient at end of to recipients with properties '
					.. '{address:"anne@example.com"}',
				"\tactivate",
				"end tell",
			}, "\n"))
			helpers.assert_nil(spawn.args[2]:lower():find("send", 1, true), "the draft is never sent")
			helpers.assert_eq(outcome.ok, true)
		end)
	end)

	helpers.it("runs a shortcut by name, its input through a private file removed afterwards", function()
		with_connectors(function(Connectors, world)
			local spawn, outcome = run(Connectors, world, { type = "shortcut", name = "Mode focus" })
			helpers.assert_eq(spawn.executable, "/usr/bin/shortcuts")
			helpers.assert_eq(table.concat(spawn.args, "|"), "run|Mode focus")
			helpers.assert_eq(outcome.ok, true)

			local outcome2 = {}
			Connectors.run({ type = "shortcut", name = "Traduire", input = "Bonjour" }, function(ok)
				outcome2.ok = ok
			end)
			spawn = world.spawns[#world.spawns]
			helpers.assert_eq(table.concat(spawn.args, "|"), "run|Traduire|-i|/private/tmp/lua_agent1")
			helpers.assert_eq(world.files["/private/tmp/lua_agent1"], "Bonjour", "the input is in the file")
			helpers.assert_eq(#world.removed, 0, "the file stays until the shortcut has read it")
			spawn.on_done(1, "", "The shortcut failed")
			helpers.assert_eq(world.removed[1], "/private/tmp/lua_agent1", "and is removed once the run ended")
			helpers.assert_eq(outcome2.ok, false)
		end)
	end)

	helpers.it("reports a refused Automation permission with the application to allow", function()
		with_connectors(function(Connectors, world)
			local _, outcome = run(Connectors, world, { type = "mail", body = "Bonjour" }, 1,
				"execution error: Not authorized to send Apple events to Mail. (-1743)\n")
			helpers.assert_eq(outcome.ok, false)
			helpers.assert_eq(outcome.detail.permission, "Mail")
			local _, other = run(Connectors, world, { type = "reminder", title = "x" }, 1, "some other error")
			helpers.assert_eq(other.ok, false)
			helpers.assert_nil(other.detail.permission)
			helpers.assert_eq(Connectors.open_automation_settings(), true)
			helpers.assert_eq(world.opens[1], Connectors.AUTOMATION_SETTINGS_URL)
		end)
	end)

	helpers.it("lists the user's Shortcuts, capped", function()
		with_connectors(function(Connectors, world)
			local listed
			helpers.assert_eq(Connectors.list_tools(2, function(names) listed = names end), true)
			local spawn = world.spawns[1]
			helpers.assert_eq(spawn.executable, "/usr/bin/shortcuts")
			helpers.assert_eq(table.concat(spawn.args, "|"), "list")
			spawn.on_done(0, "Mode focus\n  Traduire \n\nTroisième\n", "")
			helpers.assert_eq(table.concat(listed, "|"), "Mode focus|Traduire")
			Connectors.list_tools(5, function(names) listed = names end)
			world.spawns[2].on_done(1, "", "no shortcuts")
			helpers.assert_nil(listed, "an unreadable list is no list")
		end)
	end)
end)
