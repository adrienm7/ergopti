--- modules/updater/restarter.lua

--- ==============================================================================
--- MODULE: Restart On The Installed Update (Linux)
--- DESCRIPTION:
--- After the updater replaced the installation, the running daemon is still
--- the old code. This starts the new one in its place:
---   - under its systemd user unit, systemd restarts it (the unit's cgroup
---     would kill anything the daemon spawned when it stops);
---   - otherwise a detached relay waits for this process to exit, so the new
---     daemon never races the old one for the keyboard grab, then runs the
---     installed launcher with the same arguments.
--- The caller then shuts the daemon down (the relay case); systemd stops it
--- itself (the unit case).
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ShellRunner = require("adapters.shell_runner")

local LOG = "modules.updater.restarter"

M.UNIT = "ergopti-hotstrings.service"

local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local text = fh:read("*a")
	local closed = fh:close()
	if type(text) ~= "string" or not closed then return nil end
	return text
end

--- This process's id, from the kernel.
--- @param stat string|nil The text of /proc/self/stat (read when nil).
--- @return integer|nil
function M.own_pid(stat)
	stat = stat or read_file("/proc/self/stat")
	return stat and tonumber(stat:match("^(%d+)")) or nil
end

--- The kernel start tick identifies a process even if its numeric PID is reused.
--- @param pid integer Process ID.
--- @param stat string|nil Captured /proc/PID/stat text, read when absent.
--- @return string|nil start_tick Exact decimal kernel value.
function M.process_start_time(pid, stat)
	if type(pid) ~= "number" or pid <= 0 or pid % 1 ~= 0 then return nil end
	stat = stat or read_file("/proc/" .. string.format("%.0f", pid) .. "/stat")
	if type(stat) ~= "string" then return nil end
	local closing = stat:match("^.*()%) ")
	if not closing then return nil end
	local index = 0
	for field in stat:sub(closing + 2):gmatch("%S+") do
		index = index + 1
		if index == 20 then return field:match("^%d+$") and field or nil end
	end
	return nil
end

--- Linux boot identity prevents start ticks reused across reboot from sharing a marker.
--- @param text string|nil Kernel boot ID, read when absent.
--- @return string|nil
function M.boot_id(text)
	text = text or read_file("/proc/sys/kernel/random/boot_id")
	if type(text) ~= "string" then return nil end
	local id = text:match("^([%da-fA-F%-]+)%s*$")
	if not id or not id:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then return nil end
	return id:lower()
end

--- Whether this process runs inside the daemon's systemd user unit.
--- @param cgroup string|nil The text of /proc/self/cgroup (read when nil).
--- @return boolean|nil in_unit nil when the native cgroup cannot be read.
function M.under_unit(cgroup)
	if cgroup == nil then cgroup = read_file("/proc/self/cgroup") end
	if type(cgroup) ~= "string" then return nil end
	if cgroup:sub(1, 1) == "\n" or cgroup:find("\n\n", 1, true)
		or cgroup:gsub("\n", ""):find("%c") then return nil end
	-- A similarly named scope or service cannot restart this process. Match an
	-- exact ancestor in either hierarchy format, including delegated subgroups.
	local seen, matched = false, false
	for line in cgroup:gmatch("[^\n]+") do
		local path = line:match("^%d+:[^:]*:(/.*)$")
		if not path then return nil end
		seen = true
		for component in path:gmatch("[^/]+") do
			if component == M.UNIT then matched = true end
		end
	end
	if not seen then return nil end
	return matched
end

