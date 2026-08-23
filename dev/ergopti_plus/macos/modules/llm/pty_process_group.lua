--- modules/llm/pty_process_group.lua

--- ==============================================================================
--- MODULE: PTY Process-Group Wrapper
--- DESCRIPTION:
--- Publishes a temporary Python wrapper that gives an hs.task one exact native
--- parent for a whole shell process group. SIGTERM/SIGINT/SIGHUP are forwarded
--- to every descendant and the wrapper waits for the group leader before its
--- own terminal callback can prove settlement.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")

local LOG = "llm.pty_process_group"

-- A failed close/remove is ambiguous: the native operation may have mutated
-- before refusing. Keep the exact handle/path reachable until a later explicit
-- retry proves both capabilities settled.
local _file_cleanup_debt = {}
local _path_cleanup_debt = {}

local WRAPPER_SOURCE = [[import os, sys, select, subprocess, signal, time
proc = None
pending_signals = []
def forward_signal(signum, _frame):
    if proc is None:
        pending_signals.append(signum)
        return
    try: os.killpg(proc.pid, signum)
    except ProcessLookupError: pass
for forwarded in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(forwarded, forward_signal)
master_fd, slave_fd = os.openpty()
proc = subprocess.Popen(sys.argv[1:], stdin=slave_fd, stdout=slave_fd, stderr=slave_fd, close_fds=True, start_new_session=True)
os.close(slave_fd)
for pending in pending_signals:
    try: os.killpg(proc.pid, pending)
    except ProcessLookupError: pass
pending_signals = []
while True:
    try:
        ready, _, _ = select.select([master_fd], [], [], 0.05)
    except (OSError, ValueError): break
    if ready:
        try:
            data = os.read(master_fd, 4096)
        except OSError: break
        if not data: break
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
    elif proc.poll() is not None:
        try: os.killpg(proc.pid, 0)
        except ProcessLookupError: break
proc.wait()
while True:
    try: os.killpg(proc.pid, 0)
    except ProcessLookupError: break
    time.sleep(0.05)
os.close(master_fd)
sys.exit(proc.returncode)
]]

--- Removes one exact path only on a literal native success.
--- @param path string Exact wrapper path.
--- @param label string Stable diagnostic label.
--- @return boolean removed
local function remove_exact(path, label)
	local ok, removed_or_error, detail = xpcall(function()
		return os.remove(path)
	end, debug.traceback)
	if ok ~= true or removed_or_error ~= true then
		_path_cleanup_debt[path] = true
		Logger.error(LOG, "%s removal failed for %s: %s.",
			tostring(label), tostring(path),
			tostring(ok == true and (detail or removed_or_error) or removed_or_error))
		return false
	end
	_path_cleanup_debt[path] = nil
	return true
end

--- Closes one exact file handle only on a literal native success.
--- @param file file* Exact wrapper file handle.
--- @param path string Exact wrapper path.
--- @param label string Stable diagnostic label.
--- @param remove_after_close boolean Whether settlement must also unlink path.
--- @return boolean closed
local function close_exact(file, path, label, remove_after_close)
	local ok, closed_or_error, detail = xpcall(function()
		return file:close()
	end, debug.traceback)
	if ok ~= true or closed_or_error ~= true then
		_file_cleanup_debt[file] = {
			path = path,
			label = label,
			remove_after_close = remove_after_close == true,
		}
		Logger.error(LOG, "%s close failed for %s: %s.",
			tostring(label), tostring(path),
			tostring(ok == true and (detail or closed_or_error) or closed_or_error))
		return false
	end
	_file_cleanup_debt[file] = nil
	return true
end

