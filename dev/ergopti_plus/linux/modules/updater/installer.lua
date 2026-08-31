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
	path = path:gsub("\\", "/"):gsub("/+", "/")
	if path:sub(1, 1) ~= "/" then
		local cwd = os.getenv("PWD")
		if type(cwd) ~= "string" or cwd == "" then
			cwd = capture_command("pwd 2>/dev/null")
			if cwd then cwd = cwd:gsub("%s+$", "") end
		end
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

local function archive_is_canonical(archive_path)
	local quoted = shell_quote(archive_path)
	local names = capture_command("tar -tzf " .. quoted .. " 2>/dev/null")
	local verbose = capture_command("tar -tvzf " .. quoted .. " 2>/dev/null")
	if not names or not verbose then return false, "archive listing failed" end

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
			and top ~= "install.sh" and top ~= "kanata.kbd" then
			return false, "archive contains an unexpected root: " .. tostring(top)
		end
		seen[top] = true
	end

	for _, required in ipairs({ "linux", "_shared", "bin", "install.sh", "kanata.kbd" }) do
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
		work_dir .. "/kanata.kbd",
	}
	for _, path in ipairs(required_files) do
		if not ops.is_file(path) then return false, "staged archive is missing " .. path end
	end
	if not shared_root or not ops.is_dir(shared_root .. "/lua") then
		return false, "staged archive is missing the shared Lua tree"
	end

	local version_source = ops.read(work_dir .. "/linux/infra/version.lua")
	local staged_version = version_source and version_source:match('M%.VERSION%s*=%s*"([^"]+)"') or nil
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
function M.install(options)
	options = options or {}
	local ops = options.ops or DEFAULT_OPS
	local context_ok, context = validate_context(options.context)
	if not context_ok then return false, context end
	if type(options.archive_path) ~= "string" or options.archive_path == "" then
		return false, "archive path is absent"
	end
	if type(options.expected_version) ~= "string" or options.expected_version == "" then
		return false, "selected release version is absent"
	end

	local archive_ok, archive_error = ops.validate_archive(options.archive_path)
	if not archive_ok then return false, archive_error end
	local work_dir = ops.make_work_dir(context.parent)
	if not work_dir then return false, "could not allocate same-filesystem staging" end

	local function fail(detail)
		cleanup_work(work_dir, context.parent, ops)
		return false, detail
	end

	if not ops.extract(options.archive_path, work_dir) then
		return fail("archive extraction failed")
	end
	local candidate_ok, candidate_error = validate_candidate(work_dir, options.expected_version, ops)
	if not candidate_ok then return fail(candidate_error) end

	local candidate = work_dir .. "/candidate"
	if not ops.mkdir(candidate)
		or not ops.move(work_dir .. "/linux", candidate .. "/linux")
		or not ops.move(work_dir .. "/_shared", candidate .. "/_shared") then
		return fail("could not assemble the complete candidate root")
	end

	local backup = context.install_root .. ".old"
	if not is_direct_child(backup, context.parent) then
		return fail("backup path escaped the installation parent")
	end
	if ops.exists(backup) and not ops.remove_tree(backup) then
		return fail("previous backup could not be retired")
	end
	if not ops.move(context.install_root, backup) then
		return fail("current installation could not be moved to backup")
	end

	if not ops.move(candidate, context.install_root) then
		local restored = ops.move(backup, context.install_root)
		cleanup_work(work_dir, context.parent, ops)
		if not restored then
			return false, "candidate activation and rollback both failed; backup remains at " .. backup
		end
		return false, "candidate activation failed; previous installation restored"
	end

	if not ops.smoke(context.wrapper) then
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

return M
