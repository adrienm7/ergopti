--- adapters/python_interpreter.lua

--- ==============================================================================
--- MODULE: Native Python Interpreter Resolver (Hammerspoon)
--- DESCRIPTION:
--- Names the python3 the driver's helper scripts may run: the first installed
--- interpreter whose executable carries a slice for the processor this process
--- runs on, read from its Mach-O header without starting it. On Apple silicon an
--- x86_64-only Python runs under Rosetta, and macOS then tells the user that an
--- Intel app is starting; such an interpreter is never returned.
---
--- FEATURES & RATIONALE:
--- 1. Nothing is executed to decide: starting an Intel Python to ask for its
---    architecture is the very launch that raises macOS's notice
---    (hardening-h-no-rosetta). The header names the slices; a framework build
---    also has its Python.app checked, which its bin/python3 hands over to.
--- 2. The shim is looked through: /usr/bin/python3 runs the python3 of the
---    active developer folder (DEVELOPER_DIR, the xcode-select link, then Xcode
---    and the Command Line Tools), which a Mac migrated from Intel may hold
---    as x86_64 only. That copy is checked, and it is what gets started.
--- 3. Fixed candidates, never PATH: the developer tools, Apple silicon
---    Homebrew, the python.org framework, then /usr/local (Intel Homebrew on a
---    migrated Mac, or python.org's links there). A candidate is taken only
---    when its own slices prove it native, whatever its folder suggests.
--- 4. A named refusal: with no native interpreter, resolve() returns nil and a
---    state naming every candidate it found with its slices, so the caller can
---    tell the user why and offer the install (ui/python_runtime_offer.lua).
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")

local LOG = "adapters.python_interpreter"

-- Mach-O CPU types (<mach/machine.h>).
local CPU_NAMES = {
	[0x01000007] = "x86_64", [0x0100000C] = "arm64", [7] = "i386", [12] = "arm",
	[0x0200000C] = "arm64_32", [18] = "ppc", [0x01000012] = "ppc64",
}

-- Fat headers share their magic with Java class files, whose next word is a
-- version pair: more architectures than this is not a Mach-O.
local MAX_FAT_ARCHS = 16

-- Bytes read from an executable: the fat header and its slice table.
local HEADER_BYTES = 4096

-- The developer tool every developer folder holds.
M.DEVELOPER_TOOL = "usr/bin/python3"

-- The link `xcode-select --switch` writes.
M.SELECT_LINK = "/var/db/xcode_select_link"

-- Developer folders the shim tries when neither DEVELOPER_DIR nor the link
-- names one, in libxcselect's order.
M.DEFAULT_DEVELOPER_DIRS = {
	"/Applications/Xcode.app/Contents/Developer",
	"/Library/Developer/CommandLineTools",
}

-- The other interpreters, most likely native first.
M.OTHER_CANDIDATES = {
	{ path = "/opt/homebrew/bin/python3", origin = "Homebrew (Apple silicon)" },
	{ path = "/Library/Frameworks/Python.framework/Versions/Current/bin/python3", origin = "python.org" },
	{ path = "/usr/local/bin/python3", origin = "/usr/local" },
}

-- Native edges, replaceable by tests (M._set_deps).
local DEFAULT_DEPS = {
	--- Reads the first bytes of a file, following links.
	read_head = function(path)
		local fh = io.open(path, "rb")
		if not fh then return nil end
		local head = fh:read(HEADER_BYTES)
		fh:close()
		return head or ""
	end,
	--- Resolves links, or returns nil.
	realpath = function(path)
		local ok, real = pcall(function() return hs.fs.pathToAbsolute(path) end)
		if ok and type(real) == "string" and real ~= "" then return real end
		return nil
	end,
	getenv = os.getenv,
	--- The folder the xcode-select link names, nil without a link.
	select_link_target = function(path)
		local ok, mode = pcall(function() return hs.fs.symlinkAttributes(path, "mode") end)
		if not ok or mode ~= "link" then return nil end
		local resolved, real = pcall(function() return hs.fs.pathToAbsolute(path) end)
		if resolved and type(real) == "string" and real ~= "" then return real end
		return nil
	end,
	--- The processor this process runs as.
	process_arch = function()
		local info = type(hs.processInfo) == "table" and hs.processInfo.arch or nil
		if type(info) == "string" and info ~= "" then return info end
		local ok, out = pcall(function() return hs.execute("/usr/bin/uname -m") end)
		if ok and type(out) == "string" then return (out:gsub("%s+$", "")) end
		return nil
	end,
}
local _deps = DEFAULT_DEPS

-- The processor this process runs as never changes while it runs; asked once
-- (its fallback is a subprocess), false when it could not be named.
local _native_arch = nil





-- =====================================
-- =====================================
-- ======= 1/ Mach-O Headers ===========
-- =====================================
-- =====================================

--- Reads one unsigned 32-bit integer.
--- @param bytes string
--- @param offset integer 1-based index of the first byte.
--- @param big_endian boolean
--- @return integer|nil value
local function u32(bytes, offset, big_endian)
	local a, b, c, d = bytes:byte(offset, offset + 3)
	if d == nil then return nil end
	if big_endian then return ((a * 256 + b) * 256 + c) * 256 + d end
	return ((d * 256 + c) * 256 + b) * 256 + a
end

--- Names the processors an executable's first bytes declare.
--- @param head string First bytes of the file.
--- @return table|nil archs Architecture names, e.g. { "x86_64", "arm64" }.
--- @return string|nil reason "script", "not_mach_o" or "truncated" when nil.
function M.parse_header(head)
	if type(head) ~= "string" or #head < 8 then return nil, "truncated" end
	if head:sub(1, 2) == "#!" then return nil, "script" end
	local magic = u32(head, 1, true)
	if magic == 0xCAFEBABE or magic == 0xCAFEBABF then
		local count = u32(head, 5, true)
		if count < 1 or count > MAX_FAT_ARCHS then return nil, "not_mach_o" end
		local entry = magic == 0xCAFEBABE and 20 or 32
		local archs = {}
		for index = 1, count do
			local cpu = u32(head, 9 + (index - 1) * entry, true)
			if cpu == nil then return nil, "truncated" end
			archs[#archs + 1] = CPU_NAMES[cpu] or string.format("cpu_0x%x", cpu)
		end
		return archs
	end
	local little = u32(head, 1, false)
	if little == 0xFEEDFACF or little == 0xFEEDFACE then
		local cpu = u32(head, 5, false)
		return { CPU_NAMES[cpu] or string.format("cpu_0x%x", cpu) }
	end
	if magic == 0xFEEDFACF or magic == 0xFEEDFACE then
		local cpu = u32(head, 5, true)
		return { CPU_NAMES[cpu] or string.format("cpu_0x%x", cpu) }
	end
	return nil, "not_mach_o"
end

--- Names the processors an executable file declares.
--- @param path string Absolute path; links are followed.
--- @return table|nil archs
--- @return string|nil reason "missing", or a parse_header() reason.
function M.file_archs(path)
	local head = _deps.read_head(path)
	if head == nil then return nil, "missing" end
	return M.parse_header(head)
end

--- The processor a native child of this process runs as.
--- @return string|nil arch "arm64" or "x86_64", nil when unknown.
function M.native_arch()
	if _native_arch == nil then
		local arch = _deps.process_arch()
		if arch == "arm64" or arch == "arm64e" then
			_native_arch = "arm64"
		elseif arch == "x86_64" or arch == "x86_64h" then
			_native_arch = "x86_64"
		else
			_native_arch = false
		end
	end
	return _native_arch or nil
end





-- =====================================
-- =====================================
-- ======= 2/ Candidates ===============
-- =====================================
-- =====================================

--- Tells whether a slice list runs natively.
--- @param archs table
--- @param native string
--- @return boolean
local function has_slice(archs, native)
	for _, arch in ipairs(archs) do
		if arch == native then return true end
	end
	return false
end

--- The developer folder /usr/bin/python3 runs its python3 from.
--- @return string|nil folder
function M.developer_dir()
	local override = _deps.getenv("DEVELOPER_DIR")
	if type(override) == "string" and override:sub(1, 1) == "/" then return override end
	local linked = _deps.select_link_target(M.SELECT_LINK)
	if linked then return linked end
	for _, folder in ipairs(M.DEFAULT_DEVELOPER_DIRS) do
		if _deps.read_head(folder .. "/" .. M.DEVELOPER_TOOL) ~= nil then return folder end
	end
	return nil
end

--- Every place an interpreter may be, in the order they are tried.
--- @return table candidates { path, origin }
function M.candidates()
	local list = {}
	local developer = M.developer_dir()
	if developer then
		list[1] = { path = developer .. "/" .. M.DEVELOPER_TOOL, origin = "developer tools (" .. developer .. ")" }
	end
	for _, candidate in ipairs(M.OTHER_CANDIDATES) do
		list[#list + 1] = { path = candidate.path, origin = candidate.origin }
	end
	return list
end

--- Checks that an interpreter runs natively: its executable, and the
--- Python.app a framework build's bin/python3 starts.
--- @param path string Interpreter path (a link is followed).
--- @param native string|nil Required processor, the native one by default.
--- @return boolean native_ok
--- @return table detail { path, archs, reason }
function M.inspect(path, native)
	native = native or M.native_arch()
	local archs, reason = M.file_archs(path)
	local detail = { path = path, archs = archs, reason = reason }
	if archs == nil then return false, detail end
	if native == nil then
		detail.reason = "unknown_native_arch"
		return false, detail
	end
	if not has_slice(archs, native) then
		detail.reason = "no_" .. native .. "_slice"
		return false, detail
	end
	local real = _deps.realpath(path) or path
	local version_root = real:match("^(.+/Versions/[^/]+)/bin/[^/]+$")
	if version_root then
		local app = version_root .. "/Resources/Python.app/Contents/MacOS/Python"
		local app_archs, app_reason = M.file_archs(app)
		if app_archs ~= nil and not has_slice(app_archs, native) then
			detail.reason = "app_no_" .. native .. "_slice"
			detail.archs = app_archs
			detail.path = app
			return false, detail
		end
		if app_archs == nil and app_reason ~= "missing" then
			detail.reason = "app_" .. tostring(app_reason)
			return false, detail
		end
	end
	return true, detail
end

--- Formats a slice list for logs and dialogs.
--- @param archs table|nil
--- @param reason string|nil
--- @return string
function M.describe_archs(archs, reason)
	if type(archs) == "table" then return table.concat(archs, "+") end
	return tostring(reason or "unknown")
end





-- =====================================
-- =====================================
-- ======= 3/ Resolution ===============
-- =====================================
-- =====================================

--- Names the python3 a helper may start on this Mac.
--- @return string|nil path Interpreter to start, nil when none is native.
--- @return table state { kind, native, found = { { path, origin, archs, reason } } };
---   kind is "ready", "python_missing" (no interpreter anywhere) or
---   "python_not_native" (only interpreters another processor needs).
function M.resolve()
	local native = M.native_arch()
	local state = { kind = "python_missing", native = native, found = {} }
	for _, candidate in ipairs(M.candidates()) do
		local ok, detail = M.inspect(candidate.path, native)
		if ok then
			state.kind = "ready"
			Logger.info(LOG, "Python for helpers: %s (%s, %s).", candidate.path, candidate.origin,
				M.describe_archs(detail.archs))
			return candidate.path, state
		end
		if detail.reason ~= "missing" then
			state.found[#state.found + 1] = {
				path = detail.path, origin = candidate.origin, archs = detail.archs, reason = detail.reason,
			}
			state.kind = "python_not_native"
		end
	end
	local listed = {}
	for _, found in ipairs(state.found) do
		listed[#listed + 1] = string.format("%s [%s]", found.path, M.describe_archs(found.archs, found.reason))
	end
	Logger.error(LOG, "No %s Python 3 on this Mac (%s): %s.", tostring(native), state.kind,
		#listed > 0 and table.concat(listed, ", ") or "none installed")
	return nil, state
end

--- Every installed interpreter this Mac runs natively, in resolution order,
--- for a consumer that needs more than the first one (the MLX installer picks
--- one recent enough to build its venv).
--- @return table paths
function M.native_candidates()
	local native = M.native_arch()
	local paths = {}
	for _, candidate in ipairs(M.candidates()) do
		if M.inspect(candidate.path, native) then paths[#paths + 1] = candidate.path end
	end
	return paths
end

--- Replaces native edges for tests; nil restores the defaults.
--- @param overrides table|nil { read_head, realpath, getenv, select_link_target, process_arch }
function M._set_deps(overrides)
	_native_arch = nil
	if overrides == nil then
		_deps = DEFAULT_DEPS
		return
	end
	_deps = setmetatable(overrides, { __index = DEFAULT_DEPS })
end

return M
