--- install/compile_bytecode.lua

--- ==============================================================================
--- MODULE: Installed-Tree Bytecode Compiler
--- DESCRIPTION:
--- Compiles every application module of an installed tree (linux/ and
--- _shared/, their test trees excepted) into <root>/.bytecode with the luajit that runs this script,
--- which must be the one the daemon runs (infra/bytecode_package.lua). The
--- installer runs it after writing the ownership receipt, the updater after a
--- verified activation. A failure leaves no package, never a stale one: the
--- daemon then loads from source and says so once.
---
--- USAGE: luajit <root>/linux/install/compile_bytecode.lua <root>
--- Exit 0 = package published; 1 = refused, with one [bytecode] record.
--- ==============================================================================

local function refuse(code, detail)
	io.stderr:write(string.format("[bytecode] code=%s%s\n", code, detail and (" detail=" .. detail) or ""))
	os.exit(1)
end

local requested = arg and arg[1]
if type(requested) ~= "string" or requested == "" then refuse("usage") end
local ffi = require("ffi")
pcall(ffi.cdef, "char *realpath(const char *, char *);")
pcall(ffi.cdef, "void free(void *);")
local resolved = ffi.C.realpath(requested, nil)
if resolved == nil then refuse("root_unresolved") end
-- The daemon is launched through the physical path (install/launch.sh resolves
-- it with pwd -P), and every chunk keeps the name it is compiled under.
local root = ffi.string(resolved)
ffi.C.free(resolved)


-- The tree's own shared helpers, through the tree's own roots.
package.path = root .. "/linux/?.lua;" .. root .. "/_shared/?.lua;" .. root .. "/_shared/?/init.lua;"
	.. package.path
local quote = require("core.text.engine.utils_core").shell_quote
local package_owner = loadfile(root .. "/linux/infra/bytecode_package.lua")
if not package_owner then refuse("owner_missing") end
local BytecodePackage = package_owner()

-- One sha256sum run hashes every source; NUL-separated names never meet a
-- shell. LuaJIT does not report a pipe's exit status, so the pipeline prints it.
-- The test trees ship with the payload but the daemon never requires them.
local script = "set -o pipefail; cd " .. quote(root) .. " && find linux _shared"
	.. " \\( -path linux/tests -o -path _shared/tests/lua \\) -prune -o -type f -name '*.lua' -print0"
	.. " | LC_ALL=C sort -z | xargs -0 sha256sum --; printf '#exit %s\\n' \"$?\""
local listing = io.popen("bash -c " .. quote(script))
if not listing then refuse("listing_failed") end
local sources, status = {}, nil
for line in listing:lines() do
	local exit_status = line:match("^#exit (%d+)$")
	if exit_status then
		status = tonumber(exit_status)
	else
		local digest, relative = line:match("^(%x+)  (.+)$")
		if not digest or status ~= nil then listing:close(); refuse("listing_malformed") end
		sources[#sources + 1] = { relative = relative, digest = digest }
	end
end
listing:close()
if status ~= 0 or #sources == 0 then refuse("listing_failed", tostring(status)) end

local ok, failure = BytecodePackage.compile(root, sources)
if not ok then refuse("compile_failed", failure) end
print(string.format("[bytecode] code=published chunks=%d root=%s", #sources, root))
