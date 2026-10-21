--- tests/support/modules/llm/processes/mlx_cleanup_fixture.lua

--- ==============================================================================
--- MODULE: MLX cleanup command receiver
--- DESCRIPTION:
--- Captures public launch commands and executes their cleanup with Darwin-shaped
--- process inventories. Signal ports only record requests; they never send them.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}
local OWNED = {
	"infra.logger", "infra.notifications", "infra.i18n", "infra.config_paths",
	"infra.text_utils", "infra.timings", "infra.paths", "adapters.storage",
	"adapters.http_client", "adapters.json_codec", "adapters.shell_runner",
	"adapters.timer_scheduler", "adapters.task_lifecycle", "modules.llm.profiles",
	"modules.llm.api_common", "modules.llm.api_mlx_inference", "modules.llm.api_mlx_fetch",
	"modules.llm.api_mlx_discovery", "modules.llm.mlx_stream_retirement",
	"modules.llm.api_mlx", "modules.llm.boot_cleanup",
	"ui.menu.menu_llm.models_manager_mlx_server",
}

--- Quotes one opaque argument for the receiving POSIX shell.
--- @param value string Argument.
--- @return string quoted
function M.quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- Captures scripts through the public controller and server-launch entry points.
--- @param callback function Receives the three actual shell commands.
function M.with_commands(callback)
	local saved_hs = _G.hs
	local ok, err = xpcall(function()
		helpers.with_fresh_modules(OWNED, function()
			local noop = function() end
			local commands = {}
			local function capture(executable, args)
				commands[#commands + 1] = { executable = executable, script = args[2] }
				return { start = function() return true end, isRunning = function() return true end }
			end
			local protected = function(fn, _, ...)
				if type(fn) ~= "function" then return false end
				return pcall(fn, ...)
			end
			package.loaded["infra.logger"] = {
				debug = noop, info = noop, warn = noop, error = noop,
				callback = function(_, _, fn, ...) return pcall(fn, ...) end,
				today_log_path = function() return "/fixture/log.txt" end,
			}
			package.loaded["infra.notifications"] = { notify = noop }
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["infra.config_paths"] = { get = function() return "/fixture/model.txt" end }
			package.loaded["infra.text_utils"] = { shell_quote = M.quote }
			package.loaded["infra.timings"] = { sec = function() return 1 end }
			package.loaded["infra.paths"] = { shared = function() return nil end }
			package.loaded["adapters.storage"] = { get = function() return nil end }
			package.loaded["adapters.http_client"] = { new = function() return {} end }
			package.loaded["adapters.json_codec"] = { decode = function() return nil end }
			package.loaded["adapters.shell_runner"] = { spawn = capture }
			package.loaded["adapters.timer_scheduler"] = {
				awake_time = function() return 100 end,
				after = function() return { timer = {} }, true end,
			}
			package.loaded["adapters.task_lifecycle"] = {
				native = function(_, executable, _, third, fourth)
					return capture(executable, fourth or third)
				end,
				start = function(task) return task.start() end,
			}
			package.loaded["modules.llm.profiles"] = {}
			package.loaded["modules.llm.api_common"] = { protected_call = protected }
			package.loaded["modules.llm.mlx_stream_retirement"] = {}
			for _, name in ipairs({ "inference", "fetch", "discovery" }) do
				package.loaded["modules.llm.api_mlx_" .. name] = { init = noop }
			end
			local api = require("modules.llm.api_mlx")
			api.set_active_server_pgid(700)
			helpers.assert_eq(#commands, 1, "the guarded API must emit its real cleanup")
			local guarded = commands[1]
			helpers.assert_true(require("modules.llm.boot_cleanup").run_selective_cleanup(noop))
			helpers.assert_eq(#commands, 2)
			local boot = commands[2]
			api.reset_endpoints = function() return true end
			api.set_model_hf_path = noop
			_G.hs = { execute = function() return "" end }
			local obj = { get_mlx_repo = function() return "fixture/repo" end }
			require("ui.menu.menu_llm.models_manager_mlx_server").install({
				obj = obj, deps = { active_tasks = {} }, active_tasks_gc_root = {},
				project_venv_python_escaped = "/Users/Example/Library/Application Support/mlx/bin/python3",
			})
			helpers.assert_true(obj.start_server("fixture-model", noop, noop))
			local launcher
			for index = 3, #commands do
				if commands[index].executable == "/bin/bash" then launcher = commands[index] end
			end
			helpers.assert_not_nil(launcher, "the real server launch must be captured")
			callback({ boot = boot.script, guarded = guarded.script, launcher = launcher.script })
		end)
	end, debug.traceback)
	_G.hs = saved_hs
	if not ok then error(err, 0) end
end

--- Selects one executable cleanup region without reproducing its predicates.
--- @param source string Actual launcher command.
--- @param first string Unique start anchor.
--- @param last string Unique next-region anchor.
--- @return string fragment
function M.region(source, first, last)
	local start_at = assert(source:find(first, 1, true), "missing cleanup start")
	assert(not source:find(first, start_at + #first, true), "ambiguous cleanup start")
	local end_at = assert(source:find(last, start_at + #first, true), "missing cleanup end")
	return source:sub(start_at, end_at - 1)
end

--- Executes real shell/awk code with recording signal ports and no native signals.
--- @param script string Actual cleanup command or region.
--- @param options table Controlled inventory and native process facts.
--- @return table observed Ordered requested signal PIDs.
--- @return string output Complete shell output.
function M.receive(script, options)
	local rows_comm, rows_ucomm = {}, {}
	for _, row in ipairs(options.rows or {}) do
		rows_comm[#rows_comm + 1] = row.pid .. " " .. row.comm .. " " .. row.args
		rows_ucomm[#rows_ucomm + 1] = row.pid .. " " .. row.ucomm .. " " .. row.args
	end
	local function emit(value) return "printf '%s\\n' " .. M.quote(value or "") end
	local prelude = table.concat({
		"ps() { case \"$*\" in",
		"'-axo pid=,comm=,args=') " .. emit(table.concat(rows_comm, "\n")) .. ";;",
		"'-axo pid=,ucomm=,args=') " .. emit(table.concat(rows_ucomm, "\n")) .. ";;",
		"'-o comm= -p 910') " .. emit(options.old_comm) .. ";;",
		"'-o ucomm= -p 910') " .. emit(options.old_ucomm) .. ";;",
		"'-o args= -p 910') " .. emit(options.old_args) .. ";;",
		"'-o pgid= -p 102') printf '700\\n';;",
		"'-o pgid= -p '*) printf '600\\n';;",
		"*) printf 'Unexpected ps arguments: %s\\n' \"$*\" >&2; return 90;; esac; };",
		"lsof() { " .. emit(options.healthy and "102" or "") .. "; };",
		"curl() { " .. emit(options.healthy and '{"data":[{"id":"fixture-model"}]}' or "") .. "; };",
		"sleep() { :; };",
		"xargs() { [ \"$*\" = 'kill -9' ] || return 91; while read -r pid; do printf 'SIGNAL %s\\n' \"$pid\"; done; };",
		"kill() { [ \"$1\" = '-0' ] && return 0; [ \"$1\" = '-9' ] || return 92; printf 'SIGNAL %s\\n' \"$2\"; };",
	}, "\n")
	local pid_path = os.tmpname()
	local file = assert(io.open(pid_path, "w"))
	assert(file:write("910\n")); assert(file:close())
	local command = prelude .. "\nMLX_PID_FILE=" .. M.quote(pid_path) .. ";\n" .. script
	local ok, result, output = xpcall(function()
		local pipe = assert(io.popen("/bin/bash -c " .. M.quote(command) .. " 2>&1"))
		local text = pipe:read("*a")
		local closed = table.pack(pipe:close())
		assert(closed[1] == true, "cleanup shell failed: " .. text)
		local pids = {}
		for pid in text:gmatch("SIGNAL (%d+)") do pids[#pids + 1] = tonumber(pid) end
		return pids, text
	end, debug.traceback)
	os.remove(pid_path)
	if not ok then error(result, 0) end
	return result, output
end

return M
