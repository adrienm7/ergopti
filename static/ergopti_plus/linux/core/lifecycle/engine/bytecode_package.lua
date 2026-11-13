--- core/lifecycle/engine/bytecode_package.lua

--- ==============================================================================
--- MODULE: Installed-Tree Bytecode Package
--- DESCRIPTION:
--- Before the boot clock starts, the daemon requires about 440 modules; LuaJIT
--- spends most of that time compiling source. An installed tree is compiled
--- once, by the installer and the updater with the target's own luajit, into
--- <root>/.bytecode/: one bundle of string.dump chunks (debug info kept, so
--- tracebacks and source-identity checks see the same names) and a manifest.
---
--- THE CONTRACT (maintainer decision 2026-11-11, docs/memory/maintainer-decisions.md):
--- 1. Bytecode is read only in an installed tree (its ownership receipt beside
---    linux/ and _shared/), launched through its physical path, never from a
---    checkout: a saved source file always takes effect in a dev run.
--- 2. The manifest names the runtime (jit.version, the first words of
---    `luajit -v`), the architecture, the GC64 flag, the physical root, and each
---    chunk's offset, length and source SHA-256. It is trusted only when every
---    line parses, the runtime matches the running luajit and the bundle has
---    exactly the declared size.
--- 3. Anything else loads every module from source and logs one warning; the
---    next updater run recompiles. The decision is taken once, before the first
---    module loads, so no boot mixes the two; an application module missing from
---    a trusted package is a modified tree and raises.
--- 4. The tree is derived: the ownership receipt does not list it, the receipt
---    verifier admits it by name (OWNERSHIP_DERIVED_TREE), uninstall removes it.
---
--- This module runs before the logger and the shared path owners load: it
--- depends on LuaJIT and the generated identifiers table alone.
--- ==============================================================================

local M = {}

-- The package's file names and wire markers (_shared/core/text/data/identifiers.json).
local Names = require("core.text.engine.identifiers").bytecode_package
M.MANIFEST = Names.manifest
M.BUNDLE = Names.bundle
local FORMAT = Names.format
local END_MARKER = Names.end_marker
-- The tree's own receipt, derived-tree names and digest length: the ownership
-- schema is their one source, shared with install.sh, uninstall.sh and the
-- receipt verifier.
local SCHEMA = "/linux/install/ownership_schema.sh"





-- =============================
-- =============================
-- ======= 1/ Identity =========
-- =============================
-- =============================

--- The running interpreter as the manifest names it.
--- @return table runtime { version, arch, gc64 }
function M.runtime()
	local ffi = require("ffi")
	return { version = jit.version, arch = jit.arch, gc64 = ffi.abi("gc64") and "true" or "false" }
end

--- The shared Lua directory as the daemon spells it beside a driver directory:
--- the resolver probes the sibling layout (<driver>/../_shared) before the child
--- one in the order the bootstrap writes package.path, and keeps the spelling,
--- so searchpath's names and the chunk names match it.
--- @param driver_dir string The driver directory as the daemon spells it.
--- @return string|nil prefix "<shared root>/", nil when no shared tree is there.
function M.shared_lua_prefix(driver_dir)
	local shared = require("core.fs.engine.paths").shared_root_from(driver_dir)
	return shared and shared .. "/" or nil
end

--- The spelling the daemon gives a module file at runtime, which LuaJIT keeps
--- inside the dumped chunk as its source name.
--- @param root string Physical installation root.
--- @param relative string Root-relative path, linux/... or _shared/...
--- @return string|nil filename
function M.runtime_filename(root, relative)
	local driver = relative:match("^linux/(.+%.lua)$")
	if driver then return root .. "/linux/" .. driver end
	local shared = relative:match("^_shared/(.+%.lua)$")
	local prefix = shared and M.shared_lua_prefix(root .. "/linux")
	if prefix then return prefix .. shared end
	return nil
end

