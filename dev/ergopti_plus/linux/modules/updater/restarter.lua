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
---
--- After an update the new daemon must also prove it starts, as the Windows
--- swap requires its boot-ready event and a probation: a watcher hands it a
--- one-shot token (infra/updater_boot_ready.lua), keeps the installation once
--- the daemon reports its pid there and survives 0.75 s, and otherwise stops
--- it, moves the installation to <root>.failed-<pid>, puts <root>.old back and
--- starts the previous daemon. Under the unit the watcher is a transient
--- systemd-run unit, since the service's cgroup would kill it on restart.
--- The watcher's wait is the new daemon's startup, so a Quit lands in that
--- daemon: it writes `quit` to the token (infra/updater_boot_ready.lua) and the
--- watcher keeps the update and starts nothing.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local ShellRunner = require("core.process.adapters.shell_runner")

local LOG = "modules.updater.restarter"

M.UNIT = "ergopti-hotstrings.service"

-- A restart or stop of the unit this process runs in makes systemd TERM every
-- process of its cgroup, the shell and the systemctl client still reporting
-- the queued job included. Killed there, the call reads as a refusal although
-- the job runs: the restart then disarmed its update watcher and logged a
-- refusal (seen under a real user manager, tests/hardware/desktop). Ignoring TERM, which
-- the client inherits, lets it report; it exits right after, as before.
M.OWN_UNIT_JOB_PREFIX = "trap '' TERM; "

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

-- The watcher of an updated daemon. $1 mode (relay or systemd), $2 installation
-- root, $3 token, $4 log, then the unit (systemd) or the launcher and its
-- arguments (relay). A tree without the boot reporter predates it: it is only
-- started.
M.WATCH_SCRIPT = table.concat({
	'mode=$1; root=$2; token=$3; log=$4; shift 4',
	'unit=; [ "$mode" = systemd ] && { unit=$1; shift; }',
	'note() { printf "%s %s\\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$log" 2>/dev/null; }',
	'start() {',
	'	if [ "$mode" = systemd ]; then systemctl --user start "$unit"; return; fi',
	'	setsid "$@" </dev/null >/dev/null 2>&1 &',
	'	launched=$!',
	'}',
	'finish() { [ "$mode" = systemd ] && systemctl --user unset-environment ' .. 'ERGOPTI_UPDATER_BOOT_READY; rm -rf "${token%/ready}"; }',
	'if [ ! -f "$root/linux/infra/updater_boot_ready.lua" ]; then',
	'	finish; [ "$mode" = systemd ] && exit 0; exec "$@"',
	'fi',
	'launched=',
	'[ "$mode" = relay ] && { ERGOPTI_UPDATER_BOOT_READY=$token; export ERGOPTI_UPDATER_BOOT_READY; start "$@"; unset ERGOPTI_UPDATER_BOOT_READY; }',
	'ready_ticks=0; failure=',
	'while [ ! -s "$token" ]; do',
	'	ready_ticks=$((ready_ticks + 1))',
	'	if [ "$ready_ticks" -gt 600 ]; then failure="no boot report"; break; fi',
	'	sleep 0.1',
	'done',
	'successor=',
	'kept() { note "The updated daemon was quit $1: the update stays installed and no daemon is started."; finish; exit 0; }',
	'if [ -z "$failure" ]; then',
	'	successor=$(cat "$token")',
	'	[ "$successor" = quit ] && kept "before it reported ready"',
	'	case "$successor" in ""|*[!0-9]*) successor=; failure="an invalid boot report" ;; esac',
	'fi',
	'if [ -z "$failure" ]; then',
	'	sleep 0.75',
	'	kill -0 "$successor" 2>/dev/null || failure="it quit during the probation"',
	'fi',
	'if [ -z "$failure" ]; then note "The updated daemon reported a healthy start."; finish; exit 0; fi',
	'[ "$(cat "$token" 2>/dev/null)" = quit ] && kept "during its probation"',
	'if [ "$mode" = systemd ]; then',
	'	systemctl --user stop "$unit"',
	'else',
	'	for pid in $successor $launched; do kill -TERM "$pid" 2>/dev/null; done',
	'	stop_ticks=0',
	'	for pid in $successor $launched; do',
	'		while kill -0 "$pid" 2>/dev/null && [ "$stop_ticks" -lt 50 ]; do stop_ticks=$((stop_ticks + 1)); sleep 0.1; done',
	'		kill -KILL "$pid" 2>/dev/null',
	'	done',
	'fi',
	'failed="$root.failed-$$"',
	'if [ -e "$failed" ] || [ -L "$failed" ] || [ ! -d "$root.old" ] || ! mv -T -n "$root" "$failed" || [ -e "$root" ]; then',
	'	note "The updated daemon did not start ($failure) and could not be moved aside; the previous installation stays at $root.old."',
	'	finish; [ "$mode" = systemd ] && exit 1; exec "$@"',
	'fi',
	'if ! mv -T -n "$root.old" "$root" || [ -e "$root.old" ]; then',
	'	note "The previous installation could not be restored: it stays at $root.old, the new one at $failed."',
	'	finish; exit 1',
	'fi',
	'note "The updated daemon did not start ($failure): the previous installation is back and the new one is at $failed."',
	'finish',
	'[ "$mode" = systemd ] && { systemctl --user start "$unit"; exit 9; }',
	'exec "$@"',
}, "\n")

