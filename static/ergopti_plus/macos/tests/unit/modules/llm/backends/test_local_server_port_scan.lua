--- tests/unit/modules/llm/backends/test_local_server_port_scan.lua

--- ==============================================================================
--- MODULE: Local Server Port Scan (macOS commands)
--- DESCRIPTION:
--- Drives modules/llm/local_server_ports.lua with a fake asynchronous runner:
--- - one ps finds the processes; a settings-file port needs no lsof;
--- - lsof runs only for a running server without a port, on its pids only;
--- - an unreadable process list probes every server at its catalogue port;
--- - a command that outlives its deadline is terminated and the scan settles.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Policy = require("llm.local_server_ports")

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

helpers.describe("Local server port scan (local-server-ports)", function()
	helpers.it("a settings-file port needs one ps and no lsof", function()
		with_scanner(function(Scanner, world)
			world.files["/Users/u/.omlx/settings.json"] = '{"server":{"port":8181}}'
			local results
			helpers.assert_eq(Scanner.scan(catalogue_entries(), function(value) results = value end), true)
			helpers.assert_eq(#world.runs, 1)
			helpers.assert_eq(world.runs[1].executable, "/bin/ps")
			world.runs[1].on_done(true, "77996 omlx-server\n51091 /Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon")
			helpers.assert_eq(#world.runs, 1, "no lsof when the settings file gave the port")
			helpers.assert_eq(results.omlx.base_url, "http://127.0.0.1:8181/v1")
			helpers.assert_eq(results.omlx.source, "config")
			helpers.assert_eq(results.lmstudio.running, false)
			helpers.assert_true(world.timers[1].cancelled, "the ps deadline is cancelled once ps answered")
		end)
	end)

	helpers.it("lsof reads only the pids of a running server without a port", function()
		with_scanner(function(Scanner, world)
			local results
			Scanner.scan(catalogue_entries(), function(value) results = value end)
			world.runs[1].on_done(true, "900 /Applications/Jan.app/Contents/MacOS/Jan\n901 /usr/bin/other")
			helpers.assert_eq(#world.runs, 2)
			helpers.assert_eq(world.runs[2].executable, "/bin/sh")
			helpers.assert_eq(world.runs[2].args[#world.runs[2].args], "900")
			helpers.assert_eq(results, nil, "the scan waits for lsof")
			world.runs[2].on_done(true, "p900\nf9\nn127.0.0.1:1338")
			helpers.assert_eq(results.jan.base_url, "http://127.0.0.1:1338/v1")
			helpers.assert_eq(results.jan.source, "listening")
		end)
	end)

	helpers.it("an unreadable process list probes every server at its catalogue port", function()
		with_scanner(function(Scanner, world)
			local results
			Scanner.scan(catalogue_entries(), function(value) results = value end)
			world.runs[1].on_done(false, nil)
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
			helpers.assert_eq(results.jan.source, "default")
			world.runs[1].on_done(true, "900 /Applications/Jan.app/Contents/MacOS/Jan")
			helpers.assert_eq(results.jan.source, "default", "a late answer cannot settle the scan twice")
		end)
	end)
end)
