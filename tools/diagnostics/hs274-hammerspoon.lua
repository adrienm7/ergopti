-- tools/diagnostics/hs274-hammerspoon.lua
-- Native fixture consumer. The supplied context is synthetic, never arrival-time app state.

local root = assert(debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$"))
local config = assert(hs.json.read(root .. "/capture-config.json"))
local result = { runtime = "native Hammerspoon", coverage = "fixture_only", presses = {}, contexts = {}, errors = {} }
local owner = {}
_G.hs274_capture = owner

local function publish()
	result.error_count = #result.errors
	assert(hs.json.write(result, config.result, true, true), "Cannot publish native consumer result")
end

local function run()
	local driver = config.repo .. "/static/ergopti_plus/macos"
	local shared = config.repo .. "/static/ergopti_plus/_shared/lua"
	package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;"
		.. shared .. "/?.lua;" .. shared .. "/?/init.lua;" .. package.path
	local ShellRunner = require("adapters.shell_runner")
	local JsonCodec = require("adapters.json_codec")
	local Delivery = require("modules.keylogger.physical_delivery")
	local Transport = require("modules.keylogger.physical_transport")
	local convert_ticks = require("modules.keylogger.physical_clock").new(config.clock)
	result.clock, result.clock_samples = config.clock, {}
	result.capture_started_ns = tostring(hs.timer.absoluteTime())
	local state = require("modules.keylogger.aggregator.state")
	local core = require("modules.keylogger.aggregator.core")
	local events = require("modules.keylogger.aggregator.events")
	state.initialized, state.device_id = true, "hs274-native-fixture"
	core.reset_batch()
	core.reset_ngram_ctx()
	local receiver = Delivery.new({ batch_limit = config.batch_limit,
		admit = function(frame)
			assert(frame.coverage == "fixture_only", "Unexpected native coverage")
			result.opened = frame
			return frame.incarnation .. "/" .. frame.lease
		end,
		context = function(timestamp, device)
			result.contexts[#result.contexts + 1] = { timestamp = timestamp, device = device }
			local original_ns, observed_ns = convert_ticks(timestamp), hs.timer.absoluteTime()
			assert(original_ns <= observed_ns, "Physical timestamp is later than its delivery")
			result.clock_samples[#result.clock_samples + 1] = {
				original_ns = tostring(original_ns), observed_ns = tostring(observed_ns),
			}
			return { allowed = true, app = "HS274 synthetic context", timestamp = "2026-09-12 12:00:00.000" }
		end,
		keycode = function(usage) return ({ [41] = 53, [44] = 49 })[usage] end,
		emit = function(press)
			result.presses[#result.presses + 1] = press
			press.action = "physical_press"
			events.walk_system_event(press)
		end,
	})
	assert(not hs.fs.attributes(config.stream) and not hs.fs.attributes(config.diagnostics), "Capture outputs already exist")
	local stream = assert(io.open(config.stream, "w"))
	local diagnostics = assert(io.open(config.diagnostics, "w"))
	local function retain_diagnostics(stderr)
		if stderr and stderr ~= "" then assert(diagnostics:write(stderr)); assert(diagnostics:flush()) end
	end
	owner.transport = Transport.new({ receiver = receiver, frame_limit = config.frame_limit,
		spawn = function(executable, arguments, done, chunk)
			return ShellRunner.spawn(executable, arguments, function(code, stdout, stderr)
				result.exit = code
				local retained, err = pcall(retain_diagnostics, stderr)
				if not retained then result.errors[#result.errors + 1] = tostring(err) end
				done(code, stdout, stderr)
			end, function(task, stdout, stderr)
				local retained, err = pcall(retain_diagnostics, stderr)
				if not retained then
					result.errors[#result.errors + 1] = tostring(err)
					owner.transport.stop()
					return true
				end
				return chunk(task, stdout, stderr)
			end)
		end,
		decode = function(line)
			assert(stream:write(line, "\n")); assert(stream:flush())
			return JsonCodec.decode(line)
		end,
		encode = JsonCodec.encode,
		on_error = function(reason) result.errors[#result.errors + 1] = reason end,
		on_settled = function()
			result.settled = true
			result.counts = {}
			for _, row in pairs(state.agg_batch.kc_ngram) do
				result.counts[tostring(row.keycode)] = (result.counts[tostring(row.keycode)] or 0) + row.count
			end
			assert(stream:close()); assert(diagnostics:close())
			if owner.timer then owner.timer:stop() end
			-- Failure reporting can follow synchronous settlement in the same callback.
			owner.publication = hs.timer.doAfter(0, publish)
		end,
	})
	owner.timer = assert(hs.timer.doEvery(0.02, function()
		if hs.fs.attributes(config.stop, "mode") == "file" then
			result.stop_requested = true
			owner.transport.stop()
		end
	end))
	assert(owner.transport.start(config.cli, { "--hs274-capture", "25" }), "Native capture did not start")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
	result.errors[#result.errors + 1] = err
	if owner.transport then owner.transport.stop() end
	publish()
end
