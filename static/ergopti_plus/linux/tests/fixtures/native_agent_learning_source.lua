--- tests/fixtures/native_agent_learning_source.lua
--- ==============================================================================
--- MODULE: Agent Learning Native Source Fixture
--- DESCRIPTION:
--- A deadline-owned child exercises real special files without a FIFO peer.
--- Its caller owns cleanup, including when an old blocking open is terminated.
--- ==============================================================================

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_agent_learning_source%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path
require("compat.utf8").install()

local folder, kind, mode = assert(arg[1]), assert(arg[2]), assert(arg[3])
local path, target = folder .. "/source", folder .. "/target"
local Shell = require("adapters.shell_runner")
local Json = require("json")
local Learning = require("modules.llm.agent_learning")
local function run(command) assert(Shell.run(command), "fixture command failed: " .. command) end
local function write(candidate, bytes)
	local file = assert(io.open(candidate, "wb")); assert(file:write(bytes)); assert(file:close())
end
local function read(candidate)
	local file = assert(io.open(candidate, "rb")); local bytes = assert(file:read("*a")); assert(file:close()); return bytes
end
local bytes = '{"version":1,"apps":{"Mail":{"used":7,"thresholds":{"calendar":0.2}}}}\r\n'
local regular = kind == "regular" or kind == "regular-symlink"
if kind == "fifo" then run("mkfifo -- " .. Shell.quote(path))
elseif kind == "fifo-symlink" then
	run("mkfifo -- " .. Shell.quote(target)); run("ln -s -- " .. Shell.quote(target) .. " " .. Shell.quote(path))
elseif kind == "directory" then run("mkdir -- " .. Shell.quote(path))
elseif kind == "regular" then write(path, bytes)
elseif kind == "regular-symlink" then
	write(target, bytes); run("ln -s -- " .. Shell.quote(target) .. " " .. Shell.quote(path))
else error("unknown fixture kind") end

Learning._reset_for_test({ path = path, scheduler = {
	after = function() return { armed = true } end, cancel = function() return true end,
} })
local config = assert(Json.decode_lossless(read(root .. "/../_shared/modules/llm/agent.json")))
local result = Learning[mode](config, "Mail", "calendar", true)
if regular then
	assert(result == 0.2, "regular sources keep the learned threshold")
	assert(read(path) == bytes, "admission preserves every source byte")
	if kind == "regular-symlink" then
		run("test -L " .. Shell.quote(path)); assert(read(target) == bytes)
	end
else
	assert(result == config.system1.threshold, "unavailable sources return the default")
	assert(Learning.record(config, "Mail", "calendar", true) == config.system1.threshold)
	assert(Learning.flush() == false, "unavailable sources never authorize publication")
	local flag = kind == "directory" and "-d" or "-p"
	run("test " .. flag .. " " .. Shell.quote(path))
	if kind == "fifo-symlink" then run("test -L " .. Shell.quote(path)) end
	run("test ! -e " .. Shell.quote(path .. ".corrupt"))
	run("test ! -e " .. Shell.quote(path .. ".tmp"))
	assert(os.remove(path)); if kind == "fifo-symlink" then assert(os.remove(target)) end
	write(path, bytes)
	assert(Learning.threshold(config, "Mail", "calendar") == 0.2, "a repaired source is retried")
	local learned = Learning.record(config, "Mail", "calendar", true)
	assert(Learning.flush())
	local saved = assert(Json.decode_lossless(read(path)))
	assert(saved.apps.Mail.used == 8, "blocked calls never advance the learned sequence")
	assert(saved.apps.Mail.thresholds.calendar == learned)
end
write(folder .. "/complete", "complete")
