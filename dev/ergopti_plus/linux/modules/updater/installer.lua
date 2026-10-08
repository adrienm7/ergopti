--- modules/updater/installer.lua

--- ==============================================================================
--- MODULE: Standalone Update Installer (Linux)
--- DESCRIPTION:
--- Validates a canonical Linux release tarball and replaces the complete
--- standalone library root as one rollback-capable transaction. Package-managed
--- and immutable installations are classified by the manager and never enter
--- this module.
--- ==============================================================================

local M = {}

local Fs = require("adapters.file_system")
local Paths = require("infra.paths")
local Version = require("updater.version")
local Snapshot = require("diagnostics.snapshot")

local WORK_PREFIX = ".ergopti-update."





-- ==========================================
-- ==========================================
-- ======= 1/ Path and Status Helpers =======
-- ==========================================
-- ==========================================

local function shell_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- Normalises the variants returned by os.execute and pipe:close across LuaJIT
--- and Lua 5.4. A numeric non-zero status is failure even though Lua considers
--- every number truthy.
--- @param first any First process result.
--- @param exit_kind string|nil Exit kind.
--- @param exit_code number|nil Exit code.
--- @return boolean success
local function status_ok(first, exit_kind, exit_code)
	if first == true then
		return (exit_kind == nil or exit_kind == "exit")
			and (exit_code == nil or exit_code == 0)
	end
	if type(first) == "number" then return first == 0 end
	return false
end

M._status_ok = status_ok

local function run_command(command)
	return status_ok(os.execute(command))
end

local function capture_command(command)
	local pipe = io.popen(command)
	if not pipe then return nil end
	local output = pipe:read("*a")
	local first, exit_kind, exit_code = pipe:close()
	if not status_ok(first, exit_kind, exit_code) then return nil end
	return output
end