--- The detached relay command for a daemon not run by systemd.
--- @param pid integer The process to outlive.
--- @param wrapper string The installed launcher.
--- @param args table The daemon's own arguments.
--- @param cancel_path string|nil A marker file: when it exists once the process has
---   exited, the relay removes it and does not start the launcher (Quit won over the reload).
--- @param start_tick string Exact kernel start tick captured before dispatch.
--- @return string
function M.relay_command(pid, wrapper, args, cancel_path, start_tick)
	assert(type(start_tick) == "string" and start_tick:match("^%d+$"), "relay needs the original process start tick")
	local argv = { ShellRunner.quote(wrapper) }
	for _, value in ipairs(args or {}) do argv[#argv + 1] = ShellRunner.quote(tostring(value)) end
	-- A zombie has exited even if its parent has not reaped it. The raw comm
	-- in stat can contain spaces, parentheses and newlines, so remove through
	-- its final closing parenthesis before checking state and start tick. A PID
	-- reused by a different process must not hold this relay indefinitely.
	-- A Quit creates the cancellation marker while this process is still live.
	local cancel = ""
	if cancel_path ~= nil then
		local marker = ShellRunner.quote(cancel_path)
		cancel = string.format(" if [ -e %s ]; then rm -f %s; exit 0; fi;", marker, marker)
	end
	local script = string.format("while kill -0 %d 2>/dev/null; do "
		.. "stat=$(cat /proc/%d/stat 2>/dev/null) || { sleep 0.2; continue; }; "
		.. "rest=${stat##*) }; set -- $rest; "
		.. "[ \"$#\" -ge 20 ] || { sleep 0.2; continue; }; state=$1; shift 19; "
		.. "[ \"$1\" = %s ] || break; case \"$state\" in Z|X) break;; esac; sleep 0.2; done;%s exec %s",
		pid, pid, ShellRunner.quote(start_tick), cancel, table.concat(argv, " "))
	-- Keep dispatch in the foreground until the detached shell has forked its
	-- relay. An outer '&' reports success even when setsid cannot start at all,
	-- which would authorize shutdown with no process left to launch the update.
	return "setsid sh -c " .. ShellRunner.quote("(" .. script .. ") </dev/null >/dev/null 2>&1 &")
		.. " </dev/null >/dev/null 2>&1"
end

--- The marker a Quit creates to stop the relay of this process from starting the launcher.
--- It sits beside the bootstrap storage file, the per-user private location the driver
--- already owns for its restart handoffs (infra/restart_pause.lua), so it never depends on
--- XDG_RUNTIME_DIR.
--- @param pid integer The relay's target process.
--- @param start_tick string|nil Captured process start tick, read when absent.
--- @param boot_id string|nil Captured Linux boot identity, read when absent.
--- @return string|nil path Qualified marker, nil when identity is unreadable.
function M.cancel_path(pid, start_tick, boot_id)
	if type(pid) ~= "number" or pid <= 0 or pid % 1 ~= 0 then return nil end
	start_tick = start_tick or M.process_start_time(pid)
	boot_id = M.boot_id(boot_id)
	if type(start_tick) ~= "string" or not start_tick:match("^%d+$") or not boot_id then return nil end
	return require("adapters.storage").path() .. ".relay-cancel-" .. string.format("%.0f", pid)
		.. "-" .. start_tick .. "-" .. boot_id
end

-- Pin the exact dispatched marker so a transient /proc failure cannot defeat Quit.
local relay_marker, relay_pid

--- Cancels the restart that restart() requested, for a Quit that wins over a reload.
--- Under the unit, a stop job replaces the queued restart job; with a relay, the marker
--- tells the relay not to start the launcher once this process has exited.
--- @param how string "systemd" or "relay", as restart() returned.
--- @param opts table|nil { run?, pid?, start_tick?, boot_id? }
--- @return boolean cancelled
--- @return string|nil detail Why the restart could not be cancelled.
function M.cancel(how, opts)
	opts = opts or {}
	local run = opts.run or ShellRunner.run
	if how == "systemd" then
		if run("systemctl --user --no-block stop " .. M.UNIT) then
			Logger.info(LOG, "The pending restart was replaced by a stop.")
			return true
		end
		return false, "systemctl refused the stop"
	end
	if how == "relay" then
		local pid = opts.pid or relay_pid or M.own_pid()
		if not pid then return false, "own process id unreadable" end
		local path
		if opts.start_tick ~= nil or opts.boot_id ~= nil then
			path = M.cancel_path(pid, opts.start_tick, opts.boot_id)
		elseif relay_pid == pid then path = relay_marker end
		if not path then return false, "the relay process identity is unreadable" end
		if not run("touch " .. ShellRunner.quote(path)) then
			return false, "the relay cancellation marker could not be written"
		end
		Logger.info(LOG, "The restart relay was told not to start the launcher.")
		return true
	end
	return false, "no restart is pending"
end

--- Starts the installed version in place of this process.
--- @param opts table { wrapper, args, paused?, run?, cgroup?, pid?, start_tick?, boot_id? }
--- @return string|nil "systemd" (systemd stops and restarts this process) or
---   "relay" (the caller must now exit), nil when nothing could be started.
function M.restart(opts)
	if type(opts) ~= "table" or type(opts.wrapper) ~= "string" or opts.wrapper == "" then
		error("restart requires the installed launcher", 2)
	end
	local lease, Pause
	if opts.paused ~= nil then
		Pause = require("infra.restart_pause")
		local detail
		lease, detail = Pause.prepare(opts.paused)
		if not lease then
			Logger.error(LOG, "Restart refused: %s.", tostring(detail))
			return nil
		end
	end
	local run = opts.run or ShellRunner.run
	local function dispatch()
		local under_unit = M.under_unit(opts.cgroup)
		if under_unit == nil then
			Logger.error(LOG, "Own cgroup unavailable or invalid — restart route cannot be determined.")
			return nil
		end
		if under_unit then
			-- --no-block: systemd restarts the unit after this call returns, by
			-- stopping this process the way a logout does.
			if run("systemctl --user --no-block restart " .. M.UNIT) then
				Logger.info(LOG, "Restart on the update requested from systemd.")
				return "systemd"
			end
			Logger.error(LOG, "systemctl refused the restart — the update applies at the next login.")
			return nil
		end
		local pid = opts.pid or M.own_pid()
		if not pid then
			Logger.error(LOG, "Own process id unreadable — the update applies at the next start.")
			return nil
		end
		local start_tick = opts.start_tick or M.process_start_time(pid)
		if type(start_tick) ~= "string" or not start_tick:match("^%d+$") then
			Logger.error(LOG, "Own process identity unreadable — the update applies at the next start.")
			return nil
		end
		local marker = M.cancel_path(pid, start_tick, opts.boot_id)
		if not marker then
			Logger.error(LOG, "Own boot identity unreadable — the update applies at the next start.")
			return nil
		end
		if not run(M.relay_command(pid, opts.wrapper, opts.args, marker, start_tick)) then
			Logger.error(LOG, "The restart relay could not be started — the update applies at the next start.")
			return nil
		end
		relay_marker, relay_pid = marker, pid
		Logger.info(LOG, "Restart relay armed: %s starts once process %d exits.", opts.wrapper, pid)
		return "relay"
	end
	local ok, how = pcall(dispatch)
	if not ok or how == nil then
		if lease and not Pause.rollback(lease) then
			Logger.error(LOG, "The refused restart could not retire its pause handoff.")
		end
		if not ok then Logger.error(LOG, "Restart dispatch failed: %s.", tostring(how)) end
		return nil
	end
	return how
end

return M
