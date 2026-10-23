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
	fh:close()
	return text
end

--- This process's id, from the kernel.
--- @param stat string|nil The text of /proc/self/stat (read when nil).
--- @return integer|nil
function M.own_pid(stat)
	stat = stat or read_file("/proc/self/stat")
	return stat and tonumber(stat:match("^(%d+)")) or nil
end

--- Whether this process runs inside the daemon's systemd user unit.
--- @param cgroup string|nil The text of /proc/self/cgroup (read when nil).
--- @return boolean
function M.under_unit(cgroup)
	cgroup = cgroup or read_file("/proc/self/cgroup") or ""
	-- A similarly named scope or service cannot restart this process. Match an
	-- exact ancestor in either hierarchy format, including delegated subgroups.
	for line in cgroup:gmatch("[^\n]+") do
		local path = line:match("^%d+:[^:]*:(/.*)$")
		if path then
			for component in path:gmatch("[^/]+") do
				if component == M.UNIT then return true end
			end
		end
	end
	return false
end

--- The detached relay command for a daemon not run by systemd.
--- @param pid integer The process to outlive.
--- @param wrapper string The installed launcher.
--- @param args table The daemon's own arguments.
--- @return string
function M.relay_command(pid, wrapper, args)
	local argv = { ShellRunner.quote(wrapper) }
	for _, value in ipairs(args or {}) do argv[#argv + 1] = ShellRunner.quote(tostring(value)) end
	-- A zombie has exited: its parent may reap it late (or, as PID 1 in a
	-- container, never), and kill -0 alone would wait on it forever.
	-- stat embeds raw comm bytes, including newlines; status escapes that name
	-- and supplies a separate State record safe to read one line at a time.
	local script = string.format("while kill -0 %d 2>/dev/null"
		.. " && [ \"$(sed -n 's/^State:[[:space:]]*\\([A-Z]\\).*/\\1/p' /proc/%d/status 2>/dev/null)\" != Z ]; do sleep 0.2; done; exec %s",
		pid, pid, table.concat(argv, " "))
	-- Keep dispatch in the foreground until the detached shell has forked its
	-- relay. An outer '&' reports success even when setsid cannot start at all,
	-- which would authorize shutdown with no process left to launch the update.
	return "setsid sh -c " .. ShellRunner.quote("(" .. script .. ") </dev/null >/dev/null 2>&1 &")
		.. " </dev/null >/dev/null 2>&1"
end

--- Starts the installed version in place of this process.
--- @param opts table { wrapper, args, paused?, run?, cgroup?, pid? }
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
		if M.under_unit(opts.cgroup) then
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
		if not run(M.relay_command(pid, opts.wrapper, opts.args)) then
			Logger.error(LOG, "The restart relay could not be started — the update applies at the next start.")
			return nil
		end
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
