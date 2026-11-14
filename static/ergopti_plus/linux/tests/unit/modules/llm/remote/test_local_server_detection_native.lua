--- tests/unit/modules/llm/remote/test_local_server_detection_native.lua

--- ==============================================================================
--- MODULE: Local Server Detection Against Real Processes (Linux)
--- DESCRIPTION:
--- Starts one stand-in process per catalogue launch, with the command line the
--- real server shows (python -m sglang.launch_server, the KoboldCpp
--- release binary, a .llamafile, lemond, /app/model-runner, ...), each serving
--- the OpenAI models endpoint on a loopback port. The production Linux scan
--- (modules/llm/local_server_ports.lua: real /proc, real ss, a real settings
--- file) must find each one at the port its command line, settings file or
--- listening socket gives, and report every other server stopped.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")
local uv = require("luv")

local restore = helpers.keep_loaded({ "modules.llm.local_server_ports" })

local CATALOGUE = Json.decode(assert(io.open(require("core.fs.engine.paths").shared("ai/data/local_servers.json"), "rb")):read("*a"))

-- Answers GET <anything>/models like an OpenAI-compatible server. The port
-- comes from the flag the real server takes, else from FAKE_PORT.
local SERVER = [[
import http.server, json, os, socket, sys
port = None
for flag in ("--port", "--api-port"):
    if flag in sys.argv:
        port = int(sys.argv[sys.argv.index(flag) + 1])
port = port or int(os.environ["FAKE_PORT"])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"object": "list", "data": [{"id": "fake", "object": "model"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(("127.0.0.1", port), Handler, bind_and_activate=False)
server.socket.close()
server.socket = socket.socket(fileno=3)
server.server_address = server.socket.getsockname()
server.server_name, server.server_port = server.server_address
assert server.server_port == port
with open(os.environ["FAKE_READY"], "w") as ready:
    ready.write(str(port))
server.serve_forever()
]]

-- One launch per row: the script path (relative to the scratch folder) the
-- command line shows, its arguments, the port it listens on and how the scan
-- must find it. A port only in FAKE_PORT is found from the listening socket.
local LAUNCHES = {
	{ server = "sglang", module = "sglang.launch_server", args = { "--model-path", "Qwen/Qwen3-4B", "--port", "{PORT}" },
		source = "cli" },
	{ server = "koboldcpp", script = "koboldcpp-linux-x64", args = { "--model", "q.gguf", "--port", "{PORT}" },
		source = "cli" },
	{ server = "textgen_webui", script = "text-generation-webui/server.py", args = { "--api", "--api-port", "{PORT}" },
		source = "cli" },
	{ server = "gpt4all", script = "gpt4all/bin/chat", args = {}, source = "listening" },
	{ server = "lemonade", script = "bin/lemond", args = {}, source = "config" },
	{ server = "docker_model_runner", script = "app/model-runner", args = {}, source = "listening" },
	{ server = "exo", script = "venv/bin/exo", args = { "--api-port", "{PORT}" }, source = "cli" },
	{ server = "llamacpp", script = "models/Qwen3-4B.llamafile", args = { "--server", "--port", "{PORT}" },
		source = "cli" },
	{ server = "vllm", script = "venv/bin/vllm", args = { "serve", "Qwen/Qwen3-4B", "--port", "{PORT}" },
		source = "cli" },
	{ server = "tabbyapi", script = "tabbyAPI/start.py", args = { "--port", "{PORT}" }, source = "cli" },
}

--- Writes a file, creating its folders.
--- @param path string
--- @param text string
local function write(path, text)
	local folder = path:match("^(.*)/[^/]+$")
	local built = ""
	for part in folder:gmatch("[^/]+") do
		built = built .. "/" .. part
		uv.fs_mkdir(built, 448)
	end
	local file = assert(io.open(path, "wb"))
	file:write(text)
	file:close()
end

--- Milliseconds of the monotonic clock. The loop's cached uv.now() moves only
--- when the loop runs, and handles other suites left in it make it jump.
--- @return number
local function now_ms() return uv.hrtime() / 1e6 end

--- Whether a loopback port accepts a connection now.
--- @param port number
--- @return boolean
local function accepting(port)
	local socket, answer = uv.new_tcp(), nil
	socket:connect("127.0.0.1", port, function(failure) answer = failure == nil end)
	local deadline = now_ms() + 1000
	while answer == nil and now_ms() < deadline do uv.run("nowait"); uv.sleep(5) end
	socket:close()
	uv.run("nowait")
	return answer == true
end

helpers.describe("Local server detection against real processes (local-server-detection-native)", function()
	helpers.it("(local-server-detection-native) the real Linux scan finds every catalogue launch at its port", function()
		-- The driver reads processes from /proc and listening sockets with ss
		-- only (busybox has no ss): without it every row without a port in its
		-- command line or settings file would read at its catalogue default
		local status = os.execute("command -v ss >/dev/null 2>&1")
		assert(status == 0 or status == true, "ss is required to scan local servers")
		local root = assert(uv.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/ergopti-local-servers-XXXXXX"))
		local home = root .. "/home"
		local processes, reservations, started, launches = {}, {}, {}, {}
		local ok, err = pcall(function()
			for _, spec in ipairs(LAUNCHES) do
				local launch = {}
				for key, value in pairs(spec) do launch[key] = value end
				launches[#launches + 1] = launch
				-- Keep the kernel-assigned port reserved until the child inherits the
				-- listening socket. No fixed port or close/rebind race is involved.
				local reservation = assert(uv.new_tcp())
				reservations[#reservations + 1] = reservation
				assert(reservation:bind("127.0.0.1", 0))
				assert(reservation:listen(16, function() end))
				local port = assert(reservation:getsockname()).port
				launch.port = port
				launch.ready = root .. "/" .. launch.server .. ".ready"
				if launch.server == "lemonade" then
					write(home .. "/.config/lemonade/config.json", Json.encode({ port = port, host = "localhost" }))
				end
				local args, cwd = {}, root
				if launch.module then
					-- A regular package on PYTHONPATH: python -m never depends on the cwd
					local package_dir = root .. "/" .. launch.module:match("^([^.]+)")
					write(package_dir .. "/__init__.py", "")
					write(root .. "/" .. launch.module:gsub("%.", "/") .. ".py", SERVER)
					args = { "-m", launch.module }
				else
					write(root .. "/" .. launch.script, SERVER)
					args = { root .. "/" .. launch.script }
				end
				for _, value in ipairs(launch.args) do
					args[#args + 1] = value == "{PORT}" and tostring(port) or value
				end
				local handle, pid = uv.spawn("python3", { args = args, cwd = cwd,
					stdio = { 0, 1, 2, assert(uv.fileno(reservation)) },
					env = { "PATH=" .. (os.getenv("PATH") or "/usr/bin:/bin"), "FAKE_PORT=" .. port,
						"FAKE_READY=" .. launch.ready, "PYTHONPATH=" .. root } },
					function(code, signal) launch.exit = tostring(code) .. "/" .. tostring(signal) end)
				assert(handle, "python3 is required to stand in for " .. launch.server .. ": " .. tostring(pid))
				reservation:close()
				processes[#processes + 1] = handle
				started[launch.server] = launch
			end
			for _, launch in ipairs(launches) do
				local deadline = now_ms() + 10000
				while not uv.fs_stat(launch.ready) and now_ms() < deadline do uv.run("nowait"); uv.sleep(10) end
				assert(uv.fs_stat(launch.ready) and accepting(launch.port), launch.server .. " stand-in never listened on " .. launch.port
					.. " (exit " .. tostring(launch.exit) .. ")")
			end
			local Ports = helpers.load_module("modules.llm.local_server_ports")
			Ports._home = function() return home end
			local Policy = require("ai.engine.local_servers.ports_core")
			local entries = {}
			for _, id in ipairs(CATALOGUE.server_order) do
				entries[#entries + 1] = { id = id, base_url = CATALOGUE.servers[id].base_url,
					descriptor = assert(Policy.descriptor(id, CATALOGUE.servers[id].discovery)) }
			end
			for _, launch in ipairs(launches) do
				assert(CATALOGUE.servers[launch.server], launch.server .. " is a catalogue server")
			end
			for _, method in ipairs({ "scan", "scan_owned" }) do
				local results
				local owned = Ports[method](entries, function(value) results = value end)
				local deadline = now_ms() + 15000
				while (results == nil or (owned and not owned:is_settled())) and now_ms() < deadline do
					uv.run("nowait"); uv.sleep(5)
				end
				assert(results, method .. " produces a result")
				if owned then helpers.assert_true(owned:is_settled(), "the owned scan physically settles") end
				for _, id in ipairs(CATALOGUE.server_order) do
					local result, launch = results[id], started[id]
					if launch then
						helpers.assert_true(result.running, id .. " is found running: " .. Policy.describe(result))
						helpers.assert_eq(result.port, launch.port, id .. " port")
						helpers.assert_eq(result.source, launch.source, id .. " port source")
						local path = CATALOGUE.servers[id].base_url:match("^https?://[^/]+(/.*)$")
						helpers.assert_eq(result.base_url, "http://127.0.0.1:" .. launch.port .. path, id .. " base URL")
					else
						helpers.assert_eq(result.running, false, id .. " runs no process here")
					end
				end
			end
		end)
		for _, reservation in ipairs(reservations) do
			if not uv.is_closing(reservation) then reservation:close() end
		end
		for _, handle in ipairs(processes) do
			pcall(uv.process_kill, handle, "sigterm")
			handle:close()
		end
		uv.run("nowait")
		-- mkdtemp names the folder with letters and digits only, never a quote
		os.execute("rm -rf '" .. root .. "'")
		restore()
		assert(ok, err)
	end)
end)
