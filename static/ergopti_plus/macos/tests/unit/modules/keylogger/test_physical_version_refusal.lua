--- tests/unit/modules/keylogger/test_physical_version_refusal.lua

--- Keeps unsupported producer versions distinct from corrupt stream failures.
local helpers = require("tests.helpers")
local Delivery = require("modules.keylogger.physical_delivery")
local Transport = require("modules.keylogger.physical_transport")
local Frames = require("tests.support.physical_stream_frames")

--- Runs a real receiver and transport against one independently altered opening.
---@param alter function Mutates the explicit producer opening.
---@return table observed Recorded native and consumer effects.
local function refusal(alter)
	local observed = { errors = {}, writes = {}, credits = 0, admissions = 0, stops = 0 }
	local frames = Frames.new("producer", "1")
	alter(frames.opened)
	local receiver = Delivery.new({ batch_limit = 8,
		admit = function() observed.admissions = observed.admissions + 1; return "capture" end,
		context = function() error("A refused opening cannot resolve context") end,
		keycode = function() error("A refused opening cannot map keys") end,
		emit = function() observed.credits = observed.credits + 1 end,
	})
	local task = {}
	function task.start() return true end
	function task.set_input(bytes) observed.writes[#observed.writes + 1] = bytes; return true end
	function task.terminate() observed.stops = observed.stops + 1; return true, "pending" end
	function task.onSettled(callback) observed.settle = callback; return true end
	local transport = Transport.new({ receiver = receiver, frame_limit = 16,
		spawn = function(_, _, _, chunk) observed.chunk = chunk; return task end,
		decode = function() return frames.opened end,
		encode = function() error("A refused opening cannot acknowledge") end,
		on_error = function(message, failure)
			observed.errors[#observed.errors + 1] = { message = message, failure = failure }
		end,
		on_settled = function() observed.settled = true end,
	})
	helpers.assert_true(transport.start("/fixture/producer", {}))
	observed.chunk(nil, "opening\n")
	observed.chunk(nil, "opening\n")
	helpers.assert_eq(#observed.errors, 1)
	helpers.assert_eq(observed.admissions, 0)
	helpers.assert_eq(observed.credits, 0)
	helpers.assert_eq(observed.writes, {})
	helpers.assert_eq(observed.stops, 1)
	helpers.assert_eq(transport.isSettled(), false)
	observed.settle()
	helpers.assert_true(transport.isSettled())
	return observed
end

helpers.describe("physical producer version refusal", function()
	helpers.it("classifies a newer opening version before coverage admission", function()
		local observed = refusal(function(opening) opening.version = 2 end)
		local failure = observed.errors[1].failure
		helpers.assert_eq(type(failure), "table", "Unsupported opening must carry a typed refusal")
		helpers.assert_eq(failure.code, "unsupported_opening_version")
		helpers.assert_eq(failure.expected, 1)
		helpers.assert_eq(failure.received, 2)
	end)

	helpers.it("classifies historical baseline v1 without admitting its capture", function()
		local observed = refusal(function(opening) opening.baseline.version = 1 end)
		local failure = observed.errors[1].failure
		helpers.assert_eq(type(failure), "table", "Unsupported baseline must carry a typed refusal")
		helpers.assert_eq(failure.code, "unsupported_baseline_version")
		helpers.assert_eq(failure.expected, 2)
		helpers.assert_eq(failure.received, 1)
		helpers.assert_true(observed.errors[1].message:find("Unsupported physical baseline version", 1, true) ~= nil)
	end)

	helpers.it("keeps malformed version fields distinct from unsupported producers", function()
		for _, value in ipairs({ false, "1", 1.5 }) do
			local observed = refusal(function(opening) opening.version = value end)
			helpers.assert_eq(type(observed.errors[1].failure), "string")
		end
	end)
end)
