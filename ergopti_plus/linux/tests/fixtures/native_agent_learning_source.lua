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
local original = path
local writing, foreign = mode == "flush", "foreign document\0\r\n"
if writing then write(path, bytes); write(target, foreign); path = path .. ".tmp" end
local regular = kind == "regular" or kind == "regular-symlink"
if kind == "fifo" then run("mkfifo -- " .. Shell.quote(path))
elseif kind == "fifo-symlink" then
	run("mkfifo -- " .. Shell.quote(target)); run("ln -s -- " .. Shell.quote(target) .. " " .. Shell.quote(path))
elseif kind == "directory" then run("mkdir -- " .. Shell.quote(path))
elseif kind == "regular" then write(path, writing and foreign or bytes)
elseif kind == "regular-symlink" then
	write(target, writing and foreign or bytes); run("ln -s -- " .. Shell.quote(target) .. " " .. Shell.quote(path))
elseif writing and kind == "hardlink" then run("ln -- " .. Shell.quote(target) .. " " .. Shell.quote(path))
elseif writing and kind == "missing" then -- The uncontended staging control starts absent.
else error("unknown fixture kind") end

Learning._reset_for_test({ path = original, scheduler = {
	after = function() return { armed = true } end, cancel = function() return true end,
} })
local config = assert(Json.decode_lossless(read(root .. "/../_shared/modules/llm/agent.json")))
if writing then
	local learned = Learning.record(config, "Mail", "calendar", true)
	local saved = Learning.flush()
	if kind == "missing" then assert(saved == true, "an absent staging is acquired")
	else
		assert(saved == false, "a pre-existing staging is never borrowed")
		assert(read(original) == bytes, "failed staging never replaces the committed source")
		assert(read(target) == foreign, "a staging link never destroys another file")
		if kind == "regular" or kind == "regular-symlink" or kind == "hardlink" then assert(read(path) == foreign) end
		if kind == "regular-symlink" then run("test -L " .. Shell.quote(path))
		elseif kind == "fifo" then run("test -p " .. Shell.quote(path))
		elseif kind == "directory" then run("test -d " .. Shell.quote(path)) end
		assert(os.remove(path), "only the fixture owner removes its pre-existing staging")
		assert(Learning.flush(), "repair admits the retained learning without another record")
	end
	local stored = assert(Json.decode_lossless(read(original)))
	assert(stored.apps.Mail.used == 8)
	assert(stored.apps.Mail.thresholds.calendar == learned)
	assert(read(target) == foreign)
	write(folder .. "/complete", "complete")
	return
end
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
