--- tests/fixtures/native_event_loop_close_ack.lua

--- Proves the native loop retires its timer and idle before returning.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. root .. "/../_shared/?.lua;" .. root .. "/../_shared/?/init.lua;" .. package.path
local uv = require("luv")
local loop = require("core.events.loop")
loop.run({ onIdle = function() loop.stop() end, onPeriodic = function() end })
local remaining = 0
uv.walk(function() remaining = remaining + 1 end)
assert(remaining == 0, "event loop returned before its native handles closed")
print("Native loop close callbacks acknowledged.")
