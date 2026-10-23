--- tests/unit/infra/field_check/test_field_check_login_items.lua

--- ==============================================================================
--- MODULE: Field Check Login Items Definition
--- DESCRIPTION:
--- The one-click « what starts Ergopti or Hammerspoon at login » check over
--- scripted ports and scripted `sfltool dumpbtm`, grep and plutil output:
--- 1. the dumpbtm parser keeps only entries that name Ergopti or Hammerspoon,
---    only the current user's records, and reads enabled state and location;
--- 2. each entry is counted as this copy or another copy by its location, and
---    is unknown when either location is missing;
--- 3. the check only reads: every command is bounded and none is a write, and no
---    step value carries a path, a user name or a URL.
---
--- UNVERIFIED ON A MAC: the dumpbtm sample below is written from knowledge of the
--- tool's format, not captured. The first real run decides whether the parser's
--- assumptions (see M.parse_btm) hold.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.field_check", "infra.field_check_checks", "platform.remap.ke_paths" }

local APP = "/Applications/ErgoptiPlus.app"
local HOME = "/Users/someone"

local DUMP = table.concat({
	"========================",
	" Records for UID 501 : 11111111-2222-3333-4444-555555555555",
	"========================",
	"",
	" Items:",
	"",
	" #1:",
	"                 UUID: AAAA",
	"                 Name: ErgoptiPlus",
	"       Developer Name: Someone",
	"                 Type: app (0x2)",
	"          Disposition: [enabled, allowed, visible, notified] (0xb)",
	"           Identifier: 2.com.ergoptiplus.app",
	"                  URL: file:///Applications/ErgoptiPlus.app/",
	"",
	" #2:",
	"                 Name: Hammerspoon",
	"                 Type: login item (0x4)",
	"          Disposition: [disabled, allowed, visible, notified] (0x2)",
	"           Identifier: 4.org.hammerspoon.Hammerspoon",
	"                  URL: file:///Users/someone/Old%20Copy/Hammerspoon.app/",
	"",
	" #3:",
	"                 Name: Some Other App",
	"           Identifier: 2.com.example.other",
	"                  URL: file:///Applications/Other.app/",
	"",
	" #4:",
	"                 Name: Embedded driver",
	"           Identifier: 2.com.ergoptiplus.app.hammerspoon",
	"          Disposition: [enabled, allowed, visible, notified] (0xb)",
	"      Executable Path: /Applications/ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app/Contents/MacOS/Hammerspoon",
	"",
	"========================",
	" Records for UID 502 : 66666666-7777-8888-9999-000000000000",
	"========================",
	"",
	" #1:",
	"                 Name: Hammerspoon",
	"           Identifier: 2.org.hammerspoon.Hammerspoon",
	"                  URL: file:///Applications/Hammerspoon.app/",
	"",
}, "\n")

