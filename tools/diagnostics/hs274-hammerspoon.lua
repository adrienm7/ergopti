-- tools/diagnostics/hs274-hammerspoon.lua
-- Native fixture consumer with retained real app/privacy observations.

local root = assert(debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$"))
local config = assert(hs.json.read(root .. "/capture-config.json"))
local result = { runtime = "native Hammerspoon", coverage = "fixture_only", presses = {}, contexts = {}, errors = {} }
local owner = {}
_G.hs274_capture = owner

local function publish()
	result.error_count = #result.errors
	assert(hs.json.write(result, config.result, true, true), "Cannot publish native consumer result")
end

local function close_window()
	if not owner.window then return end
	local closed, detail = pcall(function() return owner.window:delete() end)
	if closed and detail ~= false then owner.window = nil
	else result.errors[#result.errors + 1] = "Native fixture window cleanup failed: " .. tostring(detail) end
end

local function prepare_modules()
	local driver = config.repo .. "/static/ergopti_plus/macos"
	local shared = config.repo .. "/static/ergopti_plus/_shared/lua"
	package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;"
		.. shared .. "/?.lua;" .. shared .. "/?/init.lua;" .. package.path
end

local function run()
	local ShellRunner = require("adapters.shell_runner")
	local JsonCodec = require("adapters.json_codec")
	local Delivery = require("modules.keylogger.physical_delivery")
	local Transport = require("modules.keylogger.physical_transport")
	local convert_ticks = require("modules.keylogger.physical_clock").new(config.clock)
	result.clock, result.clock_samples = config.clock, {}
	result.capture_started_ns = tostring(hs.timer.absoluteTime())
	result.context_observations = {}
	result.context_source = "native app/window/AX"
	owner.context = dofile(root .. "/hs274-context.lua").new(config.context_limit, result.context_observations, function(reason)
		result.errors[#result.errors + 1] = reason
		if owner.transport then owner.transport.stop() end
	end)
	owner.context.start()
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
			return owner.context.history.resolve(original_ns)
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
			if owner.probe then owner.probe.stop() end
			local stopped, detail = pcall(owner.context.stop)
			if not stopped then result.errors[#result.errors + 1] = tostring(detail) end
			result.context_stopped = stopped
			close_window()
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
	result.context_probe = {}
	owner.probe = dofile(root .. "/hs274-context-probe.lua").new(owner.window, result.context_observations,
		result.context_probe, function()
			assert(owner.transport.start(config.cli, { "--hs274-capture", "25" }), "Native capture did not start")
		end, function(reason)
			result.context_failure = owner.context.inspect(owner.window)
			result.errors[#result.errors + 1] = reason
			owner.transport.stop()
		end)
	owner.probe.start()
end

local function failed(err)
	result.errors[#result.errors + 1] = err
	owner.boot_pending = false
	owner.permission_pending = false
	if owner.permission then
		local stopped, detail = pcall(function() assert(owner.permission:stop() ~= false, "Native permission timer did not stop") end)
		if not stopped then result.errors[#result.errors + 1] = tostring(detail) end
	end
	if owner.boot then
		local stopped, detail = pcall(function() assert(owner.boot:stop() ~= false, "Native focus timer did not stop") end)
		if not stopped then result.errors[#result.errors + 1] = tostring(detail) end
	end
	if owner.transport then owner.transport.stop() end
	if owner.context then
		local stopped, detail = pcall(owner.context.stop)
		if not stopped then result.errors[#result.errors + 1] = tostring(detail) end
	end
	close_window()
	publish()
end

local function initialize()
	prepare_modules()
	local WebviewResult = require("adapters.webview_result")
	owner.window = assert(hs.webview.new({ x = 100, y = 100, w = 420, h = 160 }))
	assert(owner.window:windowStyle({ "titled", "closable" }), "Native fixture window style was refused")
	owner.window:allowTextEntry(true)
	owner.window:windowTitle("ErgoptiPlus HS274 input fixture")
	owner.window:navigationCallback(function(action, view)
		if action ~= "didFinishNavigation" or owner.boot_started then return end
		owner.boot_started = true
		local prepared, detail = xpcall(function()
			hs.focus(true)
			view:bringToFront(true)
			assert(view:show(), "Native fixture window did not become key")
			view:evaluateJavaScript("document.getElementById('input').focus(); document.activeElement.id === 'input'", function(focused, js_error)
				local completed, completion_error = xpcall(function()
					result.field_focus = { value = focused, value_type = type(focused), error = js_error,
						error_type = type(js_error), accessibility = hs.accessibilityState() }
					if WebviewResult.is_error(js_error) or focused ~= true then
						failed("Native fixture field did not acquire focus"); return
					end
					local focus_deadline = hs.timer.absoluteTime() + 2000000000
					owner.boot_pending = true
					owner.boot = assert(hs.timer.doEvery(0.02, function()
						if not owner.boot_pending then return end
						local ok, err = xpcall(function()
							local expected, focused_window = view:hswindow(), hs.window.focusedWindow()
							result.field_focus.fixture_id = expected:id()
							result.field_focus.focused_id = focused_window and focused_window:id()
							local app = hs.axuielement.applicationElementForPID(expected:application():pid())
							local element = app:attributeValue("AXFocusedUIElement")
							result.field_focus.role = element and element:attributeValue("AXRole")
							if not focused_window or focused_window:id() ~= expected:id() or result.field_focus.role ~= "AXTextField" then
								assert(hs.timer.absoluteTime() < focus_deadline, "Native fixture AX focus did not settle before its deadline")
								return
							end
							owner.boot_pending = false
							assert(owner.boot:stop() ~= false, "Native focus timer did not stop")
							run()
						end, debug.traceback)
						if not ok then failed(err) end
					end), "Native fixture boot timer was refused")
				end, debug.traceback)
				if not completed then failed(completion_error) end
			end)
		end, debug.traceback)
		if not prepared then failed(detail) end
	end)
	owner.window:html("<!doctype html><meta charset='utf-8'><title>HS274 input fixture</title><input id='input' aria-label='HS274 physical input'><input id='secret' type='password' aria-label='HS274 empty protected fixture'>")
	owner.window:show()
end

local function initialize_checked()
	local initialized, error_detail = xpcall(initialize, debug.traceback)
	if not initialized then failed(error_detail) end
end

local requested, request_error = xpcall(function()
	if hs.accessibilityState() then initialize_checked(); return end
	assert(hs.json.write({ requested = true }, config.permission_request, true, true), "Cannot publish permission request")
	hs.accessibilityState(true)
	local deadline
	owner.permission_pending = true
	owner.permission = assert(hs.timer.doEvery(0.1, function()
		if not owner.permission_pending then return end
		local ok, err = xpcall(function()
			assert(not hs.fs.attributes(config.stop), "Stopped while awaiting native accessibility permission")
			-- The supervisor owns bounded UI approval and signals completion before capture.
			if not hs.fs.attributes(config.permission_ready) then return end
			deadline = deadline or hs.timer.absoluteTime() + 2000000000
			if hs.accessibilityState() then
				owner.permission_pending = false
				assert(owner.permission:stop() ~= false, "Native permission timer did not stop")
				initialize_checked()
				return
			end
			assert(hs.timer.absoluteTime() < deadline, "Native accessibility permission was not granted")
		end, debug.traceback)
		if not ok then failed(err) end
	end), "Native permission timer was refused")
end, debug.traceback)
if not requested then failed(request_error) end
