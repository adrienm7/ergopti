--- tests/fixtures/native_toml_staging.lua
--- ==============================================================================
--- MODULE: Native TOML Staging Admission Fixture
--- DESCRIPTION:
--- The caller owns the directory and worker deadline. Real staging endpoints
--- exercise both direct codec publication and the Linux FileSystem route.
--- ==============================================================================

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_toml_staging%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path
require("compat.utf8").install()
local folder, kind, entry = assert(arg[1]), assert(arg[2]), assert(arg[3])
local path, target = folder .. "/source.toml", folder .. "/target"
local stage = path .. ".tmp"
local searchpath = package.searchpath
if entry == "portable" then
	-- Exercise module absence independently of a native owner which refuses IO.
	package.loaded["infra.regular_file_writer"] = nil
	package.preload["infra.regular_file_writer"] = function() error("portable fixture has no native writer") end
	package.searchpath = function(name, ...)
		if name == "infra.regular_file_writer" then return nil end
		return searchpath(name, ...)
	end
end
local Shell, Writer = require("adapters.shell_runner"), require("toml_codec.writer")
package.searchpath = searchpath
local adapter = entry == "adapter" and require("adapters.file_system") or nil
local function run(command) assert(Shell.run(command)) end
local function write(candidate, bytes)
	local file = assert(io.open(candidate, "wb")); assert(file:write(bytes)); assert(file:close())
end
local function read(candidate)
	local file = assert(io.open(candidate, "rb")); local bytes = assert(file:read("*a")); assert(file:close()); return bytes
end
local before, foreign = "[shortcuts]\nenabled = false\n", "foreign document\0\r\n"
write(path, before); write(target, foreign)
if kind == "fifo" then run("mkfifo -- " .. Shell.quote(stage))
elseif kind == "symlink" then run("ln -s -- " .. Shell.quote(target) .. " " .. Shell.quote(stage))
elseif kind == "hardlink" then run("ln -- " .. Shell.quote(target) .. " " .. Shell.quote(stage))
elseif kind == "regular" then write(stage, foreign)
elseif kind == "directory" then run("mkdir -- " .. Shell.quote(stage))
elseif kind ~= "missing" then error("unknown staging kind") end
local updates = { { section = "shortcuts", key = "enabled", value = true } }
local saved = Writer.batch_write(path, updates, adapter)
if kind == "missing" then assert(saved == true)
else
	assert(saved == false, "a pre-existing staging is never borrowed")
	assert(read(path) == before, "refused staging leaves the source exact")
	assert(read(target) == foreign, "refused links cannot overwrite another document")
	if kind == "fifo" then run("test -p " .. Shell.quote(stage))
	elseif kind == "directory" then run("test -d " .. Shell.quote(stage))
	else assert(read(stage) == foreign) end
	if kind == "symlink" then run("test -L " .. Shell.quote(stage)) end
	assert(os.remove(stage), "only this fixture removes its pre-existing endpoint")
	assert(Writer.batch_write(path, updates, adapter), "repair permits a later publication")
end
assert(require("toml_codec").decode(read(path)).shortcuts.enabled == true)
assert(read(target) == foreign)
run("test ! -e " .. Shell.quote(stage))
write(folder .. "/complete", "complete")
