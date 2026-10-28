--- tests/unit/modules/llm/backends/test_local_server_port_scan.lua

--- ==============================================================================
--- MODULE: Local Server Port Scan (macOS commands)
--- DESCRIPTION:
--- Drives modules/llm/local_server_ports.lua with a fake asynchronous runner:
--- - one pgrep of the catalogue's names finds the processes, within its own
---   short deadline; a settings-file port needs no lsof;
--- - lsof runs only for a running server without a port, on its pids only;
--- - a process list that outlived its deadline still reads the settings file,
---   then every listening socket, before the catalogue port;
--- - a command that outlives its deadline is terminated and the scan settles.
---
--- ROOT CAUSE ENCODED:
--- The field report of 2026-10-28 ran ps -axww -o pid=,args= (every argument
--- of every process): past the pipe hs.task drains only at exit, ps blocked
--- until its 6 s deadline, and the sweep then probed oMLX at 8000 while its
--- settings.json said 8181 (omlx-ps-timeout-config).
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Policy = require("llm.local_server_ports")
local Timings = require("infra.timings")

--- Builds the scan entries of the actual catalogue.
--- @return table entries
local function catalogue_entries()
	local file = assert(io.open(helpers.shared("modules/llm/local_servers.json"), "rb"))
	local root = assert(Json.decode(file:read("*a")))
	file:close()
	local entries = {}
	for _, id in ipairs(root.server_order) do
		entries[#entries + 1] = { id = id, descriptor = assert(Policy.descriptor(id, root.servers[id].discovery)),
			base_url = root.servers[id].base_url }
	end
	return entries
end

