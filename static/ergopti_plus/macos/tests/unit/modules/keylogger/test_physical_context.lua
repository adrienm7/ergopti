--- tests/unit/modules/keylogger/test_physical_context.lua

--- Exercises retained context ownership independently of asynchronous delivery order.
local helpers = require("tests.helpers")
local Context = require("modules.keylogger.physical_context")
local Delivery = require("modules.keylogger.physical_delivery")
local Frames = require("tests.support.physical_stream_frames")

local function rejects(callback, message)
	local ok, err = pcall(callback)
	helpers.assert_eq(ok, false)
	helpers.assert_true(tostring(err):find(message, 1, true) ~= nil, tostring(err))
end

helpers.describe("physical context (hs274)", function()
	helpers.it("resolves delayed records using copied app and wall-clock observations", function()
		local context = Context.new(3, tostring)
		local first = { allowed = true, app = "Original", epoch = 1000 }
		context.observe(1000000000, first)
		first.app, first.epoch = "Mutated", 9000
		context.observe(3000000000, { allowed = true, app = "Current", epoch = 2000 })
		helpers.assert_eq(context.resolve(2000000000), { allowed = true, app = "Original", timestamp = "1001.0" })
		helpers.assert_eq(context.resolve(3000000000), { allowed = true, app = "Current", timestamp = "2000.0" })
		local resolved = context.resolve(2000000000)
		resolved.app = "Replaced"
		helpers.assert_eq(context.resolve(2000000000).app, "Original")
	end)

	helpers.it("applies original privacy decisions across out-of-order device timestamps", function()
		local context = Context.new(3, tostring)
		context.observe(100, { allowed = true, app = "Public", epoch = 1000 })
		context.observe(200, { allowed = false, app = "Do not retain this private app" })
		context.observe(300, { allowed = true, app = "Resumed", epoch = 1001 })
		local emitted = {}
		local receiver = Delivery.new({ batch_limit = 3, admit = function() return "context-test" end,
			context = function(ticks) return context.resolve(assert(math.tointeger(tonumber(ticks)))) end,
			keycode = function(usage) return ({ [41] = 53, [44] = 49 })[usage] end,
			emit = function(press) emitted[#emitted + 1] = press end,
		})
		local frames = Frames.new("context-test", "1", { "1", "2" })
		Frames.start(receiver, frames)
		local opening = frames.ready
		local rows = {}
		for index, data in ipairs({ { 350, 41, "2" }, { 150, 44, "1" }, { 250, 41, "1" } }) do
			rows[index] = { sequence = tostring(index), timestamp = tostring(data[1]), device = data[3],
				has_page = true, has_usage = true, page = 7, usage = data[2], value = "1",
				has_cookie = true, cookie = data[2] }
		end
		opening.kind, opening.records = "batch", rows
		helpers.assert_eq(receiver.deliver(opening), "3")
		helpers.assert_eq(#emitted, 2)
		helpers.assert_eq({ emitted[1].app, emitted[1].keycode }, { "Resumed", 53 })
		helpers.assert_eq({ emitted[2].app, emitted[2].keycode }, { "Public", 49 })
	end)

	helpers.it("rejects missing history and retires on capacity or ordering failure", function()
		local context = Context.new(1, tostring)
		rejects(function() context.resolve(0) end, "predates retained context")
		context.observe(10, { allowed = false })
		rejects(function() context.resolve(9) end, "predates retained context")
		rejects(function() context.observe(11, { allowed = true, app = "New", epoch = 1 }) end, "history exhausted")
		rejects(function() context.resolve(10) end, "retired")
		for _, next_time in ipairs({ 9, 10 }) do
			context = Context.new(2, tostring)
			context.observe(10, { allowed = false })
			rejects(function() context.observe(next_time, { allowed = false }) end, "not ordered")
			rejects(function() context.resolve(10) end, "retired")
		end
	end)

	helpers.it("fences teardown re-entered by timestamp formatting", function()
		local context
		context = Context.new(1, function() context.stop(); return "formatted" end)
		context.observe(10, { allowed = true, app = "Public", epoch = 1 })
		rejects(function() context.resolve(10) end, "revoked during formatting")
		rejects(function() context.observe(20, { allowed = false }) end, "retired")
	end)
end)
