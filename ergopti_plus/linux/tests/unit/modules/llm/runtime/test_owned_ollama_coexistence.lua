--- tests/unit/modules/llm/runtime/test_owned_ollama_coexistence.lua

--- ==============================================================================
--- MODULE: Owned Ollama Beside a System Ollama (Linux)
--- DESCRIPTION:
--- Ergopti runs only its own pinned Ollama, on llm_ollama_owned_port, whether
--- or not the user installed one. A system Ollama is simulated for real: an
--- executable named `ollama` first on PATH and a daemon listening on the stock
--- port (llm_ollama_port) that answers /api/version like Ollama. The Linux
--- endpoint, the readiness probe of the runtime repair, the serve address and
--- the model page's install state must never resolve, start, reach or count it.
---
--- ROOT CAUSE ENCODED:
--- The Linux origin was the stock port, so the repair's version probe and every
--- request reached whichever Ollama answered there, and a PATH `ollama` made the
--- model page treat the local runtime as available.
--- ==============================================================================

local helpers = require("tests.helpers")
local PreferencesFixture = require("tests.support.llm_preferences_fixture")
local uv = require("luv")
local Json = require("json")

local restore = helpers.keep_loaded({ "llm.runtime_repair", "modules.llm.ollama_install_resolver",
	"modules.llm.ollama_installed_runtime", "modules.llm.ollama_install_state", "modules.llm.runtime_composition",
	"modules.llm.profiles", "infra.llm_bridge" })

-- Both ports come from the one shared source the drivers read.
local DEFAULTS = (function()
	local handle = assert(io.open(helpers.driver_root() .. "/../_shared/modules/llm/defaults.json", "r"))
	local text = handle:read("*a"); handle:close()
	return assert(Json.decode(text))
end)()
local OWNED, STOCK = DEFAULTS.llm_ollama_owned_port, DEFAULTS.llm_ollama_port





-- ===================================
-- ===================================
-- ======= 1/ System Ollama Double ===
-- ===================================
-- ===================================

--- Installs an executable `ollama` first on PATH; running it leaves a marker.
--- @return table system { directory, marker, restore }
local function system_binary()
	local directory = assert(uv.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/ergopti-system-ollama-XXXXXX"))
	local marker = directory .. "/ran"
	local path = directory .. "/ollama"
	local handle = assert(io.open(path, "w"))
	handle:write("#!/bin/sh\ntouch '" .. marker .. "'\n"); handle:close()
	assert(uv.fs_chmod(path, 493))
	local previous = os.getenv("PATH")
	assert(uv.os_setenv("PATH", directory .. ":" .. (previous or "/usr/bin:/bin")))
	return { directory = directory, path = path, marker = marker, restore = function()
		if previous then uv.os_setenv("PATH", previous) else uv.os_unsetenv("PATH") end
		os.remove(marker); os.remove(path); uv.fs_rmdir(directory)
	end }
end

--- Listens on the stock port and answers every request like a running Ollama.
--- A machine already running a real Ollama there keeps it: nothing is counted.
--- @return table daemon { bound, connections, close }
local function system_daemon()
	local daemon = { connections = 0 }
	local server = uv.new_tcp()
	daemon.bound = server:bind("127.0.0.1", STOCK) == 0 and server:listen(16, function()
		local client = uv.new_tcp()
		server:accept(client)
		daemon.connections = daemon.connections + 1
		client:read_start(function(_, data)
			if data and data:find("\r\n\r\n", 1, true) then
				local body = '{"version":"0.0.1"}'
				client:write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " .. #body
					.. "\r\nConnection: close\r\n\r\n" .. body, function() client:close() end)
			elseif not data then client:close() end
		end)
	end) == 0
	function daemon.close() if not server:is_closing() then server:close() end end
	return daemon
end

--- A minimal loopback GET over a real socket: the probe's transport, so the
--- case observes the exact address the composition probes and nothing else.
--- @param url string "http://host:port/path".
--- @param done function Receives { ok, body } or { ok = false, error }.
local function socket_get(url, done)
	local host, port, path = url:match("^http://([^:/]+):(%d+)(/.*)$")
	local socket, body = uv.new_tcp(), ""
	socket:connect(host, tonumber(port), function(failure)
		if failure then socket:close(); done({ ok = false, error = failure }); return end
		socket:write("GET " .. path .. " HTTP/1.1\r\nHost: " .. host .. "\r\nConnection: close\r\n\r\n")
		socket:read_start(function(_, data)
			if data then body = body .. data; return end
			socket:close()
			done({ ok = body:match("^HTTP/1%.1 200") ~= nil, body = body:match("\r\n\r\n(.*)$") })
		end)
	end)
