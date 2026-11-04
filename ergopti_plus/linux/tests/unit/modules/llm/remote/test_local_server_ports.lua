--- tests/unit/modules/llm/remote/test_local_server_ports.lua

--- ==============================================================================
--- MODULE: Local Server Port Discovery Contract
--- DESCRIPTION:
--- Replays the shared machine readings (process list, settings files,
--- listening sockets) against the actual catalogue: a server on a non-default
--- port is found, the settings-file port is used, and a server whose process
--- does not run is not probed.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Paths = require("infra.paths")

--- Reads one shared JSON file.
--- @param relative string
--- @return table
local function read(relative)
	local file = assert(io.open(Paths.shared(relative), "rb"))
	local root = assert(Json.decode(file:read("*a")))
	file:close()
	return root
end

helpers.describe("Local server port discovery (local-server-ports)", function()
	require("test.local_server_ports_contract").run(read("tests/corpus/llm/local_server_ports.json"),
		read("modules/llm/local_servers.json"), Json.decode, helpers)
end)

helpers.describe("Linux local server port scan from /proc (local-server-ports)", function()
	local uv = require("luv")

	--- Writes a /proc fixture: one folder per pid, holding its cmdline unless
	--- the pid is false (a process that vanished between the listing and the read).
	--- @param processes table Pid -> NUL-separated command line, or false.
	--- @return string root
	local function proc_fixture(processes)
		local root = assert(uv.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/ergopti-proc-XXXXXX"))
		assert(uv.fs_mkdir(root .. "/self", 448))
		for pid, cmdline in pairs(processes) do
			assert(uv.fs_mkdir(root .. "/" .. pid, 448))
			if cmdline then
				local file = assert(io.open(root .. "/" .. pid .. "/cmdline", "wb"))
				file:write(cmdline)
				file:close()
			end
		end
		return root
	end

	--- Runs a scan of the actual catalogue over a /proc fixture and fake ss.
	--- @param processes table Pid -> cmdline or false (see proc_fixture).
	--- @param answers table|nil Program -> { exit_code, stdout, error? } of the process runner.
	--- @param clock function|nil Replaces the monotonic clock.
	--- @return table results
	--- @return table runs The programs run, in order.
	local function scan_with(processes, answers, clock)
		local Policy = require("llm.local_server_ports")
		local previous = package.loaded["modules.llm.local_server_ports"]
		package.loaded["modules.llm.local_server_ports"] = nil
		local Scanner = require("modules.llm.local_server_ports")
		package.loaded["modules.llm.local_server_ports"] = previous
		local root = proc_fixture(processes)
		local runs, results = {}, nil
		Scanner._proc_root = root
		Scanner._home = function() return "/home/u" end
		Scanner._read_file = function() return nil end
		Scanner._defer = function(fn) fn(); return true end
		if clock then Scanner._now_ms = clock end
		Scanner._run = function(program, args, options, callback)
			runs[#runs + 1] = { program = program, args = args, timeout_ms = options.timeout_ms }
			callback((answers or {})[program] or { exit_code = 1, stdout = "" })
			return true
		end
		local catalogue = read("modules/llm/local_servers.json")
		local entries = {}
		for _, id in ipairs(catalogue.server_order) do
			entries[#entries + 1] = { id = id, descriptor = assert(Policy.descriptor(id, catalogue.servers[id].discovery)),
				base_url = catalogue.servers[id].base_url }
		end
		local ok, err = pcall(Scanner.scan, entries, function(value) results = value end)
		os.execute("rm -rf '" .. root .. "'")
		assert(ok, err)
		return results, runs
	end

	-- What busybox answers to procps-only flags: the old scan read it as no server
	local BUSYBOX = { exit_code = 1, stdout = "", error = "pgrep: unrecognized option: a" }

	helpers.it("a command-line port is read from /proc with no external tool (linux-proc-scan)", function()
		local results, runs = scan_with({
			[700] = "/usr/bin/llama-server\0--port\0008181\0",
			[701] = "/usr/lib/firefox/firefox\0-contentproc\0",
		}, { pgrep = BUSYBOX, ps = BUSYBOX })
		helpers.assert_eq(#runs, 0, "neither pgrep nor ps runs")
		helpers.assert_eq(results.llamacpp.running, true)
		helpers.assert_eq(results.llamacpp.base_url, "http://127.0.0.1:8181/v1")
		helpers.assert_eq(results.omlx.running, false)
	end)

	helpers.it("the /proc match ignores case like pgrep -i (linux-proc-scan)", function()
		local results = scan_with({ [702] = "/opt/OMLX-Server\0--port\0009191\0" }, { pgrep = BUSYBOX })
		helpers.assert_eq(results.omlx.running, true)
		helpers.assert_eq(results.omlx.port, 9191)
	end)

	helpers.it("a vanished pid and a kernel thread are skipped, not a failure (linux-proc-scan)", function()
		local results, runs = scan_with({
			[800] = false,
			[801] = "",
			[802] = "/usr/bin/llama-server\0--port\0008282\0",
		})
		helpers.assert_eq(#runs, 0, "the listing still counts: no fallback to every listening socket")
		helpers.assert_eq(results.llamacpp.port, 8282)
	end)

	helpers.it("ss gives the listening port of a running server without a port", function()
		local results, runs = scan_with({ [900] = "/opt/Jan/jan\0" }, {
			ss = { exit_code = 0, stdout = 'LISTEN 0 128 127.0.0.1:1338 0.0.0.0:* users:(("jan",pid=900,fd=30))\n' },
		})
		helpers.assert_eq(runs[1].program, "ss")
		helpers.assert_eq(results.jan.base_url, "http://127.0.0.1:1338/v1")
		helpers.assert_eq(results.jan.source, "listening")
	end)

	helpers.it("a walk past its budget falls back to the listening pids, described from /proc (omlx-ps-timeout-listening)",
		function()
			local Timings = require("infra.timings")
			local budget = Timings.ms("llm", "local_server_process_lookup_timeout_ms")
			local processes = { [4242] = "omlx-server\0" }
			for pid = 1, 300 do processes[pid] = "sleep\0001\0" end
			local now = 0
			-- Each reading moves past the lookup budget, never past the scan budget
			local results, runs = scan_with(processes, {
				ss = { exit_code = 0, stdout = 'LISTEN 0 128 127.0.0.1:8181 0.0.0.0:* users:(("omlx-server",pid=4242,fd=7))\n' },
			}, function() now = now + budget + 1; return now end)
			helpers.assert_eq(runs[1].program, "ss", "the deadline settled the walk as unread")
			helpers.assert_eq(#runs, 1, "the listening pid is described from /proc, not by ps")
			helpers.assert_eq(results.omlx.source, "listening")
			helpers.assert_eq(results.omlx.base_url, "http://127.0.0.1:8181/v1")
			helpers.assert_eq(results.llamacpp.source, "default")
		end)

	helpers.it("an unreadable /proc falls back to the catalogue port", function()
		local Policy = require("llm.local_server_ports")
		local previous = package.loaded["modules.llm.local_server_ports"]
		package.loaded["modules.llm.local_server_ports"] = nil
		local Scanner = require("modules.llm.local_server_ports")
		package.loaded["modules.llm.local_server_ports"] = previous
		Scanner._proc_root = "/nonexistent/ergopti-proc"
		Scanner._home = function() return "/home/u" end
		Scanner._read_file = function() return nil end
		Scanner._run = function(_, _, _, callback) callback({ exit_code = -1, stdout = "", error = "timed out" }); return true end
		local catalogue = read("modules/llm/local_servers.json")
		local entries = {}
		for _, id in ipairs(catalogue.server_order) do
			entries[#entries + 1] = { id = id, descriptor = assert(Policy.descriptor(id, catalogue.servers[id].discovery)),
				base_url = catalogue.servers[id].base_url }
		end
		local results
		Scanner.scan(entries, function(value) results = value end)
		helpers.assert_eq(results.omlx.running, true)
		helpers.assert_eq(results.omlx.source, "default")
	end)
end)

helpers.describe("Shared process pattern matcher (local-server-ports)", function()
	local Policy = require("llm.local_server_ports")
	local catalogue = read("modules/llm/local_servers.json")

	helpers.it("agrees with matches() on every catalogue descriptor (linux-proc-scan)", function()
		local entries = {}
		for _, id in ipairs(catalogue.server_order) do
			entries[#entries + 1] = { descriptor = assert(Policy.descriptor(id, catalogue.servers[id].discovery)) }
		end
		local matches = Policy.process_matcher(Policy.process_pattern(entries))
		for _, entry in ipairs(entries) do
			for _, name in ipairs(entry.descriptor.process_names) do
				helpers.assert_true(matches("/usr/bin/" .. name:upper() .. " --port 1"), name .. " after a path, any case")
				helpers.assert_true(matches(name .. ".exe"), name .. ".exe at the start")
				helpers.assert_eq(matches("/usr/bin/" .. name .. "x"), false, name .. " is a whole file name")
			end
			for _, fragment in ipairs(entry.descriptor.command_lines) do
				helpers.assert_true(matches("python3 " .. fragment:upper() .. " --x"), fragment .. " as a substring")
			end
		end
		helpers.assert_eq(matches("/usr/lib/firefox/firefox -contentproc"), false)
	end)

	helpers.it("refuses a pattern outside its grammar", function()
		helpers.assert_eq(pcall(Policy.process_matcher, "a.*b"), false)
		helpers.assert_eq(pcall(Policy.process_matcher, ""), false)
	end)
end)