--- Runs a scenario over a fresh scanner with fake commands, files and timers.
--- @param scenario function Receives (Scanner, world).
local function with_scanner(scenario)
	helpers.with_fresh_modules({ "modules.llm.local_server_ports", "adapters.timer_scheduler" }, function()
		local world = { runs = {}, timers = {}, files = {}, terminated = 0 }
		package.loaded["adapters.timer_scheduler"] = {
			after = function(seconds, fn)
				local timer = { seconds = seconds, fn = fn }
				world.timers[#world.timers + 1] = timer
				return timer, true
			end,
			cancel = function(timer) timer.cancelled = true; return true end,
		}
		local Scanner = require("modules.llm.local_server_ports")
		Scanner._home = function() return "/Users/u" end
		Scanner._read_file = function(path) return world.files[path] end
		Scanner._run = function(executable, args, on_done)
			world.runs[#world.runs + 1] = { executable = executable, args = args, on_done = on_done }
			return true, { terminate = function() world.terminated = world.terminated + 1 end }
		end
		scenario(Scanner, world)
	end)
end

--- Lets the first command (the process lookup) outlive its deadline.
--- @param world table
local function expire_process_lookup(world)
	helpers.assert_eq(world.runs[1].executable, "/usr/bin/pgrep")
	world.timers[1].fn()
	helpers.assert_eq(world.terminated, 1, "the overdue pgrep is terminated")
end

helpers.describe("Local server port scan (local-server-ports)", function()
	helpers.it("a settings-file port needs one pgrep and no lsof", function()
		with_scanner(function(Scanner, world)
			world.files["/Users/u/.omlx/settings.json"] = '{"server":{"port":8181}}'
			local results
			helpers.assert_eq(Scanner.scan(catalogue_entries(), function(value) results = value end), true)
			helpers.assert_eq(#world.runs, 1)
			helpers.assert_eq(world.runs[1].executable, "/usr/bin/pgrep")
			world.runs[1].on_done(0, "77996 omlx-server\n51091 /Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon")
			helpers.assert_eq(#world.runs, 1, "no lsof when the settings file gave the port")
			helpers.assert_eq(results.omlx.base_url, "http://127.0.0.1:8181/v1")
			helpers.assert_eq(results.omlx.source, "config")
			helpers.assert_eq(results.lmstudio.running, false)
			helpers.assert_true(world.timers[1].cancelled, "the pgrep deadline is cancelled once pgrep answered")
		end)
	end)

	helpers.it("the process lookup asks for the catalogue's names only, within its budget (omlx-fast-process-lookup)",
		function()
			with_scanner(function(Scanner, world)
				local results
				Scanner.scan(catalogue_entries(), function(value) results = value end)
				local run = world.runs[1]
				helpers.assert_eq(run.executable, "/usr/bin/pgrep", "no full ps listing, no shell")
				for _, arg in ipairs(run.args) do
					helpers.assert_true(arg ~= "-axww" and arg ~= "pid=,args=", "no argument of every process is read")
				end
				local pattern = run.args[#run.args]
				helpers.assert_true(pattern:find("omlx%-server", 1) ~= nil, "the pattern names oMLX's process")
				local budget_ms = Timings.ms("llm", "local_server_process_lookup_timeout_ms")
				helpers.assert_true(budget_ms <= 2000, "the lookup has its own short deadline")
				helpers.assert_eq(world.timers[1].seconds, budget_ms / 1000)
				-- pgrep exits 1 when no catalogue process runs: an answer, not a failure
				run.on_done(1, "")
				helpers.assert_true(world.timers[1].cancelled, "the answer settles before the deadline")
				helpers.assert_eq(#world.runs, 1)
				helpers.assert_eq(results.omlx.running, false)
				helpers.assert_eq(results.jan.running, false)
			end)
		end)

	helpers.it("lsof reads only the pids of a running server without a port", function()
		with_scanner(function(Scanner, world)
			local results
			Scanner.scan(catalogue_entries(), function(value) results = value end)
			world.runs[1].on_done(0, "900 /Applications/Jan.app/Contents/MacOS/Jan\n901 /usr/bin/other")
			helpers.assert_eq(#world.runs, 2)
			helpers.assert_eq(world.runs[2].executable, "/bin/sh")
			helpers.assert_eq(world.runs[2].args[#world.runs[2].args], "900")
			helpers.assert_eq(results, nil, "the scan waits for lsof")
			world.runs[2].on_done(0, "p900\nf9\nn127.0.0.1:1338")
			helpers.assert_eq(results.jan.base_url, "http://127.0.0.1:1338/v1")
			helpers.assert_eq(results.jan.source, "listening")
		end)
	end)

	helpers.it("a timed-out process list still reads oMLX's settings port (omlx-ps-timeout-config)", function()
		with_scanner(function(Scanner, world)
			world.files["/Users/u/.omlx/settings.json"] = '{"version":"1.0","server":{"host":"127.0.0.1","port":8181}}'
			local results
			Scanner.scan(catalogue_entries(), function(value) results = value end)
			expire_process_lookup(world)
			helpers.assert_eq(results, nil, "the servers without a settings port wait for the listening sockets")
			helpers.assert_eq(world.runs[2].executable, "/usr/sbin/lsof")
			world.runs[2].on_done(1, "")
			helpers.assert_eq(results.omlx.source, "config")
			helpers.assert_eq(results.omlx.port, 8181)
			helpers.assert_eq(results.omlx.base_url, "http://127.0.0.1:8181/v1")
			helpers.assert_eq(results.lmstudio.source, "default")
		end)
	end)

	helpers.it("a timed-out process list without a settings file reads the listening ports (omlx-ps-timeout-listening)",
		function()
			with_scanner(function(Scanner, world)
				local results
				Scanner.scan(catalogue_entries(), function(value) results = value end)
				expire_process_lookup(world)
				helpers.assert_eq(world.runs[2].executable, "/usr/sbin/lsof")
				world.runs[2].on_done(0, "p77996\ncomlx-server\nf5\nn127.0.0.1:8181\np51091\ncHammerspoon\nf9\nn127.0.0.1:7265")
				-- The command lines of the listening pids name a renamed interpreter
				helpers.assert_eq(world.runs[3].executable, "/bin/ps")
				helpers.assert_eq(world.runs[3].args[#world.runs[3].args], "77996,51091")
				world.runs[3].on_done(0, "77996 omlx-server\n51091 /Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon")
				helpers.assert_eq(results.omlx.source, "listening")
				helpers.assert_eq(results.omlx.port, 8181)
				helpers.assert_eq(results.omlx.base_url, "http://127.0.0.1:8181/v1")
				helpers.assert_eq(results.jan.source, "default")
				helpers.assert_eq(results.jan.port, 1337)
			end)
		end)

	helpers.it("a listener named by its interpreter is matched by its command line", function()
		with_scanner(function(Scanner, world)
			local results
			Scanner.scan(catalogue_entries(), function(value) results = value end)
			expire_process_lookup(world)
			world.runs[2].on_done(0, "p77996\ncPython\nf5\nn127.0.0.1:8282")
			world.runs[3].on_done(0, "77996 omlx-server")
			helpers.assert_eq(results.omlx.base_url, "http://127.0.0.1:8282/v1")
		end)
	end)

	helpers.it("with no reading at all a server falls back to its catalogue port", function()
		with_scanner(function(Scanner, world)
			local results
			Scanner.scan(catalogue_entries(), function(value) results = value end)
			world.runs[1].on_done(3, "")
			world.runs[2].on_done(2, "")
			helpers.assert_eq(results.omlx.running, true)
			helpers.assert_eq(results.omlx.source, "default")
			helpers.assert_eq(results.omlx.base_url, "http://127.0.0.1:8000/v1")
		end)
	end)

	helpers.it("a command past its deadline is terminated and the scan settles", function()
		with_scanner(function(Scanner, world)
			local results
			Scanner.scan(catalogue_entries(), function(value) results = value end)
			world.timers[1].fn()
			helpers.assert_eq(world.terminated, 1)
			world.timers[2].fn()
			helpers.assert_eq(world.terminated, 2)
			helpers.assert_eq(results.jan.source, "default")
			world.runs[1].on_done(0, "900 /Applications/Jan.app/Contents/MacOS/Jan")
			helpers.assert_eq(results.jan.source, "default", "a late answer cannot settle the scan twice")
		end)
	end)
end)