--- Builds scripted ports; `world` records every command.
--- @param overrides table|nil Fields replacing the defaults.
--- @return table ports, table world
local function make_ports(overrides)
	local world = { commands = {}, existing = { ["/usr/bin/sfltool"] = true }, outputs = {}, app = APP, startup = "enabled" }
	local ports = {
		path_exists = function(path) return world.existing[path] == true end,
		exec = function(executable, args, timeout_s, callback)
			world.commands[#world.commands + 1] = { executable = executable, args = args, timeout = timeout_s }
			local scripted = world.outputs[executable .. " " .. table.concat(args, " ")]
				or world.outputs[executable] or { 0, "" }
			callback(scripted[1], scripted[2])
		end,
		home = function() return HOME end,
		app_path = function() return world.app end,
		login_startup_status = function(callback) callback(world.startup) end,
	}
	for name, value in pairs(overrides or {}) do ports[name] = value end
	return ports, world
end

--- Scripts the whole Mac: the id tool, the dump and the agents.
--- @param world table From make_ports.
local function populated(world)
	world.outputs["/usr/bin/id -u"] = { 0, "501\n" }
	world.outputs["/usr/bin/sfltool dumpbtm"] = { 0, DUMP }
	world.existing[HOME .. "/Library/LaunchAgents"] = true
	world.existing["/Library/LaunchAgents"] = true
	world.outputs["/usr/bin/grep -rlisaE -- ergopti|hammerspoon " .. HOME .. "/Library/LaunchAgents"] =
		{ 0, HOME .. "/Library/LaunchAgents/com.ergoptiplus.helper.plist\n" .. HOME .. "/Library/LaunchAgents/org.hammerspoon.old.plist\n" }
	world.outputs["/usr/bin/grep -rlisaE -- ergopti|hammerspoon /Library/LaunchAgents"] = { 1, "" }
	local helper = HOME .. "/Library/LaunchAgents/com.ergoptiplus.helper.plist"
	local old = HOME .. "/Library/LaunchAgents/org.hammerspoon.old.plist"
	world.outputs["/usr/bin/plutil -extract Label raw -o - -- " .. helper] = { 0, "com.ergoptiplus.helper\n" }
	world.outputs["/usr/bin/plutil -extract ProgramArguments.0 raw -o - -- " .. helper] =
		{ 0, "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus\n" }
	world.outputs["/usr/bin/plutil -extract Label raw -o - -- " .. old] = { 0, "org.hammerspoon.old\n" }
	world.outputs["/usr/bin/plutil -extract ProgramArguments.0 raw -o - -- " .. old] = { 1, "" }
	world.outputs["/usr/bin/plutil -extract Program raw -o - -- " .. old] =
		{ 0, "/Users/someone/Old Copy/Hammerspoon.app/Contents/MacOS/Hammerspoon\n" }
end

--- Runs the check and returns its steps keyed by id.
--- @param ports table Ports.
--- @return table steps, table result
local function run(ports)
	local result
	helpers.with_stub_scope(MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.field_check"] = nil
		package.loaded["infra.field_check_checks"] = nil
		local Engine = require("infra.field_check")
		assert(Engine.run("login_items", ports, function(done) result = done end), "check did not start")
	end)
	local steps = {}
	for _, step in ipairs(result.steps) do steps[step.id] = step end
	return steps, result
end

--- Loads the checks module for its pure parsers.
--- @return table checks
local function load_checks()
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.field_check_checks"] = nil
	return require("infra.field_check_checks")
end





-- ==============================
-- ==============================
-- ======= 1/ The parsers =======
-- ==============================
-- ==============================

helpers.describe("login items: the dumpbtm parser", function()
	helpers.it("keeps only the entries that name Ergopti or Hammerspoon", function()
		local entries = load_checks().parse_btm(DUMP)
		local identifiers = {}
		for _, entry in ipairs(entries) do identifiers[#identifiers + 1] = entry.identifier end
		helpers.assert_eq(identifiers, {
			"com.ergoptiplus.app", "org.hammerspoon.Hammerspoon", "com.ergoptiplus.app.hammerspoon",
			"org.hammerspoon.Hammerspoon",
		})
	end)

	helpers.it("restricts itself to the current user's records when the id is known", function()
		local entries = load_checks().parse_btm(DUMP, "501")
		helpers.assert_eq(#entries, 3)
		helpers.assert_eq(#load_checks().parse_btm(DUMP, "502"), 1)
		helpers.assert_eq(#load_checks().parse_btm(DUMP, "999"), 0)
	end)

	helpers.it("reads the enabled state from the disposition, and leaves it unknown without one", function()
		local entries = load_checks().parse_btm(DUMP, "501")
		helpers.assert_eq(entries[1].enabled, true)
		helpers.assert_eq(entries[2].enabled, false)
		helpers.assert_eq(entries[3].enabled, true)
		local bare = load_checks().parse_btm(" #1:\n Name: Hammerspoon\n Identifier: 2.org.hammerspoon.Hammerspoon\n")
		helpers.assert_nil(bare[1].enabled)
	end)

	helpers.it("takes the location from the URL or, failing that, the executable path", function()
		local entries = load_checks().parse_btm(DUMP, "501")
		helpers.assert_eq(entries[1].location, "file:///Applications/ErgoptiPlus.app/")
		helpers.assert_eq(entries[3].location,
			"/Applications/ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app/Contents/MacOS/Hammerspoon")
	end)

	helpers.it("returns nothing, rather than a guess, for text that is not a dump", function()
		local checks = load_checks()
		helpers.assert_eq(checks.parse_btm("sfltool: must be run as root\n"), {})
		helpers.assert_eq(checks.parse_btm(nil), {})
		helpers.assert_eq(checks.parse_btm(""), {})
	end)
end)

helpers.describe("login items: copy classification", function()
	helpers.it("recognizes this copy by its bundle path, with or without a file address", function()
		local checks = load_checks()
		helpers.assert_eq(checks.classify_copy("file:///Applications/ErgoptiPlus.app/", APP), "this")
		helpers.assert_eq(checks.classify_copy("/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus", APP), "this")
		helpers.assert_eq(checks.classify_copy("/Applications/ErgoptiPlus.app", APP), "this")
	end)

	helpers.it("recognizes another copy, including a look-alike prefix and escaped spaces", function()
		local checks = load_checks()
		helpers.assert_eq(checks.classify_copy("/Applications/ErgoptiPlus.app.old/Contents/MacOS/x", APP), "other")
		helpers.assert_eq(checks.classify_copy("file:///Users/someone/Old%20Copy/ErgoptiPlus.app/", APP), "other")
		helpers.assert_eq(checks.classify_copy("/Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon", APP), "other")
	end)

	helpers.it("is unknown when either side is missing", function()
		local checks = load_checks()
		helpers.assert_eq(checks.classify_copy(nil, APP), "unknown")
		helpers.assert_eq(checks.classify_copy("relative/path", APP), "unknown")
		helpers.assert_eq(checks.classify_copy("/Applications/ErgoptiPlus.app", nil), "unknown")
		helpers.assert_eq(checks.classify_copy("/Applications/ErgoptiPlus.app", ""), "unknown")
	end)
end)





-- ================================
-- ================================
-- ======= 2/ The check run =======
-- ================================
-- ================================

helpers.describe("login items: the check", function()
	helpers.it("reports the login item, the background items and the launch agents", function()
		local ports, world = make_ports()
		populated(world)
		local steps, result = run(ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.this_copy_known.value, "yes")
		helpers.assert_eq(steps.main_app_login_item.value, "enabled")
		helpers.assert_eq(steps.btm_state.value, "readable")
		helpers.assert_eq(steps.btm_this_copy.value, "2")
		helpers.assert_eq(steps.btm_other_copy.value, "1")
		helpers.assert_eq(steps.btm_item_1.value, "com.ergoptiplus.app:this:on")
		helpers.assert_eq(steps.btm_item_2.value, "org.hammerspoon.Hammerspoon:other:off")
		helpers.assert_eq(steps.btm_item_3.value, "com.ergoptiplus.app.hammerspoon:this:on")
		helpers.assert_eq(steps.agents_this_copy.value, "1")
		helpers.assert_eq(steps.agents_other_copy.value, "1")
		helpers.assert_eq(steps.agent_item_1.value, "com.ergoptiplus.helper:this:unk")
		helpers.assert_eq(steps.agent_item_2.value, "org.hammerspoon.old:other:unk")
	end)

	helpers.it("only reads: every command is bounded and none writes, signals or unregisters", function()
		local ports, world = make_ports()
		populated(world)
		run(ports)
		local allowed = { ["/usr/bin/id"] = true, ["/usr/bin/sfltool"] = true, ["/usr/bin/grep"] = true,
			["/usr/bin/plutil"] = true }
		for _, command in ipairs(world.commands) do
			helpers.assert_true(allowed[command.executable], command.executable)
			helpers.assert_true(type(command.timeout) == "number" and command.timeout > 0)
		end
		local dump = world.commands[2]
		helpers.assert_eq(dump.args, { "dumpbtm" })
		for _, command in ipairs(world.commands) do
			if command.executable == "/usr/bin/plutil" then
				helpers.assert_eq(command.args[1], "-extract")
				helpers.assert_eq(command.args[3], "raw")
			end
		end
	end)

	helpers.it("lets no path, user name or address reach a step value", function()
		local ports, world = make_ports()
		populated(world)
		local _, result = run(ports)
		for _, step in ipairs(result.steps) do
			helpers.assert_true(not tostring(step.value):find("/", 1, true), step.id)
			helpers.assert_true(not tostring(step.value):find("someone", 1, true), step.id)
			helpers.assert_true(not tostring(step.value):find("file:", 1, true), step.id)
		end
	end)

	helpers.it("lists at most the first few entries and still counts all of them", function()
		local ports, world = make_ports()
		populated(world)
		local lines = { " Records for UID 501 : x" }
		for index = 1, 6 do
			lines[#lines + 1] = (" #%d:"):format(index)
			lines[#lines + 1] = "  Identifier: 2.org.hammerspoon.copy" .. index
			lines[#lines + 1] = "  URL: file:///Applications/Copy" .. index .. ".app/"
		end
		world.outputs["/usr/bin/sfltool dumpbtm"] = { 0, table.concat(lines, "\n") }
		local steps = run(ports)
		helpers.assert_eq(steps.btm_other_copy.value, "6")
		helpers.assert_eq(steps.btm_item_3.value, "org.hammerspoon.copy3:other:unk")
		helpers.assert_nil(steps.btm_item_4)
	end)

	helpers.it("truncates a long identifier so the value stays inside the report grammar", function()
		local ports, world = make_ports()
		populated(world)
		world.outputs["/usr/bin/sfltool dumpbtm"] = { 0, " Records for UID 501 : x\n #1:\n Identifier: 2.com.ergoptiplus."
			.. string.rep("x", 60) .. "\n URL: file:///Applications/Other.app/\n" }
		local steps = run(ports)
		helpers.assert_true(#steps.btm_item_1.value <= 48)
		helpers.assert_true(steps.btm_item_1.value ~= "redacted")
	end)

	helpers.it("treats every entry as unknown, and says so, when the running bundle is not known", function()
		local ports, world = make_ports()
		populated(world)
		world.app = nil
		local steps = run(ports)
		helpers.assert_eq(steps.this_copy_known.value, "no")
		helpers.assert_eq(steps.btm_this_copy.value, "0")
		helpers.assert_eq(steps.btm_other_copy.value, "0")
		helpers.assert_eq(steps.btm_item_1.value, "com.ergoptiplus.app:unk:on")
	end)

	helpers.it("names an unreadable or slow dump and still reads the launch agents", function()
		for _, case in ipairs({ { 1, "unreadable" }, { nil, "timeout" } }) do
			local ports, world = make_ports()
			populated(world)
			world.outputs["/usr/bin/sfltool dumpbtm"] = { case[1], "" }
			local steps = run(ports)
			helpers.assert_eq(steps.btm_state.value, case[2])
			helpers.assert_nil(steps.btm_this_copy)
			helpers.assert_eq(steps.agents_this_copy.value, "1")
		end
	end)

	helpers.it("skips the dump on a Mac without the tool and survives a missing login item answer", function()
		local ports, world = make_ports()
		populated(world)
		world.existing["/usr/bin/sfltool"] = nil
		world.startup = nil
		local steps, result = run(ports)
		helpers.assert_eq(steps.btm_state.state, "skip")
		helpers.assert_eq(steps.btm_state.value, "no_tool")
		helpers.assert_eq(steps.main_app_login_item.value, "unreadable")
		helpers.assert_true(result.passed)
	end)

	helpers.it("reads the whole dump when the user id cannot be read, and says so", function()
		local ports, world = make_ports()
		populated(world)
		world.outputs["/usr/bin/id -u"] = { 1, "" }
		local steps = run(ports)
		helpers.assert_eq(steps.btm_state.value, "readable_all_users")
		helpers.assert_eq(steps.btm_other_copy.value, "2")
	end)

	helpers.it("scans only the directories that exist and reports nothing when none matches", function()
		local ports, world = make_ports()
		populated(world)
		world.existing[HOME .. "/Library/LaunchAgents"] = nil
		world.existing["/Library/LaunchAgents"] = nil
		local steps = run(ports)
		helpers.assert_eq(steps.agents_this_copy.value, "0")
		helpers.assert_eq(steps.agents_other_copy.value, "0")
		helpers.assert_nil(steps.agent_item_1)
		for _, command in ipairs(world.commands) do
			helpers.assert_true(command.executable ~= "/usr/bin/grep")
		end
	end)

	helpers.it("falls back to the plain Program key and to an unnamed label", function()
		local ports, world = make_ports()
		populated(world)
		local old = HOME .. "/Library/LaunchAgents/org.hammerspoon.old.plist"
		world.outputs["/usr/bin/plutil -extract Label raw -o - -- " .. old] = { 1, "" }
		local steps = run(ports)
		helpers.assert_eq(steps.agent_item_2.value, "unnamed:other:unk")
	end)
end)