-- The watcher's wait, read from its script.
M.WATCH_READY_TICKS = tonumber(M.WATCH_SCRIPT:match('%[ "%$ready_ticks" %-gt (%d+) %]'))
assert(M.WATCH_READY_TICKS, "The update watcher names no boot-ready wait")

--- Allocates the watcher's one-shot token folder.
--- @param mkdtemp function|nil luv fs_mkdtemp or a test double.
--- @return string|nil token Path the new daemon reports to, nil when refused.
function M.allocate_token(mkdtemp)
	mkdtemp = mkdtemp or require("luv").fs_mkdtemp
	local base = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
	if base == "" then base = "/tmp" end
	local ok, dir = pcall(mkdtemp, base .. "/ergopti-boot-ready.XXXXXX")
	if not ok or type(dir) ~= "string" or dir == "" then return nil end
	return dir .. "/ready"
end

--- The watcher command line.
--- @param mode string "relay" or "systemd".
--- @param successor table { root, token, log }.
--- @param tail table Unit name (systemd) or launcher and arguments (relay).
--- @return string
function M.watch_command(mode, successor, tail)
	local argv = { "/bin/sh", "-c", ShellRunner.quote(M.WATCH_SCRIPT), "update-watch", mode,
		ShellRunner.quote(successor.root), ShellRunner.quote(successor.token), ShellRunner.quote(successor.log) }
	for _, value in ipairs(tail) do argv[#argv + 1] = ShellRunner.quote(tostring(value)) end
	return table.concat(argv, " ")
end

--- The watcher command line as systemd-run hands it to the manager.
--- systemd expands `$NAME`, `${NAME}` and `$$` in a unit's command line, so
--- the script's `$$` arrived as a lone `$`: every rollback under the unit moved
--- the tree to `<root>.failed-$`, and the next one found that name taken and
--- could not move aside. Doubling every `$` hands the script over intact.
--- @param successor table { root, token, log }.
--- @return string
function M.systemd_watch_command(successor)
	return (M.watch_command("systemd", successor, { M.UNIT }):gsub("%$", "$$"))
end

--- The launcher and its arguments as one list.
--- @param wrapper string The installed launcher.
--- @param args table|nil Its arguments.
--- @return table
local function launcher_argv(wrapper, args)
	local list = { wrapper }
	for _, value in ipairs(args or {}) do list[#list + 1] = value end
	return list
end

--- The detached relay command for a daemon not run by systemd.
--- @param pid integer The process to outlive.
--- @param wrapper string The installed launcher.
--- @param args table The daemon's own arguments.
--- @param cancel_path string|nil A marker file: when it exists once the process has
---   exited, the relay removes it and does not start the launcher (Quit won over the reload).
--- @param start_tick string Exact kernel start tick captured before dispatch.
--- @param successor table|nil { root, token, log }: the launcher then starts
---   under the update watcher.
--- @return string
function M.relay_command(pid, wrapper, args, cancel_path, start_tick, successor)
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
		pid, pid, ShellRunner.quote(start_tick), cancel,
		successor and M.watch_command("relay", successor, launcher_argv(wrapper, args))
		or table.concat(argv, " "))
	-- Keep dispatch in the foreground until the detached shell has forked its
	-- relay. An outer '&' reports success even when setsid cannot start at all,
	-- which would authorize shutdown with no process left to launch the update.
	return "setsid sh -c " .. ShellRunner.quote("(" .. script .. ") </dev/null >/dev/null 2>&1 &")
		.. " </dev/null >/dev/null 2>&1"
end

--- The marker a Quit creates to stop the relay of this process from starting the launcher.
--- It sits beside the bootstrap storage file, the per-user private location the driver
--- already owns for its restart handoffs (core/lifecycle/engine/reload/restart_pause.lua), so it never depends on
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
	return require("core.fs.adapters.storage").path() .. ".relay-cancel-" .. string.format("%.0f", pid)
		.. "-" .. start_tick .. "-" .. boot_id
end

-- Pin the exact dispatched marker so a transient /proc failure cannot defeat Quit.
local relay_marker, relay_pid
-- The transient unit watching an updated daemon under systemd, while one is armed.
local watch_unit, watch_token

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
		-- A Quit is no failed start: the watcher must not restore and start anything.
		if watch_unit then
			if not run("systemctl --user stop " .. ShellRunner.quote(watch_unit)) then
				return false, "systemctl refused to stop the update watcher"
			end
			run("systemctl --user unset-environment ERGOPTI_UPDATER_BOOT_READY")
			if watch_token then os.remove(watch_token); os.remove((watch_token:gsub("/ready$", ""))) end
			watch_unit, watch_token = nil, nil
		end
		if run(M.OWN_UNIT_JOB_PREFIX .. "systemctl --user --no-block stop " .. M.UNIT) then
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
--- @param opts table { wrapper, args, paused?, run?, cgroup?, pid?, start_tick?, boot_id?,
---   successor? }: successor { root } watches the updated daemon's start (see the header).
--- @return string|nil "systemd" (systemd stops and restarts this process) or
---   "relay" (the caller must now exit), nil when nothing could be started.
function M.restart(opts)
	if type(opts) ~= "table" or type(opts.wrapper) ~= "string" or opts.wrapper == "" then
		error("restart requires the installed launcher", 2)
	end
	local lease, Pause
	if opts.paused ~= nil then
		Pause = require("core.lifecycle.engine.reload.restart_pause")
		local detail
		lease, detail = Pause.prepare(opts.paused)
		if not lease then
			Logger.error(LOG, "Restart refused: %s.", tostring(detail))
			return nil
		end
	end
	local run = opts.run or ShellRunner.run
	-- The update watcher's token; without one the restart is unwatched, as before.
	local successor
	if type(opts.successor) == "table" and type(opts.successor.root) == "string" then
		local token = M.allocate_token(opts.mkdtemp)
		if token then
			successor = { root = opts.successor.root, token = token,
				log = opts.successor.log or (require("core.fs.adapters.storage").path() .. ".update-watch.log") }
		else
			Logger.warn(LOG, "No boot-ready token could be allocated; the updated daemon starts unwatched.")
		end
	end
	local function unwatched()
		if successor then os.remove(successor.token); os.remove((successor.token:gsub("/ready$", ""))) end
		successor = nil
	end
	local function dispatch()
		local under_unit = M.under_unit(opts.cgroup)
		if under_unit == nil then
			Logger.error(LOG, "Own cgroup unavailable or invalid — restart route cannot be determined.")
			return nil
		end
		if under_unit then
			-- The watcher runs as its own transient unit: the service's cgroup
			-- would kill it with this process. The token reaches the new daemon
			-- through the manager environment, which the watcher clears.
			if successor then
				if not run("systemctl --user set-environment " .. ShellRunner.quote("ERGOPTI_UPDATER_BOOT_READY="
					.. successor.token)) then
					Logger.warn(LOG, "systemd refused the boot-ready token; the updated daemon starts unwatched.")
					unwatched()
				else
					local unit = "ergopti-update-watch-" .. successor.token:match("ergopti%-boot%-ready%.(%w+)/ready$") .. ".service"
					if not run("systemd-run --user --collect --quiet --unit=" .. ShellRunner.quote(unit) .. " "
						.. M.systemd_watch_command(successor)) then
						Logger.warn(LOG, "The update watcher unit could not start; the updated daemon starts unwatched.")
						run("systemctl --user unset-environment ERGOPTI_UPDATER_BOOT_READY")
						unwatched()
					else
						watch_unit, watch_token = unit, successor.token
						Logger.info(LOG, "Update watcher armed: the previous installation returns unless the new daemon reports ready.")
					end
				end
			end
			-- --no-block: systemd restarts the unit after this call returns, by
			-- stopping this process the way a logout does.
			if run(M.OWN_UNIT_JOB_PREFIX .. "systemctl --user --no-block restart " .. M.UNIT) then
				Logger.info(LOG, "Restart on the update requested from systemd.")
				return "systemd"
			end
			-- A watcher of a restart that never happens would roll a good update back.
			if watch_unit then
				run("systemctl --user stop " .. ShellRunner.quote(watch_unit))
				run("systemctl --user unset-environment ERGOPTI_UPDATER_BOOT_READY")
				watch_unit, watch_token = nil, nil
				unwatched()
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
		if not run(M.relay_command(pid, opts.wrapper, opts.args, marker, start_tick, successor)) then
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
