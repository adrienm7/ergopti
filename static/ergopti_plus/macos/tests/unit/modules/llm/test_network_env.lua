--- tests/unit/modules/llm/test_network_env.lua

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
		helpers.assert_eq(output, "[TEST] The system proxy configuration cannot be used by this client. No download was started.\n__ERGOPTI_OPAQUE_ADMISSION_V1__:refused:verified:unavailable\n")
		helpers.assert_true(not output:find("__CHILD_STARTED__", 1, true), "refusal must stop the generated prelude")
	end)

	helpers.it("starts the Ollama service with the system network settings", function()
		package.loaded["modules.llm.ollama_server_command"] = nil
		local Builder = require("modules.llm.ollama_server_command")
		local command = assert(Builder.build("/fixture/ollama", "/tmp/logs/ErgoptiPlus_2099-01-01.log", 11434))
		local prelude = assert(require("modules.llm.network_env").prelude("OLLAMA-SERVER"))
		helpers.assert_true(not prelude:find("apply_system_network opaque", 1, true), "cached local serving requires no outgoing admission")
		helpers.assert_eq(command:sub(1, #prelude), prelude,
			"the service pulls the models itself and reads only its own relay variables")
	end)
end)
