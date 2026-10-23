--- tests/unit/modules/llm/backends/test_network_env.lua

--- ==============================================================================
--- MODULE: Download Child Network Prelude Tests (managed-network-children)
--- DESCRIPTION:
--- Every macOS download child started by the driver reads the system network
--- settings through the shared policy: the Ollama service (which pulls the
--- models itself) and the MLX model download get the relay and the loopback
--- exclusion, and no CA file.
--- ==============================================================================

local helpers = require("tests.helpers")

local POSIX = package.config:sub(1, 1) == "/"

--- Quotes a value for /bin/sh.
--- @param value string
--- @return string
local function sh_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- Runs a shell command and returns its output.
--- @param command string
--- @return string output
local function run(command)
	local handle = assert(io.popen(command .. " 2>&1"))
	local output = handle:read("*a")
	handle:close()
	return output
end

helpers.describe("managed-network-children", function()
	helpers.it("names the shared policy and exports the settings for the next command", function()
		package.loaded["modules.llm.network_env"] = nil
		local NetworkEnv = require("modules.llm.network_env")
		local policy = NetworkEnv.policy_path()
		helpers.assert_eq(policy, helpers.driver_root() .. "modules/llm/network-retry.sh")
		local prelude = assert(NetworkEnv.prelude("TEST"))
		helpers.assert_true(prelude:find(". '" .. policy .. "' && apply_system_network; ", 1, true) ~= nil, prelude)
		if POSIX then
			local output = run("env -u https_proxy -u all_proxy -u ALL_PROXY HTTPS_PROXY=http://relay.corp:3129 NO_PROXY= no_proxy= bash -c "
				.. sh_quote(prelude .. 'printf "%s|%s|%s" "$HTTPS_PROXY" "$NO_PROXY" "$UV_SYSTEM_CERTS"'))
			helpers.assert_eq(output, "http://relay.corp:3129|localhost,127.0.0.1,::1|1")
		end
	end)

	helpers.it("propagates an opaque native-admission refusal before the next command", function()
		if not POSIX then return end -- Actual Bash receiving is mandatory in the registered JS gate.
		local NetworkEnv = require("modules.llm.network_env")
		local policy = assert(io.open(assert(NetworkEnv.policy_path()), "r"))
		local body = policy:read("*a")
		policy:close()
		local fixture = os.tmpname()
		local writer = assert(io.open(fixture, "w"))
		writer:write(body, '\nopaque_system_proxy_snapshot() { printf "%s\\n" "<dictionary> {" " ProxyAutoConfigEnable : 1" "}"; }\n')
		writer:close()
		local original_path = NetworkEnv.policy_path
		NetworkEnv.policy_path = function() return fixture end
		local prelude = assert(NetworkEnv.opaque_prelude("TEST"))
		NetworkEnv.policy_path = original_path
		local output = run("env -u https_proxy -u HTTPS_PROXY -u http_proxy -u HTTP_PROXY -u all_proxy -u ALL_PROXY bash -c "
			.. sh_quote(prelude .. 'printf "__CHILD_STARTED__"'))
		os.remove(fixture)
		helpers.assert_eq(output, "[TEST] The system proxy configuration (an automatic proxy configuration file (PAC)) "
			.. "cannot be used by this client. No download was started.\n"
			.. "__ERGOPTI_OPAQUE_ADMISSION_V1__:refused:verified:unavailable\n")
		helpers.assert_true(not output:find("__CHILD_STARTED__", 1, true), "refusal must stop the generated prelude")
	end)

	-- A daemon that reads only HTTPS_PROXY cannot evaluate a PAC: the prelude names
	-- the origin it downloads from and the launcher resolves that origin.
	helpers.it("(ollama-pac-route) names the origin whose automatic route is resolved", function()
		local NetworkEnv = require("modules.llm.network_env")
		local original_path = NetworkEnv.policy_path
		NetworkEnv.policy_path = function() return "/fixture/network-retry.sh" end
		local ok, err = pcall(function()
			local options = { pac_probe_url = "https://registry.ollama.ai" }
			for _, build in ipairs({ NetworkEnv.prelude, NetworkEnv.opaque_prelude }) do
				local prelude = assert(build("TEST", options))
				local probe_at = prelude:find("OPAQUE_NETWORK_PAC_PROBE_URL='https://registry.ollama.ai'; ", 1, true)
				local source_at = prelude:find(". '/fixture/network-retry.sh' && ", 1, true)
				helpers.assert_true(probe_at ~= nil and source_at ~= nil and probe_at < source_at,
					"the origin is assigned before the policy is sourced: " .. prelude)
				helpers.assert_true(not assert(build("TEST")):find("PAC_PROBE", 1, true),
					"a client that names no origin gets the unchanged prelude")
			end
			for _, bad in ipairs({ "http://registry.ollama.ai", "https://registry.ollama.ai/path",
				"https://registry.ollama.ai'; touch x; '", "https://u:p@registry.ollama.ai", 7 }) do
				local prelude, reason = NetworkEnv.prelude("TEST", { pac_probe_url = bad })
				helpers.assert_nil(prelude, tostring(bad))
				helpers.assert_true(type(reason) == "string", tostring(bad))
			end
		end)
		NetworkEnv.policy_path = original_path
		if not ok then error(err, 0) end
	end)

	helpers.it("starts the Ollama service with the system network settings", function()
		package.loaded["modules.llm.ollama_server_command"] = nil
		local Builder = require("modules.llm.ollama_server_command")
		local command = assert(Builder.build("/fixture/ollama", "/tmp/logs/ErgoptiPlus_2099-01-01.log", 11434))
		local prelude = assert(require("modules.llm.network_env").prelude("OLLAMA-SERVER", Builder.NETWORK_OPTIONS))
		helpers.assert_true(not prelude:find("apply_system_network opaque", 1, true), "cached local serving requires no outgoing admission")
		helpers.assert_eq(command:sub(1, #prelude), prelude,
			"the service pulls the models itself and reads only its own relay variables")
	end)

	helpers.it("managed HTTP admission preserves inherited selectors before the native receiver", function()
		local NetworkEnv = require("modules.llm.network_env")
		local prelude = assert(NetworkEnv.managed_http_prelude("TEST"))
		helpers.assert_true(prelude:find("s.loader.exec_module(m); m._resolve_worker()", 1, true) ~= nil,
			"identity admission must use the canonical native receiver")
		helpers.assert_true(not prelude:find("apply_system_network", 1, true), "no seed-URL system relay may become an explicit environment selector")
		helpers.assert_true(not prelude:find("export ", 1, true), "inherited proxy and bypass provenance remains intact")
		helpers.assert_true(prelude:find("__ERGOPTI_OPAQUE_ADMISSION_V1__:accepted", 1, true) ~= nil)
		if POSIX then
			local output = run("PYTHON_BIN=/bin/false HTTPS_PROXY=http://reserved.example:3129 NO_PROXY=reserved.example bash -c "
				.. sh_quote(prelude .. 'printf "__CHILD_STARTED__"'))
			helpers.assert_eq(output, "[TEST] The bundled native network receiver is unavailable. No download was started.\n"
				.. "__ERGOPTI_OPAQUE_ADMISSION_V1__:refused:unavailable:unavailable\n")
			helpers.assert_true(not output:find("__CHILD_STARTED__", 1, true), "native identity refusal precedes download dispatch")
		end
	end)

end)