local function normalise_path(path)
	if type(path) ~= "string" or path == "" then return nil end
	path = Paths.normalize_native_separators(path):gsub("/+", "/")
	if path:sub(1, 1) ~= "/" then
		local cwd = Paths.current_directory()
		if type(cwd) ~= "string" or cwd == "" then return nil end
		path = cwd:gsub("/+$", "") .. "/" .. path
	end

	local parts = {}
	for part in path:gmatch("[^/]+") do
		if part == ".." then
			if #parts == 0 then return nil end
			parts[#parts] = nil
		elseif part ~= "." and part ~= "" then
			parts[#parts + 1] = part
		end
	end
	return "/" .. table.concat(parts, "/")
end

local function dirname(path)
	if path == "/" then return nil end
	return path:match("^(.*)/[^/]+$") or "/"
end

local function basename(path)
	return path:match("([^/]+)$")
end

local function is_direct_child(path, parent)
	return dirname(path) == parent and basename(path) ~= nil
end

local function default_probe(path, kind)
	local flag = kind == "dir" and "-d" or "-f"
	return run_command("test " .. flag .. " " .. shell_quote(path))
end

--- Resolves the installation that owns the running updater module.
--- @param source_path string debug source path for manager.lua.
--- @param probe function|nil Test hook receiving path and "file"/"dir".
--- @return table context Installation kind and owned paths.
function M.resolve(source_path, probe)
	probe = probe or default_probe
	local source = normalise_path((source_path or ""):gsub("^@", ""))
	if not source then return { kind = "unmanaged", reason = "module source path is not absolute" } end
	if os.getenv("APPIMAGE") or os.getenv("APPDIR") or os.getenv("FLATPAK_ID")
		or source:match("^/usr/") or source:match("^/app/") or source:match("^/nix/store/") then
		return { kind = "package", reason = "system package or immutable bundle owns this path" }
	end

	local script_dir = dirname(source)
	local driver_root = script_dir and normalise_path(script_dir .. "/../..") or nil
	if not driver_root or basename(driver_root) ~= "linux" then
		return { kind = "package", reason = "driver is not in the standalone linux/ sibling layout" }
	end

	local install_root = dirname(driver_root)
	local lib_dir = install_root and dirname(install_root) or nil
	local prefix = lib_dir and dirname(lib_dir) or nil
	if not install_root or not prefix or prefix == "/" then
		return { kind = "unmanaged", reason = "standalone install root is unsafe" }
	end

	local wrapper = prefix .. "/bin/ergopti-hotstrings"
	local shared_root = Paths.shared_root_from(driver_root,
		function(path) return probe(path, "file") end)
	if not shared_root or not probe(shared_root .. "/lua", "dir")
		or not probe(wrapper, "file") then
		return { kind = "unmanaged", reason = "standalone wrapper or shared tree is absent" }
	end

	return {
		kind = "standalone",
		install_root = install_root,
		parent = dirname(install_root),
		wrapper = wrapper,
	}
end

-- =========================================
-- =========================================
-- ======= 2/ Production Operations ========
-- =========================================
-- =========================================

local function split_lines(output)
	local lines = {}
	for line in tostring(output or ""):gmatch("[^\r\n]+") do
		lines[#lines + 1] = line
	end
	return lines
end

local function archive_listings_canonical(names, verbose)
	if type(names) ~= "string" or type(verbose) ~= "string" then return false, "archive listing failed" end

	local seen = {}
	for _, entry in ipairs(split_lines(names)) do
		if entry:sub(1, 1) == "/"
			or entry:find("\\", 1, true)
			or entry:find("..", 1, true)
			or entry:match("^%./") then
			return false, "archive contains an unsafe path: " .. entry
		end
		local top = entry:match("^([^/]+)")
		if top ~= "linux" and top ~= "_shared" and top ~= "bin"
			and top ~= "install.sh" then
			return false, "archive contains an unexpected root: " .. tostring(top)
		end
		seen[top] = true
	end

	for _, required in ipairs({ "linux", "_shared", "bin", "install.sh" }) do
		if not seen[required] then return false, "archive root is missing " .. required end
	end
	for _, line in ipairs(split_lines(verbose)) do
		local kind = line:sub(1, 1)
		if kind ~= "-" and kind ~= "d" then
			return false, "archive links and special files are not accepted"
		end
	end
	return true
end

local function archive_is_canonical(archive_path)
	local quoted = shell_quote(archive_path)
	local names = capture_command("tar -tzf " .. quoted .. " 2>/dev/null")
	local verbose = capture_command("tar -tvzf " .. quoted .. " 2>/dev/null")
	return archive_listings_canonical(names, verbose)
end

local DEFAULT_OPS = {}

function DEFAULT_OPS.make_work_dir(parent)
	local template = parent .. "/" .. WORK_PREFIX .. "XXXXXX"
	local output = capture_command("mktemp -d " .. shell_quote(template) .. " 2>/dev/null")
	if not output then return nil end
	local path = normalise_path(output:gsub("%s+$", ""))
	if not path or not is_direct_child(path, parent)
		or basename(path):sub(1, #WORK_PREFIX) ~= WORK_PREFIX then
		return nil
	end
	return path
end

function DEFAULT_OPS.validate_archive(archive_path)
	return archive_is_canonical(archive_path)
end

function DEFAULT_OPS.extract(archive_path, work_dir)
	return run_command("tar -xzf " .. shell_quote(archive_path)
		.. " -C " .. shell_quote(work_dir)
		.. " --no-same-owner --no-same-permissions 2>/dev/null")
end

--- Records the new payload before it can replace the user's installation.
--- @param root string Validated staging root containing only release files.
--- @param previous string Current installation whose launcher is retained.
--- @return boolean success
function DEFAULT_OPS.record_ownership(root, previous)
	-- The running updater owns the receipt format, not the selected release.
	if not run_command("bash " .. shell_quote(previous .. "/linux/install/ownership.sh")
		.. " " .. shell_quote(root .. "/linux") .. " " .. shell_quote(root .. "/_shared")
		.. " " .. shell_quote(root)) then return false end
	local manifest = previous .. "/.ergopti-owned-files"
	if not default_probe(manifest, "file") then return true end
	local old = Fs.read(manifest)
	if not old then return false end
	local retained = {}
	for line in old:gmatch("[^\r\n]+") do
		local digest, kind = line:match("^(%x+)\t@(%a+)$")
		if digest and #digest == 64 and (kind == "wrapper" or kind == "unit" or kind == "autostart") then
			retained[#retained + 1] = line .. "\n"
		end
	end
	return #retained == 0 or Fs.append(root .. "/.ergopti-owned-files", table.concat(retained))
end

function DEFAULT_OPS.mkdir(path)
	return run_command("mkdir -- " .. shell_quote(path) .. " 2>/dev/null")
end

function DEFAULT_OPS.is_file(path)
	return default_probe(path, "file")
end

function DEFAULT_OPS.is_dir(path)
	return default_probe(path, "dir")
end

function DEFAULT_OPS.read(path)
	return Fs.read(path)
end

function DEFAULT_OPS.exists(path)
	return default_probe(path, "dir") or default_probe(path, "file")
end

function DEFAULT_OPS.move(source, destination)
	return run_command("mv -- " .. shell_quote(source) .. " " .. shell_quote(destination) .. " 2>/dev/null")
end

function DEFAULT_OPS.remove_tree(path)
	return run_command("rm -rf -- " .. shell_quote(path) .. " 2>/dev/null")
end

function DEFAULT_OPS.remove_file(path)
	return run_command("rm -f -- " .. shell_quote(path) .. " 2>/dev/null")
end

function DEFAULT_OPS.smoke(wrapper)
	return run_command(shell_quote(wrapper) .. " --help >/dev/null 2>&1")
end

M.DEFAULT_OPS = DEFAULT_OPS

-- =========================================
-- =========================================
-- ======= 3/ Transaction ==================
-- =========================================
-- =========================================

local function validate_context(context)
	if type(context) ~= "table" or context.kind ~= "standalone" then
		return false, "installation is not standalone"
	end
	local root = normalise_path(context.install_root)
	local parent = normalise_path(context.parent)
	local wrapper = normalise_path(context.wrapper)
	if not root or not parent or not wrapper or parent == "/"
		or not is_direct_child(root, parent) then
		return false, "standalone installation paths are unsafe"
	end
	return true, { install_root = root, parent = parent, wrapper = wrapper }
end

local function validate_candidate(work_dir, expected_version, ops)
	local shared_root = Paths.shared_root_from(work_dir .. "/linux", ops.is_file)
	local required_files = {
		work_dir .. "/linux/ergopti_hotstrings.lua",
		work_dir .. "/linux/infra/version.lua",
		work_dir .. "/bin/ergopti-hotstrings",
		work_dir .. "/install.sh",
	}
	for _, path in ipairs(required_files) do
		if not ops.is_file(path) then return false, "staged archive is missing " .. path end
	end
	if not shared_root or not ops.is_dir(shared_root .. "/lua") then
		return false, "staged archive is missing the shared Lua tree"
	end

	-- The driver version is the release version the release build stamped into
	-- the shared tree (infra/version.lua reads the same entry at runtime), so the
	-- staged tree's stamp is what the running daemon will report after the swap.
	local stamp = ops.read(shared_root .. "/" .. Snapshot.BUILD_STAMP_FILE)
	local staged_version = stamp and Snapshot.parse_build_version(stamp) or nil
	if not staged_version
		or Version.normalize_tag(staged_version) ~= Version.normalize_tag(expected_version) then
		return false, "staged driver version does not match the selected release"
	end
	return true
end

local function cleanup_work(work_dir, parent, ops)
	if not work_dir then return true end
	if not is_direct_child(work_dir, parent)
		or basename(work_dir):sub(1, #WORK_PREFIX) ~= WORK_PREFIX then
		return false
	end
	return ops.remove_tree(work_dir)
end

--- Installs one validated archive into a standalone root.
--- @param options table archive_path, expected_version, context, optional ops.
--- @return boolean success
--- @return string|nil detail Failure or cleanup detail.
local function install_transaction(options, owned_current)
	options = options or {}
	local ops = options.ops or DEFAULT_OPS
	local context_ok, context = validate_context(options.context)
	if not context_ok then return false, context end
	if not owned_current and (type(options.archive_path) ~= "string" or options.archive_path == "") then
		return false, "archive path is absent"
	end
	if type(options.expected_version) ~= "string" or options.expected_version == "" then
		return false, "selected release version is absent"
	end

	local function forward_current()
		if not owned_current then return true end
		local checked, accepted = pcall(owned_current)
		return checked and accepted == true
	end
	if not forward_current() then return false, "local install admission expired" end
	local archive_ok, archive_error = ops.validate_archive(options.archive_path)
	if not archive_ok then return false, archive_error end
	if not forward_current() then return false, "local install admission expired" end
	local work_dir = ops.make_work_dir(context.parent)
	if not work_dir then return false, "could not allocate same-filesystem staging" end

	local function fail(detail)
		cleanup_work(work_dir, context.parent, ops)
		return false, detail
	end

	if not forward_current() or not ops.extract(options.archive_path, work_dir) then
		return fail("archive extraction failed")
	end
	if not forward_current() then return fail("local install deadline expired") end
	local candidate_ok, candidate_error = validate_candidate(work_dir, options.expected_version, ops)
	if not candidate_ok then return fail(candidate_error) end

	local candidate = work_dir .. "/candidate"
	if not forward_current() or not ops.mkdir(candidate)
		or not ops.move(work_dir .. "/linux", candidate .. "/linux")
		or not ops.move(work_dir .. "/_shared", candidate .. "/_shared")
		or not ops.move(work_dir .. "/bin", candidate .. "/bin") then
		return fail("could not assemble the complete candidate root")
	end
	if not forward_current() or not ops.record_ownership(candidate, context.install_root) then
		return fail("could not record the new installation's file ownership")
	end

	local backup = context.install_root .. ".old"
	if not is_direct_child(backup, context.parent) then
		return fail("backup path escaped the installation parent")
	end
	if not forward_current() then return fail("local install deadline expired") end
	if ops.exists(backup) and not ops.remove_tree(backup) then
		return fail("previous backup could not be retired")
	end
	if not forward_current() or not ops.move(context.install_root, backup) then
		return fail("current installation could not be moved to backup")
	end

	if not forward_current() or not ops.move(candidate, context.install_root) then
		local restored = ops.move(backup, context.install_root)
		cleanup_work(work_dir, context.parent, ops)
		if not restored then
			return false, "candidate activation and rollback both failed; backup remains at " .. backup
		end
		return false, "candidate activation failed; previous installation restored"
	end

	if not forward_current() or not ops.smoke(context.wrapper) or not forward_current() then
		local failed_root = work_dir .. "/failed"
		local displaced = ops.move(context.install_root, failed_root)
		local restored = displaced and ops.move(backup, context.install_root)
		if restored then
			cleanup_work(work_dir, context.parent, ops)
			return false, "updated wrapper smoke failed; previous installation restored"
		end
		return false, "updated wrapper smoke and rollback failed; backup remains at " .. backup
	end

	local work_removed = cleanup_work(work_dir, context.parent, ops)
	local archive_removed = ops.remove_file(options.archive_path)
	if not work_removed or not archive_removed then
		return true, "update installed but temporary cleanup was incomplete"
	end
	return true
end

--- Original synchronous API and all default filesystem operations are retained.
function M.install(options) return install_transaction(options, nil) end

-- Captured physical operations, not coroutine scheduling, authorize resumption.
local retained_installs = {}

-- The fixed producer knows this refusal occurred before its first reader. It
-- still owns an accepted registry reservation, so return an authentic cleanup
-- operation rather than an unowned nil result or a guessed physical ACK.
local function refuse_owned_admission(finish, reservation, callback)
 local operation = { started = true }
 local work = { constructing = true, received = false, done = false, listeners = {} }
 retained_installs[work] = true
 local function publish()
  if work.publishing or work.constructing or work.unknown or work.done or not work.child or not work.received then return end
  work.publishing = true
  local guarded = pcall(function()
   local checked, physical = pcall(work.methods.is_settled, work.child)
   if not checked or physical ~= true or work.done or work.constructing or work.unknown then return end
   if type(work.result) ~= "table" or rawget(work.result, "ok") ~= true then work.unknown = true; return end
   work.done = true
   retained_installs[work] = nil
   pcall(callback, false, "local install admission expired or refused")
   local listeners = work.listeners; work.listeners = {}
   for _, listener in ipairs(listeners) do pcall(listener) end
  end)
  work.publishing = false
  if not guarded then work.unknown = true end
 end
 local acquired, child = pcall(finish, reservation, true, function(result)
  if work.received then return end
  work.received, work.result = true, result
  publish()
 end)
 if acquired and type(child) == "table" then
  local methods = { is_settled = rawget(child, "is_settled"),
   cancel = rawget(child, "request_cancel") or rawget(child, "cancel"), on_settled = rawget(child, "on_settled") }
  if type(methods.is_settled) == "function" and type(methods.cancel) == "function" and type(methods.on_settled) == "function" then
   work.child, work.methods = child, methods
   local observed, ack = pcall(methods.on_settled, child, publish)
   if not observed or ack ~= true then work.unknown = true end
  else work.unknown = true end
 else work.unknown = true end -- Unknown finish acquisition cannot stand for physical retirement.
 work.constructing = false
 if work.unknown and work.child then pcall(work.methods.cancel, work.child) end
 function operation:is_settled() return work.done end
 function operation:on_settled(listener)
  if type(listener) ~= "function" then return false end
  if work.done then pcall(listener) else work.listeners[#work.listeners + 1] = listener end
  return true
 end
 function operation:request_cancel()
  if not work.done and work.child and not work.signalled then
   work.signalled = true; pcall(work.methods.cancel, work.child)
  end
  publish()
  return true
 end
 function operation:cancel() operation.request_cancel(operation); return work.done end
 publish()
 return operation
end

--- Runs the original rollback transaction on one private native reservation.
--- No displayed archive path is opened. The fixed artifact factory owns every
--- listing/extract reader and cleanup; returned operation methods export no FD.
function M.install_owned(options, callback)
 if type(options) ~= "table" or type(callback) ~= "function" then return nil end
 local factory, reservation = rawget(options, "factory"), rawget(options, "reservation")
 if type(factory) ~= "table" or reservation == nil then return nil end
 local valid, feed, finish = rawget(factory, "install_current"), rawget(factory, "install_feed"), rawget(factory, "finish_install")
 if type(valid) ~= "function" or type(feed) ~= "function" or type(finish) ~= "function" then return nil end
 local checked, admitted = pcall(valid, reservation)
 if not checked or admitted ~= true then return refuse_owned_admission(finish, reservation, callback) end
 local task = { waiting = nil, pumping = false, done = false, unknown = false, listeners = {}, cancelled = false }
 local operation = { started = true }
 retained_installs[task] = true
 local pump
 local function await(start, cleanup_only)
  if task.cancelled and not cleanup_only then return { ok = false } end
  local work = { received = false }
  task.waiting = work -- Reserve before construction or any native callback.
  local called, child = pcall(start, function(result)
   if task.waiting ~= work or work.received then return end
   work.received, work.result = true, result
   pump()
  end)
  local probe = type(child) == "table" and rawget(child, "is_settled") or nil
  local signal = type(child) == "table" and (rawget(child, "request_cancel") or rawget(child, "cancel")) or nil
  local observe = type(child) == "table" and rawget(child, "on_settled") or nil
  if called and type(probe) == "function" and type(signal) == "function" and type(observe) == "function" then
   work.operation, work.probe, work.signal = child, probe, signal
   local registered, ack = pcall(observe, child, pump)
   if not registered or ack ~= true then task.unknown = true end
   if task.cancelled or task.unknown then
    work.signalled = true; pcall(signal, child)
   end
  else task.unknown = true end -- Unknown acquisition is retained physical debt.
  return coroutine.yield()
 end
 local function owned_current()
  if task.done or task.unknown or task.cancelled then return false end
  local observed, current = pcall(valid, reservation)
  return observed and current == true and not task.done and not task.unknown and not task.cancelled
 end
 local ops = {}
 for name, fn in next, DEFAULT_OPS do ops[name] = fn end
 ops.validate_archive = function()
  local names = await(function(done) return feed(reservation, "names", nil, done, owned_current) end)
  if type(names) ~= "table" or names.ok ~= true then return false, "archive listing failed" end
  local verbose = await(function(done) return feed(reservation, "verbose", nil, done, owned_current) end)
  if type(verbose) ~= "table" or verbose.ok ~= true then return false, "archive listing failed" end
  return archive_listings_canonical(names.stdout, verbose.stdout)
 end
 ops.extract = function(_, work_dir)
  local result = await(function(done) return feed(reservation, "extract", work_dir, done, owned_current) end)
  return type(result) == "table" and result.ok == true
 end
 ops.remove_file = function()
  local result = await(function(done) return finish(reservation, false, done) end, true)
  task.artifact_finished = true
  return type(result) == "table" and result.ok == true
 end
 local captured = { context = rawget(options, "context"), expected_version = rawget(options, "expected_version"),
  archive_path = reservation, ops = ops }
 local thread = coroutine.create(function()
  local installed, detail = install_transaction(captured, owned_current)
  if not task.artifact_finished then
   -- A failed installation retains its authenticated artifact for a fresh
   -- user retry, but all native readers/consumer debt must retire first.
   local retired = await(function(done) return finish(reservation, true, done) end, true)
   if type(retired) ~= "table" or retired.ok ~= true then task.unknown = true; return end
  end
  return installed, detail
 end)
 pump = function()
  if task.pumping or task.done or task.unknown then return end
  task.pumping = true
  local input
  while not task.done and not task.unknown do
   if task.waiting then
    local work = task.waiting
    if not work.received or not work.operation then break end
    local probed, settled = pcall(work.probe, work.operation)
    if not probed or settled ~= true or task.waiting ~= work or task.unknown then break end
    task.waiting, input = nil, work.result
   end
   local resumed, installed, detail = coroutine.resume(thread, input)
   input = nil
   if not resumed then task.unknown = true; break end
   if coroutine.status(thread) == "dead" then
    task.done = true
    retained_installs[task] = nil
    pcall(callback, installed == true, detail)
    local listeners = task.listeners
    task.listeners = {}
    for _, listener in ipairs(listeners) do pcall(listener) end
    break
   end
   if not task.waiting then task.unknown = true; break end
  end
  task.pumping = false
 end
 function operation:is_settled() return task.done end
 function operation:on_settled(listener)
  if type(listener) ~= "function" then return false end
  if task.done then pcall(listener) else task.listeners[#task.listeners + 1] = listener end
  return true
 end
 function operation:request_cancel()
  if task.done then return true end
  task.cancelled = true
  local work = task.waiting
  if work and work.operation and work.signal and not work.signalled then
   work.signalled = true; pcall(work.signal, work.operation)
  end
  pump()
  return true
 end
 function operation:cancel()
  if not task.done then operation.request_cancel(operation) end
  return task.done
 end
 pump()
 return operation
end

return M