--- Retries retained close debt for one path before an unlink attempt.
--- @param path string Exact wrapper path.
--- @return boolean settled
--- @return boolean had_debt
local function retry_file_debt_for_path(path)
	local entries = {}
	for file, entry in pairs(_file_cleanup_debt) do
		if entry.path == path then
			entries[#entries + 1] = { file = file, entry = entry }
		end
	end
	local settled = true
	local had_debt = #entries > 0
	for _, item in ipairs(entries) do
		local entry = item.entry
		if _file_cleanup_debt[item.file] == entry then
			if close_exact(item.file, entry.path, entry.label,
				entry.remove_after_close) ~= true then
				settled = false
			elseif entry.remove_after_close
				and remove_exact(entry.path, entry.label) ~= true then
				settled = false
			end
		end
	end
	return settled, had_debt
end

--- Writes one unpublished wrapper file.
--- @param label string Stable filename/log label.
--- @return string|nil path
--- @return string|nil error_detail
function M.create(label)
	-- A successor is also the retry opportunity for every exact cleanup
	-- capability retained by an earlier wrapper transaction. Do not accumulate
	-- unpublished files while one of those identities is still ambiguous.
	if M.retry_cleanup() ~= true then
		Logger.error(LOG, "%s wrapper creation blocked by prior cleanup debt.",
			tostring(label))
		return nil, "prior wrapper cleanup unsettled"
	end
	local tmp_ok, path_or_error = xpcall(os.tmpname, debug.traceback)
	if not tmp_ok or type(path_or_error) ~= "string" or path_or_error == "" then
		Logger.error(LOG, "%s wrapper path allocation failed: %s.",
			tostring(label), tostring(path_or_error))
		return nil, tostring(path_or_error)
	end
	local path = path_or_error
	local open_ok, file_or_error, open_detail = xpcall(function()
		return io.open(path, "w")
	end, debug.traceback)
	if open_ok ~= true or file_or_error == nil or file_or_error == false then
		remove_exact(path, tostring(label) .. " wrapper rollback")
		local detail = open_ok == true and (open_detail or file_or_error) or file_or_error
		Logger.error(LOG, "%s wrapper open failed: %s.",
			tostring(label), tostring(detail))
		return nil, tostring(detail)
	end
	local file = file_or_error
	local write_ok, written_or_error, write_detail = xpcall(function()
		return file:write(WRAPPER_SOURCE)
	end, debug.traceback)
	if write_ok ~= true or written_or_error == nil or written_or_error == false then
		local detail = write_ok == true and (write_detail or written_or_error)
			or written_or_error
		if close_exact(file, path, tostring(label) .. " wrapper rollback", true) then
			remove_exact(path, tostring(label) .. " wrapper rollback")
		end
		Logger.error(LOG, "%s wrapper write failed: %s.",
			tostring(label), tostring(detail))
		return nil, tostring(detail)
	end
	if close_exact(file, path, tostring(label) .. " wrapper publication", true) ~= true then
		Logger.error(LOG, "%s wrapper publication close did not commit.", tostring(label))
		return nil, "wrapper close refused"
	end
	return path, nil
end

--- Removes one exact settled wrapper path.
--- @param path string|nil Wrapper path returned by create().
--- @return boolean removed
function M.remove(path)
	if type(path) ~= "string" or path == "" then return true end
	local settled, had_debt = retry_file_debt_for_path(path)
	if settled ~= true then return false end
	if had_debt == true then return _path_cleanup_debt[path] ~= true end
	return remove_exact(path, "Wrapper")
end

--- Retries every exact wrapper cleanup capability retained after refusal.
--- @return boolean settled
function M.retry_cleanup()
	local paths = {}
	for path in pairs(_path_cleanup_debt) do paths[#paths + 1] = path end
	local files = {}
	for file, entry in pairs(_file_cleanup_debt) do
		files[#files + 1] = { file = file, entry = entry }
	end
	local settled = true
	for _, item in ipairs(files) do
		local entry = item.entry
		if _file_cleanup_debt[item.file] == entry then
			if close_exact(item.file, entry.path, entry.label,
				entry.remove_after_close) ~= true then
				settled = false
			elseif entry.remove_after_close
				and remove_exact(entry.path, entry.label) ~= true then
				settled = false
			end
		end
	end
	for _, path in ipairs(paths) do
		if _path_cleanup_debt[path] == true
			and remove_exact(path, "Wrapper cleanup retry") ~= true then
			settled = false
		end
	end
	return settled
end

return M
