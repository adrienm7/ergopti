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

helpers.describe("Linux local server port scan commands (local-server-ports)", function()
	--- Runs a scan of the actual catalogue over fake pgrep, ss and ps answers.
	--- @param answers table Program -> { exit_code, stdout, error? }.
	--- @param files table|nil Absolute path -> content.
	--- @return table results
	--- @return table runs The programs run, in order.
	local function scan_with(answers, files)
		local Policy = require("llm.local_server_ports")
		local previous = package.loaded["modules.llm.local_server_ports"]
		package.loaded["modules.llm.local_server_ports"] = nil
		local Scanner = require("modules.llm.local_server_ports")
		package.loaded["modules.llm.local_server_ports"] = previous
		local runs, results = {}, nil
		Scanner._home = function() return "/home/u" end
		Scanner._read_file = function(path) return (files or {})[path] end
		Scanner._run = function(program, args, options, callback)
			runs[#runs + 1] = { program = program, args = args, timeout_ms = options.timeout_ms }
			callback(answers[program] or { exit_code = 1, stdout = "" })
			return true
		end
		local catalogue = read("modules/llm/local_servers.json")
		local entries = {}
		for _, id in ipairs(catalogue.server_order) do
			entries[#entries + 1] = { id = id, descriptor = assert(Policy.descriptor(id, catalogue.servers[id].discovery)),
				base_url = catalogue.servers[id].base_url }
		end
		Scanner.scan(entries, function(value) results = value end)
		return results, runs
	end

	-- What the process runner answers for a command past its deadline
	local TIMED_OUT = { exit_code = -1, stdout = "", error = "pgrep did not finish within 2000 ms" }

	helpers.it("a command-line port needs pgrep only", function()
		local results, runs = scan_with({ pgrep = { exit_code = 0, stdout = "700 /usr/bin/llama-server --port 8181\n" } })
		helpers.assert_eq(#runs, 1)
		helpers.assert_eq(runs[1].program, "pgrep")
		helpers.assert_eq(results.llamacpp.base_url, "http://127.0.0.1:8181/v1")
		helpers.assert_eq(results.omlx.running, false)
	end)

	helpers.it("the process lookup names the catalogue's processes within its budget (omlx-fast-process-lookup)", function()
		local Timings = require("infra.timings")
		local results, runs = scan_with({ pgrep = { exit_code = 1, stdout = "" } })
		helpers.assert_eq(runs[1].program, "pgrep", "no full ps listing of every argument of every process")
		helpers.assert_true(runs[1].args[#runs[1].args]:find("omlx%-server") ~= nil, "the pattern names oMLX's process")
		helpers.assert_eq(runs[1].timeout_ms, Timings.ms("llm", "local_server_process_lookup_timeout_ms"))
		helpers.assert_true(runs[1].timeout_ms <= 2000, "the lookup has its own short deadline")
		helpers.assert_eq(#runs, 1, "no catalogue process (pgrep exit 1) is an answer, not a failure")
		helpers.assert_eq(results.jan.running, false)
	end)

	helpers.it("ss gives the listening port of a running server without a port", function()
		local results, runs = scan_with({
			pgrep = { exit_code = 0, stdout = "900 /opt/Jan/jan\n" },
			ss = { exit_code = 0, stdout = 'LISTEN 0 128 127.0.0.1:1338 0.0.0.0:* users:(("jan",pid=900,fd=30))\n' },
		})
		helpers.assert_eq(runs[2].program, "ss")
		helpers.assert_eq(results.jan.base_url, "http://127.0.0.1:1338/v1")
		helpers.assert_eq(results.jan.source, "listening")
	end)

	helpers.it("a timed-out process list reads the listening ports of a process of the server's name (omlx-ps-timeout-listening)",
		function()
			local results, runs = scan_with({
				pgrep = TIMED_OUT,
				ss = { exit_code = 0, stdout = 'LISTEN 0 128 127.0.0.1:8181 0.0.0.0:* users:(("omlx-server",pid=4242,fd=7))\n' },
				ps = { exit_code = 0, stdout = "4242 omlx-server\n" },
			})
			helpers.assert_eq(runs[2].program, "ss")
			helpers.assert_eq(runs[3].program, "ps")
			helpers.assert_eq(runs[3].args[#runs[3].args], "4242", "only the listening pids are described")
			helpers.assert_eq(results.omlx.source, "listening")
			helpers.assert_eq(results.omlx.base_url, "http://127.0.0.1:8181/v1")
			helpers.assert_eq(results.llamacpp.source, "default")
		end)

	helpers.it("with no reading at all a server falls back to its catalogue port", function()
		local results = scan_with({ pgrep = TIMED_OUT, ss = TIMED_OUT })
		helpers.assert_eq(results.omlx.running, true)
		helpers.assert_eq(results.omlx.source, "default")
	end)
end)
