--- tests/unit/modules/llm/processes/test_mlx_cleanup_process_names.lua

--- ==============================================================================
--- MODULE: Darwin MLX process identity regression
--- DESCRIPTION:
--- Executes emitted cleanup using a real shell and awk, recording every requested
--- signal instead of sending it. Darwin comm exposes argv[0], ucomm exposes p_comm.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.modules.llm.processes.mlx_cleanup_fixture")
local ROWS = {
	{ pid = 101, comm = "/Users/Example/Library/Application Support/mlx/bin/python3.12", ucomm = "python3.12",
		args = '"/Users/Example/Library/Application Support/mlx/bin/python3.12" -m mlx_lm server --port 3460' },
	{ pid = 102, comm = "Python", ucomm = "Python", args = "Python -m mlx_lm.server --port 3460" },
	{ pid = 103, comm = "/Users/python-workspace/bin/bash", ucomm = "bash",
		args = "/Users/python-workspace/bin/bash -c python -m mlx_lm server" },
	{ pid = 104, comm = "/usr/bin/python3", ucomm = "python3", args = "/usr/bin/python3 ordinary_script.py" },
	{ pid = 105, comm = "/usr/bin/ruby", ucomm = "ruby", args = "/usr/bin/ruby inspect_mlx_lm.rb" },
}

--- Checks independently expected signal requests in order.
--- @param actual table Recorded PIDs.
--- @param expected table Expected PIDs.
local function expect_pids(actual, expected)
	helpers.assert_eq(#actual, #expected, "unexpected number of signal requests")
	for index, pid in ipairs(expected) do helpers.assert_eq(actual[index], pid) end
end

--- Executes an actual cleanup region from the public launch command.
--- @param commands table Captured commands.
--- @param kind string Either pid or fallback.
--- @param options table Controlled inventory.
--- @return table observed Recorded PIDs.
local function receive_launcher(commands, kind, options)
	local first, last
	if kind == "pid" then
		first, last = 'if [ -f "$MLX_PID_FILE" ]; then ', 'PGREP_PIDS='
	else
		first, last = 'PGREP_PIDS=', 'sleep 3; '
	end
	return fixture.receive(fixture.region(commands.launcher, first, last), options)
end

helpers.describe("MLX Darwin process names", function()
	helpers.it("boot cleanup finds an absolute Python path containing spaces", function()
		if package.config:sub(1, 1) ~= "/" then return end
		fixture.with_commands(function(commands)
			expect_pids(fixture.receive(commands.boot, { rows = ROWS }), { 101, 102 })
		end)
	end)

	helpers.it("boot cleanup spares a single healthy server", function()
		if package.config:sub(1, 1) ~= "/" then return end
		fixture.with_commands(function(commands)
			expect_pids(fixture.receive(commands.boot, { rows = ROWS, healthy = true }), {})
		end)
	end)

	helpers.it("guarded API finds absolute Python while protecting the active PGID", function()
		if package.config:sub(1, 1) ~= "/" then return end
		fixture.with_commands(function(commands)
			expect_pids(fixture.receive(commands.guarded, { rows = ROWS, healthy = true }), { 101 })
		end)
	end)

	helpers.it("guarded API spares its only healthy server", function()
		if package.config:sub(1, 1) ~= "/" then return end
		fixture.with_commands(function(commands)
			expect_pids(fixture.receive(commands.guarded, { rows = { ROWS[2] }, healthy = true }), {})
		end)
	end)

	helpers.it("launcher fallback finds both current and legacy MLX commands", function()
		if package.config:sub(1, 1) ~= "/" then return end
		fixture.with_commands(function(commands)
			expect_pids(receive_launcher(commands, "fallback", { rows = ROWS }), { 101, 102 })
		end)
	end)

	helpers.it("saved PID guard refuses a shell in a directory containing python", function()
		if package.config:sub(1, 1) ~= "/" then return end
		fixture.with_commands(function(commands)
			expect_pids(receive_launcher(commands, "pid", {
				old_comm = ROWS[3].comm, old_ucomm = ROWS[3].ucomm, old_args = ROWS[3].args,
			}), {})
		end)
	end)

	helpers.it("saved PID guard still accepts the prior Python MLX server", function()
		if package.config:sub(1, 1) ~= "/" then return end
		fixture.with_commands(function(commands)
			expect_pids(receive_launcher(commands, "pid", {
				old_comm = ROWS[1].comm, old_ucomm = ROWS[1].ucomm, old_args = ROWS[1].args,
			}), { 910 })
		end)
	end)

	helpers.it("saved PID guard refuses an ordinary Python program", function()
		if package.config:sub(1, 1) ~= "/" then return end
		fixture.with_commands(function(commands)
			expect_pids(receive_launcher(commands, "pid", {
				old_comm = ROWS[4].comm, old_ucomm = ROWS[4].ucomm, old_args = ROWS[4].args,
			}), {})
		end)
	end)
end)
