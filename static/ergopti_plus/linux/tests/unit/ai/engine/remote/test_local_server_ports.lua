--- tests/unit/ai/engine/remote/test_local_server_ports.lua

--- ==============================================================================
--- MODULE: Local Server Port Discovery Contract
--- DESCRIPTION:
--- Replays the shared machine readings (process list, settings files,
--- listening sockets) against the actual catalogue: a server on a non-default
--- port is found, the settings-file port is used, and a server whose process
--- does not run is not probed.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")
local Paths = require("core.fs.engine.paths")

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
	require("tests.lua.core.local_server_ports_contract").run(read("tests/corpus/llm/local_server_ports.json"),
		read("ai/data/local_servers.json"), Json.decode, helpers)
end)

helpers.it("local server settings refuse a FIFO without waiting for its writer", function()
	local uv = require("luv")
	local scanner = require("ai.engine.local_servers.ports")
	local dir = assert(uv.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/ergopti-settings-XXXXXX"))
	local path = dir .. "/settings.json"
	local made = os.execute("mkfifo '" .. path .. "'")
	assert(made == true or made == 0)
	local exited, process = false, nil
	process = assert(uv.spawn("sh", { args = { "-c", 'sleep 1; printf settings > "$1"', "fixture", path } }, function()
		exited = true
		process:close()
	end))
	local content = scanner._read_file(path)
	os.remove(path)
	os.remove(dir)
	while not exited do uv.run("once") end
	helpers.assert_eq(content, nil, "a FIFO must not be treated as local server settings")
end)

helpers.it("local server settings reject oversized files instead of decoding a valid prefix", function()
	local uv = require("luv")
	local scanner = require("ai.engine.local_servers.ports")
	local dir = assert(uv.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/ergopti-settings-limit-XXXXXX"))
	local path = dir .. "/settings.json"
	local prefix = '{"port":1234}'
	local file = assert(io.open(path, "wb"))
	assert(file:write(prefix .. string.rep(" ", 1048576 - #prefix) .. "invalid"))
	assert(file:close())
	local content = scanner._read_file(path)
	os.remove(path)
	os.remove(dir)
	helpers.assert_nil(content, "a truncated valid prefix must not be used as the complete settings")
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
		local Policy = require("ai.engine.local_servers.ports_core")
		local previous = package.loaded["ai.engine.local_servers.ports"]
		package.loaded["ai.engine.local_servers.ports"] = nil
		local Scanner = require("ai.engine.local_servers.ports")
		package.loaded["ai.engine.local_servers.ports"] = previous
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
		local catalogue = read("ai/data/local_servers.json")
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

	helpers.it("truncated process arguments do not invent a port", function()
		local limit = require("core.timing.engine.timings").count("limits", "proc_cmdline_bytes")
		local prefix = "/usr/bin/llama-server\0" .. string.rep("x", limit - #"/usr/bin/llama-server\0" - #"\0--port=8") .. "\0--port=8"
		local results = scan_with({ [700] = prefix .. "181\0" })
		helpers.assert_true(results.llamacpp.port ~= 8, "a truncated 8181 port must not become port 8")
	end)

	helpers.it("a final process slice that exceeds the deadline is not accepted", function()
		local Timings = require("core.timing.engine.timings")
		local budget = Timings.ms("llm", "local_server_process_lookup_timeout_ms")
		local calls = 0
		local _, runs = scan_with({ [700] = "/usr/bin/llama-server\0--port\0008181\0" }, nil, function()
			calls = calls + 1
			return calls == 1 and 0 or budget + 1
		end)
		helpers.assert_eq(runs[1].program, "ss", "a late final slice must fall back to listener discovery")
	end)

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

	helpers.it("does not trust ss output when process supervision reports an error after exit zero", function()
		local results = scan_with({ [900] = "/opt/Jan/jan\0" }, {
			ss = { exit_code = 0, error = "ss did not finish: native process group outlived leader",
				stdout = 'LISTEN 0 128 127.0.0.1:1338 0.0.0.0:* users:(("jan",pid=900,fd=30))\n' },
		})
		helpers.assert_eq(results.jan.source, "default")
		helpers.assert_true(results.jan.port ~= 1338, "failed supervision cannot establish a listener")
	end)

	helpers.it("a walk past its budget falls back to the listening pids, described from /proc (omlx-ps-timeout-listening)",
		function()
			local Timings = require("core.timing.engine.timings")
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
		local Policy = require("ai.engine.local_servers.ports_core")
		local previous = package.loaded["ai.engine.local_servers.ports"]
		package.loaded["ai.engine.local_servers.ports"] = nil
		local Scanner = require("ai.engine.local_servers.ports")
		package.loaded["ai.engine.local_servers.ports"] = previous
		Scanner._proc_root = "/nonexistent/ergopti-proc"
		Scanner._home = function() return "/home/u" end
		Scanner._read_file = function() return nil end
		Scanner._run = function(_, _, _, callback) callback({ exit_code = -1, stdout = "", error = "timed out" }); return true end
		local catalogue = read("ai/data/local_servers.json")
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
	local Policy = require("ai.engine.local_servers.ports_core")
	local catalogue = read("ai/data/local_servers.json")

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

for _, kind in ipairs({ "settings", "proc" }) do
	for _, fault in ipairs({ "read_throw", "read_nil", "close_throw", "close_false" }) do
		helpers.it("local server " .. kind .. " refuses incomplete read " .. fault, function()
			local Scanner, Reader = require("ai.engine.local_servers.ports"), require("core.fs.engine.regular_file_reader")
			local original_open, original_reader = io.open, Reader.open_source
			local closed, maximum = 0, nil
			local stream = { read = function(_, limit)
				maximum = limit
				if fault == "read_throw" then error("injected read error") end
				if fault == "read_nil" then return nil, "injected read error" end
				return "synthetic valid data"
			end, close = function()
				closed = closed + 1
				if fault == "close_throw" then error("injected close error") end
				return fault ~= "close_false"
			end }
			if kind == "settings" then Reader.open_source = function() return stream end
			else io.open = function() return stream end end
			local called, value = pcall(kind == "settings" and Scanner._read_file or Scanner._read_cmdline,
				kind == "settings" and "/synthetic/settings.json" or 42)
			io.open, Reader.open_source = original_open, original_reader
			helpers.assert_true(called, "failed kernel or settings read must not escape discovery")
			helpers.assert_nil(value, "unacknowledged data is not valid discovery evidence")
			helpers.assert_eq(closed, 1, "every opened stream is closed")
			helpers.assert_true(type(maximum) == "number" and maximum > 0, "the read remains bounded")
		end)
	end
end

helpers.it("(local-port-owned) waits for the exact cancelled slice timer close", function()
	local scanner = require("ai.engine.local_servers.ports")
	local list, read_cmdline, timer = scanner._list_proc, scanner._read_cmdline, scanner._owned_timer
	local close_ack, cancelled, callback_count = false, 0, 0
	local pids = {}
	for i = 1, 129 do pids[i] = tostring(i) end
	scanner._list_proc = function() return pids end
	scanner._read_cmdline = function() return nil end
	scanner._owned_timer = function()
		return { started = true, cancel = function() cancelled = cancelled + 1; return true end,
			is_settled = function() return close_ack end }
	end
	local ok, err = pcall(function()
		local scan = scanner.scan_owned({ { id = "test", descriptor = { process_names = { "test" }, command_lines = {} },
			base_url = "http://127.0.0.1:8000" } }, function() callback_count = callback_count + 1 end)
		helpers.assert_eq(scan:is_settled(), false)
		helpers.assert_eq(scan:cancel(), false)
		helpers.assert_eq(cancelled, 1)
		helpers.assert_eq(callback_count, 0)
		close_ack = true
		helpers.assert_eq(scan:is_settled(), true)
	end)
	scanner._list_proc, scanner._read_cmdline, scanner._owned_timer = list, read_cmdline, timer
	assert(ok, err)
end)

helpers.it("(local-port-owned) waits for the exact cancelled ss process receipt", function()
	local scanner = require("ai.engine.local_servers.ports")
	local list, read_cmdline, process = scanner._list_proc, scanner._read_cmdline, scanner._owned_process
	local close_ack, cancelled, callback_count = false, 0, 0
	scanner._list_proc = function() return { "1" } end
	scanner._read_cmdline = function() return "/usr/bin/omlx-server\0" end
	scanner._owned_process = function()
		return { started = true, cancel = function() cancelled = cancelled + 1; return true end,
			is_settled = function() return close_ack end }
	end
	local ok, err = pcall(function()
		local descriptor = read("ai/data/local_servers.json").servers.omlx.discovery
		descriptor.address_flags = {}
		local scan = scanner.scan_owned({ { id = "omlx", descriptor = descriptor,
			base_url = "http://127.0.0.1:8000/v1" } }, function() callback_count = callback_count + 1 end)
		helpers.assert_eq(scan:cancel(), false)
		helpers.assert_eq(cancelled, 1)
		helpers.assert_eq(callback_count, 0)
		close_ack = true
		helpers.assert_eq(scan:is_settled(), true)
	end)
	scanner._list_proc, scanner._read_cmdline, scanner._owned_process = list, read_cmdline, process
	assert(ok, err)
end)

helpers.it("(local-port-owned) a real slice timer acknowledges close before settlement", function()
	local scanner, uv = require("ai.engine.local_servers.ports"), require("luv")
	local list, read_cmdline = scanner._list_proc, scanner._read_cmdline
	local pids, deliveries = {}, 0
	for i = 1, 129 do pids[i] = tostring(i) end
	scanner._list_proc = function() return pids end
	scanner._read_cmdline = function() return nil end
	local ok, err = pcall(function()
		local scan = scanner.scan_owned({ { id = "test", descriptor = { process_names = { "test" }, command_lines = {} },
			base_url = "http://127.0.0.1:8000" } }, function() deliveries = deliveries + 1 end)
		helpers.assert_eq(scan:cancel(), false, "scheduled close is not a native close ACK")
		for _ = 1, 100 do if scan:is_settled() then break end; uv.run("nowait") end
		helpers.assert_eq(scan:is_settled(), true)
		helpers.assert_eq(deliveries, 0)
	end)
	scanner._list_proc, scanner._read_cmdline = list, read_cmdline
	assert(ok, err)
end)

helpers.it("(local-port-owned) a real process acknowledges exit and closure before settlement", function()
	local scanner, uv = require("ai.engine.local_servers.ports"), require("luv")
	local list, read_cmdline, process = scanner._list_proc, scanner._read_cmdline, scanner._owned_process
	local deliveries = 0
	scanner._list_proc = function() return { "1" } end
	scanner._read_cmdline = function() return "/usr/bin/omlx-server\0" end
	scanner._owned_process = function(_, _, options, callback)
		return require("core.process.adapters.owned_process").start("/bin/sleep", { "10" }, options, callback)
	end
	local ok, err = pcall(function()
		local descriptor = read("ai/data/local_servers.json").servers.omlx.discovery
		descriptor.address_flags = {}
		local scan = scanner.scan_owned({ { id = "omlx", descriptor = descriptor,
			base_url = "http://127.0.0.1:8000/v1" } }, function() deliveries = deliveries + 1 end)
		helpers.assert_eq(scan:cancel(), false)
		for _ = 1, 2000 do
			if scan:is_settled() then break end
			uv.run("nowait")
			uv.sleep(1)
		end
		helpers.assert_eq(scan:is_settled(), true)
		helpers.assert_eq(deliveries, 0)
	end)
	scanner._list_proc, scanner._read_cmdline, scanner._owned_process = list, read_cmdline, process
	assert(ok, err)
end)

helpers.it("(local-port-owned) a throwing timer constructor keeps uncertain debt and publishes nothing", function()
	local scanner = require("ai.engine.local_servers.ports")
	local list, read_cmdline, timer = scanner._list_proc, scanner._read_cmdline, scanner._owned_timer
	local pids, deliveries = {}, 0
	for i = 1, 129 do pids[i] = tostring(i) end
	scanner._list_proc = function() return pids end
	scanner._read_cmdline = function() return nil end
	scanner._owned_timer = function() error("synthetic constructor failure") end
	local ok, err = pcall(function()
		local scan = scanner.scan_owned({ { id = "test", descriptor = { process_names = { "test" }, command_lines = {} },
			base_url = "http://127.0.0.1:8000" } }, function() deliveries = deliveries + 1 end)
		helpers.assert_eq(scan:cancel(), false)
		helpers.assert_eq(scan:is_settled(), false)
		helpers.assert_eq(deliveries, 0)
	end)
	scanner._list_proc, scanner._read_cmdline, scanner._owned_timer = list, read_cmdline, timer
	assert(ok, err)
end)

helpers.it("(local-port-owned) a refused process waits for its native close before completing", function()
	local scanner = require("ai.engine.local_servers.ports")
	local list, read_cmdline, process = scanner._list_proc, scanner._read_cmdline, scanner._owned_process
	local closed, listener, process_callback, deliveries = false, nil, nil, 0
	scanner._list_proc = function() return { "1" } end
	scanner._read_cmdline = function() return "/usr/bin/omlx-server\0" end
	scanner._owned_process = function(_, _, _, callback)
		process_callback = callback
		return { started = false, error = "refused", cancel = function() return true end,
			is_settled = function() return closed end, on_settled = function(_, fn) listener = fn; return true end }
	end
	local ok, err = pcall(function()
		local descriptor = read("ai/data/local_servers.json").servers.omlx.discovery
		descriptor.address_flags = {}
		local scan = scanner.scan_owned({ { id = "omlx", descriptor = descriptor,
			base_url = "http://127.0.0.1:8000/v1" } }, function() deliveries = deliveries + 1 end)
		helpers.assert_eq(deliveries, 0)
		helpers.assert_eq(scan:is_settled(), false)
		closed = true
		process_callback({ exit_code = -1, error = "refused" })
		listener()
		helpers.assert_eq(deliveries, 1, "physical completion and settlement notification are one result")
		helpers.assert_eq(scan:is_settled(), true)
	end)
	scanner._list_proc, scanner._read_cmdline, scanner._owned_process = list, read_cmdline, process
	assert(ok, err)
end)

helpers.it("(local-port-owned) a refused slice waits for its native close before fallback", function()
	local scanner = require("ai.engine.local_servers.ports")
	local list, read_cmdline, timer, process = scanner._list_proc, scanner._read_cmdline, scanner._owned_timer, scanner._owned_process
	local pids, closed, listener, starts, deliveries = {}, false, nil, 0, 0
	for i = 1, 129 do pids[i] = tostring(i) end
	scanner._list_proc = function() return pids end
	scanner._read_cmdline = function() return nil end
	scanner._owned_timer = function()
		return { started = false, cancel = function() return true end,
			is_settled = function() return closed end, on_settled = function(_, fn) listener = fn; return true end }
	end
	scanner._owned_process = function()
		starts = starts + 1
		return { started = false, error = "refused", cancel = function() return true end,
			is_settled = function() return true end }
	end
	local ok, err = pcall(function()
		local raw = read("ai/data/local_servers.json").servers.omlx.discovery
		local descriptor = assert(require("ai.engine.local_servers.ports_core").descriptor("omlx", raw))
		local scan = scanner.scan_owned({ { id = "omlx", descriptor = descriptor,
			base_url = "http://127.0.0.1:8000/v1" } }, function() deliveries = deliveries + 1 end)
		helpers.assert_eq(starts, 0)
		helpers.assert_eq(deliveries, 0)
		helpers.assert_eq(scan:is_settled(), false)
		closed = true
		listener()
		helpers.assert_eq(deliveries, 1)
		helpers.assert_eq(scan:is_settled(), true)
	end)
	scanner._list_proc, scanner._read_cmdline, scanner._owned_timer, scanner._owned_process = list, read_cmdline, timer, process
	assert(ok, err)
end)

helpers.it("(local-port-owned) a physically settled child retains its active callback frame", function()
	local scanner = require("ai.engine.local_servers.ports")
	local list, read_cmdline, process = scanner._list_proc, scanner._read_cmdline, scanner._owned_process
	local callback, closed, during = nil, false, nil
	scanner._list_proc = function() return { "1" } end
	scanner._read_cmdline = function() return "/usr/bin/omlx-server\0" end
	scanner._owned_process = function(_, _, _, done)
		callback = done
		return { started = true, cancel = function() return true end, is_settled = function() return closed end }
	end
	local ok, err = pcall(function()
		local descriptor = assert(require("ai.engine.local_servers.ports_core").descriptor("omlx",
			read("ai/data/local_servers.json").servers.omlx.discovery))
		local scan
		scan = scanner.scan_owned({ { id = "omlx", descriptor = descriptor,
			base_url = "http://127.0.0.1:8000/v1" } }, function() during = scan:cancel() end)
		helpers.assert_type(callback, "function")
		closed = true
		callback({ exit_code = 0, stdout = "" })
		helpers.assert_eq(during, false, "the business callback still owns its stack")
		helpers.assert_eq(scan:is_settled(), true)
	end)
	scanner._list_proc, scanner._read_cmdline, scanner._owned_process = list, read_cmdline, process
	assert(ok, err)
end)

helpers.it("(local-port-owned) a missing observer retains only the known timer debt", function()
	local scanner = require("ai.engine.local_servers.ports")
	local list, read_cmdline, timer = scanner._list_proc, scanner._read_cmdline, scanner._owned_timer
	local pids, closed, deliveries = {}, false, 0
	for i = 1, 129 do pids[i] = tostring(i) end
	scanner._list_proc = function() return pids end
	scanner._read_cmdline = function() return nil end
	scanner._owned_timer = function()
		return { started = false, cancel = function() return true end, is_settled = function() return closed end }
	end
	local ok, err = pcall(function()
		local scan = scanner.scan_owned({ { id = "test", descriptor = { process_names = { "test" }, command_lines = {} },
			base_url = "http://127.0.0.1:8000" } }, function() deliveries = deliveries + 1 end)
		helpers.assert_eq(scan.failed, true)
		helpers.assert_eq(scan:is_settled(), false)
		closed = true
		helpers.assert_eq(scan:is_settled(), true)
		helpers.assert_eq(deliveries, 0)
	end)
	scanner._list_proc, scanner._read_cmdline, scanner._owned_timer = list, read_cmdline, timer
	assert(ok, err)
end)

helpers.it("(local-port-owned) joins an overlapping slice close and ss process", function()
	local scanner = require("ai.engine.local_servers.ports")
	local list, read_cmdline, timer, process = scanner._list_proc, scanner._read_cmdline, scanner._owned_timer, scanner._owned_process
	local pids, timer_done, process_done, fire, timer_cancel, process_cancel = {}, false, false, nil, 0, 0
	for i = 1, 129 do pids[i] = tostring(i) end
	scanner._list_proc = function() return pids end
	scanner._read_cmdline = function(pid) if pid == 1 then return "/usr/bin/omlx-server\0" end end
	scanner._owned_timer = function(_, callback)
		fire = callback
		return { started = true, cancel = function() timer_cancel = timer_cancel + 1; return true end,
			is_settled = function() return timer_done end }
	end
	scanner._owned_process = function()
		return { started = true, cancel = function() process_cancel = process_cancel + 1; return true end,
			is_settled = function() return process_done end }
	end
	local ok, err = pcall(function()
		local descriptor = assert(require("ai.engine.local_servers.ports_core").descriptor("omlx",
			read("ai/data/local_servers.json").servers.omlx.discovery))
		local scan = scanner.scan_owned({ { id = "omlx", descriptor = descriptor,
			base_url = "http://127.0.0.1:8000/v1" } }, function() error("cancelled scan published") end)
		helpers.assert_type(fire, "function")
		fire()
		helpers.assert_eq(scan:cancel(), false)
		helpers.assert_eq(timer_cancel, 1)
		helpers.assert_eq(process_cancel, 1)
		timer_done = true
		helpers.assert_eq(scan:is_settled(), false, "ss still owns its native process")
		process_done = true
		helpers.assert_eq(scan:is_settled(), true)
	end)
	scanner._list_proc, scanner._read_cmdline, scanner._owned_timer, scanner._owned_process = list, read_cmdline, timer, process
	assert(ok, err)
end)

helpers.it("review-scan-admit: an admission callback remains active after native settlement", function()
	local scanner = require("ai.engine.local_servers.ports")
	local list, read_cmdline, process = scanner._list_proc, scanner._read_cmdline, scanner._owned_process
	local callback, closed, during, armed, scan = nil, false, nil, false, nil
	scanner._list_proc = function() return { "1" } end
	scanner._read_cmdline = function() return "/usr/bin/omlx-server\0" end
	scanner._owned_process = function(_, _, _, done)
		callback = done
		return { started = true, cancel = function() return true end, is_settled = function() return closed end }
	end
	local ok, err = pcall(function()
		local descriptor = assert(require("ai.engine.local_servers.ports_core").descriptor("omlx",
			read("ai/data/local_servers.json").servers.omlx.discovery))
		scan = scanner.scan_owned({ { id = "omlx", descriptor = descriptor,
			base_url = "http://127.0.0.1:8000/v1" } }, function() end,
			function() if armed then during = scan:cancel() end; return true end)
		closed, armed = true, true
		callback({ exit_code = 0, stdout = "" })
		helpers.assert_eq(during, false, "admission still executes within the native callback")
	end)
	scanner._list_proc, scanner._read_cmdline, scanner._owned_process = list, read_cmdline, process
	assert(ok, err)
end)


helpers.it("(local-port-owned) child cancellation cannot acknowledge its active cancel frame", function()
	local scanner = require("ai.engine.local_servers.ports")
	local list, read_cmdline, process = scanner._list_proc, scanner._read_cmdline, scanner._owned_process
	local closed, during, scan = false, nil, nil
	scanner._list_proc = function() return { "1" } end
	scanner._read_cmdline = function() return "/usr/bin/omlx-server\0" end
	scanner._owned_process = function()
		return { started = true, cancel = function() closed = true; during = scan:is_settled(); return true end,
			is_settled = function() return closed end }
	end
	local ok, err = pcall(function()
		local descriptor = assert(require("ai.engine.local_servers.ports_core").descriptor("omlx",
			read("ai/data/local_servers.json").servers.omlx.discovery))
		scan = scanner.scan_owned({ { id = "omlx", descriptor = descriptor,
			base_url = "http://127.0.0.1:8000/v1" } }, function() end)
		helpers.assert_eq(scan:cancel(), true)
		helpers.assert_eq(during, false)
	end)
	scanner._list_proc, scanner._read_cmdline, scanner._owned_process = list, read_cmdline, process
	assert(ok, err)
end)

helpers.it("(local-port-owned) nested settlement observation cannot acknowledge itself", function()
	local scanner = require("ai.engine.local_servers.ports")
	local list, read_cmdline, process = scanner._list_proc, scanner._read_cmdline, scanner._owned_process
	local armed, during, scan = false, nil, nil
	scanner._list_proc = function() return { "1" } end
	scanner._read_cmdline = function() return "/usr/bin/omlx-server\0" end
	scanner._owned_process = function()
		return { started = true, cancel = function() return true end, is_settled = function()
			if armed then armed = false; during = scan:cancel() end
			return true
		end }
	end
	local ok, err = pcall(function()
		local descriptor = assert(require("ai.engine.local_servers.ports_core").descriptor("omlx",
			read("ai/data/local_servers.json").servers.omlx.discovery))
		scan = scanner.scan_owned({ { id = "omlx", descriptor = descriptor,
			base_url = "http://127.0.0.1:8000/v1" } }, function() end)
		armed = true
		helpers.assert_eq(scan:cancel(), true)
		helpers.assert_eq(during, false)
	end)
	scanner._list_proc, scanner._read_cmdline, scanner._owned_process = list, read_cmdline, process
	assert(ok, err)
end)
