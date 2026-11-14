--- tests/fixtures/native_logger_dst_retention.lua
--- Exercises native log retention at two explicitly specified New York DST instants.
local root = assert(arg[1])
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local driver = assert(source:match("^(.*)/tests/fixtures/native_logger_dst_retention%.lua$"))
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;" .. driver .. "/../_shared/?.lua;"
	.. driver .. "/../_shared/?/init.lua;" .. package.path

local time, date = os.time, os.date
local now
os.time = function(value) if value == nil then return now end; return time(value) end
os.date = function(format, stamp) return date(format, stamp or now) end
package.loaded["infra.timings"] = { count = function(group, key)
	assert(group == "logger" and key == "retention_days"); return 1
end }
local Sink = require("core.logger.engine.sink")
local logger = { set_sink = function() end, enable_repeat_collapsing = function() end,
	disable_repeat_collapsing = function() end }

local function scenario(label, timestamp, local_time, keep, remove)
	now = timestamp
	assert(date("%Y-%m-%d %H:%M %z", now) == local_time, "expected New York zone data")
	local dir = root .. "/" .. label
	assert(require("luv").fs_mkdir(dir, 448))
	local function write(day)
		local path = dir .. "/ErgoptiPlus_" .. day .. ".log"
		local file = assert(io.open(path, "wb")); assert(file:write("marker")); assert(file:close())
		return path
	end
	local kept, expired = write(keep), write(remove)
	assert(Sink.install(logger, { log_dir = dir, redaction_context = { home = "/home/test", user = "test" } }))
	local file = assert(io.open(kept, "rb")); assert(file:read("*a") == "marker"); assert(file:close())
	assert(io.open(expired, "rb") == nil, "prior calendar day must expire despite recent mtime")
	Sink.uninstall(logger)
end

-- 00:30 EDT, immediately after the 23-hour spring-transition calendar day.
scenario("spring", 1773030600, "2026-03-09 00:30 -0400", "2026-03-08", "2026-03-07")
-- 00:30 EST, immediately after the 25-hour fall-transition calendar day.
scenario("fall", 1793597400, "2026-11-02 00:30 -0500", "2026-11-01", "2026-10-31")