--- Reads the receipt and derived-tree names from a tree's ownership schema.
--- @param root string Installation root.
--- @return table|nil names { receipt, directory, hex_length }
function M.schema_names(root)
	local file = io.open(root .. SCHEMA, "rb")
	if not file then return nil end
	local text = file:read("*a")
	file:close()
	local receipt = text:match("\nOWNERSHIP_MANIFEST='([%w_.-]+)'\n")
	local directory = text:match("\nOWNERSHIP_DERIVED_TREE='([%w_.-]+)'\n")
	local hex_length = tonumber(text:match("\nOWNERSHIP_HEX_LENGTH='(%d+)'\n"))
	if not receipt or not directory or not hex_length then return nil end
	return { receipt = receipt, directory = directory, hex_length = hex_length }
end

--- Whether a root-relative path may name a chunk: a .lua file below linux/ or
--- _shared/, without blanks, backslashes or dot segments. Runs once per
--- manifest line at every boot, so it is a few plain searches.
local function valid_relative(relative)
	if type(relative) ~= "string" or relative:find(" ", 1, true) or relative:find("\t", 1, true)
		or relative:find("\\", 1, true) or relative:find("\0", 1, true) then
		return false
	end
	if relative:find("/./", 1, true) or relative:find("/../", 1, true) or relative:find("//", 1, true) then return false end
	if relative:sub(-4) ~= ".lua" then return false end
	return (#relative > 10 and relative:sub(1, 6) == "linux/") or (#relative > 16 and relative:sub(1, 8) == "_shared/")
end





-- =============================
-- =============================
-- ======= 2/ Manifest =========
-- =============================
-- =============================

--- Renders the manifest of a compiled bundle.
--- @param root string Physical installation root.
--- @param runtime table M.runtime().
--- @param entries table Dense { relative, offset, length, digest } rows in bundle order.
--- @return string text
function M.render(root, runtime, entries)
	local lines = { FORMAT, "runtime " .. runtime.version, "arch " .. runtime.arch, "gc64 " .. runtime.gc64,
		"root " .. root }
	local total = 0
	for _, entry in ipairs(entries) do
		lines[#lines + 1] = string.format("chunk %d %d %s %s", entry.offset, entry.length, entry.digest, entry.relative)
		total = entry.offset + entry.length
	end
	lines[#lines + 1] = string.format("bundle %d %d", total, #entries)
	lines[#lines + 1] = END_MARKER
	return table.concat(lines, "\n") .. "\n"
end

--- Parses and checks a manifest against this process and this tree.
--- @param text string Manifest bytes.
--- @param root string Physical installation root the daemon runs from.
--- @param runtime table M.runtime().
--- @param digest_length number Hex digits of a source SHA-256 (OWNERSHIP_HEX_LENGTH).
--- @return table|nil package { offsets = { [relative] = n }, lengths = { [relative] = n }, size, count }
--- @return string|nil reason Why the package cannot be trusted.
function M.parse(text, root, runtime, digest_length)
	-- Plain searches: a pattern class scan of the whole text cost 1.5 ms.
	if type(text) ~= "string" or text:sub(-1) ~= "\n" or text:find("\r", 1, true) or text:find("\0", 1, true) then
		return nil, "manifest is partial"
	end
	-- One pass, no table per line or per chunk: the daemon parses this at every
	-- boot, before anything else loads.
	local header = FORMAT .. "\n"
	if text:sub(1, #header) ~= header then return nil, "manifest format is unknown" end
	if text:sub(-(#END_MARKER + 2)) ~= "\n" .. END_MARKER .. "\n" then return nil, "manifest is partial" end
	local expected = header .. "runtime " .. runtime.version .. "\narch " .. runtime.arch .. "\ngc64 " .. runtime.gc64 .. "\n"
	if text:sub(1, #expected) ~= expected then
		local found = text:match("\nruntime ([^\n]*)\narch ([^\n]*)\ngc64 ([^\n]*)\n")
		return nil, "manifest was compiled for another runtime (" .. tostring(found) .. ")"
	end
	local root_line = "root " .. root .. "\n"
	if text:sub(#expected + 1, #expected + #root_line) ~= root_line then
		return nil, "manifest was compiled for another root"
	end
	local offsets, lengths, count, next_offset = {}, {}, 0, 0
	local position = #expected + #root_line + 1
	while text:sub(position, position + 5) == "chunk " do
		local stop = text:find("\n", position, true)
		local offset, length, digest, relative = text:sub(position + 6, stop - 1):match("^(%d+) (%d+) (%x+) (.+)$")
		offset, length = tonumber(offset), tonumber(length)
		if not offset or offset ~= next_offset or length < 1 or #digest ~= digest_length
			or not valid_relative(relative) or offsets[relative] then
			return nil, "manifest chunk " .. (count + 1) .. " is malformed"
		end
		offsets[relative], lengths[relative] = offset, length
		count, next_offset, position = count + 1, offset + length, stop + 1
	end
	local size, declared = text:sub(position):match("^bundle (%d+) (%d+)\n" .. END_MARKER .. "\n$")
	if tonumber(size) ~= next_offset or tonumber(declared) ~= count or count == 0 then
		return nil, "manifest totals do not match its chunks"
	end
	return { offsets = offsets, lengths = lengths, size = next_offset, count = count }
end





-- =============================
-- =============================
-- ======= 3/ Boot Decision ====
-- =============================
-- =============================

-- The outcome of this process's decision, read by report().
local _state = { decided = false, used = false, detail = nil, loaded = 0, chunks = 0 }

--- Declares the C functions the compiler uses, each on its own: a declaration
--- another module already made must not stop the others.
local function declare(ffi)
	for _, declaration in ipairs({ "int mkdir(const char *, unsigned int);", "int rmdir(const char *);",
		"int getpid(void);" }) do
		pcall(ffi.cdef, declaration)
	end
end

--- Reads a whole regular file.
local function read_file(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local content = file:read("*a")
	file:close()
	return content
end

--- Decides, once per process, whether this tree's modules load from bytecode,
--- and installs the searcher when they do.
--- @param script_dir string The entry point's directory as the daemon spells it.
--- @param options table|nil { runtime = table, searchers = table } test seams.
--- @return boolean used
function M.install(script_dir, options)
	assert(not _state.decided, "bytecode_package: the boot decision is taken once")
	assert(type(script_dir) == "string" and script_dir ~= "", "bytecode_package: the driver directory is required")
	options = options or {}
	_state.decided = true
	-- Only an absolute <root>/linux spelling is an installed tree's: a checkout
	-- runs as ./ergopti_hotstrings.lua or from static/ergopti_plus/linux, and
	-- neither carries the installer's receipt beside it.
	local root = script_dir:match("^(/.+)/linux$")
	if not root then return false end
	local names = M.schema_names(root)
	local receipt = names and io.open(root .. "/" .. names.receipt, "rb")
	if not receipt then return false end
	receipt:close()
	local directory = root .. "/" .. names.directory
	local text = read_file(directory .. "/" .. M.MANIFEST)
	if not text then _state.detail = "the installed tree has no bytecode manifest"; return false end
	local plan, reason = M.parse(text, root, options.runtime or M.runtime(), names.hex_length)
	if not plan then _state.detail = reason; return false end
	local bundle = io.open(directory .. "/" .. M.BUNDLE, "rb")
	if not bundle then _state.detail = "the bytecode bundle is missing"; return false end
	local size = bundle:seek("end")
	if size ~= plan.size then
		bundle:close()
		_state.detail = string.format("the bytecode bundle holds %s bytes, not %d", tostring(size), plan.size)
		return false
	end
	local driver_prefix, shared_prefix = script_dir .. "/", M.shared_lua_prefix(script_dir)
	if not shared_prefix then _state.detail = "the installed tree has no shared tree"; return false end
	local searchers = options.searchers or package.loaders or package.searchers
	--- Loads an application module from the bundle; any other module falls
	--- through to the next searcher, exactly as before.
	local function searcher(name)
		local filename = package.searchpath(name, package.path)
		if not filename then return "\n\tno bytecode for " .. name end
		-- The shared spelling starts with the driver's, so it is tested first.
		local relative
		if filename:sub(1, #shared_prefix) == shared_prefix then
			relative = "_shared/" .. filename:sub(#shared_prefix + 1)
		elseif filename:sub(1, #driver_prefix) == driver_prefix then
			relative = "linux/" .. filename:sub(#driver_prefix + 1)
		else
			return "\n\tnot an application module: " .. name
		end
		local offset, length = plan.offsets[relative], plan.lengths[relative]
		if not offset then
			error("bytecode_package: " .. relative .. " is not in the installed tree's bytecode package;"
				.. " the tree changed after installation: reinstall or update", 0)
		end
		assert(bundle:seek("set", offset) == offset, "bytecode_package: bundle seek failed")
		local bytes = bundle:read(length)
		assert(bytes and #bytes == length, "bytecode_package: bundle read failed for " .. relative)
		local chunk, load_error = loadstring(bytes)
		if not chunk then error("bytecode_package: " .. relative .. ": " .. tostring(load_error), 0) end
		_state.loaded = _state.loaded + 1
		return chunk, filename
	end
	-- After the preload searcher, before the Lua source searcher.
	table.insert(searchers, 2, searcher)
	_state.used, _state.chunks = true, plan.count
	return true
end

--- Logs the boot decision once the logger exists: one line when the bytecode
--- is used, one warning when an installed tree falls back to source.
--- @param info function info(fmt, ...) of the central logger.
--- @param warn function warn(fmt, ...) of the central logger.
function M.report(info, warn)
	if _state.used then
		info("Modules load from the installed bytecode package (%d chunk(s), %d loaded before the logger).",
			_state.chunks, _state.loaded)
	elseif _state.detail then
		warn("Modules load from source: %s. The next update recompiles the bytecode package.", _state.detail)
	end
end

--- The decision as data, for the boot summary and tests.
--- @return table state { used, detail, loaded, chunks }
function M.state()
	return { used = _state.used, detail = _state.detail, loaded = _state.loaded, chunks = _state.chunks }
end





-- =============================
-- =============================
-- ======= 4/ Compiler =========
-- =============================
-- =============================

--- Compiles an installed tree's application modules into <root>/.bytecode,
--- replacing any previous package only once the new one is complete.
--- @param root string Physical installation root.
--- @param sources table Dense { relative, digest } rows, every .lua file under linux/ and _shared/.
--- @return boolean ok
--- @return string|nil failure
function M.compile(root, sources)
	assert(type(root) == "string" and root:sub(1, 1) == "/", "bytecode_package: the root must be absolute")
	assert(type(sources) == "table" and #sources > 0, "bytecode_package: no source to compile")
	local names = M.schema_names(root)
	if not names then return false, "the tree has no ownership schema" end
	local ffi = require("ffi")
	declare(ffi)
	local staging = string.format("%s/%s.%d.tmp", root, names.directory, ffi.C.getpid())
	if ffi.C.mkdir(staging, tonumber("755", 8)) ~= 0 then return false, "cannot create " .. staging end
	local function discard(directory)
		os.remove(directory .. "/" .. M.BUNDLE)
		os.remove(directory .. "/" .. M.MANIFEST)
		ffi.C.rmdir(directory)
	end
	local bundle = io.open(staging .. "/" .. M.BUNDLE, "wb")
	if not bundle then discard(staging); return false, "cannot write the bytecode bundle" end
	table.sort(sources, function(a, b) return a.relative < b.relative end)
	local entries, offset = {}, 0
	for _, source in ipairs(sources) do
		local filename = M.runtime_filename(root, source.relative)
		local chunk, load_error = filename and loadfile(filename)
		if not chunk or not valid_relative(source.relative) or #tostring(source.digest) ~= names.hex_length then
			bundle:close()
			discard(staging)
			return false, "cannot compile " .. tostring(source.relative) .. ": " .. tostring(load_error)
		end
		local bytes = string.dump(chunk)
		assert(bundle:write(bytes))
		entries[#entries + 1] = { relative = source.relative, offset = offset, length = #bytes, digest = source.digest }
		offset = offset + #bytes
	end
	bundle:close()
	local manifest = io.open(staging .. "/" .. M.MANIFEST, "wb")
	if not manifest or not manifest:write(M.render(root, M.runtime(), entries)) then
		if manifest then manifest:close() end
		discard(staging)
		return false, "cannot write the bytecode manifest"
	end
	manifest:close()
	-- The previous package is retired before the new one takes its name, so a
	-- failure in between leaves no package rather than a stale one.
	local live = root .. "/" .. names.directory
	discard(live)
	local renamed, rename_error = os.rename(staging, live)
	if not renamed then discard(staging); return false, "cannot publish the bytecode package: " .. tostring(rename_error) end
	return true
end

--- Resets the process decision (tests only).
function M._reset_for_test()
	_state = { decided = false, used = false, detail = nil, loaded = 0, chunks = 0 }
end

return M
