--- tests/support/opaque_network_owner_fixture.lua

--- ==============================================================================
--- MODULE: Actual Opaque Network Pull Wrapper Receiver
--- DESCRIPTION:
--- Receives the complete original Ollama exec command and MLX launcher file
--- through their original fixtures, retaining exact task constructor metadata.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local M = {}

--- Captures actual outgoing-owner wrappers using independent receiver ports.
--- @param network table Real NetworkEnv module with the receiver policy path.
--- @param python string Receiver interpreter path inside the emitted launcher.
--- @param binary string Receiver Ollama binary path.
--- @return table packet
function M.capture(network, python, binary)
	local packet = {}
	require("tests.support.ollama_pull_fixture").with_fixture({
		network_env = network, binary_path = binary,
	}, function(fixture)
		helpers.assert_true(fixture.manager.pull_model("model-A", "org/model", nil, nil, {
			is_current = function() return true end,
		}))
		helpers.assert_eq(#fixture.pulls, 1)
		local task = fixture.pulls[1]
		helpers.assert_eq(fixture.active_tasks.ollama_pull, task)
		packet.ollama = { executable = task.executable, args = task.args }
	end)
	require("tests.support.mlx_download_fixture").with_fixture({
		network_env = network, project_venv_python_escaped = python,
	}, function(fixture)
		helpers.assert_true(fixture.controls.pull())
		local task = fixture.controls.latest("launcher")
		helpers.assert_type(task.path, "string")
		packet.mlx = { path = task.path, source = assert(fixture.controls.files[task.path]) }
	end)
	return packet
end

--- Feeds real wrapper stderr through original current/commit owner callbacks.
--- @param network table Real NetworkEnv receiver port.
--- @param bytes string Stderr from the actually executed emitted wrapper.
--- @param code number Actual wrapper terminal code.
--- @param mode string|nil "terminal_only", "stale" or "start_refused".
--- @return table result Shared message publication and report-call inventory.
function M.receive(network, bytes, code, mode)
	local file = assert(io.open(helpers.shared("modules/network/managed_network.json"), "rb"))
	local policy = json.decode(file:read("*a"))
	assert(file:close())
	local contract = require("network.failure").new(policy)
	local admission = require("modules.llm.opaque_network_admission")
	local calls = 0
	local revoke
	local port = { new = admission.new, report = function(receipt, capabilities)
		calls = calls + 1
		if mode == "stale_during_report" and revoke then revoke() end
		return contract.classify(receipt, capabilities)
	end }
	local result = { ollama_messages = json.array({}), mlx_messages = json.array({}) }
	local function record(messages, notifications)
		for _, notification in ipairs(notifications) do
			if notification[2] == "network.failure.proxy" or notification[2] == "network.failure.unknown" then
				messages[#messages + 1] = notification[2]
			end
		end
	end
	local saved_print = print
	print = function() end -- Keep the standalone receiving result machine-readable.
	local ok, err = xpcall(function()
		local fresh = true
		require("tests.support.ollama_pull_fixture").with_fixture({
			network_env = network, network_admission = port,
			start_result = mode ~= "start_refused",
			complete_during_start = mode == "start_refused" and code or nil,
			complete_stderr = mode == "start_refused" and bytes or nil,
		}, function(fixture)
			revoke = function() fresh = false end
			fixture.manager.pull_model("model-A", "org/model", nil, nil, {
				is_current = function() return fresh end,
			})
			local task = assert(fixture.pulls[1])
			if mode == "stale" then fresh = false end
			if mode ~= "start_refused" then
				if mode == "terminal_only" then task.on_done(code, "", bytes) else
					local split = math.floor(#bytes / 2)
					task.on_stream(task, "", bytes:sub(1, split))
					task.on_stream(task, "", bytes:sub(split + 1))
					task.on_done(code, "", "")
				end
			end
			record(result.ollama_messages, fixture.notification_records)
		end)
		require("tests.support.mlx_download_fixture").with_fixture({
			network_env = network, network_admission = port, requirement_lifecycle = true,
			launcher = mode == "start_refused" and { start = "false", complete_on_start = true,
				complete_code = code, complete_stderr = bytes } or nil,
		}, function(fixture)
			fixture.controls.pull()
			revoke = function() fixture.controls.requirement_pause_join() end
			local task = assert(fixture.controls.latest("launcher"))
			if mode == "stale" then fixture.controls.requirement_pause_join() end
			if mode ~= "start_refused" then
				if mode == "terminal_only" then task:complete(code, bytes) else
					local split = math.floor(#bytes / 2)
					task:emit("", bytes:sub(1, split))
					task:emit("", bytes:sub(split + 1))
					task:complete(code)
				end
			end
			record(result.mlx_messages, fixture.records.notifications)
		end)
	end, debug.traceback)
	print = saved_print
	if not ok then error(err, 0) end
	result.report_calls = calls
	return result
end

return M