end

--- The Linux runtime composition with recording process and HTTP ports. The
--- shared controller is replaced only while the composition module loads.
--- @param http table get_owned port.
--- @return table controller, table served
local function composition(http)
	local Repair = require("llm.runtime_repair")
	package.loaded["llm.runtime_repair"] = { new = function(ports) return { ports = ports } end }
	local Composition = helpers.load_module("modules.llm.runtime_composition")
	package.loaded["llm.runtime_repair"] = Repair
	local served = {}
	local controller = Composition.new({
		source = { current = function() return true end, publish = function() end, app_capture = function() end,
			app_current = function() end },
		resolver = { plan = function() return {} end, current = function() return true end },
		installed = { capture = function() return { status = "missing" } end },
		file_factory = {}, admission = { new = function() end }, install_phase = { start = function() end },
		process = { start_service = function(executable, args, options)
			served.executable, served.args, served.env = executable, args, options.env
		end },
		http = http,
		owned_timer = { after = function() end, now_ms = function() return 0 end },
		timings = { ms = function() return 2000 end },
		environment = function() return { "PATH=/usr/bin", "OLLAMA_HOST=127.0.0.1:" .. STOCK } end,
		serve_environment = { "OLLAMA_NO_CLOUD=1" },
	})
	return controller, served
end





-- ================================
-- ================================
-- ======= 2/ Regression Cases ====
-- ================================
-- ================================

