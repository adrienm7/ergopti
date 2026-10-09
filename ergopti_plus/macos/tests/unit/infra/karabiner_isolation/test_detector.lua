--- tests/unit/infra/karabiner_isolation/test_detector.lua

--- ==============================================================================
--- MODULE: Karabiner Isolation detector cases
--- DESCRIPTION:
--- Behavioral scenarios for the shared Karabiner source detector.
--- ==============================================================================

local helpers = require("tests.helpers")
local process_calls = require("tests.support.karabiner_isolation.process_calls")
local detector = require("tests.support.karabiner_isolation.detector")
local CLI_BOUNDARY_OFFENDER = process_calls.CLI_BOUNDARY_OFFENDER
local find_offenders = detector.find_offenders

helpers.describe("Karabiner isolation: detector cases", function()
	helpers.it("stock-process isolation: rejects direct shell destruction", function()
		local mutant = [[
#!/bin/sh
pkill -f Karabiner-Menu
launchctl disable gui/501/org.pqrs.karabiner.karabiner_console_user_server
pid=$(pgrep -f Karabiner-Core-Service); kill -TERM "$pid"
]]
		helpers.assert_true(#find_offenders(mutant) >= 3,
			"the guard must be mutation-sensitive to destructive commands in .sh runtime files")
	end)

	helpers.it("stock-process isolation: rejects Swift stock-process launch APIs", function()
		local mutants = {
			[[
var childPID: pid_t = 0
posix_spawn(&childPID, "/Applications/Karabiner-Elements.app/Contents/MacOS/Karabiner-Elements", nil, nil, nil, nil)
]],
			[[
let stockBinary = "/Library/Application Support/org.pqrs/Karabiner-Elements/Karabiner-Core-Service.app/Contents/MacOS/Karabiner-Core-Service"
let process = Process()
process.executableURL = URL(fileURLWithPath: stockBinary)
try process.run()
]],
			[[
try Process.run(URL(fileURLWithPath: "/Applications/Karabiner-Elements.app/Contents/MacOS/Karabiner-Elements"), arguments: [])
]],
		}
		for index, mutant in ipairs(mutants) do
			helpers.assert_eq(
				find_offenders(mutant)[1],
				"stock Karabiner process auto-launch",
				"the guard must classify Swift stock-process launch mutant #" .. index
			)
		end

		local canonical_cli_children = {
			[[
ShellRunner.spawn(KePaths.CLI, { "--set-variables", payload }, onDone)
]],
			[[
local KARABINER_CLI = KePaths.CLI
local ok, task = pcall(
	hs.task.new,
	KARABINER_CLI,
	onDone,
	{ "--get-variable", scoped_name }
)
]],
			[[
let cli = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
let process = Process()
process.executableURL = URL(fileURLWithPath: cli)
process.arguments = ["--set-variables", payload]
try process.run()
]],
			[[
let cli = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
var childPID: pid_t = 0
posix_spawn(&childPID, cli, nil, nil, [cli, "--set-variables", payload], nil)
]],
		}
		for index, source in ipairs(canonical_cli_children) do
			helpers.assert_eq(#find_offenders(source), 0,
				"exact transient --set-variables CLI context must remain allowed #" .. index)
		end
	end)

	helpers.it("stock-process isolation: rejects CLI commands outside exact variable operations", function()
		local mutants = {
			[[ShellRunner.spawn(KePaths.CLI, { "--show-current-profile-name" })]],
			[[
local KARABINER_CLI = KePaths.CLI
local ok, task = pcall(
	hs.task.new,
	KARABINER_CLI,
	onDone,
	{ "--select-profile", "Gaming" }
)
]],
			[[
let cli = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
let process = Process()
process.executableURL = URL(fileURLWithPath: cli)
process.arguments = ["--select-profile", "Gaming"]
try process.run()
]],
			[[
guard let rawArguments = duplicateLeaseArguments([
	cliPath,
	"--list-profile-names",
]) else { return .spawnFailed(ENOMEM) }
]],
			[[
let cli = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
var childPID: pid_t = 0
posix_spawn(&childPID, cli, nil, nil, [cli, "--version"], nil)
]],
			[[
let kCanonicalKarabinerCLIPath = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
final class Mutant {
	func run(cliPath: String) {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: cliPath)
		process.arguments = ["--version"]
		try process.run()
	}
}
]],
		}
		for index, source in ipairs(mutants) do
			helpers.assert_eq(
				find_offenders(source)[1],
				CLI_BOUNDARY_OFFENDER,
				"canonical CLI subcommand mutant must be rejected #" .. index
			)
		end
	end)

	helpers.it("stock-process isolation: correlates Swift /bin/kill with stock-derived PIDs", function()
		local mutants = {
			[[
let stockPID = processIdentifier(named: "Karabiner-Core-Service")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/kill")
process.arguments = ["-TERM", String(stockPID)]
try process.run()
]],
			[[
let stockPID = processIdentifier(named: "karabiner_grabber")
try Process.run(
	URL(fileURLWithPath: "/bin/kill"),
	arguments: ["-KILL", String(stockPID)]
)
]],
			[[
final class Mutant {
	func stopStock() {
		let stockPID = processIdentifier(named: "Karabiner-Menu")
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/kill")
		process.arguments = ["-TERM", String(stockPID)]
		try process.run()
	}
}
]],
		}
		for index, source in ipairs(mutants) do
			helpers.assert_eq(find_offenders(source)[1], "stock Karabiner kill",
				"Swift Process PID-flow mutant must be rejected #" .. index)
		end

		local private_child = [[
let childPID = privateLeaseChild.processIdentifier
let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/kill")
process.arguments = ["-TERM", String(childPID)]
try process.run()
]]
		helpers.assert_eq(#find_offenders(private_child), 0,
			"signalling a directly-owned private helper must not imply stock ownership")
	end)

	helpers.it("stock-process isolation: rejects destructive data flows across argv, lines and indirection", function()
		local mutants = {
			[[kill -TERM "$(pgrep -f Karabiner-Core-Service)"]],
			[[pgrep -f org.pqrs.Karabiner-Elements | xargs kill -TERM]],
			[[
pid=$(pgrep -f karabiner_grabber)
kill -KILL "$pid"
]],
			[[
local _, pid = ShellRunner.exec("/usr/bin/pgrep", { "-f", "karabiner_session_monitor" })
ShellRunner.spawn("/bin/kill", { "-TERM", pid })
]],
			[[
local app = hs.application.get("org.pqrs.Karabiner-Elements")
app:kill()
]],
			[[
local stock_group = process_group_for("Karabiner-Core-Service")
Darwin.killpg(stock_group, SIGKILL)
]],
			[[
ShellRunner.spawn("/bin/launchctl", {
	"bootout",
	"gui/501/org.pqrs.karabiner.karabiner_console_user_server",
})
]],
			[[
local target = KePaths.CORE_SERVICE
WindowManager.kill({ path = target })
]],
			[[hs.application.launchOrFocus("Karabiner-Elements")]],
			[[ShellRunner.spawn("/usr/bin/open", { "-a", "Karabiner-Elements" })]],
		}

		for index, mutant in ipairs(mutants) do
			helpers.assert_true(#find_offenders(mutant) > 0,
				"the stock-process guard must reject destructive mutant #" .. index)
		end
	end)

	helpers.it("stock-process isolation: folds split stock-family constants before destructive use", function()
		local mutant = [[
local prefix = "karabiner_"
local family = prefix .. "grabber"
ShellRunner.spawn("/usr/bin/pkill", { "-f", family })
]]
		local offenders = find_offenders(mutant)
		helpers.assert_eq(#offenders, 1,
			"the guard must reject one destructive use of a constant-propagated stock family")
		helpers.assert_eq(offenders[1], "pkill stock Karabiner",
			"the folded family must taint the actual destructive process command")

		local suffix_mutant = [[
local suffix = "grabber"
local family = "karabiner_" .. suffix
ShellRunner.spawn("/usr/bin/pkill", { "-f", family })
]]
		helpers.assert_eq(find_offenders(suffix_mutant)[1], "pkill stock Karabiner",
			"a constant suffix alias must not hide a destructive stock-family command")

		local inline_mutant = [[
ShellRunner.spawn("/usr/bin/pkill", { "-f", "karabiner_" .. "grabber" })
]]
		helpers.assert_eq(find_offenders(inline_mutant)[1], "pkill stock Karabiner",
			"an inline constant concatenation must taint the destructive process command")

		local inline_probe = [[
ShellRunner.exec("/usr/bin/pgrep", { "-f", "karabiner_" .. "grabber" })
]]
			helpers.assert_eq(#find_offenders(inline_probe), 0,
			"an inline constant concatenation in a read-only probe must remain allowed")
	end)

	helpers.it("stock-process isolation: folds split destructive executable names", function()
		local command_mutants = {
			{
				source = [[
ShellRunner.spawn("/usr/bin/p" .. "kill", { "-f", "Karabiner-Menu" })
]],
				label = "pkill stock Karabiner",
			},
			{
				source = [[
ShellRunner.spawn("/bin/launch" .. "ctl", {
	"bootout",
	"gui/501/org.pqrs.karabiner.karabiner_console_user_server",
})
]],
				label = "launchctl bootout stock Karabiner",
			},
			{
				source = [[
ShellRunner.spawn("/bin/" .. "kill", { "-TERM", "Karabiner-Core-Service" })
]],
				label = "stock Karabiner kill",
			},
			{
				source = [[
local command = "/usr/bin/p" .. "kill"
ShellRunner.spawn(command, { "-f", "Karabiner-Menu" })
]],
				label = "pkill stock Karabiner",
			},
			{
				source = [[
local command = "/bin/launch" .. "ctl"
local mutation = "boot" .. "out"
ShellRunner.spawn(command, { mutation, "org.pqrs.karabiner.karabiner_console_user_server" })
]],
				label = "launchctl bootout stock Karabiner",
			},
		}
		for index, mutant in ipairs(command_mutants) do
			helpers.assert_eq(find_offenders(mutant.source)[1], mutant.label,
				"the guard must classify split destructive executable mutant #" .. index)
		end

		local gui_mutants = {
			[[ShellRunner.spawn("/usr/bin/op" .. "en", { "-a", "Karabiner-Elements" })]],
			[=[
local command = "/usr/bin/op" .. "en"
ShellRunner.spawn(command, { "-a", "Karabiner-Menu" })
]=],
			[[ShellRunner.spawn("op" .. "en", { "-a", "Karabiner-EventViewer" })]],
		}
		for index, source in ipairs(gui_mutants) do
			helpers.assert_eq(
				find_offenders(source)[1],
				"stock Karabiner GUI launch outside explicit capability",
				"the guard must classify split GUI executable mutant #" .. index
			)
		end

		local read_only_probe = [[
ShellRunner.spawn("/usr/bin/p" .. "grep", { "-f", "Karabiner-Menu" })
]]
		helpers.assert_eq(#find_offenders(read_only_probe), 0,
			"a split read-only process probe must not be classified as destructive")

		local aliased_read_only_probe = [[
local command = "/usr/bin/p" .. "grep"
ShellRunner.spawn(command, { "-f", "Karabiner-Menu" })
]]
		helpers.assert_eq(#find_offenders(aliased_read_only_probe), 0,
			"an aliased read-only process probe must not be classified as destructive")
	end)

	helpers.it("stock-process isolation: covers every shared family without flagging unrelated kills", function()
		local shared_families = {
			"Karabiner-Elements",
			"Karabiner-Core-Service",
			"karabiner_grabber",
			"Karabiner-Menu",
			"Karabiner-EventViewer",
			"karabiner_console_user_server",
			"karabiner_session_monitor",
			"org.pqrs.service.agent.karabiner_non_privileged_agent",
			"karabiner_observer",
			"Karabiner-NotificationWindow",
			"Karabiner-Multitouch-Extension",
			"Karabiner-MultitouchExtension",
			"Karabiner-Updater",
			"Karabiner-AppIconSwitcher",
			"Karabiner-VirtualHIDDevice-Daemon",
			"org.pqrs.Karabiner-DriverKit-VirtualHIDDevice",
		}
		for _, family in ipairs(shared_families) do
			helpers.assert_true(#find_offenders("pkill -f " .. family) > 0,
				"the guard must cover shared Karabiner family " .. family)
		end

		local safe_controls = {
			[[kill -TERM "$ERGOPTI_WATCHDOG_PID"]],
			[[pgrep -f mlx_lm | xargs kill -9]],
			[[local app = hs.application.get("Dock"); app:kill()]],
			[[local running = ShellRunner.exec("/usr/bin/pgrep", { "-f", "Karabiner-Core-Service" })]],
			[[
local prefix = "karabiner_"
local family = prefix .. "grabber"
local running = ShellRunner.exec("/usr/bin/pgrep", { "-f", family })
]],
			[[ShellRunner.spawn(KePaths.CLI, { "--set-variables", payload })]],
			[[-- kill -TERM "$(pgrep -f Karabiner-Core-Service)"]],
			[[local ok = true -- app:kill() Karabiner-Core-Service]],
			[[# pkill -f Karabiner-NotificationWindow]],
			[[// launchctl bootout org.pqrs.karabiner.karabiner_console_user_server]],
			[[/* hs.application.get("Karabiner-Elements"):kill() */]],
			[[Logger.info(LOG, "Never kill Karabiner-Elements from Ergopti")]],
		}
		for index, source in ipairs(safe_controls) do
			helpers.assert_eq(#find_offenders(source), 0,
				"the guard must not flag safe control #" .. index)
		end
	end)

end)
