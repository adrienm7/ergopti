--- tests/fixtures/native_crash_notice_source.lua
--- ==============================================================================
--- MODULE: Native Crash Notice Source Fixture
--- DESCRIPTION:
--- Exercises the actual startup notice against native special endpoints and
--- real stream refusals. The parent owns the deadline and filesystem cleanup.
--- ==============================================================================

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_crash_notice_source%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path
require("compat.utf8").install()

local folder, kind = assert(arg[1]), assert(arg[2])
local Shell = require("adapters.shell_runner")
local Writer = require("infra.regular_file_writer")
local Reader = require("infra.regular_file_reader")
local dump, marker, target = folder .. "/crash_probe.json", folder .. "/.last_crash_notice", folder .. "/.target"
local function write(path, bytes)
	local fh = assert(io.open(path, "wb")); assert(fh:write(bytes)); assert(fh:close())
end
local function read(path)
	local fh = assert(io.open(path, "rb")); local bytes = assert(fh:read("*a")); assert(fh:close()); return bytes
end
local function run(command) assert(Shell.run(command), "native fixture command failed") end
local bytes = require("json").encode({ module = "native_probe", error_msg = "marker" })
write(dump, bytes)
local endpoint = kind:find("dump", 1, true) and dump or marker
if kind:find("fifo", 1, true) then
	os.remove(endpoint)
	if kind:find("symlink", 1, true) then
		run("mkfifo -- " .. Shell.quote(target))
		run("ln -s -- " .. Shell.quote(target) .. " " .. Shell.quote(endpoint))
	else run("mkfifo -- " .. Shell.quote(endpoint)) end
elseif kind == "dump-symlink" then
	assert(os.rename(dump, target)); run("ln -s -- " .. Shell.quote(target) .. " " .. Shell.quote(dump))
end
if kind == "marker-unreadable" or kind == "marker-read-close-refusal" then write(marker, "older\n") end
if kind == "marker-unreadable" then run("chmod 000 -- " .. Shell.quote(marker)) end
if kind == "dump-unreadable" then run("chmod 000 -- " .. Shell.quote(dump)) end

package.loaded["logger.shim"] = setmetatable({}, { __index = function() return function() end end })
package.loaded["infra.paths"] = { shared = function(path) return root .. "/../_shared/" .. path end }
package.loaded["adapters.storage"] = { get = function() return true end }
package.loaded["infra.manifest_reader"] = { default_for = function() return true end }
local bridge = require("ui.error_dialog.bridge")
assert(bridge.init())
local scheduled = 0
bridge.defer = function() scheduled = scheduled + 1; return true end
if kind == "marker-close-refusal" or kind == "marker-replaced" or kind == "marker-write-refusal" then
	local open = Writer.open
	Writer.open = function(path, mode)
		local stream, detail, errno = open(path, mode)
		if path ~= marker or not stream then return stream, detail, errno end
		return {
			write = function(_, content)
				if kind == "marker-write-refusal" then return nil, "injected write refusal" end
				return stream:write(content)
			end,
			close = function()
				assert(stream:close())
				if kind == "marker-replaced" then assert(os.remove(marker)); write(marker, "foreign marker\n") end
				return kind ~= "marker-close-refusal"
			end,
		}
	end
elseif kind == "dump-close-refusal" or kind == "marker-read-close-refusal" then
	local open = Reader.open_source
	Reader.open_source = function(path)
		local stream, detail, errno = open(path)
		local expected = kind == "dump-close-refusal" and dump or marker
		if path ~= expected or not stream then return stream, detail, errno end
		return { read = function(_, ...) return stream:read(...) end,
			close = function() assert(stream:close()); return nil, "injected close refusal" end }
	end
end
local allowed = kind == "regular" or kind == "dump-symlink"
assert(bridge.notify_last_crash(folder) == allowed, "notice must acknowledge only admitted sources and a retained marker")
assert(scheduled == (allowed and 1 or 0), "refused native acquisition never queues a notice")
if allowed then
	assert(read(marker) == "crash_probe.json\n")
	bridge._reset(); assert(bridge.init())
	assert(bridge.notify_last_crash(folder) == false and scheduled == 1, "retained marker suppresses the same notice")
end
if kind == "marker-replaced" then assert(read(marker) == "foreign marker\n", "foreign successor is retained") end
write(folder .. "/complete", "complete")