helpers.describe("Ergopti's own Ollama beside a system Ollama (linux-owned-ollama)", function()
	helpers.it("(linux-owned-ollama) the endpoint is the owned port of defaults.json, never the stock one", function()
		helpers.assert_true(type(OWNED) == "number" and type(STOCK) == "number" and OWNED ~= STOCK,
			"defaults.json names two distinct ports")
		local Bridge = helpers.load_module("infra.llm_bridge")
		helpers.assert_eq(Bridge.OLLAMA_OWNED_PORT, OWNED)
		helpers.assert_eq(Bridge.OLLAMA_STOCK_PORT, STOCK)
		helpers.assert_eq(Bridge.resolve_base_url(), "http://127.0.0.1:" .. OWNED)
		helpers.assert_eq(Bridge.resolve_base_url(STOCK), "", "the stock port is refused as an override")
	end)

	PreferencesFixture.it("(linux-owned-ollama) profiles take the owned origin and refuse a stock-port override", function()
		local Bridge = helpers.load_module("infra.llm_bridge")
		local Profiles = helpers.load_module("modules.llm.profiles")
		helpers.assert_eq(Profiles.init({ port = Bridge.OLLAMA_OWNED_PORT }), true)
		helpers.assert_eq(Profiles.get_base_url(), "http://127.0.0.1:" .. OWNED)
		helpers.assert_eq(Profiles.init({ port = STOCK }), false, "a stock-port override is refused, not adopted")
		helpers.assert_eq(Profiles.get_base_url(), "http://127.0.0.1:" .. OWNED, "the refused init publishes nothing")
	end)

	helpers.it("(linux-owned-ollama) the owned daemon is served on the owned port only", function()
		local Repair = helpers.load_module("llm.runtime_repair")
		local origin, host = Repair.loopback_origin(helpers.load_module("infra.llm_bridge").resolve_base_url())
		helpers.assert_eq(origin, "http://127.0.0.1:" .. OWNED)
		local controller, served = composition({ get_owned = function() end })
		controller.ports.start_service("/owned/ollama", { "serve" }, { host = host, owner = "test",
			authorized = function() return true end }, function() end)
		local hosts = {}
		for _, row in ipairs(served.env) do if row:match("^OLLAMA_HOST=") then hosts[#hosts + 1] = row end end
		helpers.assert_eq(#hosts, 1, "the inherited stock address never reaches the owned daemon")
		helpers.assert_eq(hosts[1], "OLLAMA_HOST=127.0.0.1:" .. OWNED)
		helpers.assert_eq(served.executable, "/owned/ollama")
	end)

	helpers.it("(linux-owned-ollama) a system Ollama on PATH is never resolved, run or counted", function()
		local system = system_binary()
		local ok, err = pcall(function()
			-- The runner's scratch home lies in the sticky /tmp, which the resolver
			-- rightly refuses as an ancestor, so the home tree is a native double:
			-- the real PATH executable stays the only system Ollama on the machine.
			local home, uid = "/home/owned-ollama-user", 1000
			local native = { getuid = function() return uid end, os_uname = function() return { machine = "x86_64" } end,
				fs_access = function() return true end, fs_mkdir = function() return true end,
				fs_lstat = function(path)
					if path ~= "/" and path ~= "/home" and path ~= home then return nil, "ENOENT: absent", "ENOENT" end
					return { type = "directory", uid = path == home and uid or 0, mode = 16877, dev = 1, ino = #path }
				end }
			local resolver = assert(helpers.load_module("modules.llm.ollama_install_resolver").new({ native = native,
				environment = { HOME = home } }))
			local plan = resolver.plan()
			helpers.assert_true(plan.executable ~= system.path, "the resolver never names the PATH Ollama")
			helpers.assert_eq(plan.executable:sub(1, #home + 1), home .. "/", "the resolver names the owned runtime only")
			local Installed = helpers.load_module("modules.llm.ollama_installed_runtime")
			local verdict = Installed.capture(resolver, { getuid = native.getuid, fs_lstat = native.fs_lstat,
				fs_access = native.fs_access, fs_scandir = function() end, fs_scandir_next = function() end,
				fs_readlink = function() end, fs_realpath = function() end })
			helpers.assert_eq(verdict.status, "missing", "a PATH Ollama is no installed runtime")
			-- The page's own read-only ports, with the owned runtime held missing.
			package.loaded["modules.llm.ollama_install_resolver"] = { new = function() return resolver end }
			package.loaded["modules.llm.ollama_installed_runtime"] = { capture = function() return { status = "missing" } end }
			local State = helpers.load_module("modules.llm.ollama_install_state")
			State._reset()
			local available, reason, cause = State.capture({ get_cached_models = function() return {} end,
				get_base_url = function() return "http://127.0.0.1:" .. OWNED end })
			helpers.assert_eq(cause, "absent", "a system Ollama never stands in for Ergopti's own")
			helpers.assert_eq(available, false)
			helpers.assert_eq(reason, "model_browser.reason_ollama_missing")
			State._reset()
			helpers.assert_nil(uv.fs_stat(system.marker), "the system Ollama was never executed")
		end)
		system.restore()
		assert(ok, err)
	end)

	helpers.it("(linux-owned-ollama) the readiness probe never reaches a daemon on the stock port", function()
		local daemon = system_daemon()
		local ok, err = pcall(function()
			local Repair = helpers.load_module("llm.runtime_repair")
			local origin = Repair.loopback_origin(helpers.load_module("infra.llm_bridge").resolve_base_url())
			local probed, result
			local controller = composition({ get_owned = function(url, _, _, done)
				probed = url
				socket_get(url, done)
				return { started = true }
			end })
			-- The URL the shared repair probes after starting the owned daemon.
			controller.ports.probe(origin .. require("llm.enable_admission").VERSION_PATH,
				{ remaining_ms = function() return 2000 end }, function() return true end,
				function(value) result = value end)
			local deadline = uv.now() + 5000
			while result == nil and uv.now() < deadline do uv.run("once") end
			helpers.assert_true(result ~= nil, "the probe settles")
			if daemon.bound then
				helpers.assert_eq(daemon.connections, 0, "the system daemon is never contacted")
				helpers.assert_true(not (result.ok and result.body == '{"version":"0.0.1"}'),
					"the system daemon's answer is never the owned runtime's")
			else
				print("    note: the stock port is busy here (a real Ollama runs); connection count not observed")
			end
			helpers.assert_eq(probed, "http://127.0.0.1:" .. OWNED .. "/api/version")
		end)
		daemon.close()
		uv.run("nowait")
		assert(ok, err)
	end)
end)

restore()
